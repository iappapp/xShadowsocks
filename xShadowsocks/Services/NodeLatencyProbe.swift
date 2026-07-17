import Foundation
import Network

enum NodeLatencyProbe {
    /// TCP connect RTT to the node host/port (display-only latency).
    static func measure(host: String, port: Int, timeout: TimeInterval = 4) async -> Int {
        let start = Date()
        do {
            try await withTimeout(seconds: timeout) {
                try await tcpConnect(host: host, port: port)
            }
            return max(Int(Date().timeIntervalSince(start) * 1000), 1)
        } catch {
            return -1
        }
    }

    private static func tcpConnect(host: String, port: Int) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw ProbeError.invalidPort
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var finished = false

            @Sendable
            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(ProbeError.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func withTimeout(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProbeError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private enum ProbeError: Error {
        case invalidPort
        case cancelled
        case timeout
    }
}
