//
//  ConfigSoureModel.swift
//  xShadowsocks
//
//  Created by apple on 2026/7/21.
//

import Foundation

struct ConfigSourceModel: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var url: String
    var nodes: [ServerNode]
    var updatedAt: Date
    /// Merged mihomo YAML (original subscription YAML + injected proxies).
    /// When present, selecting this source re-writes its file before starting the proxy.
    var yamlConfig: String?
    /// On-disk filename (`<sanitized name>.yaml`) this source is persisted to.
    var fileName: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        nodes: [ServerNode],
        updatedAt: Date = Date(),
        yamlConfig: String? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.nodes = nodes
        self.updatedAt = updatedAt
        self.yamlConfig = yamlConfig
        self.fileName = fileName
    }
}

