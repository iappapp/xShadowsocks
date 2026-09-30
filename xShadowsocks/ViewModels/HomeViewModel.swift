import Foundation
import NetworkExtension
import os

@MainActor
final class HomeViewModel: ObservableObject {
    /// User intent, bound to the toggle.
    @Published var wantsProxy: Bool = false
    /// Actual running state, never written optimistically.
    @Published private(set) var tunnelState: TunnelState = .disconnected
    @Published var proxyErrorMessage: String?
    @Published var routeMode: RouteMode = .configuration
    @Published var isTesting = false
    @Published var configSources: [ConfigSourceModel] = []
    @Published var selectedSourceID: UUID?
    @Published var nodes: [ServerNode] = []
    @Published var selectedNodeID: UUID?

    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "HomeViewModel")
    private let configSourcesKey = "config_sources"
    private let isPreviewMode: Bool
    private let store = AppGroupStore.shared
    private var statusObserver: NSObjectProtocol?
    private var isApplying = false

    enum TunnelState: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case failed(String)
    }

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
        guard !isPreviewMode else { return }
        observeTunnelStatus()
        Task { await refreshTunnelState() }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    // MARK: - Mode

    /// Which host the core runs in. The tunnel is only usable when the app was signed
    /// with the Network Extension entitlement *and* the extension is embedded; both
    /// require a paid account, so on a free account the app stays on loopback.
    var isTunnelAvailable: Bool { TunnelManager.isExtensionEmbedded }

    /// Persisted preference; forced to loopback when the tunnel cannot run.
    var proxyMode: ProxyMode {
        get {
            guard isTunnelAvailable else { return .loopback }
            let raw = store.loadString(forKey: store.proxyModeKey, default: ProxyMode.loopback.rawValue)
            return ProxyMode(rawValue: raw) ?? .loopback
        }
        set {
            store.saveValue(newValue.rawValue, forKey: store.proxyModeKey)
            objectWillChange.send()
        }
    }

    // MARK: - Derived state

    var selectedNode: ServerNode? {
        nodes.first { $0.id == selectedNodeID }
    }

    var selectedSource: ConfigSourceModel? {
        configSources.first { $0.id == selectedSourceID }
    }

    var activeConfigFileName: String? {
        guard let source = selectedSource ?? configSources.first else { return nil }
        return source.fileName ?? MihomoConfigFileStore.fileName(forConfigName: source.name)
    }

    /// Whether the user is allowed to start the proxy. Requires at least one imported
    /// config; with more than one the user must pick one first.
    var canConnect: Bool {
        !configSources.isEmpty && (configSources.count == 1 || selectedSourceID != nil)
    }

    var isApplyingProxyState: Bool {
        isApplying || tunnelState == .connecting || tunnelState == .disconnecting
    }

    var proxyStatusText: String {
        switch tunnelState {
        case .connected:
            return proxyMode == .tunnel ? "已连接（系统 VPN）" : "已连接（本地 \(LocalProxyHost.shared.proxyPort)）"
        case .connecting:
            return "连接中"
        case .disconnecting:
            return "断开中"
        case .disconnected:
            return "未连接"
        case .failed(let message):
            return "连接失败：\(message)"
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !isPreviewMode else { return }
        loadConfigSourcesFromStore()
        ensureSelectedSourceAndNode()
        routeMode = loadRouteModeFromSettings()
        Task { await refreshTunnelState() }
    }

    func persistRouteMode() {
        guard !isPreviewMode else { return }
        store.saveValue(routeMode.rawValue, forKey: store.routeModeKey)
    }

    func selectNode(_ node: ServerNode) {
        selectedNodeID = node.id
    }

    func selectSource(_ source: ConfigSourceModel) {
        selectedSourceID = source.id
        nodes = source.nodes
        if selectedNodeID == nil || !nodes.contains(where: { $0.id == selectedNodeID }) {
            selectedNodeID = nodes.first?.id
        }
    }

    func nodes(for source: ConfigSourceModel) -> [ServerNode] {
        source.nodes
    }

    // MARK: - Connect / disconnect

    /// Called when the user flips the toggle. `apply(status:)` also writes `wantsProxy`,
    /// so this reconciles rather than acting unconditionally — otherwise a status
    /// notification could restart a session that is already up.
    func setProxyEnabled(_ enabled: Bool) {
        guard !isApplying else { return }
        wantsProxy = enabled
        Task { await applyProxyIntent() }
    }

    private func applyProxyIntent() async {
        guard !isPreviewMode else { return }
        guard !isApplying else { return }

        // Already where the user wants to be — nothing to do.
        if wantsProxy, tunnelState == .connected || tunnelState == .connecting { return }
        if !wantsProxy, tunnelState == .disconnected || tunnelState == .disconnecting { return }

        isApplying = true
        defer { isApplying = false }

        if wantsProxy {
            await start()
        } else {
            await stop()
        }
    }

    private func start() async {
        guard let fileName = activeConfigFileName else {
            wantsProxy = false
            proxyErrorMessage = "请先选择一个配置"
            return
        }
        guard MihomoSharedPaths.ensureDirectory() else {
            wantsProxy = false
            proxyErrorMessage = "无法创建运行目录"
            return
        }

        // The source list can be newer than what is on disk (e.g. right after an
        // import), so re-write the selected file before starting.
        if let source = selectedSource ?? configSources.first, let yaml = source.yamlConfig {
            try? MihomoConfigFileStore.save(yaml, as: fileName)
        }
        MihomoConfigFileStore.activeFileName = fileName

        let userYAML = MihomoConfigFileStore.loadText(forFileName: fileName) ?? ""

        switch proxyMode {
        case .loopback:
            tunnelState = .connecting
            do {
                try LocalProxyHost.shared.start(userYAML: userYAML)
                tunnelState = .connected
            } catch {
                tunnelState = .failed(error.localizedDescription)
                wantsProxy = false
                proxyErrorMessage = error.localizedDescription
            }

        case .tunnel:
            do {
                try await TunnelManager.shared.start(activeConfigFileName: fileName)
                // The real state arrives through `NEVPNStatusDidChange`.
                tunnelState = .connecting
            } catch {
                tunnelState = .failed(error.localizedDescription)
                wantsProxy = false
                proxyErrorMessage = "系统 VPN 启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func stop() async {
        switch proxyMode {
        case .loopback:
            tunnelState = .disconnecting
            LocalProxyHost.shared.stop()
            tunnelState = .disconnected

        case .tunnel:
            tunnelState = .disconnecting
            do {
                try await TunnelManager.shared.stop()
            } catch {
                proxyErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshTunnelState() async {
        guard !isPreviewMode else { return }

        switch proxyMode {
        case .loopback:
            // The app owns the core, so its own flag is the truth.
            tunnelState = LocalProxyHost.shared.isRunning ? .connected : .disconnected
            wantsProxy = LocalProxyHost.shared.isRunning

        case .tunnel:
            guard let manager = await TunnelManager.shared.existingManager() else {
                tunnelState = .disconnected
                return
            }
            apply(status: manager.connection.status)
        }
    }

    private func observeTunnelStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                guard let self, self.proxyMode == .tunnel else { return }
                self.apply(status: connection.status)
            }
        }
    }

    private func apply(status: NEVPNStatus) {
        switch status {
        case .connected:
            tunnelState = .connected
            wantsProxy = true
        case .connecting, .reasserting:
            tunnelState = .connecting
        case .disconnecting:
            tunnelState = .disconnecting
        case .disconnected, .invalid:
            tunnelState = .disconnected
            wantsProxy = false
        @unknown default:
            tunnelState = .disconnected
        }
    }

    // MARK: - Connectivity test

    /// Measures TCP reachability of each node's own endpoint.
    ///
    /// This is a plain TCP handshake from the device, so it is only meaningful as a
    /// pre-flight check; routing latency should come from the core's own
    /// `/proxies/{name}/delay` endpoint instead. The concurrency is capped because a
    /// subscription can carry hundreds of nodes.
    func runConnectivityTest() {
        guard !isTesting else { return }
        isTesting = true

        Task {
            let currentNodes = nodes
            let limit = 8
            var latencyMap: [UUID: Int] = [:]

            await withTaskGroup(of: (UUID, Int).self) { group in
                var index = 0
                func addNext() {
                    guard index < currentNodes.count else { return }
                    let node = currentNodes[index]
                    index += 1
                    group.addTask {
                        let latency = await NodeLatencyProbe.measure(host: node.host, port: node.port)
                        return (node.id, latency)
                    }
                }

                for _ in 0..<min(limit, currentNodes.count) { addNext() }

                while let (id, latency) = await group.next() {
                    latencyMap[id] = latency
                    addNext()
                }
            }

            nodes = currentNodes.map { node in
                var updated = node
                updated.latency = latencyMap[node.id] ?? -1
                return updated
            }
            syncSelectedSourceNodes(with: nodes)
            isTesting = false
        }
    }

    // MARK: - Source / node mutation

    func deleteSource(_ source: ConfigSourceModel) {
        guard let sourceIndex = configSources.firstIndex(where: { $0.id == source.id }) else {
            return
        }

        configSources.remove(at: sourceIndex)

        if selectedSourceID == source.id {
            selectedSourceID = configSources.first?.id
            nodes = configSources.first?.nodes ?? []
            selectedNodeID = nodes.first?.id
        } else if let selectedSourceID,
                  let selectedIndex = configSources.firstIndex(where: { $0.id == selectedSourceID }) {
            nodes = configSources[selectedIndex].nodes
            if selectedNodeID == nil || !nodes.contains(where: { $0.id == selectedNodeID }) {
                selectedNodeID = nodes.first?.id
            }
        } else {
            nodes = []
            selectedNodeID = nil
        }

        if let fileName = source.fileName {
            try? FileManager.default.removeItem(at: MihomoSharedPaths.configFileURL(forFileName: fileName))
        }
        persistSourceState()
    }

    func deleteNode(_ node: ServerNode, from source: ConfigSourceModel) {
        guard let sourceIndex = configSources.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        guard let nodeIndex = configSources[sourceIndex].nodes.firstIndex(where: { $0.id == node.id }) else {
            return
        }

        configSources[sourceIndex].nodes.remove(at: nodeIndex)
        configSources[sourceIndex].updatedAt = Date()

        if selectedSourceID == source.id {
            nodes = configSources[sourceIndex].nodes
            if selectedNodeID == node.id || !nodes.contains(where: { $0.id == selectedNodeID }) {
                selectedNodeID = nodes.first?.id
            }
        }

        persistSourceState()
    }

    // MARK: - Loading

    private func loadConfigSourcesFromStore() {
        configSources = store.load([ConfigSourceModel].self, forKey: configSourcesKey) ?? []
    }

    private func ensureSelectedSourceAndNode() {
        if selectedSourceID == nil, configSources.count == 1 {
            selectedSourceID = configSources.first?.id
        }

        if let selectedSource {
            if nodes != selectedSource.nodes {
                nodes = selectedSource.nodes
            }
        } else {
            nodes = []
        }

        if selectedNodeID == nil || !nodes.contains(where: { $0.id == selectedNodeID }) {
            selectedNodeID = nodes.first?.id
        }
    }

    private func syncSelectedSourceNodes(with updatedNodes: [ServerNode]) {
        guard let selectedSourceID,
              let index = configSources.firstIndex(where: { $0.id == selectedSourceID }) else {
            return
        }

        configSources[index].nodes = updatedNodes
        configSources[index].updatedAt = Date()
        try? store.save(configSources, forKey: configSourcesKey)
    }

    private func persistSourceState() {
        try? store.save(configSources, forKey: configSourcesKey)
    }

    private func loadRouteModeFromSettings() -> RouteMode {
        let rawValue = store.loadString(forKey: store.routeModeKey, default: RouteMode.configuration.rawValue)
        return RouteMode(rawValue: rawValue) ?? .configuration
    }
}

extension HomeViewModel {
    static func previewMock() -> HomeViewModel {
        let viewModel = HomeViewModel(isPreviewMode: true)
        let hkNodes: [ServerNode] = [
            .init(name: "🇭🇰 香港 01", host: "hk.example.com", port: 443, password: "demo", nodeType: "vless", sni: "cdn.example.com", latency: 72),
            .init(name: "🇯🇵 日本 01", host: "jp.example.com", port: 443, password: "demo", nodeType: "vless", sni: "cdn.example.com", latency: 124),
            .init(name: "🇺🇸 美国 01", host: "us.example.com", port: 443, password: "demo", nodeType: "anytls", sni: "cdn.example.com", latency: -1)
        ]
        let sgNodes: [ServerNode] = [
            .init(name: "🇸🇬 新加坡 01", host: "sg1.example.com", port: 443, password: "demo", nodeType: "vless", sni: "cdn.example.com", latency: 38),
            .init(name: "🇸🇬 新加坡 02", host: "sg2.example.com", port: 443, password: "demo", nodeType: "anytls", sni: "cdn.example.com", latency: 42)
        ]
        viewModel.configSources = [
            ConfigSourceModel(name: "XFLTD", url: "https://example.com/a.yaml", nodes: hkNodes),
            ConfigSourceModel(name: "备用订阅", url: "https://example.com/b.yaml", nodes: sgNodes)
        ]
        viewModel.selectedSourceID = viewModel.configSources.first?.id
        viewModel.nodes = hkNodes
        viewModel.selectedNodeID = viewModel.nodes.first?.id
        viewModel.routeMode = .proxy
        viewModel.wantsProxy = true
        viewModel.tunnelState = .connected
        return viewModel
    }
}
