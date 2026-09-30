import Foundation
import NetworkExtension

/// Owns the system VPN profile and the lifecycle of the packet-tunnel extension.
///
/// The core runs inside the extension, so the app's job is to make sure the profile
/// exists with the right settings, hand the extension the identifiers it needs, and
/// then start/stop it. Everything the extension reads comes from the App Group.
public final class TunnelManager {
    public static let shared = TunnelManager()

    public static let extensionBundleIdentifier = "com.github.iappapp.xShadowsocks.xPacketTunnel"
    public static let tunnelDescription = "xShadowsocks"

    /// True when the packet-tunnel extension was actually embedded in this build.
    ///
    /// Embedding it is a build-time decision driven by the signing entitlement: without
    /// a paid developer account there is no Network Extension entitlement, so the
    /// extension cannot be signed and Xcode drops it (or fails the build). Checking the
    /// bundle is more reliable than asking the system, which reports nothing useful when
    /// no profile was ever installed.
    public static var isExtensionEmbedded: Bool {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(
            atPath: pluginsURL.appendingPathComponent("xPacketTunnel.appex").path
        )
    }

    private let store = AppGroupStore.shared

    private init() {}

    public enum TunnelManagerError: LocalizedError {
        case providerBundleNotFound
        case noConfigurationSaved
        case notConnected
        case messageFailed(String)

        public var errorDescription: String? {
            switch self {
            case .providerBundleNotFound:
                return "未找到隧道扩展，请确认 xPacketTunnel 已嵌入并签名"
            case .noConfigurationSaved:
                return "未找到 VPN 配置，请先开启一次代理以完成安装"
            case .notConnected:
                return "隧道未连接"
            case .messageFailed(let reason):
                return "发送消息失败: \(reason)"
            }
        }
    }

    /// The most recently used configuration, if one was already installed.
    public func existingManager() async -> NETunnelProviderManager? {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        return managers.first { configuration in
            (configuration.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == Self.extensionBundleIdentifier
        }
    }

    public func isConnected() async -> Bool {
        guard let manager = await existingManager() else { return false }
        return manager.connection.status == .connected
    }

    /// Installs (or refreshes) the profile, then starts the tunnel.
    ///
    /// - Parameter activeConfigFileName: the YAML file inside the App Group workdir
    ///   the extension should hand to the core. Written before starting so the
    ///   extension always sees the user's current selection.
    public func start(activeConfigFileName: String) async throws {
        let manager = try await loadOrCreateManager()

        // The extension reads these from the App Group, but the profile is what the
        // system uses to decide whether the tunnel may run at all.
        store.saveValue(activeConfigFileName, forKey: store.activeConfigFileNameKey)

        let secret = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["apiSecret"] as? String
            ?? UUID().uuidString

        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = Self.extensionBundleIdentifier
        protocolConfiguration.serverAddress = "127.0.0.1"
        protocolConfiguration.providerConfiguration = [
            "apiSecret": secret,
            "configFileName": activeConfigFileName
        ]
        // The extension installs its own routes, so no on-demand or default routes
        // should be added by the system.
        protocolConfiguration.includeAllNetworks = false
        protocolConfiguration.excludeLocalNetworks = true

        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = Self.tunnelDescription
        manager.isEnabled = true

        try await saveAndReload(manager)

        // Options are also passed per start so a restart picks up the newest file even
        // if the profile has not been re-saved.
        try manager.connection.startVPNTunnel(options: [
            "apiSecret": secret as NSObject,
            "configFileName": activeConfigFileName as NSObject
        ])
    }

    public func stop() async throws {
        guard let manager = await existingManager() else { return }
        manager.connection.stopVPNTunnel()
    }

    /// Removes the profile from the system VPN list.
    public func removeProfile() async throws {
        guard let manager = await existingManager() else { return }
        try await manager.removeFromPreferences()
    }

    // MARK: - Provider messages

    @discardableResult
    public func send(_ command: TunnelCommand, payload: [String: String]? = nil) async throws -> TunnelReply? {
        guard let manager = await existingManager() else {
            throw TunnelManagerError.noConfigurationSaved
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelManagerError.notConnected
        }
        guard manager.connection.status == .connected else {
            throw TunnelManagerError.notConnected
        }

        let request = try JSONEncoder().encode(TunnelMessage(command: command, payload: payload))

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(request) { response in
                    guard let response else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: try? JSONDecoder().decode(TunnelReply.self, from: response))
                }
            } catch {
                continuation.resume(throwing: TunnelManagerError.messageFailed(error.localizedDescription))
            }
        }
    }

    /// Asks a running tunnel to rebuild its runtime config and reload the core, so a
    /// settings change takes effect without a reconnect. No-op when disconnected.
    public func reloadConfigIfConnected() async {
        guard await isConnected() else { return }
        _ = try? await send(.reloadConfig)
    }

    // MARK: - Profile plumbing

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let existing = await existingManager() {
            return existing
        }
        return NETunnelProviderManager()
    }

    /// `saveToPreferences` only takes effect after the manager is reloaded from
    /// preferences, which is why the reload is not optional here.
    private func saveAndReload(_ manager: NETunnelProviderManager) async throws {
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }
}
