import Foundation

enum MihomoYAMLProxyInjector {
    static func injecting(_ nodes: [ServerNode], into yaml: String) -> String {
        guard !nodes.isEmpty else { return yaml }

        let normalized = MihomoConfigFileStore.normalizeForMihomoYAML(yaml)
        let lines = normalized.components(separatedBy: .newlines)
        let proxySection = renderProxySection(for: nodes)
        let proxyGroupSection = renderProxyGroupSection(for: nodes, in: lines)

        if let range = topLevelSectionRange(named: "proxies", in: lines) {
            var updated = lines
            updated.replaceSubrange(range, with: proxySection)
            updated = replacingProxyGroups(in: updated, with: proxyGroupSection)
            return joined(updated)
        }

        var updated = lines
        let insertIndex = firstTopLevelSectionIndex(
            namedAnyOf: ["proxy-groups", "rules", "rule-providers"],
            in: updated
        ) ?? updated.count

        var insertion = proxySection
        if insertIndex > 0, !updated[insertIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertion.insert("", at: 0)
        }
        if insertIndex < updated.count, !updated[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertion.append("")
        }
        updated.insert(contentsOf: insertion, at: insertIndex)
        updated = replacingProxyGroups(in: updated, with: proxyGroupSection)
        return joined(updated)
    }

    private static func replacingProxyGroups(in lines: [String], with proxyGroupSection: [String]) -> [String] {
        var updated = lines
        if let range = topLevelSectionRange(named: "proxy-groups", in: updated) {
            updated.replaceSubrange(range, with: proxyGroupSection)
            return updated
        }

        let insertIndex = firstTopLevelSectionIndex(namedAnyOf: ["rules", "rule-providers"], in: updated) ?? updated.count
        var insertion = proxyGroupSection
        if insertIndex > 0, !updated[insertIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertion.insert("", at: 0)
        }
        if insertIndex < updated.count, !updated[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertion.append("")
        }
        updated.insert(contentsOf: insertion, at: insertIndex)
        return updated
    }

    private static func topLevelSectionRange(named name: String, in lines: [String]) -> Range<Int>? {
        guard let start = firstTopLevelSectionIndex(namedAnyOf: [name], in: lines) else { return nil }
        var end = start + 1
        if !isBlockSectionLine(lines[start]) {
            return start..<end
        }
        while end < lines.count {
            if isTopLevelSectionLine(lines[end]) {
                break
            }
            end += 1
        }
        return start..<end
    }

    private static func firstTopLevelSectionIndex(namedAnyOf names: [String], in lines: [String]) -> Int? {
        let wanted = Set(names.map { "\($0):" })
        return lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isTopLevelSectionLine(line) else { return false }
            if wanted.contains(trimmed) {
                return true
            }
            return names.contains { trimmed.hasPrefix("\($0):") }
        }
    }

    private static func isTopLevelSectionLine(_ line: String) -> Bool {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: ":") else { return false }
        let key = String(trimmed[..<separator])
        return !key.isEmpty && !key.contains(" ")
    }

    private static func isBlockSectionLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":")
    }

    private static func renderProxySection(for nodes: [ServerNode]) -> [String] {
        var lines = ["proxies:"]
        for node in nodes {
            lines.append(contentsOf: renderProxy(node))
        }
        return lines
    }

    private static func renderProxyGroupSection(for nodes: [ServerNode], in lines: [String]) -> [String] {
        let groupName = firstProxyGroupName(in: lines) ?? "Proxy"
        let proxyNames = nodes.map { quoted($0.name) }.joined(separator: ", ")
        return [
            "proxy-groups:",
            "  - name: \(quoted(groupName))",
            "    type: select",
            "    proxies: [\(proxyNames), DIRECT]"
        ]
    }

    private static func firstProxyGroupName(in lines: [String]) -> String? {
        guard let range = topLevelSectionRange(named: "proxy-groups", in: lines) else { return nil }
        let section = Array(lines[range])
        for line in section {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("- {") || trimmed.hasPrefix("{") {
                if let name = inlineValue(for: "name", in: trimmed) {
                    return name
                }
            }
            if trimmed.hasPrefix("name:") {
                return unquote(String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    private static func inlineValue(for key: String, in text: String) -> String? {
        let pattern = "\(key):"
        guard let keyRange = text.range(of: pattern) else { return nil }
        let rest = text[keyRange.upperBound...]
        let raw = rest.split(separator: ",", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return unquote(raw)
    }

    private static func renderProxy(_ node: ServerNode) -> [String] {
        switch node.nodeType.lowercased() {
        case "vless":
            return renderVLESS(node)
        case "anytls":
            return renderAnyTLS(node)
        default:
            return []
        }
    }

    private static func renderVLESS(_ node: ServerNode) -> [String] {
        var lines = commonProxyLines(node, type: "vless")
        lines.append("    uuid: \(quoted(node.password))")
        appendIfPresent("    flow: ", node.flow, to: &lines)
        appendIfPresent("    encryption: ", node.encryption, to: &lines)
        appendIfPresent("    network: ", node.network, to: &lines)
        if node.tls == true || node.publicKey != nil || node.sni != nil {
            lines.append("    tls: true")
        } else if node.tls == false {
            lines.append("    tls: false")
        }
        appendIfPresent("    servername: ", node.sni.map(quoted), to: &lines)
        appendIfPresent("    client-fingerprint: ", node.clientFingerprint, to: &lines)
        if hasValue(node.publicKey) || hasValue(node.shortId) {
            lines.append("    reality-opts:")
            appendIfPresent("      public-key: ", node.publicKey.map(quoted), to: &lines)
            appendIfPresent("      short-id: ", node.shortId.map(quoted), to: &lines)
        }
        appendTransportOptions(from: node, to: &lines)
        appendCommonTail(node, to: &lines)
        return lines
    }

    private static func renderAnyTLS(_ node: ServerNode) -> [String] {
        var lines = commonProxyLines(node, type: "anytls")
        lines.append("    password: \(quoted(node.password))")
        appendIfPresent("    sni: ", node.sni.map(quoted), to: &lines)
        appendIfPresent("    client-fingerprint: ", node.clientFingerprint, to: &lines)
        appendCommonTail(node, to: &lines)
        return lines
    }

    private static func commonProxyLines(_ node: ServerNode, type: String) -> [String] {
        [
            "  - name: \(quoted(node.name))",
            "    type: \(type)",
            "    server: \(quoted(node.host))",
            "    port: \(node.port)"
        ]
    }

    private static func appendTransportOptions(from node: ServerNode, to lines: inout [String]) {
        guard let serviceName = node.serviceName, !serviceName.isEmpty else { return }
        switch node.network?.lowercased() {
        case "grpc":
            lines.append("    grpc-opts:")
            lines.append("      grpc-service-name: \(quoted(serviceName))")
        case "ws":
            lines.append("    ws-opts:")
            lines.append("      path: \(quoted(serviceName))")
        default:
            break
        }
    }

    private static func appendCommonTail(_ node: ServerNode, to lines: inout [String]) {
        lines.append("    udp: true")
        if let skipCertVerify = node.skipCertVerify {
            lines.append("    skip-cert-verify: \(skipCertVerify)")
        }
    }

    private static func appendIfPresent(_ prefix: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append(prefix + value)
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func joined(_ lines: [String]) -> String {
        let text = lines.joined(separator: "\n")
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}
