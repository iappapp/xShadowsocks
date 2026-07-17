import Foundation

/// Shared path + helpers for the downloaded mihomo YAML (`default.conf`).
enum MihomoConfigFileStore {
    static let fileName = "default.conf"

    enum ProxyKind {
        case httpConnect
        case socks5
    }

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("mihomo", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static func save(_ yaml: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let normalized = normalizeForMihomoYAML(yaml)
        guard let data = normalized.data(using: .utf8) else {
            throw NSError(
                domain: "MihomoConfigFileStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "配置内容编码失败"]
            )
        }
        try data.write(to: fileURL, options: .atomic)
    }

    static func loadText() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Reads the actual local proxy endpoint from saved YAML.
    /// `mixed-port` and `port` support HTTP CONNECT; `socks-port` needs SOCKS5.
    static func readProxyEndpoint(defaultPort: Int = 7890) -> (port: Int, kind: ProxyKind) {
        guard let text = loadText() else { return (defaultPort, .httpConnect) }

        var mixed: Int?
        var http: Int?
        var socks: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            guard isTopLevelLine(rawLine) else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), let sep = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            guard let port = Int(value) else { continue }
            switch key {
            case "mixed-port":
                mixed = port
            case "port":
                http = port
            case "socks-port":
                socks = port
            default:
                break
            }
        }

        if let mixed {
            return (mixed, .httpConnect)
        }
        if let http {
            return (http, .httpConnect)
        }
        if let socks {
            return (socks, .socks5)
        }
        return (defaultPort, .httpConnect)
    }

    /// Reads mixed-port / port / socks-port from the saved YAML for status UI.
    static func readProxyPort(default defaultPort: Int = 7890) -> Int {
        readProxyEndpoint(defaultPort: defaultPort).port
    }

    private static func isTopLevelLine(_ line: String) -> Bool {
        !line.hasPrefix(" ") && !line.hasPrefix("\t")
    }

    /// Some subscription endpoints return YAML with tabs in indentation or a BOM.
    /// go-yaml rejects tabs as indentation, so normalize only whitespace syntax.
    static func normalizeForMihomoYAML(_ yaml: String) -> String {
        var text = yaml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
            var result = ""
            var isIndent = true
            for character in rawLine {
                if isIndent {
                    if character == "\t" {
                        result += "  "
                        continue
                    }
                    if character == " " {
                        result.append(character)
                        continue
                    }
                    isIndent = false
                }
                result.append(character)
            }
            return result
        }

        return lines.joined(separator: "\n")
    }
}
