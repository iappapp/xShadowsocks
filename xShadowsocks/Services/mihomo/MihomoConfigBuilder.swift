import Foundation

struct MihomoConfigBuilder {
    static let initialServerNodes: [ServerNode] = []

    func build(request: MihomoBootstrapRequest) throws -> MihomoRenderedConfig {
        guard !request.nodes.isEmpty else {
            throw MihomoRuntimeError.emptyNodeList
        }

        let selected = try selectNode(from: request)
        let proxies = try request.nodes.map(makeProxyEntry)
        let proxyNames = request.nodes.map { quoted($0.name) }.joined(separator: ", ")
        let selectedProxyName = selected.name

        let modeRule: String
        switch request.routeMode {
        case .configuration:
            modeRule = "MATCH,Proxy"
        case .proxy:
            modeRule = "MATCH,Proxy"
        case .direct:
            modeRule = "MATCH,DIRECT"
        }

        var lines: [String] = []
        lines.append("mixed-port: \(request.mixedPort)")
        lines.append("socks-port: \(request.socksPort)")
        lines.append("bind-address: '*'")
        lines.append("mode: rule")
        lines.append("log-level: info")
        lines.append("external-controller: '127.0.0.1:\(request.externalControllerPort)'")
        if let secret = request.externalControllerSecret, !secret.isEmpty {
            lines.append("secret: \(quoted(secret))")
        }
        lines.append("")

        lines.append("dns:")
        lines.append("  enable: true")
        lines.append("  ipv6: false")
        lines.append("  default-nameserver: [223.5.5.5, 119.29.29.29, 114.114.114.114]")
        lines.append("  enhanced-mode: fake-ip")
        lines.append("  fake-ip-range: 198.18.0.1/16")
        lines.append("  use-hosts: true")
        lines.append("  respect-rules: true")
        lines.append("  proxy-server-nameserver: [223.5.5.5, 119.29.29.29, 114.114.114.114]")
        lines.append("  nameserver: [223.5.5.5, 119.29.29.29, 114.114.114.114]")
        lines.append("  nameserver-policy:")
        lines.append("    '+.google.com': [1.1.1.1, 8.8.8.8]")
        lines.append("    '+.facebook.com': [1.1.1.1, 8.8.8.8]")
        lines.append("    '+.youtube.com': [1.1.1.1, 8.8.8.8]")
        lines.append("  fallback: [1.1.1.1, 8.8.8.8]")
        lines.append("  fallback-filter: { geoip: true, geoip-code: CN, ipcidr: [240.0.0.0/4], domain: [+.google.com, +.facebook.com, +.youtube.com] }")
        lines.append("")

        lines.append("proxies:")
        for proxy in proxies {
            lines.append(contentsOf: proxy)
        }
        lines.append("")

        lines.append("proxy-groups:")
        lines.append("  - name: Proxy")
        lines.append("    type: select")
        lines.append("    proxies: [\(proxyNames), DIRECT]")
        lines.append("  - name: Auto")
        lines.append("    type: url-test")
        lines.append("    url: http://www.gstatic.com/generate_204")
        lines.append("    interval: 300")
        lines.append("    tolerance: 100")
        lines.append("    proxies: [\(proxyNames)]")
        lines.append("")

        lines.append("rules:")
        lines.append("  - DOMAIN-SUFFIX,local,DIRECT")
        lines.append("  - DOMAIN-SUFFIX,lan,DIRECT")
        lines.append("  - GEOIP,CN,DIRECT")
        lines.append("  - \(modeRule)")

        let yamlText = lines.joined(separator: "\n") + "\n"
        return MihomoRenderedConfig(
            yamlText: yamlText,
            selectedProxyName: selectedProxyName,
            externalController: "127.0.0.1:\(request.externalControllerPort)"
        )
    }

    private func selectNode(from request: MihomoBootstrapRequest) throws -> MihomoProxyNode {
        if let selectedNodeID = request.selectedNodeID,
           let selected = request.nodes.first(where: { $0.id == selectedNodeID }) {
            return selected
        }

        guard let first = request.nodes.first else {
            throw MihomoRuntimeError.missingSelectedNode
        }
        return first
    }

    private func makeProxyEntry(from node: MihomoProxyNode) throws -> [String] {
        guard node.type.lowercased() == "trojan" else {
            throw MihomoRuntimeError.unsupportedNodeType(node.type)
        }

        var lines: [String] = []
        lines.append("  - name: \(quoted(node.name))")
        lines.append("    type: trojan")
        lines.append("    server: \(quoted(node.host))")
        lines.append("    port: \(node.port)")
        lines.append("    password: \(quoted(node.password))")
        if let sni = node.sni, !sni.isEmpty {
            lines.append("    sni: \(quoted(sni))")
        }
        lines.append("    udp: true")
        lines.append("    skip-cert-verify: true")
        return lines
    }

    private func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\\"", with: "\\\\\\\""))\""
    }
}
