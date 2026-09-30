import Foundation
import os
import MihomoCore

/// Thin Swift wrapper over the four C entry points exported by `MihomoCore`.
///
/// The core keeps global state, so every call is funnelled through one queue.
public final class MihomoCoreBridge {
    public static let shared = MihomoCoreBridge()

    public enum BridgeError: LocalizedError {
        case alreadyRunning
        case notRunning
        case missingConfigFile(String)
        case startFailed(Int32)
        case reloadFailed(Int32)
        case stopFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Mihomo 已在运行"
            case .notRunning:
                return "Mihomo 未运行"
            case .missingConfigFile(let path):
                return "未找到配置文件: \(path)"
            case .startFailed(let code):
                return "Mihomo 启动失败 (code \(code))\(MihomoCoreBridge.explanation(forStartCode: code))"
            case .reloadFailed(let code):
                return "Mihomo 重载配置失败 (code \(code))"
            case .stopFailed(let code):
                return "Mihomo 停止失败 (code \(code))"
            }
        }
    }

    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "MihomoCoreBridge")
    private let queue = DispatchQueue(label: "com.github.iappapp.xShadowsocks.mihomo-core")

    private init() {}

    public var isRunning: Bool {
        queue.sync { mihomo_is_running() != 0 }
    }

    /// Starts the core with `configPath` inside `workingDirectory`.
    ///
    /// `configPath` may be absolute or relative to `workingDirectory` — the bundled
    /// bridge resolves either.
    public func start(configPath: String, workingDirectory: String) throws {
        try queue.sync {
            if mihomo_is_running() != 0 {
                throw BridgeError.alreadyRunning
            }
            let code = configPath.withCString { configPointer in
                workingDirectory.withCString { directoryPointer in
                    mihomo_start_with_config(configPointer, directoryPointer)
                }
            }
            guard code == 0 else {
                logger.error("start failed code=\(code)")
                throw BridgeError.startFailed(code)
            }
            logger.info("core started")
        }
    }

    public func reload(configPath: String) throws {
        try queue.sync {
            guard mihomo_is_running() != 0 else { throw BridgeError.notRunning }
            let code = configPath.withCString { mihomo_reload_config($0) }
            guard code == 0 else {
                logger.error("reload failed code=\(code)")
                throw BridgeError.reloadFailed(code)
            }
            logger.info("core reloaded")
        }
    }

    public func stop() throws {
        try queue.sync {
            guard mihomo_is_running() != 0 else { return }
            let code = mihomo_stop()
            guard code == 0 else {
                logger.error("stop failed code=\(code)")
                throw BridgeError.stopFailed(code)
            }
            logger.info("core stopped")
        }
    }

    /// Mirrors the codes returned by the core's `startCore` so the tunnel can surface
    /// something actionable instead of a bare number.
    private static func explanation(forStartCode code: Int32) -> String {
        switch code {
        case -1: return "（参数为空）"
        case -2: return "（配置目录初始化失败）"
        case -3: return "（配置解析失败，请检查 YAML 是否合法）"
        case -5: return "（配置文件不存在）"
        default: return ""
        }
    }
}
