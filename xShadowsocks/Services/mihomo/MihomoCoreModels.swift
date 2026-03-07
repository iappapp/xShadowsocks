import Foundation

enum MihomoRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(MihomoRuntimeSnapshot)
    case failed(String)
}

struct MihomoRuntimeSnapshot: Equatable, Sendable {
    let configPath: String
    let workingDirectory: String
    let mixedPort: Int
    let socksPort: Int
    let externalController: String
}

enum MihomoRouteMode: String, CaseIterable, Sendable {
    case configuration
    case proxy
    case direct
}

struct MihomoProxyNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let password: String
    let sni: String?
    let type: String

    init(id: UUID = UUID(), name: String, host: String, port: Int, password: String, sni: String?, type: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        self.sni = sni
        self.type = type
    }
}

struct MihomoBootstrapRequest: Sendable {
    let nodes: [MihomoProxyNode]
    let selectedNodeID: UUID?
    let routeMode: MihomoRouteMode
    let mixedPort: Int
    let socksPort: Int
    let externalControllerPort: Int
    let externalControllerSecret: String?

    init(
        nodes: [MihomoProxyNode],
        selectedNodeID: UUID?,
        routeMode: MihomoRouteMode,
        mixedPort: Int = 7890,
        socksPort: Int = 7891,
        externalControllerPort: Int = 9090,
        externalControllerSecret: String? = nil
    ) {
        self.nodes = nodes
        self.selectedNodeID = selectedNodeID
        self.routeMode = routeMode
        self.mixedPort = mixedPort
        self.socksPort = socksPort
        self.externalControllerPort = externalControllerPort
        self.externalControllerSecret = externalControllerSecret
    }
}

struct MihomoRenderedConfig: Sendable {
    let yamlText: String
    let selectedProxyName: String
    let externalController: String
}

protocol MihomoCoreBridge: Sendable {
    var isRunning: Bool { get }

    func start(configPath: String, workingDirectory: String) throws
    func reload(configPath: String) throws
    func stop() throws
}

struct MihomoCoreBridgeHandlers: Sendable {
    let isRunning: @Sendable () -> Bool
    let start: @Sendable (_ configPath: String, _ workingDirectory: String) throws -> Void
    let reload: @Sendable (_ configPath: String) throws -> Void
    let stop: @Sendable () throws -> Void
}

final class ClosureMihomoCoreBridge: MihomoCoreBridge {
    private let handlers: MihomoCoreBridgeHandlers

    init(handlers: MihomoCoreBridgeHandlers) {
        self.handlers = handlers
    }

    var isRunning: Bool {
        handlers.isRunning()
    }

    func start(configPath: String, workingDirectory: String) throws {
        try handlers.start(configPath, workingDirectory)
    }

    func reload(configPath: String) throws {
        try handlers.reload(configPath)
    }

    func stop() throws {
        try handlers.stop()
    }
}

final class PlaceholderMihomoCoreBridge: MihomoCoreBridge {
    var isRunning: Bool { false }

    func start(configPath: String, workingDirectory: String) throws {
        throw MihomoRuntimeError.bridgeNotReady
    }

    func reload(configPath: String) throws {
        throw MihomoRuntimeError.bridgeNotReady
    }

    func stop() throws {
        throw MihomoRuntimeError.bridgeNotReady
    }
}

enum MihomoRuntimeError: LocalizedError {
    case missingSelectedNode
    case unsupportedNodeType(String)
    case emptyNodeList
    case bridgeNotReady

    var errorDescription: String? {
        switch self {
        case .missingSelectedNode:
            return "未选择可用节点"
        case .unsupportedNodeType(let type):
            return "Mihomo 模式暂不支持节点类型: \(type)"
        case .emptyNodeList:
            return "节点列表为空"
        case .bridgeNotReady:
            return "Mihomo Core 未就绪：请检查 xcframework 是否 Embed & Sign 且已导出 mihomo_* 符号"
        }
    }
}
