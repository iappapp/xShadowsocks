import Foundation

/// The core's cumulative counters for the current tunnel session. Daily totals are not
/// included — those live in the App Group and the app reads them directly.
public struct TrafficSnapshot: Equatable, Sendable {
    public let uploadTotal: Double
    public let downloadTotal: Double

    public init(uploadTotal: Double, downloadTotal: Double) {
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
    }
}

/// Commands the app sends to the running tunnel through `sendProviderMessage`.
public enum TunnelCommand: String, Sendable {
    /// Flush the extension's in-flight traffic counters into the App Group so the
    /// Data tab reflects the newest numbers instead of waiting for the next flush.
    case flushTraffic
    /// Current counters, including the totals mihomo reports for the live process.
    case trafficSnapshot
    /// Ask the core to reload the runtime config from disk.
    case reloadConfig
}

public struct TunnelMessage: Codable, Sendable {
    public let command: String
    public let payload: [String: String]?

    public init(command: TunnelCommand, payload: [String: String]? = nil) {
        self.command = command.rawValue
        self.payload = payload
    }
}

public struct TunnelReply: Codable, Sendable {
    public let success: Bool
    public let message: String?
    public let snapshot: TrafficPayload?

    public init(success: Bool, message: String? = nil, snapshot: TrafficPayload? = nil) {
        self.success = success
        self.message = message
        self.snapshot = snapshot
    }
}

public struct TrafficPayload: Codable, Sendable {
    public let uploadTotal: Double
    public let downloadTotal: Double

    public init(_ snapshot: TrafficSnapshot) {
        self.uploadTotal = snapshot.uploadTotal
        self.downloadTotal = snapshot.downloadTotal
    }

    public var snapshot: TrafficSnapshot {
        TrafficSnapshot(uploadTotal: uploadTotal, downloadTotal: downloadTotal)
    }
}
