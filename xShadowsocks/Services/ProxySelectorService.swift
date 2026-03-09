import Foundation

@MainActor
final class ProxySelectorService {
    private let store: AppGroupStore
    private let mihomoRuntimeManager: MihomoRuntimeManager
    private var runtimeServices: [ProxyEngine: any ProxyRuntimeServiceProtocol] = [:]
    private var activeEngine: ProxyEngine?
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

        self.mihomoRuntimeManager = MihomoRuntimeManager(
            bridge: DynamicMihomoCoreBridge(),
            workingDirectoryURL: workingDirectoryURL
        )
        self.runtimeServices = Self.makeRuntimeServices(
            localProxyPort: localProxyPort,
            runtimeManager: mihomoRuntimeManager
        )
        bindRuntimeStateChanges()
    }

    func syncPortFromSettings(isProxyEnabled: Bool) {
        let latestPort = Self.loadProxyPort(from: store)
        guard latestPort != localProxyPort else { return }
        guard !isProxyEnabled else { return }

        localProxyPort = latestPort
        runtimeServices = Self.makeRuntimeServices(
            localProxyPort: localProxyPort,
            runtimeManager: mihomoRuntimeManager
        )
        bindRuntimeStateChanges()
    }

    func setProxyEnabled(
        enabled: Bool,
        engine: ProxyEngine,
        nodes: [ServerNode],
        selectedNode: ServerNode?,
        selectedNodeID: UUID?,
        routeMode: MihomoRouteMode
    ) async throws {
        let request = ProxyRuntimeRequest(
            nodes: nodes,
            selectedNode: selectedNode,
            selectedNodeID: selectedNodeID,
            routeMode: routeMode,
            localProxyPort: localProxyPort
        )

        if enabled {
            guard selectedNode != nil else {
                throw ProxyRuntimeRequestError.missingNode
            }

            try await stopAllServices(except: engine)
            let runtime = try service(for: engine)

            if activeEngine == engine {
                try await runtime.refreshConfig(with: request)
            } else {
                try await runtime.start(with: request)
            }

            activeEngine = engine
        } else {
            try await stopAllServices(except: nil)
            activeEngine = nil
        }
    }

    func refreshConfig(
        engine: ProxyEngine,
        nodes: [ServerNode],
        selectedNode: ServerNode?,
        selectedNodeID: UUID?,
        routeMode: MihomoRouteMode
    ) async throws {
        let runtime = try service(for: engine)
        try await runtime.refreshConfig(
            with: ProxyRuntimeRequest(
                nodes: nodes,
                selectedNode: selectedNode,
                selectedNodeID: selectedNodeID,
                routeMode: routeMode,
                localProxyPort: localProxyPort
            )
        )
    }

    func currentState(for engine: ProxyEngine) async throws -> ProxyRuntimeState {
        try await service(for: engine).currentState()
    }

    private func bindRuntimeStateChanges() {
        for service in runtimeServices.values {
            service.onStateChange = { [weak self] state in
                self?.handleRuntimeState(state)
            }
        }
    }

    private func handleRuntimeState(_ state: ProxyRuntimeState) {
        switch state {
        case .stopped:
            onStatusTextChange?("未启动")
        case .starting:
            onStatusTextChange?("启动中")
        case .running(let statusDetail):
            onStatusTextChange?("运行中(\(statusDetail))")
        case .failed(let message):
            onStatusTextChange?("启动失败")
            onFailure?(message)
        }
    }

    private func service(for engine: ProxyEngine) throws -> any ProxyRuntimeServiceProtocol {
        guard let service = runtimeServices[engine] else {
            throw NSError(
                domain: "ProxySelectorService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未找到代理引擎实现: \(engine.rawValue)"]
            )
        }
        return service
    }

    private func stopAllServices(except engine: ProxyEngine?) async throws {
        for service in runtimeServices.values where engine == nil || service.engine != engine {
            try await service.stop()
        }
    }

    private static func makeRuntimeServices(
        localProxyPort: UInt16,
        runtimeManager: MihomoRuntimeManager
    ) -> [ProxyEngine: any ProxyRuntimeServiceProtocol] {
        [
            .local: LocalProxyRuntimeService(listenPort: localProxyPort),
            .mihomo: MihomoProxyRuntimeService(runtimeManager: runtimeManager)
        ]
    }

    private static func loadProxyPort(from store: AppGroupStore) -> UInt16 {
        let rawValue = store.loadInt(forKey: store.proxyPortKey, default: 7890)
        let clamped = min(max(rawValue, 2000), 9000)
        return UInt16(clamped)
    }
}
