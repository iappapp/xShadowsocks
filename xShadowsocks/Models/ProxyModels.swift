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
    var flow: String?
    var encryption: String?
    var tls: Bool?
    var skipCertVerify: Bool?
    var network: String?          // VLESS 传输类型 (tcp, ws, grpc, h2 等)
    var publicKey: String?        // VLESS Reality 公钥 (pbk)
    var shortId: String?          // VLESS Reality 短ID (sid)
    var serviceName: String?      // gRPC 服务名称或 WebSocket 路径
    var clientFingerprint: String? // Reality/TLS 客户端指纹 (chrome, safari 等)
    var headers: [String: String]? // HTTP 头部信息

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 443,
        password: String = "",
        nodeType: String = "shadowsocks",
        method: String? = nil,
        sni: String? = nil,
        latency: Int?,
        flow: String? = nil,
        encryption: String? = nil,
        tls: Bool? = nil,
        skipCertVerify: Bool? = nil,
        network: String? = nil,
        publicKey: String? = nil,
        shortId: String? = nil,
        serviceName: String? = nil,
        clientFingerprint: String? = nil,
        headers: [String: String]? = nil
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
        self.flow = flow
        self.encryption = encryption
        self.tls = tls
        self.skipCertVerify = skipCertVerify
        self.network = network
        self.publicKey = publicKey
        self.shortId = shortId
        self.serviceName = serviceName
        self.clientFingerprint = clientFingerprint
        self.headers = headers
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
