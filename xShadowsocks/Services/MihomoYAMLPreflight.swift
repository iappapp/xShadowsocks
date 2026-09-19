import Foundation

/// Lightweight preflight checks for mihomo YAML before save / start.
/// Catches encoding, invisible/special characters, and basic structure issues
/// that commonly break go-yaml after iOS editing.
enum MihomoYAMLPreflight {
    enum Severity: Equatable {
        case error
        case warning
    }

    struct Issue: Equatable {
        let severity: Severity
        let line: Int? // 1-based; nil = whole document
        let message: String
    }

    struct Report: Equatable {
        let issues: [Issue]

        var errors: [Issue] { issues.filter { $0.severity == .error } }
        var warnings: [Issue] { issues.filter { $0.severity == .warning } }
        var isOK: Bool { errors.isEmpty }

        var summary: String {
            guard !issues.isEmpty else { return "YAML 检查通过" }
            let preview = issues.prefix(8).map { issue in
                let prefix = issue.severity == .error ? "[错误]" : "[警告]"
                if let line = issue.line {
                    return "\(prefix) 第 \(line) 行：\(issue.message)"
                }
                return "\(prefix) \(issue.message)"
            }.joined(separator: "\n")
            if issues.count > 8 {
                return preview + "\n…共 \(issues.count) 处问题"
            }
            return preview
        }
    }

    /// Validate raw editor text.
    static func check(_ yaml: String) -> Report {
        var issues: [Issue] = []

        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Report(issues: [Issue(severity: .error, line: nil, message: "配置内容为空")])
        }

        if yaml.contains("\0") {
            issues.append(Issue(severity: .error, line: nil, message: "包含空字符（\\0），编码可能已损坏"))
        }
        if yaml.data(using: .utf8) == nil {
            issues.append(Issue(severity: .error, line: nil, message: "无法按 UTF-8 编码，存在非法字符"))
        }

        if yaml.hasPrefix("\u{FEFF}") {
            issues.append(Issue(severity: .warning, line: 1, message: "文件开头有 BOM，保存时会自动去除"))
        }

        let lines = yaml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        var sawProxies = false
        var sawProxyProviders = false
        var sawTopLevelKey = false
        var specialCharCount = 0

        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1
            let line = String(raw)

            if line.contains("\u{2028}") || line.contains("\u{2029}") {
                specialCharCount += 1
                issues.append(Issue(
                    severity: .warning,
                    line: lineNumber,
                    message: "包含 Unicode 行分隔符"
                ))
            }

            for (offset, ch) in line.enumerated() {
                let column = offset + 1
                switch ch {
                case "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}":
                    specialCharCount += 1
                    issues.append(Issue(
                        severity: .warning,
                        line: lineNumber,
                        message: "第 \(column) 列有零宽字符"
                    ))
                case "\u{00A0}":
                    specialCharCount += 1
                    issues.append(Issue(
                        severity: .warning,
                        line: lineNumber,
                        message: "第 \(column) 列有不换行空格（NBSP）"
                    ))
                case "\u{3000}":
                    specialCharCount += 1
                    issues.append(Issue(
                        severity: .warning,
                        line: lineNumber,
                        message: "第 \(column) 列有全角空格"
                    ))
                case "\u{201C}", "\u{201D}", "\u{FF02}":
                    specialCharCount += 1
                    issues.append(Issue(
                        severity: .warning,
                        line: lineNumber,
                        message: "第 \(column) 列有弯引号/全角双引号"
                    ))
                case "\u{2018}", "\u{2019}", "\u{FF07}":
                    specialCharCount += 1
                    issues.append(Issue(
                        severity: .warning,
                        line: lineNumber,
                        message: "第 \(column) 列有弯引号/全角单引号"
                    ))
                default:
                    break
                }
            }

            if let indentInfo = leadingIndent(line) {
                if indentInfo.hasTab {
                    issues.append(Issue(
                        severity: .error,
                        line: lineNumber,
                        message: "缩进使用了 Tab，mihomo 要求空格缩进"
                    ))
                }
                if indentInfo.hasUnicodeSpace {
                    issues.append(Issue(
                        severity: .error,
                        line: lineNumber,
                        message: "缩进含特殊空格（全角/NBSP），会导致解析失败"
                    ))
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if !line.hasPrefix(" "), !line.hasPrefix("\t"),
               !line.hasPrefix("\u{00A0}"), !line.hasPrefix("\u{3000}"),
               trimmed.contains(":") {
                sawTopLevelKey = true
                let key = trimmed.split(separator: ":", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if key == "proxies" { sawProxies = true }
                if key == "proxy-providers" { sawProxyProviders = true }
            }
        }

        if !sawTopLevelKey {
            issues.append(Issue(
                severity: .error,
                line: nil,
                message: "未检测到顶层 YAML 键（如 mixed-port / proxies / rules）"
            ))
        } else if !sawProxies && !sawProxyProviders {
            issues.append(Issue(
                severity: .warning,
                line: nil,
                message: "未找到 proxies: 或 proxy-providers:"
            ))
        }

        if specialCharCount > 8 {
            // Collapse noisy per-character warnings into one summary + keep first few.
            let kept = issues.filter { $0.severity == .error }
            let sample = issues.filter { $0.severity == .warning }.prefix(3)
            issues = kept + sample + [
                Issue(
                    severity: .warning,
                    line: nil,
                    message: "另有 \(specialCharCount) 处特殊字符，保存时会尝试自动清理"
                )
            ]
        }

        var seen = Set<String>()
        let unique = issues.filter { issue in
            let key = "\(issue.severity)|\(issue.line.map(String.init) ?? "-")|\(issue.message)"
            return seen.insert(key).inserted
        }
        return Report(issues: unique)
    }

    /// Normalize then check — matches what will be written for mihomo.
    ///
    /// - Errors after normalize block save/start.
    /// - Special characters in the original become warnings (auto-cleaned).
    static func checkNormalized(_ yaml: String) -> (normalized: String, report: Report) {
        let original = check(yaml)
        let normalized = MihomoConfigFileStore.normalizeForMihomoYAML(yaml)
        let after = check(normalized)

        var merged: [Issue] = after.errors
        let autoCleanNotes = original.warnings.filter { issue in
            let msg = issue.message
            return msg.contains("零宽")
                || msg.contains("NBSP")
                || msg.contains("全角")
                || msg.contains("弯引号")
                || msg.contains("BOM")
                || msg.contains("行分隔符")
                || msg.contains("特殊字符")
        }
        if !autoCleanNotes.isEmpty {
            merged.append(Issue(
                severity: .warning,
                line: nil,
                message: "原文含特殊字符/非常规空格，已自动清理为标准 YAML 文本"
            ))
        }
        merged.append(contentsOf: after.warnings)

        return (normalized, Report(issues: merged))
    }

    // MARK: - Helpers

    private struct IndentInfo {
        let spaceCount: Int
        let hasTab: Bool
        let hasUnicodeSpace: Bool
    }

    private static func leadingIndent(_ line: String) -> IndentInfo? {
        guard !line.isEmpty else { return nil }
        var spaceCount = 0
        var hasTab = false
        var hasUnicodeSpace = false
        for ch in line {
            switch ch {
            case " ":
                spaceCount += 1
            case "\t":
                hasTab = true
            case "\u{00A0}", "\u{3000}", "\u{2000}", "\u{2001}", "\u{2002}",
                 "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}",
                 "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}":
                hasUnicodeSpace = true
                spaceCount += 1
            default:
                if spaceCount == 0 && !hasTab && !hasUnicodeSpace { return nil }
                return IndentInfo(spaceCount: spaceCount, hasTab: hasTab, hasUnicodeSpace: hasUnicodeSpace)
            }
        }
        return IndentInfo(spaceCount: spaceCount, hasTab: hasTab, hasUnicodeSpace: hasUnicodeSpace)
    }
}
