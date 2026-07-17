import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var isProxyEnabled = false
    @Published var isApplyingProxyState = false
    @Published var showProxyError = false
    @Published var proxyErrorMessage = ""
    @Published var isImportingNodes = false
    @Published var showImportError = false
    @Published var importErrorMessage = ""
    @Published var localProxyStatusText = "未启动"
    @Published var routeMode: RouteMode = .configuration
    @Published var isTesting = false
    @Published var configSources: [ProxyConfigSource] = []
    @Published var selectedSourceID: UUID?
    @Published var nodes: [ServerNode] = []
    @Published var selectedNodeID: UUID?

    private let importedNodesKey = "imported_nodes"
    private let configSourcesKey = "config_sources"
    private let isPreviewMode: Bool
    private let store = AppGroupStore.shared
    private let subscriptionImportService = SubscriptionNodeImportService()
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

    var selectedSource: ProxyConfigSource? {
        configSources.first { $0.id == selectedSourceID }
    }

    func onAppear() {
        guard !isPreviewMode else { return }
        // Prefer parsing the saved config file; fall back to persisted sources.
        if !reloadHomeFromConfigFile() {
            loadConfigSourcesIfNeeded()
            ensureSelectedSourceAndNode()
        }
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

    func selectSource(_ source: ProxyConfigSource) {
        selectedSourceID = source.id
        nodes = source.nodes
        if selectedNodeID == nil || !nodes.contains(where: { $0.id == selectedNodeID }) {
            selectedNodeID = nodes.first?.id
        }
    }

    func nodes(for source: ProxyConfigSource) -> [ServerNode] {
        source.nodes
    }

    func deleteSource(_ source: ProxyConfigSource) {
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

    func deleteNode(_ node: ServerNode, from source: ProxyConfigSource) {
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


    func importNodes(from urlString: String, configName: String?) async -> Bool {
        isImportingNodes = true
        defer {
            isImportingNodes = false
        }

        do {
            let result = try await subscriptionImportService.importNodes(from: urlString, configName: configName)

            guard let yaml = result.rawYAMLConfig else {
                throw SubscriptionNodeImportError.requiresYAMLConfig
            }

            // Save runtime config as original YAML plus inline proxies from node subscription.
            let mergedYAML = MihomoYAMLProxyInjector.injecting(result.nodes, into: yaml)
            try MihomoConfigFileStore.save(mergedYAML)
            if result.nodes.isEmpty {
                _ = reloadHomeFromConfigFile(sourceName: result.sourceName, sourceURL: result.sourceURL)
            } else {
                let source = ProxyConfigSource(
                    name: result.sourceName,
                    url: result.sourceURL,
                    nodes: result.nodes,
                    updatedAt: Date()
                )
                configSources = [source]
                selectSource(source)
                persistSourceState()
            }
            return true
        } catch {
            importErrorMessage = (error as? SubscriptionNodeImportError)?.localizedDescription ?? error.localizedDescription
            showImportError = true
            return false
        }
    }

    /// Parse `default.conf` and refresh「我的配置」node list. Returns false if no file.
    @discardableResult
    private func reloadHomeFromConfigFile(sourceName: String? = nil, sourceURL: String? = nil) -> Bool {
        guard let yaml = MihomoConfigFileStore.loadText() else { return false }

        let parsedNodes = MihomoYAMLConfigParser.parseProxies(from: yaml)
        let name = sourceName
            ?? configSources.first?.name
            ?? "本地配置"
        let url = sourceURL
            ?? configSources.first?.url
            ?? "local://default.conf"

        let source = ProxyConfigSource(
            name: name,
            url: url,
            nodes: parsedNodes,
            updatedAt: Date()
        )
        configSources = [source]
        selectSource(source)
        persistSourceState()
        return true
    }

    private func loadConfigSourcesIfNeeded() {
        if let savedSources = store.load([ProxyConfigSource].self, forKey: configSourcesKey), !savedSources.isEmpty {
            configSources = savedSources
            return
        }

        guard let savedNodes = store.load([ServerNode].self, forKey: importedNodesKey), !savedNodes.isEmpty else {
            configSources = []
            nodes = []
            return
        }

        configSources = [
            ProxyConfigSource(
                name: "已导入配置",
                url: "local://legacy-import",
                nodes: savedNodes,
                updatedAt: Date()
            )
        ]
        nodes = savedNodes
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

        if configSources.isEmpty {
            store.removeValue(forKey: importedNodesKey)
            return
        }

        if let selectedSourceID,
           let selectedSource = configSources.first(where: { $0.id == selectedSourceID }) {
            try? store.save(selectedSource.nodes, forKey: importedNodesKey)
        } else if let first = configSources.first {
            try? store.save(first.nodes, forKey: importedNodesKey)
        }
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
            .init(name: "🇭🇰 香港 01", host: "hk.example.com", port: 443, password: "demo", nodeType: "trojan", sni: "cdn.example.com", latency: 72),
            .init(name: "🇯🇵 日本 01", host: "jp.example.com", port: 443, password: "demo", nodeType: "trojan", sni: "cdn.example.com", latency: 124),
            .init(name: "🇺🇸 美国 01", host: "us.example.com", port: 443, password: "demo", nodeType: "trojan", sni: "cdn.example.com", latency: -1)
        ]
        let sgNodes: [ServerNode] = [
            .init(name: "🇸🇬 新加坡 01", host: "sg1.example.com", port: 443, password: "demo", nodeType: "trojan", sni: "cdn.example.com", latency: 38),
            .init(name: "🇸🇬 新加坡 02", host: "sg2.example.com", port: 443, password: "demo", nodeType: "trojan", sni: "cdn.example.com", latency: 42)
        ]
        viewModel.configSources = [
            ProxyConfigSource(name: "XFLTD", url: "https://example.com/a.yaml", nodes: hkNodes),
            ProxyConfigSource(name: "备用订阅", url: "https://example.com/b.yaml", nodes: sgNodes)
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