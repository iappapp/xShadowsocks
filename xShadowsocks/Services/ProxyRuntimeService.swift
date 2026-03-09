import Foundation

@MainActor
protocol ProxyRuntimeServiceProtocol: AnyObject {
    var engine: ProxyEngine { get }
    var onStateChange: ((ProxyRuntimeState) -> Void)? { get set }

    func start(with request: ProxyRuntimeRequest) async throws
    func stop() async throws
    func refreshConfig(with request: ProxyRuntimeRequest) async throws
    func currentState() async -> ProxyRuntimeState
}

enum ProxyRuntimeState: Equatable {
    case stopped
    case starting
    case running(statusDetail: String)
    case failed(String)
}

struct ProxyRuntimeRequest {
    let nodes: [ServerNode]
    let selectedNode: ServerNode?
    let selectedNodeID: UUID?
    let routeMode: MihomoRouteMode
    let localProxyPort: UInt16
}

enum ProxyRuntimeRequestError: LocalizedError {
    case missingNode

    var errorDescription: String? {
        switch self {
        case .missingNode:
            return "请先选择一个节点"
        }
    }
}

@MainActor
final class LocalProxyRuntimeService: ProxyRuntimeServiceProtocol {
    let engine: ProxyEngine = .local
    var onStateChange: ((ProxyRuntimeState) -> Void)?

    private let listenPort: UInt16
    private let localProxyService: LocalTrojanProxyService
    private var state: ProxyRuntimeState = .stopped

    init(listenPort: UInt16) {
        self.listenPort = listenPort
        self.localProxyService = LocalTrojanProxyService(listenPort: listenPort)

        localProxyService.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleLocalStateChange(state)
            }
        }
    }

    func start(with request: ProxyRuntimeRequest) async throws {
        guard let selectedNode = request.selectedNode else {
            throw ProxyRuntimeRequestError.missingNode
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
    }

    func stop() async throws {
        localProxyService.stop()
    }

    func refreshConfig(with request: ProxyRuntimeRequest) async throws {
        try await start(with: request)
    }

    func currentState() async -> ProxyRuntimeState {
        state
    }

    private func handleLocalStateChange(_ state: LocalDebugProxyState) {
        let mappedState = Self.mapLocalState(state, listenPort: listenPort)
        self.state = mappedState
        onStateChange?(mappedState)
    }

    private static func mapLocalState(_ state: LocalDebugProxyState, listenPort: UInt16) -> ProxyRuntimeState {
        switch state {
        case .stopped:
            return .stopped
        case .starting:
            return .starting
        case .running:
            return .running(statusDetail: "端口 \(listenPort)")
        case .failed(let message):
            return .failed(message)
        }
    }
}

@MainActor
final class MihomoProxyRuntimeService: ProxyRuntimeServiceProtocol {
    let engine: ProxyEngine = .mihomo
    var onStateChange: ((ProxyRuntimeState) -> Void)?

    private let runtimeManager: MihomoRuntimeManager

    init(runtimeManager: MihomoRuntimeManager) {
        self.runtimeManager = runtimeManager

        let weakBox = WeakMihomoProxyRuntimeServiceBox(self)
        Task {
            await runtimeManager.setOnStateChange { state in
                Task { @MainActor in
                    weakBox.value?.onStateChange?(Self.mapMihomoState(state))
                }
            }
        }
    }

    func start(with request: ProxyRuntimeRequest) async throws {
        try await runtimeManager.start(with: makeBootstrapRequest(from: request))
    }

    func stop() async throws {
        try await runtimeManager.stop()
    }

    func refreshConfig(with request: ProxyRuntimeRequest) async throws {
        try await runtimeManager.reload(with: makeBootstrapRequest(from: request))
    }

    func currentState() async -> ProxyRuntimeState {
        Self.mapMihomoState(await runtimeManager.currentState())
    }

    private func makeBootstrapRequest(from request: ProxyRuntimeRequest) -> MihomoBootstrapRequest {
        MihomoBootstrapRequest(
            nodes: request.nodes.map {
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
            selectedNodeID: request.selectedNodeID,
            routeMode: request.routeMode,
            mixedPort: Int(request.localProxyPort),
            socksPort: Int(request.localProxyPort) + 1,
            externalControllerPort: 9090,
            externalControllerSecret: nil
        )
    }

    private static func mapMihomoState(_ state: MihomoRuntimeState) -> ProxyRuntimeState {
        switch state {
        case .stopped:
            return .stopped
        case .starting:
            return .starting
        case .running(let snapshot):
            return .running(statusDetail: "Mixed \(snapshot.mixedPort)")
        case .failed(let message):
            return .failed(message)
        }
    }
}

private final class WeakMihomoProxyRuntimeServiceBox: @unchecked Sendable {
    weak var value: MihomoProxyRuntimeService?

    init(_ value: MihomoProxyRuntimeService?) {
        self.value = value
    }
}
