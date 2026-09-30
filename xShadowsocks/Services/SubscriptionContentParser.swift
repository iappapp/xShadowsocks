import Foundation

// MARK: - Subscription payload dispatch
//
// Three paths, tried in order:
//
//   A. the payload already looks like a YAML config  -> kept as `rawYAML`
//   B. the payload is Base64 of a `scheme://` URI list -> nodes only
//   C. anything else that still parses as a YAML config -> kept as `rawYAML`
//
// `rawYAML` is what the caller persists as the active config file; the nodes are the
// proxy list shown in the Home tab.

enum SubscriptionContentParser {
    struct ParseResult {
        let nodes: [ServerNode]
        /// The original raw YAML text when the subscription is a full mihomo config.
        /// The caller is responsible for persisting this to the local config file path.
        let rawYAML: String?
    }

    static func parse(_ payload: String) -> ParseResult {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // Path A: the raw payload is already a YAML config.
        if looksLikeYAMLConfig(trimmedPayload) {
            return ParseResult(
                nodes: MihomoYAMLConfigParser.parseProxies(from: trimmedPayload),
                rawYAML: trimmedPayload
            )
        }

        // Path B: Base64-encoded URI list.
        if let decoded = decodeBase64(trimmedPayload) {
            let nodes = URIParser.parse(decoded)
            if !nodes.isEmpty {
                return ParseResult(nodes: nodes, rawYAML: nil)
            }
        }

        // Path C: not a URI list, so try it as a YAML config anyway.
        let nodes = MihomoYAMLConfigParser.parseProxies(from: trimmedPayload)
        return ParseResult(
            nodes: nodes,
            rawYAML: nodes.isEmpty ? nil : trimmedPayload
        )
    }

    // MARK: - Format detection

    /// Whether the payload carries the top-level keys of a Clash/Mihomo config.
    private static func looksLikeYAMLConfig(_ payload: String) -> Bool {
        if payload.hasPrefix("---") { return true }

        let configKeys = [
            "proxies:",
            "proxy-providers:",
            "proxy-groups:",
            "rule-providers:",
            "rules:",
            "payload:"
        ]
        let lowercased = payload.lowercased()
        return configKeys.contains { lowercased.contains($0) }
    }

    // MARK: - Base64 helper

    /// Decodes URL-safe or standard Base64 text (strips whitespace, fixes padding).
    /// Returns nil if the input is not valid Base64 or decodes to non-UTF8 bytes.
    static func decodeBase64(_ text: String) -> String? {
        let compact = text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !compact.isEmpty else { return nil }

        let normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingCount = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingCount)

        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return decoded
    }
}
