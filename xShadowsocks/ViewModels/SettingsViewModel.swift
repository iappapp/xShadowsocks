import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var subscriptionURL = ""
    @Published var updateOnLaunch = true
    @Published var backgroundUpdate = false
    @Published var updateInterval = UpdateInterval.sixHours.rawValue
    @Published var lastUpdateTimestamp: Double = 0

    @Published var allowCellular = true
    @Published var allowLANAccess = false
    @Published var preferIPv6 = false
    @Published var routeMode: RouteMode = .configuration
    @Published var proxyEngine: ProxyEngine = .mihomo
    @Published var proxyPortText = "7890"

    @Published var isUpdatingSubscription = false
    @Published var updateMessage: String?
    @Published var showResetAlert = false

    private let isPreviewMode: Bool
    private let store = AppGroupStore.shared
    private let minProxyPort = 2000
    private let maxProxyPort = 9000
    private let defaultProxyPort = 7890

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
    }

    private enum Keys {
        static let subscriptionURL = "settings.subscription.url"
        static let updateOnLaunch = "settings.subscription.updateOnLaunch"
        static let backgroundUpdate = "settings.subscription.backgroundUpdate"
        static let updateInterval = "settings.subscription.interval"
        static let lastUpdate = "settings.subscription.lastUpdate"

        static let allowCellular = "settings.network.allowCellular"
        static let allowLan = "settings.network.allowLan"
        static let preferIPv6 = "settings.network.preferIPv6"
    }

    var canUpdateSubscription: Bool {
        !subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isUpdatingSubscription
    }

    var proxyPortValidationMessage: String? {
        guard let port = Int(proxyPortText), !proxyPortText.isEmpty else {
            return "请输入 2000-9000 之间的端口"
        }
        guard (minProxyPort...maxProxyPort).contains(port) else {
            return "端口范围需在 \(minProxyPort)-\(maxProxyPort)"
        }
        return nil
    }

    var resolvedProxyPort: Int {
        guard let port = Int(proxyPortText), (minProxyPort...maxProxyPort).contains(port) else {
            return defaultProxyPort
        }
        return port
    }

    func onAppear() {
        guard !isPreviewMode else { return }
        subscriptionURL = store.loadString(forKey: Keys.subscriptionURL)
        updateOnLaunch = store.loadBool(forKey: Keys.updateOnLaunch, default: true)
        backgroundUpdate = store.loadBool(forKey: Keys.backgroundUpdate, default: false)
        updateInterval = store.loadString(forKey: Keys.updateInterval, default: UpdateInterval.sixHours.rawValue)
        lastUpdateTimestamp = store.loadDouble(forKey: Keys.lastUpdate, default: 0)

        allowCellular = store.loadBool(forKey: Keys.allowCellular, default: true)
        allowLANAccess = store.loadBool(forKey: Keys.allowLan, default: false)
        preferIPv6 = store.loadBool(forKey: Keys.preferIPv6, default: false)
        let savedRouteModeRawValue = store.loadString(forKey: store.routeModeKey, default: RouteMode.configuration.rawValue)
        routeMode = RouteMode(rawValue: savedRouteModeRawValue) ?? .configuration
        let savedEngineRawValue = store.loadString(forKey: store.proxyEngineKey, default: ProxyEngine.mihomo.rawValue)
        proxyEngine = ProxyEngine(rawValue: savedEngineRawValue) ?? .mihomo
        proxyPortText = "\(store.loadInt(forKey: store.proxyPortKey, default: defaultProxyPort))"
        handleProxyPortInputChange(proxyPortText)
    }

    func persist() {
        guard !isPreviewMode else { return }
        store.saveValue(subscriptionURL, forKey: Keys.subscriptionURL)
        store.saveValue(updateOnLaunch, forKey: Keys.updateOnLaunch)
        store.saveValue(backgroundUpdate, forKey: Keys.backgroundUpdate)
        store.saveValue(updateInterval, forKey: Keys.updateInterval)
        store.saveValue(lastUpdateTimestamp, forKey: Keys.lastUpdate)

        store.saveValue(allowCellular, forKey: Keys.allowCellular)
        store.saveValue(allowLANAccess, forKey: Keys.allowLan)
        store.saveValue(preferIPv6, forKey: Keys.preferIPv6)
        store.saveValue(routeMode.rawValue, forKey: store.routeModeKey)
        store.saveValue(proxyEngine.rawValue, forKey: store.proxyEngineKey)
        store.saveValue(resolvedProxyPort, forKey: store.proxyPortKey)
    }

    func handleProxyPortInputChange(_ newValue: String) {
        let digitsOnly = newValue.filter(\.isNumber)
        if digitsOnly != proxyPortText {
            proxyPortText = digitsOnly
        }

        guard let port = Int(proxyPortText), port > maxProxyPort else { return }
        proxyPortText = "\(maxProxyPort)"
    }

    func updateSubscriptionNow() {
        guard canUpdateSubscription else { return }
        isUpdatingSubscription = true
        updateMessage = nil

        Task {
            try? await Task.sleep(for: .seconds(1.1))
            let success = Bool.random()

            isUpdatingSubscription = false
            if success {
                lastUpdateTimestamp = Date().timeIntervalSince1970
                updateMessage = "订阅更新成功"
            } else {
                updateMessage = "订阅更新失败，请检查 URL 或网络"
            }
            persist()
        }
    }

    func clearSavedNodeConfig() {
        if !isPreviewMode {
            store.removeValue(forKey: store.sharedConfigKey)
        }
        updateMessage = "已清除节点配置"
    }

    func resetSettings() {
        subscriptionURL = ""
        updateOnLaunch = true
        backgroundUpdate = false
        updateInterval = UpdateInterval.sixHours.rawValue
        lastUpdateTimestamp = 0

        allowCellular = true
        allowLANAccess = false
        preferIPv6 = false
        routeMode = .configuration
        proxyEngine = .mihomo
        proxyPortText = "\(defaultProxyPort)"
        updateMessage = "已恢复默认设置"
        persist()
    }
}

extension SettingsViewModel {
    static func previewMock() -> SettingsViewModel {
        let viewModel = SettingsViewModel(isPreviewMode: true)
        viewModel.subscriptionURL = "https://example.com/subscription.yaml"
        viewModel.updateOnLaunch = true
        viewModel.backgroundUpdate = true
        viewModel.updateInterval = UpdateInterval.oneHour.rawValue
        viewModel.lastUpdateTimestamp = Date().addingTimeInterval(-3600).timeIntervalSince1970
        viewModel.allowCellular = true
        viewModel.allowLANAccess = true
        viewModel.preferIPv6 = false
        viewModel.routeMode = .proxy
        viewModel.proxyEngine = .mihomo
        viewModel.proxyPortText = "7890"
        viewModel.updateMessage = "订阅更新成功"
        return viewModel
    }
}
