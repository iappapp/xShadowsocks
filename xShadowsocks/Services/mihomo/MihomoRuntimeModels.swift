import Foundation

// Runtime vocabulary of `MihomoRuntimeManager`, which hosts the core inside the app
// (no packet tunnel). The models describe what the manager reports and what a
// start/reload is asked to run.

/// Lifecycle state reported through the manager's state-change handler.
enum MihomoRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(MihomoRuntimeSnapshot)
    case failed(String)
}

/// What the core is currently running from.
struct MihomoRuntimeSnapshot: Equatable, Sendable {
    let configPath: String
    let workingDirectory: String
}

/// A request to start or reload the core.
///
/// `configFileName` is relative to the manager's working directory; nil means the
/// file `MihomoConfigFileStore.activeFileName` points at.
struct MihomoBootstrapRequest: Sendable {
    let configFileName: String?

    init(configFileName: String? = nil) {
        self.configFileName = configFileName
    }
}

enum MihomoRuntimeError: LocalizedError {
    case missingConfigFile(String)

    var errorDescription: String? {
        switch self {
        case .missingConfigFile(let fileName):
            return "未找到配置文件 \(fileName)，请先导入订阅或配置"
        }
    }
}
