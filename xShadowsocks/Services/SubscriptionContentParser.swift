import Foundation

// MARK: - Subscription payload dispatch + Base64 decoding
//
// Two-path dispatch:
//   Path A – Base64 decode succeeds → decoded text is a trojan:// URI list
//   Path B – Base64 decode fails    → raw payload is a full mihomo YAML config file
//
// Consumers should use SubscriptionPayloadParser.parse(_:) and inspect the
// returned ParseResult; rawYAML is non-nil only for Path B.

enum SubscriptionContentParser {
    struct ParseResult {
        let nodes: [ServerNode]
        /// The original raw YAML text when the subscription is a full mihomo config.
        /// The caller is responsible for persisting this to the local config file path.
        let rawYAML: String?
    }

    static func parse(_ payload: String) -> ParseResult {
        // Path A: Base64-encoded trojan:// URI list
        if let decoded = decodeBase64(payload) {
            let nodes = TrojanURIParser.parse(decoded)
            if !nodes.isEmpty {
                return ParseResult(nodes: nodes, rawYAML: nil)
            }
        }

        // Path B: Full mihomo YAML config file
        let yamlNodes = MihomoYAMLConfigParser.parseProxies(from: payload)
        return ParseResult(nodes: yamlNodes, rawYAML: yamlNodes.isEmpty ? nil : payload)
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
