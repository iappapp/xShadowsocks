import Foundation

@MainActor
final class ProxySelectorService {
    private let store: AppGroupStore
    private let mihomoRuntimeManager: MihomoRuntimeManager
    private let runtimeService: MihomoProxyRuntimeService
    private var localProxyPort: UInt16
    private var isRunning = false

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
        self.runtimeService = MihomoProxyRuntimeService(runtimeManager: mihomoRuntimeManager)
        bindRuntimeStateChanges()
    }

    func syncPortFromSettings(isProxyEnabled: Bool) {
        let latestPort = Self.loadProxyPort(from: store)
        guard latestPort != localProxyPort else { return }
        guard !isProxyEnabled else { return }
        localProxyPort = latestPort
    }

    func setProxyEnabled(
        enabled: Bool,
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
            if isRunning {
                try await runtimeService.refreshConfig(with: request)
            } else {
                try await runtimeService.start(with: request)
            }
            isRunning = true
        } else {
            try await runtimeService.stop()
            isRunning = false
        }
    }

    func refreshConfig(
        nodes: [ServerNode],
        selectedNode: ServerNode?,
        selectedNodeID: UUID?,
        routeMode: MihomoRouteMode
    ) async throws {
        try await runtimeService.refreshConfig(
            with: ProxyRuntimeRequest(
                nodes: nodes,
                selectedNode: selectedNode,
                selectedNodeID: selectedNodeID,
                routeMode: routeMode,
                localProxyPort: localProxyPort
            )
        )
    }

    func currentState() async -> ProxyRuntimeState {
        await runtimeService.currentState()
    }

    private func bindRuntimeStateChanges() {
        runtimeService.onStateChange = { [weak self] state in
            self?.handleRuntimeState(state)
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

    private static func loadProxyPort(from store: AppGroupStore) -> UInt16 {
        let rawValue = store.loadInt(forKey: store.proxyPortKey, default: 7890)
        let clamped = min(max(rawValue, 2000), 9000)
        return UInt16(clamped)
    }
}
