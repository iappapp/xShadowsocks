import Foundation
import UIKit
import os

/// Runs mihomo inside the app itself, listening on loopback for clients that are told
/// to use it.
///
/// This is the mode that works on a **free Apple Developer account**: it needs no
/// entitlement at all, because nothing privileged happens — the core only opens TCP/UDP
/// listeners on `127.0.0.1`, exactly like any other local socket. The trade-off is that
/// it does not carry other apps' traffic; the user has to point a client at the port
/// (the built-in browser does this for you, and `allow-lan` can expose it to the LAN).
///
/// For system-wide proxying the packet-tunnel extension is required, which needs a paid
/// account. `LocalProxyHost` exists so the app is fully usable without one.
@MainActor
public final class LocalProxyHost {
    public static let shared = LocalProxyHost()

    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "LocalProxyHost")
    private let store = AppGroupStore.shared

    private var trafficTimer: Timer?
    /// iOS suspends apps in the background; the assertion is what keeps the core's
    /// sockets alive for a while after the user leaves the app.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    public var isRunning: Bool { MihomoCoreHost.shared.isRunning }

    /// The loopback endpoint a client should be pointed at.
    public var proxyPort: Int {
        min(max(store.loadInt(forKey: store.proxyPortKey, default: 7890), 1024), 65_000)
    }

    // MARK: - Lifecycle

    public func start(userYAML: String) throws {
        try MihomoCoreHost.shared.start(mode: .loopback, userYAML: userYAML)
        startTrafficMonitor()
        beginBackgroundAssertion()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        logger.info("loopback core started on port \(self.proxyPort)")
    }

    public func stop() {
        stopTrafficMonitor()
        endBackgroundAssertion()
        NotificationCenter.default.removeObserver(self)
        do {
            try MihomoCoreHost.shared.stop()
        } catch {
            logger.error("core stop failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func reload() throws {
        try MihomoCoreHost.shared.reload()
    }

    // MARK: - Traffic

    private func startTrafficMonitor() {
        stopTrafficMonitor()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await MihomoCoreHost.shared.pollTraffic() }
        }
        trafficTimer = timer
    }

    private func stopTrafficMonitor() {
        trafficTimer?.invalidate()
        trafficTimer = nil
    }

    // MARK: - Background execution

    /// Renews the background assertion so the core survives a reasonable amount of time
    /// after the app is backgrounded. iOS still has the final say; the assertion is
    /// re-acquired on the next foreground because the tunnel is not re-created.
    @objc private func applicationDidEnterBackground() {
        endBackgroundAssertion()
        beginBackgroundAssertion()
    }

    private func beginBackgroundAssertion() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "mihomo-loopback") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundAssertion()
            }
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
