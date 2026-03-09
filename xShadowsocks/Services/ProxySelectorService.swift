import Foundation

@MainActor
final class ProxySelectorService {
    private let store: AppGroupStore
    private let mihomoRuntimeManager: MihomoRuntimeManager
    private var localProxyService: LocalTrojanProxyService
    private var localProxyPort: UInt16

    var onStatusTextChange: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    init(store: AppGroupStore = .shared) {
        self.store = store
        self.localProxyPort = ProxySelectorService.loadProxyPort(from: store)

        let workingDirectoryURL: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            workingDirectoryURL = appSupport.appendingPathComponent("mihomo", isDirectory: true)
        } else {
            workingDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("mihomo", isDirectory: true)
        }

        self.localProxyService = LocalTrojanProxyService(listenPort: localProxyPort)
        self.mihomoRuntimeManager = MihomoRuntimeManager(
            bridge: DynamicMihomoCoreBridge(),
            workingDirectoryURL: workingDirectoryURL
        )

        bindLocalProxyStateChange()

        let weakBox = WeakProxySelectorServiceBox(self)
        let runtime = mihomoRuntimeManager

        Task {
            await runtime.setOnStateChange { state in
                Task { @MainActor in
                    weakBox.value?.handleMihomoRuntimeState(state)
                }
            }
        }
    }

    func syncPortFromSettings(isProxyEnabled: Bool) {
        let latestPort = Self.loadProxyPort(from: store)
        guard latestPort != localProxyPort else { return }
        guard !isProxyEnabled else { return }

        localProxyPort = latestPort
        localProxyService = LocalTrojanProxyService(listenPort: localProxyPort)
        bindLocalProxyStateChange()
    }

    func setProxyEnabled(
        enabled: Bool,
        engine: ProxyEngine,
        nodes: [ServerNode],
        selectedNode: ServerNode?,
        selectedNodeID: UUID?,
        routeMode: MihomoRouteMode
    ) async throws {
        switch engine {
        case .local:
            try applyLocalProxy(enabled: enabled, selectedNode: selectedNode)
        case .mihomo:
            try await applyMihomoProxy(
                enabled: enabled,
                nodes: nodes,
                selectedNode: selectedNode,
                selectedNodeID: selectedNodeID,
                routeMode: routeMode
            )
        }
    }

    private func applyLocalProxy(enabled: Bool, selectedNode: ServerNode?) throws {
        if enabled {
            guard let selectedNode else {
                throw ProxyOrchestratorError.missingNode
            }
            try localProxyService.start(
                using: LocalDebugTrojanNode(
                    host: selectedNode.host,
                    port: selectedNode.port,
                    password: selectedNode.password,
                    sni: selectedNode.sni,
                    type: selectedNode.nodeType
                )
            )
        } else {
            localProxyService.stop()
        }
    }

    private func applyMihomoProxy(
        enabled: Bool,
        nodes: [ServerNode],
        selectedNode: ServerNode?,
        selectedNodeID: UUID?,
        routeMode: MihomoRouteMode
    ) async throws {
        if enabled {
            guard selectedNode != nil else {
                throw ProxyOrchestratorError.missingNode
            }

            localProxyService.stop()

            try await mihomoRuntimeManager.start(
                with: MihomoBootstrapRequest(
                    nodes: nodes.map {
                        MihomoProxyNode(
                            id: $0.id,
                            name: $0.name,
                            host: $0.host,
                            port: $0.port,
                            password: $0.password,
                            sni: $0.sni,
                            type: $0.nodeType
                        )
                    },
                    selectedNodeID: selectedNodeID,
                    routeMode: routeMode,
                    mixedPort: Int(localProxyPort),
                    socksPort: Int(localProxyPort) + 1,
                    externalControllerPort: 9090,
                    externalControllerSecret: nil
                )
            )
        } else {
            try await mihomoRuntimeManager.stop()
            localProxyService.stop()
        }
    }

    private func bindLocalProxyStateChange() {
        localProxyService.onStateChange = { [weak self] state in
            guard let self else { return }

            switch state {
            case .stopped:
                onStatusTextChange?("未启动")
            case .starting:
                onStatusTextChange?("启动中")
            case .running:
                onStatusTextChange?("运行中(端口 \(localProxyPort))")
            case let .failed(message):
                onStatusTextChange?("启动失败")
                onFailure?(message)
            }
        }
    }

    private func handleMihomoRuntimeState(_ state: MihomoRuntimeState) {
        switch state {
        case .stopped:
            onStatusTextChange?("未启动")
        case .starting:
            onStatusTextChange?("启动中")
        case .running(let snapshot):
            onStatusTextChange?("运行中(Mixed \(snapshot.mixedPort))")
        case .failed(let message):
            onStatusTextChange?("启动失败")
            onFailure?(message)
        }
    }

    private static func loadProxyPort(from store: AppGroupStore) -> UInt16 {
        let rawValue = store.loadInt(forKey: store.proxyPortKey, default: 7890)
        let clamped = min(max(rawValue, 2000), 9000)
        return UInt16(clamped)
    }
}

enum ProxyOrchestratorError: LocalizedError {
    case missingNode

    var errorDescription: String? {
        switch self {
        case .missingNode:
            return "请先选择一个节点"
        }
    }
}

private final class WeakProxySelectorServiceBox: @unchecked Sendable {
    weak var value: ProxySelectorService?

    init(_ value: ProxySelectorService?) {
        self.value = value
    }
}
