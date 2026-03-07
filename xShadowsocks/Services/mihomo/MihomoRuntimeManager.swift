import Foundation

actor MihomoRuntimeManager {
    private  var onStateChange: (@Sendable (MihomoRuntimeState) -> Void)?

    private let bridge: any MihomoCoreBridge
    private let configBuilder = MihomoConfigBuilder()
    private let fileManager: FileManager
    private let workingDirectoryURL: URL
    private let countryMMDBFileName = "Country.mmdb"
    private let countryMMDBDownloadURL = URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb")!

    private var currentSnapshot: MihomoRuntimeSnapshot?

    init(
        bridge: any MihomoCoreBridge,
        workingDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.bridge = bridge
        self.workingDirectoryURL = workingDirectoryURL
        self.fileManager = fileManager
    }

    func setOnStateChange(_ handler: (@Sendable (MihomoRuntimeState) -> Void)?) {
        onStateChange = handler
    }

    func start(with request: MihomoBootstrapRequest) async throws {
        notify(.starting)

        do {
            let rendered = try configBuilder.build(request: request)
            let paths = try writeConfig(rendered.yamlText)
            _ = try await ensureCountryMMDB()

            if bridge.isRunning {
                try bridge.reload(configPath: paths.configPath)
            } else {
                try bridge.start(configPath: paths.configPath, workingDirectory: paths.workingDirectory)
            }

            let snapshot = MihomoRuntimeSnapshot(
                configPath: paths.configPath,
                workingDirectory: paths.workingDirectory,
                mixedPort: request.mixedPort,
                socksPort: request.socksPort,
                externalController: rendered.externalController
            )
            currentSnapshot = snapshot
            notify(.running(snapshot))
        } catch {
            notify(.failed(error.localizedDescription))
            throw error
        }
    }

    func reload(with request: MihomoBootstrapRequest) async throws {
        let rendered = try configBuilder.build(request: request)
        let paths = try writeConfig(rendered.yamlText)
        _ = try await ensureCountryMMDB()
        try bridge.reload(configPath: paths.configPath)

        let snapshot = MihomoRuntimeSnapshot(
            configPath: paths.configPath,
            workingDirectory: paths.workingDirectory,
            mixedPort: request.mixedPort,
            socksPort: request.socksPort,
            externalController: rendered.externalController
        )
        currentSnapshot = snapshot
        notify(.running(snapshot))
    }

    func stop() async throws {
        if !bridge.isRunning {
            currentSnapshot = nil
            notify(.stopped)
            return
        }

        do {
            try bridge.stop()
        } catch {
            notify(.failed(error.localizedDescription))
            throw error
        }

        currentSnapshot = nil
        notify(.stopped)
    }

    func currentState() -> MihomoRuntimeState {
        if let snapshot = currentSnapshot {
            return .running(snapshot)
        }
        return bridge.isRunning ? .starting : .stopped
    }

    private func writeConfig(_ yaml: String) throws -> (configPath: String, workingDirectory: String) {
        try ensureDirectoryIfNeeded(workingDirectoryURL)
        let configURL = workingDirectoryURL.appendingPathComponent("mihomo-config.yaml")

        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        return (configURL.path, workingDirectoryURL.path)
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
