import Foundation

// MARK: - Parser A: Base64-decoded proxy URI list
//
// Input  : the Base64-decoded text from a subscription URL
// Format : one proxy URI per line
//
//   vless://<uuid>@<host>:<port>?encryption=none&security=tls&sni=...&flow=xtls-rprx-vision#🇭🇰 香港 01
//   anytls://<password>@<host>:<port>?sni=...&fp=chrome#🇭🇰 香港 01
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
            if line.lowercased().hasPrefix("vless://") {
                if let node = parseVlessURI(line) { nodes.append(node) }
            } else if line.lowercased().hasPrefix("anytls://") {
                if let node = parseAnyTLSURI(line) { nodes.append(node) }
            }
        }

        return deduplicate(nodes)
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
        let sni = queryValue("sni", in: queryItems)
               ?? queryValue("peer", in: queryItems)
        let flow = queryValue("flow", in: queryItems)
        let encryption = queryValue("encryption", in: queryItems)
        let security = queryValue("security", in: queryItems)?.lowercased()
        let networkType = queryValue("type", in: queryItems)
        let publicKey = queryValue("pbk", in: queryItems)
        let shortId = queryValue("sid", in: queryItems)
        let clientFingerprint = queryValue("fp", in: queryItems)
            ?? queryValue("client-fingerprint", in: queryItems)
        let serviceName = queryValue("serviceName", in: queryItems)
               ?? queryValue("path", in: queryItems)

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
            tls: security == "tls" || publicKey != nil ? true : nil,
            network: networkType,
            publicKey: publicKey,
            shortId: shortId,
            serviceName: serviceName,
            clientFingerprint: clientFingerprint
        )
    }

    // MARK: - AnyTLS URI

    /// Parses: `anytls://<password>@<host>:<port>?type=tcp&insecure=0&fp=chrome&sni=...#Name`
    private static func parseAnyTLSURI(_ line: String) -> ServerNode? {
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
        let sni = queryValue("sni", in: queryItems)
            ?? queryValue("peer", in: queryItems)
        let networkType = queryValue("type", in: queryItems)
        let clientFingerprint = queryValue("fp", in: queryItems)
            ?? queryValue("client-fingerprint", in: queryItems)
        let skipCertVerify = parseSkipCertVerify(from: queryItems)

        return ServerNode(
            name: nameFromFragment ?? host,
            host: host,
            port: port,
            password: password,
            nodeType: "anytls",
            method: nil,
            sni: sni,
            latency: nil,
            tls: true,
            skipCertVerify: skipCertVerify,
            network: networkType,
            clientFingerprint: clientFingerprint
        )
    }

    // MARK: - Helpers

    private static func queryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        let wanted = name.lowercased()
        return queryItems.first { $0.name.lowercased() == wanted }?.value
    }

    private static func parseSkipCertVerify(from queryItems: [URLQueryItem]) -> Bool? {
        let rawValue = queryValue("allowInsecure", in: queryItems)
            ?? queryValue("insecure", in: queryItems)
            ?? queryValue("skip-cert-verify", in: queryItems)
        switch rawValue?.lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

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