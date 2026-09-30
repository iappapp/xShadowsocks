import Foundation

// MARK: - Parser B: full mihomo / Clash YAML config file
//
// Input  : the raw YAML text of a complete mihomo configuration file
// Output : every entry under the top-level `proxies:` key as a ServerNode
//
// The nodes are for display only — the caller persists the raw YAML verbatim and the
// core reads that file, so a field this parser does not know about still works.
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
        let nodes = proxyEntries(in: yamlText).compactMap { ProxyFields($0).node }
        return deduplicate(nodes)
    }

    // MARK: - Section scanning

    /// The field map of every proxy entry, in document order.
    private static func proxyEntries(in yamlText: String) -> [[String: String]] {
        let document = yamlText.trimmed

        // Some endpoints hand back a single proxy instead of a config file.
        if let inlineObject = inlineObject(of: document) {
            return [parseInlineObject(inlineObject)]
        }

        return scanProxiesSection(in: document.components(separatedBy: .newlines))
    }

    private static func scanProxiesSection(in lines: [String]) -> [[String: String]] {
        var entries: [[String: String]] = []
        var current: [String: String] = [:]

        func flushCurrentEntry() {
            guard !current.isEmpty else { return }
            entries.append(current)
            current.removeAll(keepingCapacity: true)
        }

        var insideProxies = false
        for rawLine in lines {
            let line = stripComment(from: rawLine)
            let trimmed = line.trimmed
            guard !trimmed.isEmpty else { continue }

            guard insideProxies else {
                insideProxies = trimmed == "proxies:"
                continue
            }

            // The next top-level key closes the section.
            guard line.isIndented || !trimmed.hasSuffix(":") else {
                flushCurrentEntry()
                break
            }

            guard trimmed.hasPrefix("-") else {
                appendContinuation(trimmed, to: &current)
                continue
            }

            // A new list entry closes the previous one.
            flushCurrentEntry()
            let item = String(trimmed.dropFirst()).trimmed
            if let inlineObject = inlineObject(of: item) {
                entries.append(parseInlineObject(inlineObject))
            } else {
                current = keyValuePair(in: item).map { [$0.key: $0.value] } ?? [:]
            }
        }

        flushCurrentEntry()
        return entries
    }

    /// A key on its own line either holds a value or an inline nested object.
    private static func appendContinuation(_ line: String, to fields: inout [String: String]) {
        guard let pair = keyValuePair(in: line) else { return }
        if let inlineObject = inlineObject(of: pair.value) {
            fields.merge(parseInlineObject(inlineObject, prefix: pair.key)) { _, newValue in newValue }
        } else {
            fields[pair.key] = pair.value
        }
    }

    // MARK: - Field mapping

    /// The fields of one proxy entry. Mihomo subscriptions spell the same concept in
    /// several ways, so each lookup walks the aliases in order.
    private struct ProxyFields {
        private let values: [String: String]

        init(_ values: [String: String]) {
            self.values = values
        }

        /// First non-empty value among `keys`.
        private func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = values[key], !value.isEmpty { return value }
            }
            return nil
        }

        private func string(_ keys: String...) -> String? {
            string(keys)
        }

        private func int(_ key: String) -> Int? {
            string([key]).flatMap(Int.init)
        }

        private func boolean(_ keys: [String]) -> Bool? {
            guard let text = string(keys)?.lowercased() else { return nil }
            switch text {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }

        private func boolean(_ keys: String...) -> Bool? {
            boolean(keys)
        }

        /// A display-only node: name and server are enough, the secret field's name
        /// varies by protocol.
        var node: ServerNode? {
            guard let name = string("name"), let host = string("server") else { return nil }

            let cipher = string("cipher", "method")
            return ServerNode(
                name: name,
                host: host,
                port: int("port") ?? 443,
                password: string("password", "uuid", "auth", "auth-str", "private-key") ?? "",
                nodeType: string("type") ?? "shadowsocks",
                method: cipher,
                sni: string("sni", "servername", "server-name"),
                latency: nil,
                flow: string("flow"),
                encryption: string("encryption") ?? cipher,
                tls: boolean("tls"),
                skipCertVerify: boolean("skip-cert-verify"),
                network: string("network"),
                publicKey: string("reality-opts.public-key", "reality-opts.publickey", "pbk"),
                shortId: string("reality-opts.short-id", "reality-opts.shortid", "sid"),
                serviceName: string("grpc-opts.grpc-service-name", "ws-opts.path", "path", "servicename"),
                clientFingerprint: string("client-fingerprint", "fingerprint", "fp")
            )
        }
    }

    // MARK: - YAML text helpers

    /// The `{...}` body of a lone inline object (`{...}` or `- {...}`), else nil.
    private static func inlineObject(of text: String) -> String? {
        let body = text.hasPrefix("-") ? String(text.dropFirst()).trimmed : text
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return nil }
        return body
    }

    /// Parses `{key: value, key2: value2, nested: {key: value}}`, flattening nested
    /// objects under a `parent.child` key.
    private static func parseInlineObject(_ text: String, prefix: String? = nil) -> [String: String] {
        let body = String(text.dropFirst().dropLast())

        var result: [String: String] = [:]
        for field in splitOnCommas(body) {
            guard let pair = keyValuePair(in: field) else { continue }
            let key = [prefix, pair.key].compactMap { $0 }.joined(separator: ".")
            if let nested = inlineObject(of: pair.value) {
                result.merge(parseInlineObject(nested, prefix: key)) { _, newValue in newValue }
            } else {
                result[key] = pair.value
            }
        }
        return result
    }

    /// Splits `key: value` into a lowercased key and an unquoted value.
    private static func keyValuePair(in text: String) -> (key: String, value: String)? {
        guard let separator = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<separator]).trimmed.lowercased()
        guard !key.isEmpty else { return nil }
        return (key, unquote(String(text[text.index(after: separator)...])))
    }

    /// Splits on `,` while respecting quoted strings and nested inline objects.
    private static func splitOnCommas(_ text: String) -> [String] {
        var segments: [String] = []
        var buffer = ""
        var quote: Character?
        var braceDepth = 0

        for character in text {
            if let opening = quote {
                if character == opening { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth -= 1
            }

            if character == ",", quote == nil, braceDepth == 0 {
                segments.append(buffer.trimmed)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(character)
            }
        }
        if !buffer.trimmed.isEmpty { segments.append(buffer.trimmed) }
        return segments
    }

    /// Strips a trailing `# comment` while respecting single- and double-quoted text.
    private static func stripComment(from line: String) -> String {
        var result = ""
        var quote: Character?

        for character in line {
            if let opening = quote {
                if character == opening { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            }
            result.append(character)
        }
        return result
    }

    /// Removes surrounding `"..."` or `'...'` quotes.
    private static func unquote(_ text: String) -> String {
        let trimmed = text.trimmed
        guard trimmed.count >= 2 else { return trimmed }
        let quote = trimmed.first
        guard quote == "\"" || quote == "'", trimmed.hasSuffix(String(quote!)) else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func deduplicate(_ nodes: [ServerNode]) -> [ServerNode] {
        var seen = Set<String>()
        return nodes.filter { seen.insert("\($0.name.lowercased())|\($0.host.lowercased())").inserted }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isIndented: Bool { hasPrefix(" ") || hasPrefix("\t") }
}
