import Foundation
import os

/// Owns the mihomo core within whichever process is hosting it.
///
/// Both host modes (the packet-tunnel extension and the app itself in loopback mode)
/// need the same three steps: build the runtime config, start the core with it, and keep
/// the traffic counters flowing. This type holds that shared part; the only difference
/// between the modes is the `HostMode` it is given.
public final class MihomoCoreHost {
    public static let shared = MihomoCoreHost()

    public static let externalControllerPort = 9090

    public enum HostError: LocalizedError {
        case noActiveConfig
        case missingUserConfig(String)
        case workingDirectoryUnavailable(String)
        case runtimeConfigEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .noActiveConfig:
                return "未选择配置文件，请先在“配置”页导入订阅"
            case .missingUserConfig(let path):
                return "找不到配置文件: \(path)"
            case .workingDirectoryUnavailable(let path):
                return "无法创建运行目录: \(path)"
            case .runtimeConfigEncodingFailed:
                return "运行配置编码失败"
            }
        }
    }

    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "CoreHost")
    private let store = AppGroupStore.shared
    private let lock = NSLock()

    /// Cumulative counters mihomo reports for the current core run, used to derive the
    /// deltas added to the daily totals.
    private var lastReportedTotals: MihomoAPIClient.Totals?
    private var pendingUploadBytes: Double = 0
    private var pendingDownloadBytes: Double = 0
    private var runningMode: MihomoRuntimeConfigBuilder.HostMode?
    private var secret: String = UUID().uuidString

    private init() {}

    public var isRunning: Bool { MihomoCoreBridge.shared.isRunning }
    public var apiSecret: String { lock.withLock { secret } }

    // MARK: - Lifecycle

    /// Writes the runtime config for `mode` and starts the core with it.
    ///
    /// - Parameter userYAML: the user's selected subscription file, verbatim.
    public func start(mode: MihomoRuntimeConfigBuilder.HostMode, userYAML: String) throws {
        lock.withLock {
            runningMode = mode
            lastReportedTotals = nil
            pendingUploadBytes = 0
            pendingDownloadBytes = 0
        }

        do {
            try writeRuntimeConfig(mode: mode, userYAML: userYAML)
            try MihomoCoreBridge.shared.start(
                configPath: configURL(for: mode).lastPathComponent,
                workingDirectory: MihomoSharedPaths.directoryURL.path
            )
        } catch {
            lock.withLock { runningMode = nil }
            throw error
        }

        logger.info("core started in mode \(String(describing: mode), privacy: .public)")
    }

    /// Rewrites the runtime config from the current store state and hot-reloads it.
    /// Used after a settings change or a subscription re-import.
    public func reload() throws {
        guard let mode = lock.withLock({ runningMode }) else {
            throw MihomoCoreBridge.BridgeError.notRunning
        }
        let userYAML = try loadUserYAML()
        try writeRuntimeConfig(mode: mode, userYAML: userYAML)
        try MihomoCoreBridge.shared.reload(configPath: configURL(for: mode).path)
        logger.info("core reloaded")
    }

    public func stop() throws {
        flushTraffic()
        try MihomoCoreBridge.shared.stop()
        lock.withLock {
            runningMode = nil
            lastReportedTotals = nil
            pendingUploadBytes = 0
            pendingDownloadBytes = 0
        }
        logger.info("core stopped")
    }

    // MARK: - Traffic

    /// Fetches the core's cumulative counters and folds the delta into today's totals.
    public func pollTraffic() async {
        let client = MihomoAPIClient(port: Self.externalControllerPort, secret: apiSecret)
        guard let totals = try? await client.fetchTotals() else { return }
        recordDelta(totals)
    }

    /// Cumulative counters for the current run, for the Data tab.
    public func currentSessionTotals() -> (upload: Double, download: Double) {
        lock.withLock {
            guard let totals = lastReportedTotals else { return (0, 0) }
            return (Double(totals.upload), Double(totals.download))
        }
    }

    /// Moves any pending bytes into the daily counters.
    public func flushTraffic() {
        lock.withLock { flush(force: true) }
    }

    private func recordDelta(_ totals: MihomoAPIClient.Totals) {
        lock.withLock {
            defer { lastReportedTotals = totals }
            guard let previous = lastReportedTotals else { return }

            let uploadDelta = max(totals.upload - previous.upload, 0)
            let downloadDelta = max(totals.download - previous.download, 0)
            guard uploadDelta > 0 || downloadDelta > 0 else { return }

            pendingUploadBytes += Double(uploadDelta)
            pendingDownloadBytes += Double(downloadDelta)
            flush(force: false)
        }
    }

    /// Must be called with `lock` held.
    private func flush(force: Bool) {
        guard pendingUploadBytes > 0 || pendingDownloadBytes > 0 else { return }
        // Small deltas are batched: a defaults write per poll is not free, and the Data
        // tab only refreshes once a second anyway.
        guard force || pendingUploadBytes + pendingDownloadBytes >= 64 * 1024 else { return }

        let upload = pendingUploadBytes
        let download = pendingDownloadBytes
        pendingUploadBytes = 0
        pendingDownloadBytes = 0
        store.addTodayTrafficBytes(upload: upload, download: download)
    }

    // MARK: - Config

    private func configURL(for mode: MihomoRuntimeConfigBuilder.HostMode) -> URL {
        switch mode {
        case .tunnel: return MihomoSharedPaths.runtimeConfigURL
        case .loopback: return MihomoSharedPaths.localRuntimeConfigURL
        }
    }

    private func writeRuntimeConfig(mode: MihomoRuntimeConfigBuilder.HostMode, userYAML: String) throws {
        guard MihomoSharedPaths.ensureDirectory() else {
            throw HostError.workingDirectoryUnavailable(MihomoSharedPaths.directoryURL.path)
        }

        // `Country.mmdb` must sit in the core's home directory or mihomo will try to
        // download it — which, in tunnel mode, would loop back through the tunnel it is
        // still starting.
        let missingGeoFiles = GeoDataStore().ensureAvailable()
        if !missingGeoFiles.isEmpty {
            logger.error("missing geo data: \(missingGeoFiles.joined(separator: ", "), privacy: .public)")
        }

        let yaml = MihomoRuntimeConfigBuilder.runtimeConfig(
            userYAML: userYAML,
            mode: mode,
            mixedPort: currentMixedPort(),
            allowLan: store.loadBool(forKey: store.lanAccessKey, default: false),
            ipv6Enabled: store.loadBool(forKey: store.ipv6Key, default: false),
            routingMode: currentRoutingMode(),
            externalControllerPort: Self.externalControllerPort,
            externalControllerSecret: apiSecret
        )

        guard let data = yaml.data(using: .utf8) else {
            throw HostError.runtimeConfigEncodingFailed
        }
        try data.write(to: configURL(for: mode), options: .atomic)
        logger.info("runtime config written (\(data.count) bytes)")
    }

    private func loadUserYAML() throws -> String {
        let fileName = store.loadString(forKey: store.activeConfigFileNameKey)
        guard !fileName.isEmpty else { throw HostError.noActiveConfig }

        let url = MihomoSharedPaths.configFileURL(forFileName: fileName)
        guard let yaml = try? String(contentsOf: url, encoding: .utf8), !yaml.isEmpty else {
            throw HostError.missingUserConfig(url.path)
        }
        return yaml
    }

    private func currentMixedPort() -> Int {
        let port = store.loadInt(forKey: store.proxyPortKey, default: 7890)
        return min(max(port, 1024), 65_000)
    }

    private func currentRoutingMode() -> MihomoRuntimeConfigBuilder.RoutingMode {
        MihomoRuntimeConfigBuilder.RoutingMode.resolved(
            fromPersistedValue: store.loadString(forKey: store.routeModeKey, default: "配置")
        )
    }
}
