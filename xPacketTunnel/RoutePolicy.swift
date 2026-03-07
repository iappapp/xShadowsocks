import Foundation
import Network

enum RouteRuleType: String {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCidr = "IP-CIDR"
    case ipCidr6 = "IP-CIDR6"
    case geoIP = "GEOIP"
    case match = "MATCH"
}

struct RouteRule {
    let type: RouteRuleType
    let value: String?
    let action: String
    let noResolve: Bool
    let raw: String
}

struct RouteDecision {
    let action: String
    let matchedRule: String?
}

protocol GeoIPResolving {
    func countryCode(for ip: String) -> String?
}

struct BasicGeoIPResolver: GeoIPResolving {
    func countryCode(for ip: String) -> String? {
        if CIDRMatcher.containsIPv4(ip: ip, cidr: "10.0.0.0/8")
            || CIDRMatcher.containsIPv4(ip: ip, cidr: "172.16.0.0/12")
            || CIDRMatcher.containsIPv4(ip: ip, cidr: "192.168.0.0/16")
            || CIDRMatcher.containsIPv4(ip: ip, cidr: "127.0.0.0/8") {
            return "CN"
        }
        return nil
    }
}

struct ClashRoutePolicy {
    private(set) var rules: [RouteRule] = []
    private let geoIPResolver: GeoIPResolving

    init(rulesText: String, geoIPResolver: GeoIPResolving = BasicGeoIPResolver()) {
        self.geoIPResolver = geoIPResolver
        self.rules = Self.parseRules(from: rulesText)
    }

    init(ruleLines: [String], geoIPResolver: GeoIPResolving = BasicGeoIPResolver()) {
        self.geoIPResolver = geoIPResolver
        self.rules = Self.parseRules(from: ruleLines)
    }

    func decide(domain: String?, ip: String?) -> RouteDecision {
        let normalizedDomain = domain?.lowercased()

        for rule in rules {
            if matches(rule: rule, domain: normalizedDomain, ip: ip) {
                return RouteDecision(action: rule.action, matchedRule: rule.raw)
            }
        }

        return RouteDecision(action: "DIRECT", matchedRule: nil)
    }

    private func matches(rule: RouteRule, domain: String?, ip: String?) -> Bool {
        switch rule.type {
        case .domain:
            guard let domain, let value = rule.value?.lowercased() else { return false }
            return domain == value

        case .domainSuffix:
            guard let domain, let value = rule.value?.lowercased() else { return false }
            return domain == value || domain.hasSuffix("." + value)

        case .domainKeyword:
            guard let domain, let value = rule.value?.lowercased() else { return false }
            return domain.contains(value)

        case .ipCidr:
            guard let ip, let value = rule.value else { return false }
            return CIDRMatcher.containsIPv4(ip: ip, cidr: value)

        case .ipCidr6:
            guard let ip, let value = rule.value else { return false }
            return CIDRMatcher.containsIPv6(ip: ip, cidr: value)

        case .geoIP:
            guard let ip, let value = rule.value?.uppercased() else { return false }
            return geoIPResolver.countryCode(for: ip)?.uppercased() == value

        case .match:
            return true
        }
    }

    private static func parseRules(from text: String) -> [RouteRule] {
        let lines = text.components(separatedBy: .newlines)
        return parseRules(from: lines)
    }

    private static func parseRules(from lines: [String]) -> [RouteRule] {
        lines.compactMap { rawLine in
            guard let content = extractRuleContent(from: rawLine) else {
                return nil
            }
            return parseRule(content)
        }
    }

    private static func extractRuleContent(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("- '") && trimmed.hasSuffix("'") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 3)
            let end = trimmed.index(before: trimmed.endIndex)
            return String(trimmed[start..<end])
        }

        if trimmed.hasPrefix("-") {
            return trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func parseRule(_ content: String) -> RouteRule? {
        let fields = content.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let first = fields.first,
              let type = RouteRuleType(rawValue: first) else {
            return nil
        }

        switch type {
        case .match:
            guard fields.count >= 2 else { return nil }
            return RouteRule(type: type, value: nil, action: fields[1], noResolve: false, raw: content)

        default:
            guard fields.count >= 3 else { return nil }
            let noResolve = fields.dropFirst(3).contains { $0.lowercased() == "no-resolve" }
            return RouteRule(type: type, value: fields[1], action: fields[2], noResolve: noResolve, raw: content)
        }
    }
}

enum CIDRMatcher {
    static func containsIPv4(ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), (0...32).contains(prefix),
              let ipValue = ipv4ToUInt32(ip),
              let networkValue = ipv4ToUInt32(String(parts[0])) else {
            return false
        }

        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - UInt32(prefix)))
        return (ipValue & mask) == (networkValue & mask)
    }

    static func containsIPv6(ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), (0...128).contains(prefix),
              let ipBytes = ipv6ToBytes(ip),
              let networkBytes = ipv6ToBytes(String(parts[0])) else {
            return false
        }

        let fullBytes = prefix / 8
        let remainBits = prefix % 8

        if fullBytes > 0 && ipBytes.prefix(fullBytes) != networkBytes.prefix(fullBytes) {
            return false
        }

        if remainBits == 0 {
            return true
        }

        let mask = UInt8(0xFF << (8 - remainBits))
        return (ipBytes[fullBytes] & mask) == (networkBytes[fullBytes] & mask)
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let segments = ip.split(separator: ".")
        guard segments.count == 4 else { return nil }

        var result: UInt32 = 0
        for segment in segments {
            guard let octet = UInt8(segment) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }

    private static func ipv6ToBytes(_ ip: String) -> [UInt8]? {
        guard let ipv6 = IPv6Address(ip) else { return nil }
        return Array(ipv6.rawValue)
    }
}
