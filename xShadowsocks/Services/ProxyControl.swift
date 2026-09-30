import Foundation
import os

/// The app's single entry point for pushing a config change to whichever process is
/// running the core.
///
/// Both host modes (in-app loopback and the packet-tunnel extension) need the same
/// thing after an import or a settings change, so callers should not have to branch on
/// the mode themselves. This is the one place that does.
@MainActor
enum ProxyControl {
    private static let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "ProxyControl")

    static func reload() async {
        if LocalProxyHost.shared.isRunning {
            do {
                try LocalProxyHost.shared.reload()
                logger.info("loopback core reloaded")
            } catch {
                logger.error("loopback reload failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        await TunnelManager.shared.reloadConfigIfConnected()
    }
}
