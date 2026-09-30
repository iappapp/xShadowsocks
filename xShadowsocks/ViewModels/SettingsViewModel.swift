import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var updateInterval = UpdateInterval.sixHours.rawValue
    @Published var updateOnLaunch = true

    @Published var allowCellular = true
    @Published var allowLANAccess = false
    @Published var preferIPv6 = false
    @Published var routeMode: RouteMode = .configuration
    @Published var proxyPortText = "7890"
    @Published var proxyMode: ProxyMode = .loopback

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
        static let updateInterval = "settings.subscription.interval"
        static let updateOnLaunch = "settings.subscription.updateOnLaunch"
        static let allowCellular = "settings.network.allowCellular"
    }

    /// The packet-tunnel extension only exists when the app was signed with the Network
    /// Extension entitlement, which needs a paid developer account. Until then the mode
    /// picker is disabled rather than pretending the option works.
    var isTunnelAvailable: Bool { TunnelManager.isExtensionEmbedded }

    var proxyPortValidationMessage: String? {
        guard let port = Int(proxyPortText), !proxyPortText.isEmpty else {
            return "请输入 \(minProxyPort)-\(maxProxyPort) 之间的端口"
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
        updateInterval = store.loadString(forKey: Keys.updateInterval, default: UpdateInterval.sixHours.rawValue)
        updateOnLaunch = store.loadBool(forKey: Keys.updateOnLaunch, default: true)

        allowCellular = store.loadBool(forKey: Keys.allowCellular, default: true)
        // These two are read by the packet-tunnel extension when it builds its runtime
        // config, so they must land in the App Group, not in UserDefaults.standard.
        allowLANAccess = store.loadBool(forKey: store.lanAccessKey, default: false)
        preferIPv6 = store.loadBool(forKey: store.ipv6Key, default: false)

        let savedRouteModeRawValue = store.loadString(forKey: store.routeModeKey, default: RouteMode.configuration.rawValue)
        routeMode = RouteMode(rawValue: savedRouteModeRawValue) ?? .configuration
        proxyPortText = "\(store.loadInt(forKey: store.proxyPortKey, default: defaultProxyPort))"
        handleProxyPortInputChange(proxyPortText)

        let savedProxyMode = store.loadString(forKey: store.proxyModeKey, default: ProxyMode.loopback.rawValue)
        proxyMode = ProxyMode(rawValue: savedProxyMode) ?? .loopback
        if !isTunnelAvailable { proxyMode = .loopback }
    }

    func persist() {
        guard !isPreviewMode else { return }
        store.saveValue(updateInterval, forKey: Keys.updateInterval)
        store.saveValue(updateOnLaunch, forKey: Keys.updateOnLaunch)

        store.saveValue(allowCellular, forKey: Keys.allowCellular)
        store.saveValue(allowLANAccess, forKey: store.lanAccessKey)
        store.saveValue(preferIPv6, forKey: store.ipv6Key)
        store.saveValue(routeMode.rawValue, forKey: store.routeModeKey)
        store.saveValue(resolvedProxyPort, forKey: store.proxyPortKey)
        store.saveValue(proxyMode.rawValue, forKey: store.proxyModeKey)
    }

    func handleProxyPortInputChange(_ newValue: String) {
        let digitsOnly = newValue.filter(\.isNumber)
        if digitsOnly != proxyPortText {
            proxyPortText = digitsOnly
        }

        guard let port = Int(proxyPortText), port > maxProxyPort else { return }
        proxyPortText = "\(maxProxyPort)"
    }

    func resetSettings() {
        updateInterval = UpdateInterval.sixHours.rawValue
        updateOnLaunch = true

        allowCellular = true
        allowLANAccess = false
        preferIPv6 = false
        routeMode = .configuration
        proxyPortText = "\(defaultProxyPort)"
        proxyMode = .loopback
        updateMessage = "已恢复默认设置"
        persist()
    }
}

extension SettingsViewModel {
    static func previewMock() -> SettingsViewModel {
        let viewModel = SettingsViewModel(isPreviewMode: true)
        viewModel.updateOnLaunch = true
        viewModel.updateInterval = UpdateInterval.oneHour.rawValue
        viewModel.allowCellular = true
        viewModel.allowLANAccess = true
        viewModel.preferIPv6 = false
        viewModel.routeMode = .proxy
        viewModel.proxyPortText = "7890"
        viewModel.updateMessage = "已恢复默认设置"
        return viewModel
    }
}
