import Foundation

/// Where the core -- and therefore the traffic it carries -- lives.
public enum ProxyMode: String, CaseIterable, Identifiable, Sendable {
    /// Core runs inside the app, listening on loopback. Needs no entitlement, so it is
    /// the only mode available on a free Apple Developer account.
    case loopback
    /// Core runs inside the packet-tunnel extension and carries all system traffic.
    /// Requires a paid account (Network Extension entitlement).
    ///
    /// The extension is not built by the default scheme so the project can be opened
    /// and run on a free account; see the note in the app target of the project file.
    case tunnel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .loopback: return "本地端口"
        case .tunnel: return "系统 VPN"
        }
    }

    public var detail: String {
        switch self {
        case .loopback: return "仅代理指向本机端口的 App（含内置浏览器），无需付费账号"
        case .tunnel: return "接管全部系统流量，需要付费开发者账号签名；当前构建未包含扩展"
        }
    }
}
