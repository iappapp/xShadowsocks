import Foundation
import Network
import os

struct LocalDebugVlessNode: Sendable {
    let host: String
    let port: Int
    let uuid: String
    let sni: String?
    let type: String
    let flow: String?
    let encryption: String?
    // Reality 特定参数
    let publicKey: String?
    let shortId: String?
    let network: String?
    let serviceName: String?
}

final class LocalVlessProxyService {
    let listenPort: UInt16

    var onStateChange: ((LocalDebugProxyState) -> Void)?

    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "LocalVlessDebugProxy")
    private let queue = DispatchQueue(label: "com.github.iappapp.xShadowsocks.local-vless-debug-proxy")
    private var listener: NWListener?

    init(listenPort: UInt16) {
        self.listenPort = listenPort
    }

    static func measureConnectivity(using node: LocalDebugVlessNode, timeout: TimeInterval = 4) async throws -> Int {
        let startTime = Date()

        try await withTimeout(seconds: timeout) {
            try await performVlessProbe(node: node)
        }

        let elapsedMS = Int(Date().timeIntervalSince(startTime) * 1000)
        return max(elapsedMS, 1)
    }

    func start(using node: LocalDebugVlessNode) throws {
        stop()
        onStateChange?(.starting)

        guard node.type.lowercased() == "vless" else {
            onStateChange?(.failed("当前仅支持 vless 节点调试"))
            return
        }

        guard let localPort = NWEndpoint.Port(rawValue: listenPort) else {
            onStateChange?(.failed("本地监听端口无效: \(listenPort)"))
            return
        }
        let listener = try NWListener(using: .tcp, on: localPort)

        listener.newConnectionHandler = { [weak self] client in
            self?.handleClient(client, node: node)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                self.onStateChange?(.running)
            case .failed(let error):
                self.logger.error("Local VLESS debug proxy failed: \(error.localizedDescription, privacy: .public)")
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.stopped)
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
        onStateChange?(.stopped)
    }

    // MARK: - Client handling

    private func handleClient(_ client: NWConnection, node: LocalDebugVlessNode) {
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

            self.openVlessTunnel(client: client, node: node, targetHost: target.host, targetPort: target.port)
        }
    }

    // MARK: - VLESS tunnel

    private func openVlessTunnel(client: NWConnection, node: LocalDebugVlessNode, targetHost: String, targetPort: UInt16) {
        let remoteHost = NWEndpoint.Host(node.host)
        let remotePort = NWEndpoint.Port(rawValue: UInt16(node.port)) ?? .https

        let tlsOptions = NWProtocolTLS.Options()
        if let sni = node.sni, !sni.isEmpty {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)
        }

        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (_, _, completion) in
            completion(true)
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(tls: tlsOptions)
        let remote = NWConnection(host: remoteHost, port: remotePort, using: parameters)

        remote.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self else { return }

            switch state {
            case .ready:
                do {
                    let handshake = try Self.makeVlessHandshake(
                        uuid: node.uuid,
                        targetHost: targetHost,
                        targetPort: targetPort,
                        flow: node.flow,
                        encryption: node.encryption,
                        network: node.network,
                        serviceName: node.serviceName
                    )
                    self.send(remote, data: handshake) { success in
                        guard success else {
                            Self.sendPlain(client, text: "HTTP/1.1 502 Bad Gateway\r\n\r\n")
                            client.cancel()
                            remote.cancel()
                            return
                        }

                        Self.sendPlain(client, text: "HTTP/1.1 200 Connection Established\r\n\r\n")
                        self.pipe(source: client, destination: remote, tag: "local->remote")
                        self.pipe(source: remote, destination: client, tag: "remote->local")
                    }
                } catch {
                    Self.sendPlain(client, text: "HTTP/1.1 502 Bad Gateway\r\n\r\n")
                    client.cancel()
                    remote.cancel()
                }
            case .failed(let error):
                self.logger.error("VLESS upstream connect failed: \(error.localizedDescription, privacy: .public)")
                Self.sendPlain(client, text: "HTTP/1.1 502 Bad Gateway\r\n\r\n")
                client.cancel()
                remote.cancel()
            default:
                break
            }
        }

        remote.start(queue: queue)
    }

    // MARK: - Data pipe

    private func pipe(source: NWConnection, destination: NWConnection, tag: String) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                if tag == "remote->local" {
                    let preview = String(decoding: data.prefix(50), as: UTF8.self)
                        .replacingOccurrences(of: "\r", with: ".")
                        .replacingOccurrences(of: "\n", with: ".")
                    self.logger.debug("Received from remote (\(data.count) bytes): \(preview)")
                }

                self.send(destination, data: data) { success in
                    if success {
                        self.pipe(source: source, destination: destination, tag: tag)
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

    // MARK: - HTTP header parsing

    private func receiveHTTPHeader(from connection: NWConnection, completion: @escaping (String?) -> Void) {
        var buffer = Data()

        func receiveChunk() {
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

                receiveChunk()
            }
        }

        receiveChunk()
    }

    // MARK: - Static helpers

    private static func parseConnectTarget(from header: String) -> (host: String, port: UInt16)? {
        guard let firstLine = header.components(separatedBy: "\r\n").first else {
            return nil
        }
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

    // MARK: - VLESS Protocol Handshake

    /// Builds the VLESS v0 protocol handshake payload.
    ///
    /// Format:
    /// ```
    /// [1 byte]   Version (0x00)
    /// [16 bytes] UUID (raw bytes)
    /// [1 byte]   Additional Data Length (0x00 = no addons)
    /// [1 byte]   Command (0x01 = TCP)
    /// [2 bytes]  Target Port (big-endian)
    /// [1 byte]   Address Type
    ///             0x01 = IPv4 → 4 bytes
    ///             0x02 = Domain → 1 byte length + N bytes
    ///             0x03 = IPv6 → 16 bytes
    /// [variable] Address Data
    /// ```
    static func makeVlessHandshake(uuid: String, targetHost: String, targetPort: UInt16, flow: String? = nil, encryption: String? = nil, network: String? = nil, serviceName: String? = nil) throws -> Data {
        // Parse UUID string → raw 16 bytes
        guard let uuidData = uuidToBytes(uuid) else {
            throw LocalVlessProxyError.invalidUUID
        }

        var payload = Data()

        // Version: 0x00
        payload.append(0x00)

        // UUID: 16 raw bytes
        payload.append(uuidData)

        // Additional Data Length: 0x00 (no proxy protocol addons like "tcp", "mux")
        payload.append(0x00)

        // Command: 0x01 = TCP
        payload.append(0x01)

        // Target Port: 2 bytes, big-endian
        payload.append(UInt8((targetPort >> 8) & 0xFF))
        payload.append(UInt8(targetPort & 0xFF))

        // Address Type + Address
        if let _ = IPv4Address(targetHost) {
            // 0x01 = IPv4
            payload.append(0x01)
            let parts = targetHost.split(separator: ".")
            for part in parts {
                if let byte = UInt8(part) {
                    payload.append(byte)
                }
            }
        } else if let _ = IPv6Address(targetHost) {
            // 0x03 = IPv6
            payload.append(0x03)
            // Parse IPv6 address string to 16 bytes
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            targetHost.withCString { cString in
                _ = inet_pton(AF_INET6, cString, &addr.sin6_addr)
            }
            let ipv6Bytes = withUnsafeBytes(of: &addr.sin6_addr) { Data($0) }
            payload.append(ipv6Bytes)
        } else {
            // 0x02 = Domain
            let hostData = Data(targetHost.utf8)
            guard hostData.count <= 255 else {
                throw LocalVlessProxyError.invalidTargetHost
            }
            payload.append(0x02)
            payload.append(UInt8(hostData.count))
            payload.append(hostData)
        }

        return payload
    }

    // MARK: - UUID conversion

    /// Converts a UUID string (e.g. "b8c91e3f-4d6d-5a7b-8f2e-3c4d5e6f7a8b") to raw 16 bytes.
    /// Supports both standard UUID format and hex strings without dashes.
    private static func uuidToBytes(_ uuidString: String) -> Data? {
        // Try standard UUID format first
        if let uuid = UUID(uuidString: uuidString) {
            return withUnsafeBytes(of: uuid.uuid) { Data($0) }
        }

        // Try hex string without dashes
        let hex = uuidString.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }

        var bytes = Data()
        var index = hex.startIndex
        for _ in 0..<16 {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }

    // MARK: - Delay measurement

    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LocalVlessProxyError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - VLESS Probe

    private static func performVlessProbe(node: LocalDebugVlessNode) async throws {
        guard node.type.lowercased() == "vless" else {
            throw LocalVlessProxyError.unsupportedNodeType
        }

        let remoteHost = NWEndpoint.Host(node.host)
        let remotePort = NWEndpoint.Port(rawValue: UInt16(max(1, min(node.port, 65535)))) ?? .https

        let tlsOptions = NWProtocolTLS.Options()
        if let sni = node.sni, !sni.isEmpty {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)
        }

        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (_, _, completion) in
            completion(true)
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(tls: tlsOptions)
        let connection = NWConnection(host: remoteHost, port: remotePort, using: parameters)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false

            func finish(_ result: Result<Void, Error>) {
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    do {
                        let handshake = try makeVlessHandshake(
                            uuid: node.uuid,
                            targetHost: "google.com",
                            targetPort: 80,
                            flow: node.flow,
                            encryption: node.encryption,
                            network: node.network,
                            serviceName: node.serviceName
                        )
                        let probe = Data("GET / HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n".utf8)
                        var payload = Data()
                        payload.append(handshake)
                        payload.append(probe)

                        connection.send(content: payload, completion: .contentProcessed { error in
                            if let error {
                                finish(.failure(error))
                                return
                            }

                            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, receiveError in
                                if let receiveError {
                                    finish(.failure(receiveError))
                                    return
                                }

                                if let data, !data.isEmpty {
                                    finish(.success(()))
                                } else if isComplete {
                                    finish(.failure(LocalVlessProxyError.emptyResponse))
                                }
                            }
                        })
                    } catch {
                        finish(.failure(error))
                    }

                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue(label: "com.github.iappapp.xShadowsocks.vless-probe"))
        }
    }
}

// MARK: - VLESS Proxy Errors

private enum LocalVlessProxyError: LocalizedError {
    case invalidUUID
    case invalidTargetHost
    case timeout
    case emptyResponse
    case unsupportedNodeType

    var errorDescription: String? {
        switch self {
        case .invalidUUID:
            return "无效的 VLESS UUID"
        case .invalidTargetHost:
            return "目标主机名过长"
        case .timeout:
            return "连接超时"
        case .emptyResponse:
            return "未收到响应"
        case .unsupportedNodeType:
            return "仅支持 vless 节点测试"
        }
    }
}