import Foundation
import SwiftUI

struct ServerNode: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var password: String
    var nodeType: String
    var method: String?
    var sni: String?
    var latency: Int?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 443,
        password: String = "",
        nodeType: String = "shadowsocks",
        method: String? = nil,
        sni: String? = nil,
        latency: Int?
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        self.nodeType = nodeType
        self.method = method
        self.sni = sni
        self.latency = latency
    }

    var latencyText: String {
        guard let latency else { return "-" }
        return latency >= 0 ? "\(latency) ms" : "超时"
    }

    var latencyColor: Color {
        guard let latency else { return .secondary }
        if latency < 0 { return .red }
        if latency < 100 { return .green }
        if latency < 180 { return .orange }
        return .red
    }
}

struct ProxyConfigSource: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var url: String
    var nodes: [ServerNode]
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, url: String, nodes: [ServerNode], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.nodes = nodes
        self.updatedAt = updatedAt
    }
}

enum ProxyEngine: String, CaseIterable, Identifiable, Codable {
    case local = "Local"
    case mihomo = "Mihomo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            return "Local"
        case .mihomo:
            return "Mihomo"
        }
    }

    var subtitle: String {
        switch self {
        case .local:
            return "仅需节点信息，轻量转发"
        case .mihomo:
            return "完整配置文件，支持规则分流"
        }
    }
}

enum RouteMode: String, CaseIterable, Identifiable {
    case configuration = "配置"
    case proxy = "代理"
    case direct = "直连"
    case scenario = "场景"

    var id: String { rawValue }
}

enum UpdateInterval: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case sixHours = "6h"
    case oneDay = "24h"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes:
            return "15 分钟"
        case .thirtyMinutes:
            return "30 分钟"
        case .oneHour:
            return "1 小时"
        case .sixHours:
            return "6 小时"
        case .oneDay:
            return "24 小时"
        }
    }
}
