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
    private let trojanProxyService: LocalTrojanProxyService?
    private let vlessProxyService: LocalVlessProxyService?
    private var activeServiceType: String?
    private var state: ProxyRuntimeState = .stopped

    init(listenPort: UInt16) {
        self.listenPort = listenPort
        let trojan = LocalTrojanProxyService(listenPort: listenPort)
        let vless = LocalVlessProxyService(listenPort: listenPort)
        self.trojanProxyService = trojan
        self.vlessProxyService = vless

        trojan.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleLocalStateChange(state)
            }
        }
        vless.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleLocalStateChange(state)
            }
        }
    }

    func start(with request: ProxyRuntimeRequest) async throws {
        guard let selectedNode = request.selectedNode else {
            throw ProxyRuntimeRequestError.missingNode
        }

        // Stop any previously running local service
        trojanProxyService?.stop()
        vlessProxyService?.stop()

        let nodeType = selectedNode.nodeType.lowercased()

        switch nodeType {
        case "trojan":
            guard let svc = trojanProxyService else {
                throw LocalProxyRuntimeError.noService
            }
            activeServiceType = "trojan"
            try svc.start(using: LocalDebugTrojanNode(
                host: selectedNode.host,
                port: selectedNode.port,
                password: selectedNode.password,
                sni: selectedNode.sni,
                type: selectedNode.nodeType
            ))
        case "vless":
            guard let svc = vlessProxyService else {
                throw LocalProxyRuntimeError.noService
            }
            activeServiceType = "vless"
            try svc.start(using: LocalDebugVlessNode(
                host: selectedNode.host,
                port: selectedNode.port,
                uuid: selectedNode.password,
                sni: selectedNode.sni,
                type: selectedNode.nodeType,
                flow: selectedNode.flow,
                encryption: selectedNode.encryption,
                publicKey: selectedNode.publicKey,
                shortId: selectedNode.shortId,
                network: selectedNode.network,
                serviceName: selectedNode.serviceName
            ))
        default:
            throw LocalProxyRuntimeError.unsupportedNodeType(nodeType)
        }
    }

    func stop() async throws {
        trojanProxyService?.stop()
        vlessProxyService?.stop()
        activeServiceType = nil
    }

    func refreshConfig(with request: ProxyRuntimeRequest) async throws {
        try await start(with: request)
    }

    func currentState() async -> ProxyRuntimeState {
        state
    }

    private func handleLocalStateChange(_ state: LocalDebugProxyState) {
        let mappedState = Self.mapLocalState(state, listenPort: listenPort, nodeType: activeServiceType)
        self.state = mappedState
        onStateChange?(mappedState)
    }

    private static func mapLocalState(_ state: LocalDebugProxyState, listenPort: UInt16, nodeType: String?) -> ProxyRuntimeState {
        switch state {
        case .stopped:
            return .stopped
        case .starting:
            return .starting
        case .running:
            let typeLabel = nodeType?.uppercased() ?? "Proxy"
            return .running(statusDetail: "\(typeLabel) 端口 \(listenPort)")
        case .failed(let message):
            return .failed(message)
        }
    }
}

private enum LocalProxyRuntimeError: LocalizedError {
    case noService
    case unsupportedNodeType(String)

    var errorDescription: String? {
        switch self {
        case .noService:
            return "本地代理服务未就绪"
        case .unsupportedNodeType(let type):
            return "Local 引擎不支持节点类型: \(type)"
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
                    type: $0.nodeType,
                    flow: $0.flow,
                    encryption: $0.encryption,
                    network: $0.network,
                    realityOpts: $0.publicKey != nil || $0.shortId != nil ? RealityOpts(
                        publicKey: $0.publicKey,
                        shortId: $0.shortId,
                        serverName: $0.sni
                    ) : nil,
                    serviceName: $0.serviceName,
                    headers: $0.headers
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