import Foundation

// MARK: - Parser A: Base64-decoded trojan:// URI list
//
// Input  : the Base64-decoded text from a subscription URL
// Format : one trojan:// URI per line
//
//   trojan://<password>@<host>:<port>?sni=...&allowInsecure=1#🇹🇭 泰国 01
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
            guard line.lowercased().hasPrefix("trojan://") else { continue }

            // Fragment after '#' is the node name (may contain emoji + spaces)
            let rawFragment = line.components(separatedBy: "#").dropFirst().joined(separator: "#")
            let nameFromFragment = decodedFragment(rawFragment)

            // Percent-encode spaces so URLComponents can parse the URI
            let sanitized = line.replacingOccurrences(of: " ", with: "%20")

            guard let components = URLComponents(string: sanitized),
                  let host = components.host,
                  let port = components.port,
                  let password = components.user,
                  !password.isEmpty
            else { continue }

            let queryItems = components.queryItems ?? []
            let sni = queryItems.first(where: { $0.name.lowercased() == "sni" })?.value
                   ?? queryItems.first(where: { $0.name.lowercased() == "peer" })?.value

            nodes.append(
                ServerNode(
                    name: nameFromFragment ?? host,
                    host: host,
                    port: port,
                    password: password,
                    nodeType: "trojan",
                    method: nil,
                    sni: sni,
                    latency: nil
                )
            )
        }

        return deduplicate(nodes)
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
