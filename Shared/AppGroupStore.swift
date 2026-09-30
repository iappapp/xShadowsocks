import Foundation

/// Cross-process state shared by the app and, when tunnel mode is in use, the
/// packet-tunnel extension.
///
/// Every persisted value lives in the App Group so both processes observe the same
/// data. Traffic counters are written by whichever process owns the core and read by
/// the app; the active config filename is written by the app and read by the core's host.
///
/// The App Group requires a paid Apple Developer account. On a free account the
/// entitlement cannot be signed at all, so this falls back to `UserDefaults.standard`:
/// everything still works, because the app is then also the process running the core
/// (loopback mode). See `MihomoSharedPaths`.
public final class AppGroupStore {
    public static let shared = AppGroupStore()

    public let appGroupID = "group.com.github.iappapp.xShadowsocks"

    // Which YAML file the core should load as its user config.
    public let activeConfigFileNameKey = "active_config_filename"
    // Settings the core's host needs in order to build its runtime config.
    public let routeModeKey = "settings.routing.mode"
    public let proxyPortKey = "settings.proxy.port"
    public let lanAccessKey = "settings.network.allowLan"
    public let ipv6Key = "settings.network.preferIPv6"
    // Which process hosts the core: the app (loopback) or the extension (tunnel).
    public let proxyModeKey = "settings.proxy.mode"

    public let trafficDayStartKey = "traffic_day_start"
    public let trafficUploadBytesKey = "traffic_upload_bytes"
    public let trafficDownloadBytesKey = "traffic_download_bytes"

    /// True when the App Group entitlement is in effect, i.e. a second process (the
    /// packet-tunnel extension) can see the same files and defaults.
    public var isAppGroupAvailable: Bool {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    /// The shared defaults when possible, otherwise this process's own store so the app
    /// still persists its settings on a free developer account.
    private var defaults: UserDefaults? {
        isAppGroupAvailable ? UserDefaults(suiteName: appGroupID) : .standard
    }

    public init() {}

    // MARK: - Codable values

    public func save<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        defaults?.set(data, forKey: key)
    }

    public func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        if let data = defaults?.data(forKey: key),
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }

        if let data = UserDefaults.standard.data(forKey: key),
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }

        return nil
    }

    // MARK: - Scalars

    public func saveValue(_ value: Any?, forKey key: String) {
        defaults?.setValue(value, forKey: key)
    }

    public func loadString(forKey key: String, default defaultValue: String = "") -> String {
        (defaults?.string(forKey: key)) ?? defaultValue
    }

    public func loadBool(forKey key: String, default defaultValue: Bool) -> Bool {
        if defaults?.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults?.bool(forKey: key) ?? defaultValue
    }

    public func loadDouble(forKey key: String, default defaultValue: Double) -> Double {
        if defaults?.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults?.double(forKey: key) ?? defaultValue
    }

    public func loadInt(forKey key: String, default defaultValue: Int) -> Int {
        if defaults?.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults?.integer(forKey: key) ?? defaultValue
    }

    public func removeValue(forKey key: String) {
        defaults?.removeObject(forKey: key)
    }

    // MARK: - Daily traffic counters

    public func loadTodayTrafficBytes() -> (upload: Double, download: Double) {
        ensureTrafficDayCurrent()
        let upload = defaults?.double(forKey: trafficUploadBytesKey) ?? 0
        let download = defaults?.double(forKey: trafficDownloadBytesKey) ?? 0
        return (upload, download)
    }

    /// Adds to today's counters. Called by whichever process owns the running core.
    public func addTodayTrafficBytes(upload: Double, download: Double) {
        guard upload > 0 || download > 0 else { return }
        ensureTrafficDayCurrent()
        let currentUpload = defaults?.double(forKey: trafficUploadBytesKey) ?? 0
        let currentDownload = defaults?.double(forKey: trafficDownloadBytesKey) ?? 0
        defaults?.set(currentUpload + upload, forKey: trafficUploadBytesKey)
        defaults?.set(currentDownload + download, forKey: trafficDownloadBytesKey)
    }

    public func saveTodayTrafficBytes(upload: Double, download: Double) {
        ensureTrafficDayCurrent()
        defaults?.set(upload, forKey: trafficUploadBytesKey)
        defaults?.set(download, forKey: trafficDownloadBytesKey)
    }

    public func resetTodayTrafficBytes() {
        defaults?.set(currentDayStartTimestamp(), forKey: trafficDayStartKey)
        defaults?.set(0, forKey: trafficUploadBytesKey)
        defaults?.set(0, forKey: trafficDownloadBytesKey)
    }

    private func ensureTrafficDayCurrent() {
        let todayStart = currentDayStartTimestamp()
        let storedDayStart = defaults?.double(forKey: trafficDayStartKey) ?? 0
        if storedDayStart != todayStart {
            defaults?.set(todayStart, forKey: trafficDayStartKey)
            defaults?.set(0, forKey: trafficUploadBytesKey)
            defaults?.set(0, forKey: trafficDownloadBytesKey)
        }
    }

    private func currentDayStartTimestamp() -> TimeInterval {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }
}
