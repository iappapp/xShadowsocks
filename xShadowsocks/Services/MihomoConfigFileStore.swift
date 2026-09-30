import Foundation

/// Shared path + helpers for the mihomo YAML config files the user imported.
///
/// Files live in the App Group working directory (see `MihomoSharedPaths`) because
/// the packet-tunnel extension is the process that hands them to the core. The
/// active filename is persisted in `AppGroupStore` so the app, the extension and
/// the browser proxy-port reader all agree on which file is in use.
///
/// Note this is *not* the file the core is started with: the extension derives
/// `runtime.yaml` from it at start time. See `MihomoRuntimeConfigBuilder`.
enum MihomoConfigFileStore {
    /// Filename used for the built-in default template (restore-defaults).
    static let defaultTemplateFileName = "default.yaml"

    private static let store = AppGroupStore.shared

    /// The currently active config filename (persisted).
    static var activeFileName: String {
        get {
            let saved = store.loadString(forKey: store.activeConfigFileNameKey, default: "")
            if saved.isEmpty {
                return defaultTemplateFileName
            }
            return saved
        }
        set {
            store.saveValue(newValue, forKey: store.activeConfigFileNameKey)
        }
    }

    static var directoryURL: URL {
        MihomoSharedPaths.directoryURL
    }

    /// URL of the currently active config file.
    static var fileURL: URL {
        fileURL(forFileName: activeFileName)
    }

    static func fileURL(forFileName fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Builds a safe filename `<sanitized name>.yaml` for a config display name.
    static func fileName(forConfigName name: String) -> String {
        "\(sanitizeFileName(name)).yaml"
    }

    /// Replaces characters that are unsafe in filenames with `_`.
    static func sanitizeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden: Set<Character> = ["/", "\\", ":", "?", "*", "\"", "<", ">", "|", "."]
        var result = ""
        for ch in trimmed {
            if forbidden.contains(ch) {
                result.append("_")
            } else {
                result.append(ch)
            }
        }
        if result.isEmpty { result = "config" }
        return result
    }

    // MARK: - Save / load (active file)

    static func save(_ yaml: String) throws {
        try save(yaml, as: activeFileName)
    }

    static func save(_ yaml: String, as fileName: String) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let normalized = normalizeForMihomoYAML(yaml)
        guard let data = normalized.data(using: .utf8) else {
            throw NSError(
                domain: "MihomoConfigFileStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "配置内容编码失败"]
            )
        }
        try data.write(to: fileURL(forFileName: fileName), options: .atomic)
    }

    static func loadText() -> String? {
        loadText(forFileName: activeFileName)
    }

    static func loadText(forFileName fileName: String) -> String? {
        guard let text = try? String(contentsOf: fileURL(forFileName: fileName), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func fileExists(forFileName fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forFileName: fileName).path)
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
