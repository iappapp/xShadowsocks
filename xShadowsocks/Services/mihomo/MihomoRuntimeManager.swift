import Foundation
import os

actor MihomoRuntimeManager {
    private  var onStateChange: (@Sendable (MihomoRuntimeState) -> Void)?

    private let bridge: any MihomoCoreBridge
    private let fileManager: FileManager
    private let workingDirectoryURL: URL
    private let mmdbStore: CountryMMDBStore
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
        self.mmdbStore = CountryMMDBStore(fileManager: fileManager)
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
            _ = try await mmdbStore.ensureMMDB(in: workingDirectoryURL)
            logger.info("Country.mmdb / GeoSite.dat ready")

            if bridge.isRunning {
                logger.info("bridge already running -> reload")
                try bridge.reload(configPath: paths.configPath)
            } else {
                logger.info("bridge start")
                try bridge.start(configPath: paths.configPath, workingDirectory: paths.workingDirectory)
            }

            let snapshot = MihomoRuntimeSnapshot(
                configPath: paths.configPath,
                workingDirectory: paths.workingDirectory
            )
            currentSnapshot = snapshot
            logger.info("runtime running config=\(paths.configPath, privacy: .public)")
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
            _ = try await mmdbStore.ensureMMDB(in: workingDirectoryURL)
            try bridge.reload(configPath: paths.configPath)

            let snapshot = MihomoRuntimeSnapshot(
                configPath: paths.configPath,
                workingDirectory: paths.workingDirectory
            )
            currentSnapshot = snapshot
            logger.info("runtime reload ok config=\(paths.configPath, privacy: .public)")
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
