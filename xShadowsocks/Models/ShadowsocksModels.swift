//
//  Untitled.swift
//  xShadowsocks
//
//  Created by mac on 2026/3/7.
//

enum ShadowsocksMethod: String, CaseIterable, Codable, Identifiable {
    case aes256gcm = "aes-256-gcm"
    case aes128gcm = "aes-128-gcm"
    case chacha20IetfPoly1305 = "chacha20-ietf-poly1305"
    case xchacha20IetfPoly1305 = "xchacha20-ietf-poly1305"

    var id: String { rawValue }
}

enum ShadowsocksPlugin: String, CaseIterable, Codable, Identifiable {
    case none = "无"
    case obfs = "obfs-local"
    case v2ray = "v2ray-plugin"

    var id: String { rawValue }
}

struct ShadowsocksConfig: Codable {
    var remark: String = ""
    var server: String = ""
    var port: String = ""
    var password: String = ""
    var method: ShadowsocksMethod = .aes256gcm
    var plugin: ShadowsocksPlugin = .none
    var pluginOptions: String = ""
    var udpRelay: Bool = true
    var tcpFastOpen: Bool = false

    var isValid: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && isPortValid
    }

    private var isPortValid: Bool {
        guard let value = Int(port), (1...65535).contains(value) else {
            return false
        }
        return true
    }
}
