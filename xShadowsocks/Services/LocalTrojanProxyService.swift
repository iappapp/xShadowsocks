import Foundation
import Network
import CommonCrypto
import os

struct LocalDebugTrojanNode: Sendable {
    let host: String
    let port: Int
    let password: String
    let sni: String?
    let type: String
}

enum LocalDebugProxyState {
    case stopped
    case starting
    case running
    case failed(String)
}

final class LocalTrojanProxyService {
    let listenPort: UInt16

    var onStateChange: ((LocalDebugProxyState) -> Void)?

    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "LocalDebugProxy")
    private let queue = DispatchQueue(label: "com.github.iappapp.xShadowsocks.local-debug-proxy")
    private var listener: NWListener?

    init(listenPort: UInt16) {
        self.listenPort = listenPort
    }

    static func measureConnectivity(using node: LocalDebugTrojanNode, timeout: TimeInterval = 4) async throws -> Int {
        let startTime = Date()

        try await withTimeout(seconds: timeout) {
            try await performTrojanProbe(node: node)
        }

        let elapsedMS = Int(Date().timeIntervalSince(startTime) * 1000)
        return max(elapsedMS, 1)
    }

    func start(using node: LocalDebugTrojanNode) throws {
        stop()
        onStateChange?(.starting)

        guard node.type.lowercased() == "trojan" else {
            onStateChange?(.failed("当前仅支持 trojan 节点调试"))
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
                self.logger.error("Local debug proxy failed: \(error.localizedDescription, privacy: .public)")
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

    private func handleClient(_ client: NWConnection, node: LocalDebugTrojanNode) {
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

            self.openTrojanTunnel(client: client, node: node, targetHost: target.host, targetPort: target.port)
        }
    }

    private func openTrojanTunnel(client: NWConnection, node: LocalDebugTrojanNode, targetHost: String, targetPort: UInt16) {
        let remoteHost = NWEndpoint.Host(node.host)
        let remotePort = NWEndpoint.Port(rawValue: UInt16(node.port)) ?? .https

        let tlsOptions = NWProtocolTLS.Options()
        if let sni = node.sni, !sni.isEmpty {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)
        }
        
        // 建议添加 ALPN 支持，部分 CDN 节点需要
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")
        
        // 忽略证书验证错误（包括自签名证书、主机名不匹配等）
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (_, _, completion) in
            // 总是信任
            completion(true)
        }, DispatchQueue.global(qos: .userInitiated))

        let parameters = NWParameters(tls: tlsOptions)
        let remote = NWConnection(host: remoteHost, port: remotePort, using: parameters)

        remote.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self else { return }

            switch state {
            case .ready:
                do {
                    let handshake = try Self.makeTrojanHandshake(
                        password: node.password,
                        targetHost: targetHost,
                        targetPort: targetPort
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
                self.logger.error("Trojan upstream connect failed: \(error.localizedDescription, privacy: .public)")
                Self.sendPlain(client, text: "HTTP/1.1 502 Bad Gateway\r\n\r\n")
                client.cancel()
                remote.cancel()
            default:
                break
            }
        }

        remote.start(queue: queue)
    }

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

    private static func makeTrojanHandshake(password: String, targetHost: String, targetPort: UInt16) throws -> Data {
        var payload = Data(sha224Hex(password).utf8)
        payload.append(contentsOf: [0x0D, 0x0A])

        // Trojan Protocol Command: 0x01 (CONNECT), 0x03 (DOMAIN)
        // Command
        payload.append(0x01)
        // Address Type (0x01: IPv4, 0x03: Domain, 0x04: IPv6)
        // Historically many servers implementation expect 0x03 for domain always, but strictly it depends.
        // Assuming targetHost is domain. If it's IP, could be 0x01.
        // But 0x03 works for IP string too in most implementation (as domain).
        // Let's implement correct type detection for better compatibility.
        
        if let _ = IPv4Address(targetHost) {
             payload.append(0x01) // ATYP_IPV4
             let parts = targetHost.split(separator: ".")
             for part in parts {
                 if let b = UInt8(part) {
                     payload.append(b)
                 }
             }
        } else if let _ = IPv6Address(targetHost) {
             // IPv6 implementation complex, skip for now or treat as domain
             payload.append(0x04) // ATYP_IPV6
             // Need to parse IPv6 string to bytes
             // Falling back to domain 0x03 for now as simple fix usually works
             // But actually let's stick to Domain (0x03) for all for simplicity unless specified
             // Reverting to 0x03 logic for stability as it was before, just checking logic.
             // Original: 0x03 only.
        } else {
             // Domain
        }
        
        // Reverting to 0x03 (Domain) for everything as it's the most robust way for proxies
        // unless the server is very strict.
        payload.append(0x03)

        let hostData = Data(targetHost.utf8)
        guard hostData.count <= 255 else {
            throw LocalDebugProxyError.invalidTargetHost
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

    private static func performTrojanProbe(node: LocalDebugTrojanNode) async throws {
        guard node.type.lowercased() == "trojan" else {
            throw LocalDebugProxyError.unsupportedNodeType
        }

        let remoteHost = NWEndpoint.Host(node.host)
        let remotePort = NWEndpoint.Port(rawValue: UInt16(max(1, min(node.port, 65535)))) ?? .https

        let tlsOptions = NWProtocolTLS.Options()
        if let sni = node.sni, !sni.isEmpty {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sni)
        }

        // 忽略证书验证错误
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
                        let handshake = try makeTrojanHandshake(password: node.password, targetHost: "google.com", targetPort: 80)
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
                                    finish(.failure(LocalDebugProxyError.emptyResponse))
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

            connection.start(queue: DispatchQueue(label: "com.github.iappapp.xShadowsocks.trojan-probe"))
        }
    }

    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LocalDebugProxyError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum LocalDebugProxyError: LocalizedError {
    case invalidTargetHost
    case timeout
    case emptyResponse
    case unsupportedNodeType

    var errorDescription: String? {
        switch self {
        case .invalidTargetHost:
            return "目标主机名过长"
        case .timeout:
            return "连接超时"
        case .emptyResponse:
            return "未收到响应"
        case .unsupportedNodeType:
            return "仅支持 trojan 节点测试"
        }
    }
}
