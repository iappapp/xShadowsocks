import Foundation

/// Turns the user's subscription YAML into the config the core is actually started
/// with.
///
/// The core is never handed the user's file directly, for three reasons:
///
///   * In tunnel mode the tun inbound needs `file-descriptor`, whose value only exists
///     at runtime.
///   * The host owns the interface address and routes (`NEPacketTunnelNetworkSettings`
///     in tunnel mode, nothing at all in loopback mode), so mihomo must not try to
///     configure them itself.
///   * Tunnel mode must not leave DNS disabled: the extension advertises the tun
///     address as the system resolver, so a config without DNS resolves nothing.
///
/// Everything else — proxies, proxy-groups, rules, rule-providers, DNS servers,
/// sniffer, etc. — is copied through untouched.
public enum MihomoRuntimeConfigBuilder {

    /// How the core is hosted, which is what decides the tun section and how much of
    /// the config the host has to own.
    public enum HostMode: Equatable, Sendable {
        /// Inside the packet-tunnel extension, pumping packets through the utun socket
        /// the system created for us.
        case tunnel(fileDescriptor: Int32)
        /// Inside the app itself, listening on loopback for apps that are told to use
        /// it (the in-app browser, or a manual proxy configuration). No privileged
        /// entitlement needed, which is what makes it usable on a free account.
        case loopback
    }

    /// Interface parameters derived from the user's config, used to build the
    /// `NEPacketTunnelNetworkSettings` that must line up with what mihomo expects.
    ///
    /// mihomo takes the *address* of `dns.fake-ip-range` (not the network address) as
    /// the tun address, widened to a /30, and reserves the next address for the DNS
    /// listener it hijacks. The extension assigns that address to the utun interface,
    /// so the connections mihomo originates to its own address land back on the tun
    /// and are matched to their original session.
    public struct TunnelSettings: Equatable, Sendable {
        public let interfaceAddress: String
        public let prefixLength: Int
        public let subnetMask: String
        public let dnsServers: [String]
        public let mtu: Int

        public var interfaceCIDR: String { "\(interfaceAddress)/\(prefixLength)" }
    }

    /// mihomo's own default when the config has no `dns.fake-ip-range`.
    public static let defaultFakeIPRange = "198.18.0.1/16"
    /// Bumped from mihomo's 9000 default: the extent is what the core sizes its read
    /// buffers from, and the interface itself is set to `mtu` by the extension.
    public static let interfaceMTU = 1500
    private static let tunPrefixLength = 30

    // MARK: - Tunnel settings

    public static func tunnelSettings(fromUserYAML yaml: String) -> TunnelSettings {
        let address = normalizedTunAddress(fromFakeIPRange: fakeIPRange(in: yaml) ?? defaultFakeIPRange)

        let next = incrementIPv4(address) ?? "198.18.0.2"
        let afterNext = incrementIPv4(next) ?? "198.18.0.3"

        return TunnelSettings(
            interfaceAddress: address,
            prefixLength: tunPrefixLength,
            subnetMask: mask(forPrefixLength: tunPrefixLength),
            // mihomo hijacks DNS sent to the tun address and to the address after it
            // (`tun.dns-hijack` covers the rest), so both are advertised to the system.
            dnsServers: [next, afterNext],
            mtu: interfaceMTU
        )
    }

    /// mihomo widens `dns.fake-ip-range` to a /30 and uses its address verbatim, so the
    /// interface address is whatever the config names — `198.18.0.1` by default.
    static func normalizedTunAddress(fromFakeIPRange range: String) -> String {
        let address = range.split(separator: "/").first.map(String.init) ?? ""
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return "198.18.0.1" }
        return octets.map(String.init).joined(separator: ".")
    }

    // MARK: - Runtime config

    /// The three modes mihomo itself understands. The app's `RouteMode` maps onto
    /// these; the config file's own mode is overridden either way.
    public enum RoutingMode: String, Sendable {
        case rule
        case global
        case direct

        var mihomoValue: String { rawValue }

        /// Maps the persisted `RouteMode` raw value onto a mihomo mode. `RouteMode`'s
        /// raw values are display strings, which is why this cannot be a `Codable`
        /// round trip.
        static func resolved(fromPersistedValue value: String) -> RoutingMode {
            switch value {
            case "代理", "proxy": return .global
            case "直连", "direct": return .direct
            default: return .rule      // 配置 / 场景 / anything unknown
            }
        }
    }

    /// Builds the YAML the core is started with.
    ///
    /// Forced top-level keys: `mixed-port`, `socks-port`, `allow-lan`, `bind-address`,
    /// `mode`, `log-level`, `ipv6`, `external-controller`/`secret`, and `tun`. In
    /// tunnel mode a `dns:` block is also guaranteed to exist (and to be enabled),
    /// since a tunnel with no resolver cannot resolve anything; its servers, `fallback`
    /// and `fake-ip-filter` are preserved. In loopback mode the user's `dns.enable` is
    /// left alone — the device's own resolver is still there as a fallback.
    public static func runtimeConfig(
        userYAML: String,
        mode: HostMode,
        mixedPort: Int,
        allowLan: Bool,
        ipv6Enabled: Bool,
        routingMode: RoutingMode,
        externalControllerPort: Int,
        externalControllerSecret: String
    ) -> String {
        var lines = userYAML
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // Drop the blocks we own. Existing tun/external-controller settings come from
        // the subscription and cannot be honoured by either host mode.
        let ownedKeys: Set<String> = [
            "tun", "mixed-port", "port", "socks-port", "allow-lan", "bind-address",
            "mode", "log-level", "ipv6", "external-controller", "external-controller-tls",
            "external-controller-unix", "external-controller-pipe", "secret"
        ]
        lines = removingTopLevelSections(ownedKeys, from: lines)
        if case .tunnel = mode {
            lines = forcingDNSSection(in: lines)
        }

        var header = [
            "# Generated by xShadowsocks — do not edit; the app rewrites this file.",
            "mixed-port: \(mixedPort)",
            "socks-port: \(mixedPort + 1)",
            "allow-lan: \(allowLan)",
            "bind-address: 127.0.0.1",
            "mode: \(routingMode.mihomoValue)",
            "log-level: warning",
            "ipv6: \(ipv6Enabled)",
            "external-controller: 127.0.0.1:\(externalControllerPort)",
            "secret: \"\(escapedYAMLString(externalControllerSecret))\"",
            ""
        ]
        header.append(contentsOf: tunSection(for: mode, mixedPort: mixedPort))
        header.append("")

        let body = trimmingTrailingBlankLines(lines)
        return (header + body).joined(separator: "\n") + "\n"
    }

    private static func tunSection(for mode: HostMode, mixedPort: Int) -> [String] {
        switch mode {
        case .tunnel(let fileDescriptor):
            return [
                "tun:",
                "  enable: true",
                // The extension owns the address, the MTU and the routes; mihomo only
                // pumps packets through this descriptor.
                "  file-descriptor: \(fileDescriptor)",
                "  stack: system",
                "  auto-route: false",
                "  auto-detect-interface: false",
                "  mtu: \(interfaceMTU)",
                "  recvmsgx: true",
                "  dns-hijack:",
                "    - any:53"
            ]

        case .loopback:
            // No tun at all: the core only serves its loopback proxy ports. Everything
            // that reaches those ports is already addressed by the client, so there is
            // nothing for the tun inbound to do — and creating a utun would need the
            // Network Extension entitlement this mode exists to avoid.
            return [
                "tun:",
                "  enable: false"
            ]
        }
    }

    // MARK: - DNS plumbing

    private static func forcingDNSSection(in lines: [String]) -> [String] {
        guard let range = topLevelSectionRange(named: "dns", in: lines) else {
            var updated = lines
            let index = firstTopLevelSectionIndex(in: updated) ?? updated.count
            let block = [
                "dns:",
                "  enable: true",
                "  ipv6: false",
                "  enhanced-mode: fake-ip",
                "  fake-ip-range: \(defaultFakeIPRange)",
                "  default-nameserver:",
                "    - 223.5.5.5",
                "    - 1.1.1.1",
                "  nameserver:",
                "    - 223.5.5.5",
                "    - 119.29.29.29",
                ""
            ]
            updated.insert(contentsOf: block, at: index)
            return updated
        }

        // Rebuild the block's direct entries, replacing `enable` in place.
        let header = lines[range.lowerBound]
        let body = Array(lines[range].dropFirst())
        let (entries, trailing) = directEntries(in: body)

        var rebuilt: [String] = [header]
        rebuilt.append("  enable: true")
        rebuilt.append(contentsOf: entries.filter { $0.key != "enable" }.flatMap(\.lines))
        rebuilt.append(contentsOf: trailing)

        var updated = lines
        updated.replaceSubrange(range, with: rebuilt)
        return updated
    }

    /// Splits a section body into its direct children (indent level 2 for a 2-space
    /// document body) and any trailing blank lines, so nested blocks stay attached to
    /// the entry that owns them.
    private static func directEntries(in body: [String]) -> (entries: [(key: String, lines: [String])], trailing: [String]) {
        var entries: [(key: String, lines: [String])] = []
        var trailing: [String] = []

        for line in body {
            let indent = leadingSpaceCount(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if entries.isEmpty { trailing.append(line) } else { entries[entries.count - 1].lines.append(line) }
                continue
            }
            if indent == 0 {
                // A nested value at the document level belongs to the previous entry.
                if !entries.isEmpty { entries[entries.count - 1].lines.append(line) } else { trailing.append(line) }
                continue
            }
            if indent == 2, let key = keyName(of: trimmed) {
                entries.append((key, [line]))
            } else if !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
            } else {
                trailing.append(line)
            }
        }

        return (entries, trailing)
    }

    // MARK: - Section helpers

    private static func removingTopLevelSections(_ keys: Set<String>, from lines: [String]) -> [String] {
        var updated = lines
        // Walk backwards so earlier ranges stay valid as we delete.
        var index = updated.count - 1
        while index >= 0 {
            guard let key = topLevelKey(of: updated[index]) else {
                index -= 1
                continue
            }
            guard keys.contains(key) else {
                index -= 1
                continue
            }
            let start = index
            var end = start + 1
            while end < updated.count, topLevelKey(of: updated[end]) == nil {
                end += 1
            }
            // Keep blank lines that separate sections.
            var trimmedEnd = end
            while trimmedEnd > start + 1, updated[trimmedEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                trimmedEnd -= 1
            }
            updated.removeSubrange(start..<trimmedEnd)
            index = start - 1
        }
        return updated
    }

    private static func topLevelSectionRange(named name: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { topLevelKey(of: $0) == name }) else { return nil }
        var end = start + 1
        while end < lines.count, topLevelKey(of: lines[end]) == nil {
            end += 1
        }
        return start..<end
    }

    private static func firstTopLevelSectionIndex(in lines: [String]) -> Int? {
        lines.firstIndex { topLevelKey(of: $0) != nil }
    }

    /// The key of a top-level mapping line, or nil for nested/blank/comment lines.
    private static func topLevelKey(of line: String) -> String? {
        guard !line.isEmpty, line.first != " ", line.first != "\t", line.first != "#" else { return nil }
        return keyName(of: line.trimmingCharacters(in: .whitespaces))
    }

    private static func keyName(of trimmed: String) -> String? {
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<separator])
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        return key
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else { break }
        }
        return count
    }

    private static func trimmingTrailingBlankLines(_ lines: [String]) -> [String] {
        var result = lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func escapedYAMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Address helpers

    private static func fakeIPRange(in yaml: String) -> String? {
        for rawLine in yaml.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("fake-ip-range:") else { continue }
            let value = trimmed.dropFirst("fake-ip-range:".count)
                .trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !unquoted.isEmpty { return unquoted }
        }
        return nil
    }

    private static func ipv4Value(_ octets: [UInt8]) -> UInt32? {
        guard octets.count == 4 else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func formatted(_ value: UInt32) -> String {
        [
            String((value >> 24) & 0xFF),
            String((value >> 16) & 0xFF),
            String((value >> 8) & 0xFF),
            String(value & 0xFF)
        ].joined(separator: ".")
    }

    static func incrementIPv4(_ address: String) -> String? {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, let value = ipv4Value(octets), value < UInt32.max else { return nil }
        return formatted(value + 1)
    }

    static func mask(forPrefixLength prefix: Int) -> String {
        guard prefix > 0 else { return "0.0.0.0" }
        guard prefix < 32 else { return "255.255.255.255" }
        let value = ~UInt32(0) << UInt32(32 - prefix)
        return formatted(value)
    }
}
