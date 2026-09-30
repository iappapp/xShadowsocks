import Foundation
import NetworkExtension
import os

/// The packet-tunnel extension.
///
/// Swift stays out of the data path entirely: mihomo's `tun` inbound accepts a
/// `file-descriptor`, so the extension hands it the utun socket that
/// `NEPacketTunnelNetworkSettings` created and lets the core's own `system` stack move
/// the packets. The extension's jobs are only:
///
///   1. Configure the tunnel interface and routes so packets reach mihomo.
///   2. Let `MihomoCoreHost` build the runtime config and start the core.
///   3. Publish traffic totals into the App Group for the app's Data tab.
///
/// This target needs a paid Apple Developer account (Network Extension entitlement).
/// Without one the app still works in loopback mode — see `LocalProxyHost`.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "PacketTunnel")
    private let store = AppGroupStore.shared

    private var trafficTimer: DispatchSourceTimer?
    private let trafficQueue = DispatchQueue(label: "com.github.iappapp.xShadowsocks.traffic")

    // MARK: - Tunnel lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            let request = try TunnelStartRequest(options: options, store: store)
            let settings = makeTunnelSettings(for: request)
            logger.info("starting tunnel, interface \(request.tunnelSettings.interfaceCIDR, privacy: .public)")

            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else {
                    completionHandler(TunnelError.providerDeallocated)
                    return
                }
                if let error {
                    self.logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                    return
                }

                do {
                    let descriptor = try self.resolveUtunDescriptor()
                    try MihomoCoreHost.shared.start(
                        mode: .tunnel(fileDescriptor: descriptor),
                        userYAML: request.userYAML
                    )
                    self.startTrafficMonitor()
                    completionHandler(nil)
                } catch {
                    self.logger.error("tunnel start failed: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                }
            }
        } catch {
            logger.error("invalid start request: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopTrafficMonitor()
        do {
            try MihomoCoreHost.shared.stop()
        } catch {
            logger.error("core stop failed: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("tunnel stopped, reason \(reason.rawValue)")
        completionHandler()
    }

    /// The tunnel can be suspended without being stopped. mihomo keeps running — its
    /// sockets belong to the extension process, not the tunnel interface — and its
    /// counters stay valid, so only the polling timer is suspended.
    override func sleep(completionHandler: @escaping () -> Void) {
        logger.info("tunnel sleeping")
        stopTrafficMonitor()
        MihomoCoreHost.shared.flushTraffic()
        completionHandler()
    }

    override func wake() {
        logger.info("tunnel woke")
        startTrafficMonitor()
    }

    // MARK: - App messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONDecoder().decode(TunnelMessage.self, from: messageData),
              let command = TunnelCommand(rawValue: message.command) else {
            completionHandler?(nil)
            return
        }

        switch command {
        case .flushTraffic:
            MihomoCoreHost.shared.flushTraffic()
            completionHandler?(encode(TunnelReply(success: true)))

        case .trafficSnapshot:
            MihomoCoreHost.shared.flushTraffic()
            let totals = MihomoCoreHost.shared.currentSessionTotals()
            let snapshot = TrafficSnapshot(uploadTotal: totals.upload, downloadTotal: totals.download)
            completionHandler?(encode(TunnelReply(success: true, snapshot: TrafficPayload(snapshot))))

        case .reloadConfig:
            guard MihomoCoreHost.shared.isRunning else {
                completionHandler?(encode(TunnelReply(success: false, message: "隧道未运行")))
                return
            }
            // The runtime config is regenerated rather than re-read: what changed is
            // usually a setting the app just wrote (routing mode, LAN access), and the
            // file itself may also have been replaced by a re-import.
            do {
                try MihomoCoreHost.shared.reload()
                completionHandler?(encode(TunnelReply(success: true)))
            } catch {
                completionHandler?(encode(TunnelReply(success: false, message: error.localizedDescription)))
            }
        }
    }

    // MARK: - Utun descriptor

    private func resolveUtunDescriptor() throws -> Int32 {
        guard let descriptor = UtunFileDescriptor.resolve(packetFlow: packetFlow) else {
            throw TunnelError.missingTunnelFileDescriptor
        }
        let name = UtunFileDescriptor.interfaceName(forDescriptor: descriptor) ?? "unknown"
        logger.info("resolved utun fd \(descriptor) (\(name, privacy: .public))")
        return descriptor
    }

    // MARK: - Tunnel settings

    private func makeTunnelSettings(for request: TunnelStartRequest) -> NEPacketTunnelNetworkSettings {
        let tun = request.tunnelSettings
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: [tun.interfaceAddress], subnetMasks: [tun.subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // Private ranges stay off the tunnel: mihomo's `auto-route: false` and the
        // system stack's direct-route handling assume the LAN is reachable directly.
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: tun.dnsServers)
        dns.matchDomains = [""]      // resolver for everything
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: tun.mtu)
        return settings
    }

    // MARK: - Traffic reporting

    private func startTrafficMonitor() {
        stopTrafficMonitor()

        let timer = DispatchSource.makeTimerSource(queue: trafficQueue)
        // The controller may not be listening yet right after start.
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            Task { await MihomoCoreHost.shared.pollTraffic() }
        }
        timer.resume()
        trafficTimer = timer
    }

    private func stopTrafficMonitor() {
        trafficTimer?.cancel()
        trafficTimer = nil
    }
}

// MARK: - Start request

/// Everything the extension needs, resolved from the App Group at start time.
private struct TunnelStartRequest {
    let userYAML: String
    let activeConfigFileName: String
    let tunnelSettings: MihomoRuntimeConfigBuilder.TunnelSettings

    init(options: [String: NSObject]?, store: AppGroupStore) throws {
        // The filename arrives through the start options as well as the App Group.
        // App Group `UserDefaults` propagation between processes is not guaranteed to be
        // instantaneous, so the option — written by the app immediately before the start
        // call — wins when present.
        let optionFileName = (options?["configFileName"] as? NSString) as String?
        let storedFileName = store.loadString(forKey: store.activeConfigFileNameKey)
        guard let fileName = [optionFileName, storedFileName]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) else {
            throw MihomoCoreHost.HostError.noActiveConfig
        }

        let url = MihomoSharedPaths.configFileURL(forFileName: fileName)
        guard let yaml = try? String(contentsOf: url, encoding: .utf8), !yaml.isEmpty else {
            throw MihomoCoreHost.HostError.missingUserConfig(url.path)
        }

        self.userYAML = yaml
        self.activeConfigFileName = fileName
        self.tunnelSettings = MihomoRuntimeConfigBuilder.tunnelSettings(fromUserYAML: yaml)
    }
}

private func encode(_ reply: TunnelReply) -> Data? {
    try? JSONEncoder().encode(reply)
}

enum TunnelError: LocalizedError {
    case providerDeallocated
    case missingTunnelFileDescriptor

    var errorDescription: String? {
        switch self {
        case .providerDeallocated:
            return "隧道已被系统回收"
        case .missingTunnelFileDescriptor:
            return "未取得隧道文件描述符，无法启动内核"
        }
    }
}
