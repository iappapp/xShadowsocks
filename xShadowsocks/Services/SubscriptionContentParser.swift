import Foundation

// MARK: - Subscription payload dispatch + Base64 decoding
//
// Three-path dispatch:
//   Path A – Raw payload looks like YAML (starts with 'proxies:', 'proxy-providers:', etc.) → parse as YAML directly
//   Path B – Base64 decode succeeds → decoded text is a trojan:// URI list
//   Path C – Base64 decode fails    → raw payload is a full mihomo YAML config file
//
// Consumers should use SubscriptionPayloadParser.parse(_:) and inspect the
// returned ParseResult; rawYAML is non-nil only for Path C.

enum SubscriptionContentParser {
    struct ParseResult {
        let nodes: [ServerNode]
        /// The original raw YAML text when the subscription is a full mihomo config.
        /// The caller is responsible for persisting this to the local config file path.
        let rawYAML: String?
    }

    static func parse(_ payload: String) -> ParseResult {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Path A: Check if raw payload looks like a YAML config file
        if isYAMLFormat(trimmedPayload) {
            let yamlNodes = MihomoYAMLConfigParser.parseProxies(from: trimmedPayload)
            // Always keep the downloaded YAML for runtime; nodes are for Home UI only.
            return ParseResult(nodes: yamlNodes, rawYAML: trimmedPayload)
        }
        
        // Path B: Base64-encoded trojan:// URI list
        if let decoded = decodeBase64(trimmedPayload) {
            let nodes = URIParser.parse(decoded)
            if !nodes.isEmpty {
                return ParseResult(nodes: nodes, rawYAML: nil)
            }
        }

        // Path C: Full mihomo YAML config file
        let yamlNodes = MihomoYAMLConfigParser.parseProxies(from: trimmedPayload)
        return ParseResult(
            nodes: yamlNodes,
            rawYAML: yamlNodes.isEmpty ? nil : trimmedPayload
        )
    }

    // MARK: - YAML format detection
    
    /// Checks if the payload looks like a YAML configuration file
    private static func isYAMLFormat(_ payload: String) -> Bool {
        let lowercased = payload.lowercased()
        
        // Look for common YAML configuration keys in Clash/Mihomo configs
        let yamlIndicators = [
            "proxies:",
            "proxy-providers:",
            "proxy-groups:",
            "rule-providers:",
            "rules:",
            "payload:"
        ]
        
        for indicator in yamlIndicators {
            if lowercased.contains(indicator) {
                return true
            }
        }
        
        // Check for YAML document start marker
        if payload.hasPrefix("---") {
            return true
        }
        
        return false
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
