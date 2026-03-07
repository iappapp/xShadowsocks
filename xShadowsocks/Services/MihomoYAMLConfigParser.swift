import Foundation

// MARK: - Parser B: Full mihomo / Clash YAML config file
//
// Input  : the raw YAML text of a complete mihomo configuration file
// Output : every proxy entry under the `proxies:` key as a ServerNode
//
// The caller is also expected to persist the raw YAML as the local
// config file (default.conf) so mihomo can use it directly.
//
// Supports both block-scalar and inline-object proxy entries:
//
//   proxies:
//     - name: "节点名"       # block form
//       type: trojan
//       server: example.com
//       port: 443
//       password: secret
//
//     - {name: 节点名, type: trojan, server: example.com, port: 443, password: secret}

enum MihomoYAMLConfigParser {
    static func parseProxies(from yamlText: String) -> [ServerNode] {
        let lines = yamlText.components(separatedBy: .newlines)

        var inProxiesSection = false
        var currentFields: [String: String] = [:]
        var parsedNodes: [ServerNode] = []

        func flushCurrentNode() {
            guard !currentFields.isEmpty else { return }
            defer { currentFields.removeAll(keepingCapacity: true) }

            let name     = currentFields["name"]?.trimmed     ?? ""
            let host     = currentFields["server"]?.trimmed   ?? ""
            let port     = Int(currentFields["port"] ?? "")   ?? 443
            let password = currentFields["password"]?.trimmed ?? ""
            let type     = currentFields["type"]?.trimmed     ?? "shadowsocks"
            let method   = currentFields["cipher"]?.trimmed ?? currentFields["method"]?.trimmed
            let sni      = currentFields["sni"]?.trimmed

            guard !name.isEmpty, !host.isEmpty, !password.isEmpty else { return }

            parsedNodes.append(
                ServerNode(
                    name: name,
                    host: host,
                    port: port,
                    password: password,
                    nodeType: type,
                    method: method,
                    sni: sni,
                    latency: nil
                )
            )
        }

        for rawLine in lines {
            let line    = stripYAMLComment(from: rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Detect start of `proxies:` section
            if !inProxiesSection {
                if trimmed == "proxies:" { inProxiesSection = true }
                continue
            }

            // Any top-level key (no leading whitespace) other than `proxies:` ends the section
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasSuffix(":") {
                flushCurrentNode()
                break
            }

            // New list entry `-`
            if trimmed.hasPrefix("-") {
                flushCurrentNode()

                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if item.hasPrefix("{") && item.hasSuffix("}") {
                    // Inline object: {name: ..., type: ..., ...}
                    currentFields = parseInlineObject(String(item))
                    flushCurrentNode()
                } else {
                    currentFields = [:]
                    if let (k, v) = parseKeyValue(item) { currentFields[k] = v }
                }
                continue
            }

            // Continuation key-value inside the current block entry
            if let (k, v) = parseKeyValue(trimmed) {
                currentFields[k] = v
            }
        }

        flushCurrentNode()
        return deduplicate(parsedNodes)
    }

    // MARK: - YAML helpers

    /// Strips trailing `# comment` while respecting single- and double-quoted strings.
    private static func stripYAMLComment(from line: String) -> String {
        var out = ""
        var inSingle = false
        var inDouble = false
        for ch in line {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "#" && !inSingle && !inDouble { break }
            out.append(ch)
        }
        return out
    }

    /// Parses `key: value` (lowercases the key, strips surrounding quotes from value).
    private static func parseKeyValue(_ text: String) -> (String, String)? {
        guard let sep = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<sep]).trimmed.lowercased()
        let val = String(text[text.index(after: sep)...]).trimmed
        guard !key.isEmpty else { return nil }
        return (key, unquote(val))
    }

    /// Parses `{key: value, key2: value2, ...}` inline YAML objects.
    private static func parseInlineObject(_ text: String) -> [String: String] {
        let inner  = String(text.dropFirst().dropLast())
        let fields = splitCommaRespectingQuotes(inner)
        var result: [String: String] = [:]
        for field in fields {
            if let (k, v) = parseKeyValue(field) { result[k] = v }
        }
        return result
    }

    /// Splits on `,` while respecting quoted strings.
    private static func splitCommaRespectingQuotes(_ text: String) -> [String] {
        var results: [String] = []
        var buffer = ""
        var inSingle = false
        var inDouble = false
        for ch in text {
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "," && !inSingle && !inDouble {
                results.append(buffer.trimmed)
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            buffer.append(ch)
        }
        if !buffer.isEmpty { results.append(buffer.trimmed) }
        return results
    }

    /// Removes surrounding `"..."` or `'...'` quotes.
    private static func unquote(_ text: String) -> String {
        let t = text.trimmed
        guard t.count >= 2 else { return t }
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func deduplicate(_ nodes: [ServerNode]) -> [ServerNode] {
        var seen   = Set<String>()
        var result = [ServerNode]()
        for node in nodes {
            let key = "\(node.name.lowercased())|\(node.host.lowercased())"
            if seen.insert(key).inserted { result.append(node) }
        }
        return result
    }
}

// MARK: - String convenience

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
