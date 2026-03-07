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
    @Published var proxyEngine: ProxyEngine = .mihomo
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

        let orchestrator = ProxySelectorService(store: store)
        orchestrator.onStatusTextChange = { [weak self] text in
            self?.localProxyStatusText = text
        }
        orchestrator.onFailure = { [weak self] message in
            guard let self else { return }
            self.proxyErrorMessage = message
            self.showProxyError = true
            self.isSyncingProxyState = true
            self.isProxyEnabled = false
            self.isSyncingProxyState = false
        }
        self.proxySelectorService = orchestrator
    }

    var selectedNode: ServerNode? {
        nodes.first { $0.id == selectedNodeID }
    }

    var selectedSource: ProxyConfigSource? {
        configSources.first { $0.id == selectedSourceID }
    }

    var isLocalDevelopmentMode: Bool {
        proxyEngine == .local || proxyEngine == .mihomo
    }

    var proxyEngineTitle: String {
        proxyEngine.title
    }

    func onAppear() {
        guard !isPreviewMode else { return }
        loadConfigSourcesIfNeeded()
        routeMode = loadRouteModeFromSettings()
        proxyEngine = loadProxyEngineFromSettings()
        proxySelectorService?.syncPortFromSettings(isProxyEnabled: isProxyEnabled)

        ensureSelectedSourceAndNode()
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
                        do {
                            let latency = try await LocalTrojanProxyService.measureConnectivity(
                                using: LocalDebugTrojanNode(
                                    host: node.host,
                                    port: node.port,
                                    password: node.password,
                                    sni: node.sni,
                                    type: node.nodeType
                                )
                            )
                            return (node.id, latency)
                        } catch {
                            return (node.id, -1)
                        }
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
                if enabled {
                    _ = try makeLaunchConfigData()
                }

                try await proxySelectorService?.setProxyEnabled(
                    enabled: enabled,
                    engine: proxyEngine,
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

            // If the subscription was a full mihomo YAML config, persist it as the local config file.
            if let yaml = result.rawYAMLConfig {
                saveYAMLConfigFile(yaml)
            }

            let source = ProxyConfigSource(name: result.sourceName, url: result.sourceURL, nodes: result.nodes, updatedAt: Date())
            if let index = configSources.firstIndex(where: { $0.url == result.sourceURL }) {
                configSources[index] = source
            } else {
                configSources.append(source)
            }

            selectSource(source)
            try store.save(configSources, forKey: configSourcesKey)
            try store.save(result.nodes, forKey: importedNodesKey)
            return true
        } catch {
            importErrorMessage = (error as? SubscriptionNodeImportError)?.localizedDescription ?? error.localizedDescription
            showImportError = true
            return false
        }
    }

    /// Writes a full mihomo YAML config to the shared app-support directory,
    /// mirroring the path used by ConfigViewModel so both tabs see the same file.
    private func saveYAMLConfigFile(_ yaml: String) {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = baseDir
            .appendingPathComponent("mihomo", isDirectory: true)
            .appendingPathComponent("default.conf", isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try yaml.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: nodes were still parsed; config file write failure is surfaced via ConfigViewModel
        }
    }

    private func makeLaunchConfigData() throws -> Data {
        guard let selectedNode else {
            throw NodeImportError.missingNode
        }

        let payload = TunnelLaunchConfig(
            remark: selectedNode.name,
            server: selectedNode.host,
            port: String(selectedNode.port),
            password: selectedNode.password,
            method: selectedNode.method ?? "aes-256-gcm",
            plugin: selectedNode.nodeType == "trojan" ? "trojan" : "none",
            pluginOptions: selectedNode.sni ?? "",
            udpRelay: true,
            tcpFastOpen: false,
            routingRules: []
        )

        let appConfig = ShadowsocksConfig(
            remark: payload.remark,
            server: payload.server,
            port: payload.port,
            password: payload.password,
            method: .aes256gcm,
            plugin: .none,
            pluginOptions: payload.pluginOptions,
            udpRelay: payload.udpRelay,
            tcpFastOpen: payload.tcpFastOpen
        )
        try store.save(appConfig, forKey: store.sharedConfigKey)
        return try JSONEncoder().encode(payload)
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

    private func loadProxyEngineFromSettings() -> ProxyEngine {
        let rawValue = store.loadString(forKey: store.proxyEngineKey, default: ProxyEngine.mihomo.rawValue)
        return ProxyEngine(rawValue: rawValue) ?? .mihomo
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
        viewModel.proxyEngine = .mihomo
        viewModel.isProxyEnabled = true
        viewModel.localProxyStatusText = "运行中 (Mixed 7890)"
        return viewModel
    }
}

private enum NodeImportError: LocalizedError {
    case missingNode

    var errorDescription: String? {
        switch self {
        case .missingNode:
            return "请先选择一个节点"
        }
    }
}

private struct TunnelLaunchConfig: Codable {
    let remark: String
    let server: String
    let port: String
    let password: String
    let method: String
    let plugin: String
    let pluginOptions: String
    let udpRelay: Bool
    let tcpFastOpen: Bool
    let routingRules: [String]
}
