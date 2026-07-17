import Foundation

@MainActor
protocol ProxyRuntimeServiceProtocol: AnyObject {
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

@MainActor
final class MihomoProxyRuntimeService: ProxyRuntimeServiceProtocol {
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
                    tls: $0.tls,
                    skipCertVerify: $0.skipCertVerify,
                    network: $0.network,
                    realityOpts: $0.publicKey != nil || $0.shortId != nil ? RealityOpts(
                        publicKey: $0.publicKey,
                        shortId: $0.shortId,
                        serverName: $0.sni
                    ) : nil,
                    serviceName: $0.serviceName,
                    clientFingerprint: $0.clientFingerprint,
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
