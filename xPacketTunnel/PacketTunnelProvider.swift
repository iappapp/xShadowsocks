//
//  PacketTunnelProvider.swift
//  xPacketTunnel
//
//  Created by mac on 2026/3/2.
//

import NetworkExtension
import os
import Darwin
import Network
import CommonCrypto

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "PacketTunnel")
    private let appGroupID = "group.com.github.iappapp.xShadowsocks"
    private let sharedConfigKey = "ss_config"
    private let trafficDayStartKey = "traffic_day_start"
    private let trafficUploadBytesKey = "traffic_upload_bytes"
    private let trafficDownloadBytesKey = "traffic_download_bytes"
    private let localHTTPProxyPort = 7890
    private var engine: PacketProxyEngine?
    private var proxyServer: TrojanHTTPProxyServer?
    private var pendingUploadBytes: Double = 0
    private var pendingDownloadBytes: Double = 0
    private var lastTrafficFlushDate = Date.distantPast
    private let trafficMonitorQueue = DispatchQueue(label: "com.github.iappapp.xShadowsocks.traffic-monitor")
    private var trafficMonitorTimer: DispatchSourceTimer?
    private var previousUtunInboundBytes: UInt64?

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        resetPendingTraffic()

        do {
            let config = try loadConfig(options: options)
            let settings = makeTunnelSettings(from: config)

            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else {
                    completionHandler(NSError(domain: "PacketTunnel", code: -1))
                    return
                }

                if let error {
                    self.logger.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                    return
                }

                do {
                    let mmdbPath = Self.parseString(from: options?["mmdbPath"])
                    let geoIPResolver = MMDBGeoIPResolver(appGroupID: self.appGroupID, explicitPath: mmdbPath)
                    let routePolicy = ClashRoutePolicy(ruleLines: config.routingRules, geoIPResolver: geoIPResolver)

                    if config.plugin.lowercased() == "trojan" {
                        let proxy = TrojanHTTPProxyServer(
                            localPort: self.localHTTPProxyPort,
                            trojanServerHost: config.server,
                            trojanServerPort: config.serverPort ?? 443,
                            password: config.password,
                            sni: config.pluginOptions,
                            logger: self.logger,
                            onTraffic: { [weak self] upload, download in
                                self?.recordTraffic(uploadBytes: upload, downloadBytes: download)
                            }
                        )
                        try proxy.start()
                        self.proxyServer = proxy
                    } else {
                        let engine = LocalProxyEngine(
                            packetFlow: self.packetFlow,
                            logger: self.logger,
                            routePolicy: routePolicy,
                            onOutboundPackets: { [weak self] bytes in
                                self?.recordTraffic(uploadBytes: bytes, downloadBytes: 0)
                            }
                        )
                        try engine.start(with: config)
                        self.engine = engine
                    }

                    self.startTrafficMonitor()
                    self.logger.info("Tunnel started with server \(config.server, privacy: .private(mask: .hash)):\(config.port)")
                    completionHandler(nil)
                } catch {
                    self.logger.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                }
            }
        } catch {
            logger.error("Load config failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        engine?.stop()
        engine = nil
        proxyServer?.stop()
        proxyServer = nil
        stopTrafficMonitor()
        flushTrafficIfNeeded(force: true)
        logger.info("Tunnel stopped, reason: \(reason.rawValue)")
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = try? JSONDecoder().decode(RouteDecisionRequest.self, from: messageData),
              request.command == "routeDecision" else {
            completionHandler?(messageData)
            return
        }

        let decision = engine?.routeDecision(domain: request.domain, ip: request.ip)
        let response = RouteDecisionResponse(action: decision?.action ?? "DIRECT", matchedRule: decision?.matchedRule)
        let data = try? JSONEncoder().encode(response)
        completionHandler?(data)
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        engine?.pause()
        proxyServer?.stop()
        proxyServer = nil
        stopTrafficMonitor()
        flushTrafficIfNeeded(force: true)
        completionHandler()
    }
    
    override func wake() {
        engine?.resume()
        startTrafficMonitor()
    }

    private func resetPendingTraffic() {
        pendingUploadBytes = 0
        pendingDownloadBytes = 0
        lastTrafficFlushDate = Date.distantPast
    }

    private func startTrafficMonitor() {
        stopTrafficMonitor()
        previousUtunInboundBytes = readTotalUtunInboundBytes()

        let timer = DispatchSource.makeTimerSource(queue: trafficMonitorQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.pollInboundTrafficFromUtun()
        }
        timer.resume()
        trafficMonitorTimer = timer
    }

    private func stopTrafficMonitor() {
        trafficMonitorTimer?.cancel()
        trafficMonitorTimer = nil
        previousUtunInboundBytes = nil
    }

    private func pollInboundTrafficFromUtun() {
        guard let currentInbound = readTotalUtunInboundBytes() else {
            return
        }

        defer {
            previousUtunInboundBytes = currentInbound
        }

        guard let previous = previousUtunInboundBytes, currentInbound >= previous else {
            return
        }

        let delta = currentInbound - previous
        guard delta > 0 else { return }

        let safeDelta = Int(min(delta, UInt64(Int.max)))
        recordTraffic(uploadBytes: 0, downloadBytes: safeDelta)
    }

    private func readTotalUtunInboundBytes() -> UInt64? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return nil
        }
        defer {
            freeifaddrs(addressList)
        }

        var totalInboundBytes: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first

        while let current = pointer {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)

            if name.hasPrefix("utun"),
               let rawData = interface.ifa_data {
                let networkData = rawData.assumingMemoryBound(to: if_data.self).pointee
                totalInboundBytes += UInt64(networkData.ifi_ibytes)
            }

            pointer = interface.ifa_next
        }

        return totalInboundBytes
    }

    private func recordTraffic(uploadBytes: Int, downloadBytes: Int) {
        if uploadBytes > 0 {
            pendingUploadBytes += Double(uploadBytes)
        }
        if downloadBytes > 0 {
            pendingDownloadBytes += Double(downloadBytes)
        }

        flushTrafficIfNeeded(force: false)
    }

    private func flushTrafficIfNeeded(force: Bool) {
        let pendingTotal = pendingUploadBytes + pendingDownloadBytes
        if !force {
            let shouldFlushBySize = pendingTotal >= 64 * 1024
            let shouldFlushByTime = Date().timeIntervalSince(lastTrafficFlushDate) >= 1
            if !shouldFlushBySize && !shouldFlushByTime {
                return
            }
        }

        guard pendingTotal > 0 else { return }
        guard let defaults = sharedDefaults else { return }

        let todayStart = currentDayStartTimestamp()
        let storedDayStart = defaults.double(forKey: trafficDayStartKey)
        if storedDayStart != todayStart {
            defaults.set(todayStart, forKey: trafficDayStartKey)
            defaults.set(0, forKey: trafficUploadBytesKey)
            defaults.set(0, forKey: trafficDownloadBytesKey)
        }

        let currentUpload = defaults.double(forKey: trafficUploadBytesKey)
        let currentDownload = defaults.double(forKey: trafficDownloadBytesKey)
        defaults.set(currentUpload + pendingUploadBytes, forKey: trafficUploadBytesKey)
        defaults.set(currentDownload + pendingDownloadBytes, forKey: trafficDownloadBytesKey)

        pendingUploadBytes = 0
        pendingDownloadBytes = 0
        lastTrafficFlushDate = Date()
    }

    private func currentDayStartTimestamp() -> TimeInterval {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }

    private func loadConfig(options: [String : NSObject]?) throws -> TunnelConfig {
        let overridePort = Self.parsePort(from: options?["serverPort"])
        let overrideRouteRules = Self.parseRules(from: options?["routeRulesText"])

        if let payload = options?["configData"] as? Data,
           var config = try? JSONDecoder().decode(TunnelConfig.self, from: payload) {
            if let overridePort {
                config.port = String(overridePort)
            }
            if let overrideRouteRules {
                config.routingRules = overrideRouteRules
            }
            try config.validate()
            return config
        }

        guard let sharedDefaults = UserDefaults(suiteName: appGroupID),
              let data = sharedDefaults.data(forKey: sharedConfigKey),
              var config = try? JSONDecoder().decode(TunnelConfig.self, from: data) else {
            throw TunnelError.invalidConfig("未找到共享配置，请先在主 App 中保存配置")
        }

        if let overridePort {
            config.port = String(overridePort)
        }

        if let overrideRouteRules {
            config.routingRules = overrideRouteRules
        }

        try config.validate()

        return config
    }

    private static func parsePort(from value: NSObject?) -> Int? {
        if let number = value as? NSNumber {
            let port = number.intValue
            return (1...65535).contains(port) ? port : nil
        }

        if let text = value as? NSString,
           let port = Int(text as String),
           (1...65535).contains(port) {
            return port
        }

        return nil
    }

    private static func parseRules(from value: NSObject?) -> [String]? {
        if let text = value as? NSString {
            let raw = text as String
            if FileManager.default.fileExists(atPath: raw),
               let fileContent = try? String(contentsOfFile: raw, encoding: .utf8) {
                return fileContent.components(separatedBy: .newlines)
            }
            return text.components(separatedBy: .newlines)
        }

        if let data = value as? Data,
           let text = String(data: data, encoding: .utf8) {
            return text.components(separatedBy: .newlines)
        }

        return nil
    }

    private static func parseString(from value: NSObject?) -> String? {
        if let text = value as? NSString {
            return text as String
        }

        if let data = value as? Data,
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return nil
    }

    private func makeTunnelSettings(from config: TunnelConfig) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: config.server)
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        if config.plugin.lowercased() == "trojan" {
            let proxySettings = NEProxySettings()
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true
            proxySettings.httpServer = NEProxyServer(address: "127.0.0.1", port: localHTTPProxyPort)
            proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: localHTTPProxyPort)
            proxySettings.excludeSimpleHostnames = false
            proxySettings.matchDomains = [""]
            settings.proxySettings = proxySettings
        }

        return settings
    }
}

private final class TrojanHTTPProxyServer {
    private let localPort: UInt16
    private let trojanServerHost: String
    private let trojanServerPort: UInt16
    private let password: String
    private let sni: String?
    private let logger: Logger
    private let onTraffic: (Int, Int) -> Void
    private let queue = DispatchQueue(label: "com.github.iappapp.xShadowsocks.trojan-proxy")

    private var listener: NWListener?

    init(
        localPort: Int,
        trojanServerHost: String,
        trojanServerPort: Int,
        password: String,
        sni: String,
        logger: Logger,
        onTraffic: @escaping (Int, Int) -> Void
    ) {
        self.localPort = UInt16(max(1, min(localPort, 65535)))
        self.trojanServerHost = trojanServerHost
        self.trojanServerPort = UInt16(max(1, min(trojanServerPort, 65535)))
        self.password = password
        self.sni = sni.isEmpty ? nil : sni
        self.logger = logger
        self.onTraffic = onTraffic
    }

    func start() throws {
        let port = NWEndpoint.Port(rawValue: localPort) ?? .init(integerLiteral: 7890)
        let listener = try NWListener(using: .tcp, on: port)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleClient(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.logger.error("Local proxy listener failed: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleClient(_ client: NWConnection) {
        client.start(queue: queue)

        receiveHTTPHeader(from: client) { [weak self] header in
            guard let self else {
                client.cancel()
                return
            }

            guard let header,
                  let target = Self.parseConnectTarget(from: header) else {
                Self.sendPlain(client, text: "HTTP/1.1 400 Bad Request\r\n\r\n")
                client.cancel()
                return
            }

            self.establishTrojanConnectionAndRelay(client: client, targetHost: target.host, targetPort: target.port)
        }
    }

    private func establishTrojanConnectionAndRelay(client: NWConnection, targetHost: String, targetPort: UInt16) {
        let host = NWEndpoint.Host(trojanServerHost)
        let port = NWEndpoint.Port(rawValue: trojanServerPort) ?? .https

        let tlsOptions = NWProtocolTLS.Options()
        if let sni {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)
        }

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        let remote = NWConnection(host: host, port: port, using: parameters)

        remote.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                do {
                    let handshake = try Self.makeTrojanHandshake(password: self.password, targetHost: targetHost, targetPort: targetPort)
                    self.send(remote, data: handshake) { success in
                        guard success else {
                            client.cancel()
                            remote.cancel()
                            return
                        }

                        Self.sendPlain(client, text: "HTTP/1.1 200 Connection Established\r\n\r\n")
                        self.pipe(source: client, destination: remote, uploadDirection: true)
                        self.pipe(source: remote, destination: client, uploadDirection: false)
                    }
                } catch {
                    Self.sendPlain(client, text: "HTTP/1.1 502 Bad Gateway\r\n\r\n")
                    client.cancel()
                    remote.cancel()
                }

            case .failed(let error):
                self.logger.error("Remote trojan connect failed: \(error.localizedDescription, privacy: .public)")
                Self.sendPlain(client, text: "HTTP/1.1 502 Bad Gateway\r\n\r\n")
                client.cancel()
                remote.cancel()
            default:
                break
            }
        }

        remote.start(queue: queue)
    }

    private func pipe(source: NWConnection, destination: NWConnection, uploadDirection: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                if uploadDirection {
                    self.onTraffic(data.count, 0)
                } else {
                    self.onTraffic(0, data.count)
                }

                self.send(destination, data: data) { success in
                    if success {
                        self.pipe(source: source, destination: destination, uploadDirection: uploadDirection)
                    } else {
                        source.cancel()
                        destination.cancel()
                    }
                }
                return
            }

            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
            }
        }
    }

    private func send(_ connection: NWConnection, data: Data, completion: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    private func receiveHTTPHeader(from connection: NWConnection, completion: @escaping (String?) -> Void) {
        var buffer = Data()

        func receiveNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                        completion(text)
                        return
                    }
                }

                if isComplete || error != nil || buffer.count > 64 * 1024 {
                    completion(nil)
                    return
                }

                receiveNextChunk()
            }
        }

        receiveNextChunk()
    }

    private static func parseConnectTarget(from header: String) -> (host: String, port: UInt16)? {
        guard let firstLine = header.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
            return nil
        }

        let target = String(parts[1])
        let hostPort = target.split(separator: ":", omittingEmptySubsequences: false)
        guard hostPort.count == 2,
              let port = UInt16(hostPort[1]),
              !hostPort[0].isEmpty else {
            return nil
        }

        return (String(hostPort[0]), port)
    }

    private static func sendPlain(_ connection: NWConnection, text: String) {
        connection.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private static func makeTrojanHandshake(password: String, targetHost: String, targetPort: UInt16) throws -> Data {
        let passwordHash = sha224Hex(password)
        var payload = Data(passwordHash.utf8)
        payload.append(contentsOf: [0x0D, 0x0A])

        payload.append(0x01)
        payload.append(0x03)

        let hostData = Data(targetHost.utf8)
        guard hostData.count <= 255 else {
            throw TunnelError.invalidConfig("目标域名过长")
        }

        payload.append(UInt8(hostData.count))
        payload.append(hostData)

        payload.append(UInt8((targetPort >> 8) & 0xFF))
        payload.append(UInt8(targetPort & 0xFF))

        payload.append(contentsOf: [0x0D, 0x0A])
        return payload
    }

    private static func sha224Hex(_ string: String) -> String {
        let bytes = [UInt8](string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        CC_SHA224(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct TunnelConfig: Codable {
    let remark: String
    let server: String
    var port: String
    let password: String
    let method: String
    let plugin: String
    let pluginOptions: String
    let udpRelay: Bool
    let tcpFastOpen: Bool
    var routingRules: [String] = []

    func validate() throws {
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelError.invalidConfig("服务器地址不能为空")
        }

        guard !password.isEmpty else {
            throw TunnelError.invalidConfig("密码不能为空")
        }

        guard let serverPort, (1...65535).contains(serverPort) else {
            throw TunnelError.invalidConfig("端口必须是 1~65535")
        }
    }

    var serverPort: Int? {
        Int(port)
    }
}

private protocol PacketProxyEngine {
    func start(with config: TunnelConfig) throws
    func stop()
    func pause()
    func resume()
    func routeDecision(domain: String?, ip: String?) -> RouteDecision
}

private final class LocalProxyEngine: PacketProxyEngine {
    private let packetFlow: NEPacketTunnelFlow
    private let logger: Logger
    private let routePolicy: ClashRoutePolicy
    private let onOutboundPackets: (Int) -> Void
    private var isRunning = false

    init(packetFlow: NEPacketTunnelFlow, logger: Logger, routePolicy: ClashRoutePolicy, onOutboundPackets: @escaping (Int) -> Void) {
        self.packetFlow = packetFlow
        self.logger = logger
        self.routePolicy = routePolicy
        self.onOutboundPackets = onOutboundPackets
    }

    func start(with config: TunnelConfig) throws {
        guard config.serverPort != nil else {
            throw TunnelError.invalidConfig("端口格式错误")
        }
        isRunning = true
        readPacketsLoop()
    }

    func stop() {
        isRunning = false
    }

    func pause() {
        isRunning = false
    }

    func resume() {
        guard !isRunning else { return }
        isRunning = true
        readPacketsLoop()
    }

    func routeDecision(domain: String?, ip: String?) -> RouteDecision {
        routePolicy.decide(domain: domain, ip: ip)
    }

    private func readPacketsLoop() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            guard self.isRunning else { return }
            let outboundBytes = packets.reduce(0) { partialResult, packet in
                partialResult + packet.count
            }
            if outboundBytes > 0 {
                self.onOutboundPackets(outboundBytes)
            }
            self.readPacketsLoop()
        }
    }
}

private struct RouteDecisionRequest: Decodable {
    let command: String
    let domain: String?
    let ip: String?
}

private struct RouteDecisionResponse: Encodable {
    let action: String
    let matchedRule: String?
}

private enum TunnelError: LocalizedError {
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfig(message):
            return message
        }
    }
}
