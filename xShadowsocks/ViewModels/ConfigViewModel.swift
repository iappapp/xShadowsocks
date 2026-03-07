import Foundation

struct LocalConfigFileInfo: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let modifiedAt: Date
    let sizeInBytes: Int64

    var modifiedText: String {
        Self.dateFormatter.string(from: modifiedAt)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

@MainActor
final class ConfigViewModel: ObservableObject {
    @Published var importErrorMessage: String?
    @Published var localConfigFile: LocalConfigFileInfo?
    @Published var configOperationMessage: String?
    @Published var isImportingConfigFile = false

    private let isPreviewMode: Bool
    private let defaultConfigFileName = "default.conf"
    private let fileManager = FileManager.default

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
    }

    func onAppear() {
        guard !isPreviewMode else {
            if localConfigFile == nil {
                localConfigFile = LocalConfigFileInfo(
                    name: defaultConfigFileName,
                    modifiedAt: Date(),
                    sizeInBytes: Int64(defaultTemplate.utf8.count)
                )
            }
            return
        }
        ensureDefaultConfigFileIfNeeded()
        refreshLocalConfigFile()
    }

    func restoreDefaultConfigFile() {
        do {
            try writeConfigFile(contents: defaultTemplate)
            refreshLocalConfigFile()
            configOperationMessage = "已恢复默认配置"
            importErrorMessage = nil
        } catch {
            importErrorMessage = "恢复默认配置失败：\(error.localizedDescription)"
        }
    }

    func importConfigFile(from urlString: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            importErrorMessage = "链接无效，请输入完整的 http(s) 链接"
            return false
        }

        isImportingConfigFile = true
        importErrorMessage = nil
        defer { isImportingConfigFile = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw ConfigFileImportError.httpStatus(http.statusCode)
            }

            guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigFileImportError.invalidText
            }

            try writeConfigFile(contents: text)
            refreshLocalConfigFile()
            configOperationMessage = "导入成功，已更新 \(defaultConfigFileName)"
            return true
        } catch {
            importErrorMessage = (error as? ConfigFileImportError)?.localizedDescription ?? error.localizedDescription
            return false
        }
    }

    private func ensureDefaultConfigFileIfNeeded() {
        let fileURL = defaultConfigFileURL()
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        try? writeConfigFile(contents: defaultTemplate)
    }

    private func refreshLocalConfigFile() {
        let fileURL = defaultConfigFileURL()
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else {
            localConfigFile = nil
            return
        }

        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        localConfigFile = LocalConfigFileInfo(name: defaultConfigFileName, modifiedAt: modifiedAt, sizeInBytes: size)
    }

    private func writeConfigFile(contents: String) throws {
        let fileURL = defaultConfigFileURL()
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = contents.data(using: .utf8) else {
            throw NSError(domain: "ConfigViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "配置内容编码失败"])
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func defaultConfigFileURL() -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent("mihomo", isDirectory: true)
            .appendingPathComponent(defaultConfigFileName, isDirectory: false)
    }

    private var defaultTemplate: String {
        """
        port: 7890
        socks-port: 7891
        allow-lan: false
        mode: rule
        log-level: info
        external-controller: 127.0.0.1:9090

        dns:
          enable: true
          ipv6: true
          enhanced-mode: fake-ip
          nameserver:
            - https://1.1.1.1/dns-query
            - https://8.8.8.8/dns-query

        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        """
    }

}

extension ConfigViewModel {
    static func previewMock() -> ConfigViewModel {
        let viewModel = ConfigViewModel(isPreviewMode: true)
        return viewModel
    }

    static func previewEmpty() -> ConfigViewModel {
        ConfigViewModel(isPreviewMode: true)
    }
}

private enum ConfigFileImportError: LocalizedError {
    case invalidText
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidText:
            return "下载内容不是有效文本"
        case let .httpStatus(statusCode):
            return "下载失败，HTTP 状态码 \(statusCode)"
        }
    }
}
