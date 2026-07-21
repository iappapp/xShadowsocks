import Foundation
import os

actor MihomoRuntimeManager {
    private  var onStateChange: (@Sendable (MihomoRuntimeState) -> Void)?

    private let bridge: any MihomoCoreBridge
    private let fileManager: FileManager
    private let workingDirectoryURL: URL
    private let countryMMDBFileName = "Country.mmdb"
    private let countryMMDBDownloadURL = URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb")!
    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "MihomoRuntime")

    private var currentSnapshot: MihomoRuntimeSnapshot?

    init(
        bridge: any MihomoCoreBridge,
        workingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.bridge = bridge
        self.workingDirectoryURL = workingDirectoryURL
        self.fileManager = fileManager
        logger.info("init workdir=\(workingDirectoryURL.path, privacy: .public)")
    }

    func setOnStateChange(_ handler: (@Sendable (MihomoRuntimeState) -> Void)?) {
        onStateChange = handler
    }

    func start(with request: MihomoBootstrapRequest) async throws {
        notify(.starting)
        logger.info("runtime start begin")

        do {
            let paths = try resolveDownloadedConfigPaths()
            logger.info("resolved config=\(paths.configPath, privacy: .public)")
            _ = try await ensureCountryMMDB()
            logger.info("Country.mmdb ready")

            if bridge.isRunning {
                logger.info("bridge already running -> reload")
                try bridge.reload(configPath: paths.configPath)
            } else {
                logger.info("bridge start")
                try bridge.start(configPath: paths.configPath, workingDirectory: paths.workingDirectory)
            }

            let ports = Self.readPortHints(from: URL(fileURLWithPath: paths.configPath), fallback: request)
            let snapshot = MihomoRuntimeSnapshot(
                configPath: paths.configPath,
                workingDirectory: paths.workingDirectory,
                mixedPort: ports.mixedPort,
                socksPort: ports.socksPort,
                externalController: ports.externalController
            )
            currentSnapshot = snapshot
            logger.info("runtime running mixed=\(ports.mixedPort) socks=\(ports.socksPort) ctl=\(ports.externalController, privacy: .public)")
            notify(.running(snapshot))
        } catch {
            logger.error("runtime start failed: \(error.localizedDescription, privacy: .public)")
            notify(.failed(error.localizedDescription))
            throw error
        }
    }

    func reload(with request: MihomoBootstrapRequest) async throws {
        logger.info("runtime reload begin")
        do {
            let paths = try resolveDownloadedConfigPaths()
            _ = try await ensureCountryMMDB()
            try bridge.reload(configPath: paths.configPath)

            let ports = Self.readPortHints(from: URL(fileURLWithPath: paths.configPath), fallback: request)
            let snapshot = MihomoRuntimeSnapshot(
                configPath: paths.configPath,
                workingDirectory: paths.workingDirectory,
                mixedPort: ports.mixedPort,
                socksPort: ports.socksPort,
                externalController: ports.externalController
            )
            currentSnapshot = snapshot
            logger.info("runtime reload ok mixed=\(ports.mixedPort)")
            notify(.running(snapshot))
        } catch {
            logger.error("runtime reload failed: \(error.localizedDescription, privacy: .public)")
            notify(.failed(error.localizedDescription))
            throw error
        }
    }

    func stop() async throws {
        logger.info("runtime stop begin")
        if !bridge.isRunning {
            currentSnapshot = nil
            notify(.stopped)
            logger.info("runtime already stopped")
            return
        }

        do {
            try bridge.stop()
        } catch {
            logger.error("runtime stop failed: \(error.localizedDescription, privacy: .public)")
            notify(.failed(error.localizedDescription))
            throw error
        }

        currentSnapshot = nil
        notify(.stopped)
        logger.info("runtime stop ok")
    }

    func currentState() -> MihomoRuntimeState {
        if let snapshot = currentSnapshot {
            return .running(snapshot)
        }
        return bridge.isRunning ? .starting : .stopped
    }

    /// Uses the downloaded/imported YAML file as-is (no rebuild / concat).
    /// The filename is the active one tracked in `MihomoConfigFileStore`.
    private func resolveDownloadedConfigPaths() throws -> (configPath: String, workingDirectory: String) {
        try ensureDirectoryIfNeeded(workingDirectoryURL)
        let configFileName = MihomoConfigFileStore.activeFileName
        let configURL = workingDirectoryURL.appendingPathComponent(configFileName)
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw MihomoRuntimeError.missingConfigFile
        }
        return (configURL.path, workingDirectoryURL.path)
    }

    /// Best-effort port/controller hints for status UI; mihomo itself reads the file.
    private static func readPortHints(
        from configURL: URL,
        fallback: MihomoBootstrapRequest
    ) -> (mixedPort: Int, socksPort: Int, externalController: String) {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return (
                fallback.mixedPort,
                fallback.socksPort,
                "127.0.0.1:\(fallback.externalControllerPort)"
            )
        }

        var mixed = fallback.mixedPort
        var socks = fallback.socksPort
        var controller = "127.0.0.1:\(fallback.externalControllerPort)"

        for rawLine in text.components(separatedBy: .newlines) {
            guard !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let sep = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "mixed-port":
                if let port = Int(value) { mixed = port }
            case "socks-port":
                if let port = Int(value) { socks = port }
            case "port":
                // Classic Clash HTTP port; use as mixed fallback when mixed-port absent.
                if mixed == fallback.mixedPort, let port = Int(value) { mixed = port }
            case "external-controller":
                if !value.isEmpty { controller = value }
            default:
                break
            }
        }

        return (mixed, socks, controller)
    }

    private func ensureDirectoryIfNeeded(_ directoryURL: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw NSError(domain: "MihomoRuntimeManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "工作目录路径不是文件夹: \(directoryURL.path)"])
            }
            return
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func notify(_ state: MihomoRuntimeState) {
        onStateChange?(state)
    }

    private func ensureCountryMMDB() async throws -> URL {
        try ensureDirectoryIfNeeded(workingDirectoryURL)
        let destinationURL = workingDirectoryURL.appendingPathComponent(countryMMDBFileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        if let bundledURL = Bundle.main.url(forResource: "Country", withExtension: "mmdb") {
            do {
                try fileManager.copyItem(at: bundledURL, to: destinationURL)
                return destinationURL
            } catch {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
            }
        }

        return try await downloadCountryMMDB()
    }

    private func downloadCountryMMDB() async throws -> URL {

        var request = URLRequest(url: countryMMDBDownloadURL)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "MihomoRuntimeManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "下载 Country.mmdb 失败，状态码: \(http.statusCode)"]
            )
        }

        let destinationURL = workingDirectoryURL.appendingPathComponent(countryMMDBFileName)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }
}

extension MihomoRuntimeManager {
    static func makeAppGroupWorkingDirectory(appGroupID: String, folderName: String = "mihomo") throws -> URL {
        guard let baseURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw NSError(domain: "MihomoRuntimeManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法获取 App Group 目录: \(appGroupID)"])
        }
        print("makeAppGroupWorkingDirectory appGroupID: \(appGroupID)")
        
        return baseURL.appendingPathComponent(folderName, isDirectory: true)
    }
}
