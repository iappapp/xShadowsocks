import Foundation

final class AppGroupStore {
    static let shared = AppGroupStore()

    let appGroupID = "group.com.github.iappapp.xShadowsocks"
    let sharedConfigKey = "ss_config"
    let trafficDayStartKey = "traffic_day_start"
    let trafficUploadBytesKey = "traffic_upload_bytes"
    let trafficDownloadBytesKey = "traffic_download_bytes"
    let routeModeKey = "settings.routing.mode"
    let proxyEngineKey = "settings.proxy.engine"
    let proxyPortKey = "settings.proxy.port"

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private init() {}

    func save<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        defaults?.set(data, forKey: key)
    }

    func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
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

    func saveValue(_ value: Any?, forKey key: String) {
        defaults?.setValue(value, forKey: key)
    }

    func loadString(forKey key: String, default defaultValue: String = "") -> String {
        (defaults?.string(forKey: key)) ?? defaultValue
    }

    func loadBool(forKey key: String, default defaultValue: Bool) -> Bool {
        if defaults?.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults?.bool(forKey: key) ?? defaultValue
    }

    func loadDouble(forKey key: String, default defaultValue: Double) -> Double {
        if defaults?.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults?.double(forKey: key) ?? defaultValue
    }

    func loadInt(forKey key: String, default defaultValue: Int) -> Int {
        if defaults?.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults?.integer(forKey: key) ?? defaultValue
    }

    func removeValue(forKey key: String) {
        defaults?.removeObject(forKey: key)
    }

    func loadTodayTrafficBytes() -> (upload: Double, download: Double) {
        ensureTrafficDayCurrent()
        let upload = defaults?.double(forKey: trafficUploadBytesKey) ?? 0
        let download = defaults?.double(forKey: trafficDownloadBytesKey) ?? 0
        return (upload, download)
    }

    func saveTodayTrafficBytes(upload: Double, download: Double) {
        ensureTrafficDayCurrent()
        defaults?.set(upload, forKey: trafficUploadBytesKey)
        defaults?.set(download, forKey: trafficDownloadBytesKey)
    }

    func resetTodayTrafficBytes() {
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
