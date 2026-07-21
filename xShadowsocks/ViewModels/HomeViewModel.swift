import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var isProxyEnabled = false
    @Published var isApplyingProxyState = false
    @Published var showProxyError = false
    @Published var proxyErrorMessage = ""
    @Published var localProxyStatusText = "未启动"
    @Published var routeMode: RouteMode = .configuration
    @Published var isTesting = false
    @Published var configSources: [ConfigSourceModel] = []
    @Published var selectedSourceID: UUID?
    @Published var nodes: [ServerNode] = []
    @Published var selectedNodeID: UUID?

    private let configSourcesKey = "config_sources"
    private let isPreviewMode: Bool
    private let store = AppGroupStore.shared
    private var proxySelectorService: ProxySelectorService?
    private var isSyncingProxyState = false

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode

        guard !isPreviewMode else { return }

        let selectorService = ProxySelectorService(store: store)
        selectorService.onStatusTextChange = { [weak self] text in
            self?.localProxyStatusText = text
        }
        selectorService.onFailure = { [weak self] message in
            guard let self else { return }
            self.proxyErrorMessage = message
            self.showProxyError = true
            self.isSyncingProxyState = true
            self.isProxyEnabled = false
            self.isSyncingProxyState = false
        }
        self.proxySelectorService = selectorService
    }

    var selectedNode: ServerNode? {
        nodes.first { $0.id == selectedNodeID }
    }

    var selectedSource: ConfigSourceModel? {
        configSources.first { $0.id == selectedSourceID }
    }

    func onAppear() {
        guard !isPreviewMode else { return }
        loadConfigSourcesFromStore()
        ensureSelectedSourceAndNode()
        routeMode = loadRouteModeFromSettings()
        proxySelectorService?.syncPortFromSettings(isProxyEnabled: isProxyEnabled)
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

    func runConnectivityTest() {
        guard !isTesting else { return }
        isTesting = true

        Task {
            let currentNodes = nodes

            let latencyMap = await withTaskGroup(of: (UUID, Int).self) { group in
                for node in currentNodes {
                    group.addTask {
                        let latency = await NodeLatencyProbe.measure(host: node.host, port: node.port)
                        return (node.id, latency)
                    }
                }

                var result: [UUID: Int] = [:]
                for await (id, latency) in group {
                    result[id] = latency
                }
                return result
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

    func setProxyEnabled(_ enabled: Bool) {
        guard !isSyncingProxyState else { return }
        guard !isApplyingProxyState else { return }

        if enabled {
            routeMode = loadRouteModeFromSettings()
            proxySelectorService?.syncPortFromSettings(isProxyEnabled: isProxyEnabled)
            // Re-activate the selected config file before starting the proxy so that
            // the runtime loads the user's current selection (each source has its own file).
            if let source = selectedSource, let yaml = source.yamlConfig {
                let fileName = source.fileName ?? MihomoConfigFileStore.fileName(forConfigName: source.name)
                try? MihomoConfigFileStore.save(yaml, as: fileName)
                MihomoConfigFileStore.activeFileName = fileName
            }
        }

        isApplyingProxyState = true
        Task {
            defer { isApplyingProxyState = false }

            do {
                try await proxySelectorService?.setProxyEnabled(
                    enabled: enabled,
                    nodes: nodes,
                    selectedNode: selectedNode,
                    selectedNodeID: selectedNodeID,
                    routeMode: mapRouteMode(routeMode)
                )

                try? await Task.sleep(for: .milliseconds(250))
                isSyncingProxyState = true
                isProxyEnabled = enabled
                isSyncingProxyState = false
            } catch {
                proxyErrorMessage = error.localizedDescription
                showProxyError = true
                isSyncingProxyState = true
                isProxyEnabled = !enabled
                isSyncingProxyState = false
            }
        }
    }

    private func mapRouteMode(_ routeMode: RouteMode) -> MihomoRouteMode {
        switch routeMode {
        case .configuration, .scenario:
            return .configuration
        case .proxy:
            return .proxy
        case .direct:
            return .direct
        }
    }

    // MARK: - Loading

    private func loadConfigSourcesFromStore() {
        // The subscription URL is owned by the saved ConfigSourceModel (set at
        // import time). Never synthesize a placeholder URL here — if there is
        // no saved source, show nothing.
        if let saved = store.load([ConfigSourceModel].self, forKey: configSourcesKey), !saved.isEmpty {
            configSources = saved
            return
        }
        configSources = []
    }

    private func ensureSelectedSourceAndNode() {
        if selectedSourceID == nil {
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
        viewModel.isProxyEnabled = true
        viewModel.localProxyStatusText = "运行中 (Mixed 7890)"
        return viewModel
    }
}
