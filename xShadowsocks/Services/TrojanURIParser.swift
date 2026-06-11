import Foundation

// MARK: - Parser A: Base64-decoded proxy URI list
//
// Input  : the Base64-decoded text from a subscription URL
// Format : one proxy URI per line
//
//   trojan://<password>@<host>:<port>?sni=...&allowInsecure=1#🇹🇭 泰国 01
//   vless://<uuid>@<host>:<port>?encryption=none&security=tls&sni=...&flow=xtls-rprx-vision#🇭🇰 香港 01
//
// The fragment after '#' becomes the node display name.
// Falls back to the hostname when no fragment is present.

enum TrojanURIParser {
    static func parse(_ decodedText: String) -> [ServerNode] {
        let lines = decodedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var nodes: [ServerNode] = []

        for line in lines {
            if line.lowercased().hasPrefix("trojan://") {
                if let node = parseTrojanURI(line) { nodes.append(node) }
            } else if line.lowercased().hasPrefix("vless://") {
                if let node = parseVlessURI(line) { nodes.append(node) }
            }
        }

        return deduplicate(nodes)
    }

    // MARK: - Trojan URI

    /// Parses: `trojan://<password>@<host>:<port>?sni=...&allowInsecure=1#Name`
    private static func parseTrojanURI(_ line: String) -> ServerNode? {
        let rawFragment = line.components(separatedBy: "#").dropFirst().joined(separator: "#")
        let nameFromFragment = decodedFragment(rawFragment)

        let sanitized = line.replacingOccurrences(of: " ", with: "%20")

        guard let components = URLComponents(string: sanitized),
              let host = components.host,
              let port = components.port,
              let password = components.user,
              !password.isEmpty
        else { return nil }

        let queryItems = components.queryItems ?? []
        let sni = queryItems.first(where: { $0.name.lowercased() == "sni" })?.value
               ?? queryItems.first(where: { $0.name.lowercased() == "peer" })?.value

        return ServerNode(
            name: nameFromFragment ?? host,
            host: host,
            port: port,
            password: password,
            nodeType: "trojan",
            method: nil,
            sni: sni,
            latency: nil
        )
    }

    // MARK: - VLESS URI

    /// Parses: `vless://<uuid>@<host>:<port>?encryption=none&security=tls&sni=...&flow=xtls-rprx-vision&type=tcp#Name`
    private static func parseVlessURI(_ line: String) -> ServerNode? {
        let rawFragment = line.components(separatedBy: "#").dropFirst().joined(separator: "#")
        let nameFromFragment = decodedFragment(rawFragment)

        let sanitized = line.replacingOccurrences(of: " ", with: "%20")

        guard let components = URLComponents(string: sanitized),
              let host = components.host,
              let port = components.port,
              let uuid = components.user,
              !uuid.isEmpty
        else { return nil }

        let queryItems = components.queryItems ?? []
        let sni = queryItems.first(where: { $0.name.lowercased() == "sni" })?.value
               ?? queryItems.first(where: { $0.name.lowercased() == "peer" })?.value
        let flow = queryItems.first(where: { $0.name.lowercased() == "flow" })?.value
        let encryption = queryItems.first(where: { $0.name.lowercased() == "encryption" })?.value
        let networkType = queryItems.first(where: { $0.name.lowercased() == "type" })?.value
        let publicKey = queryItems.first(where: { $0.name.lowercased() == "pbk" })?.value
        let shortId = queryItems.first(where: { $0.name.lowercased() == "sid" })?.value
        let serviceName = queryItems.first(where: { $0.name.lowercased() == "serviceName" })?.value
               ?? queryItems.first(where: { $0.name.lowercased() == "path" })?.value

        return ServerNode(
            name: nameFromFragment ?? host,
            host: host,
            port: port,
            password: uuid,
            nodeType: "vless",
            method: encryption,
            sni: sni,
            latency: nil,
            flow: flow,
            encryption: encryption,
            network: networkType,
            publicKey: publicKey,
            shortId: shortId,
            serviceName: serviceName
        )
    }

    // MARK: - Helpers

    private static func decodedFragment(_ rawFragment: String) -> String? {
        let trimmed = rawFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let decoded = (trimmed.removingPercentEncoding ?? trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private static func deduplicate(_ nodes: [ServerNode]) -> [ServerNode] {
        var seen = Set<String>()
        var result: [ServerNode] = []
        for node in nodes {
            let key = "\(node.name.lowercased())|\(node.host.lowercased())|\(node.port)"
            if seen.insert(key).inserted {
                result.append(node)
            }
        }
        return result
    }
}