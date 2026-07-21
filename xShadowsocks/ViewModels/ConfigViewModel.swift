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
    @Published var configOperationMessage: String?
    @Published var isImportingConfigFile = false
    @Published var localConfigFile: LocalConfigFileInfo?
    @Published var configSources: [ProxyConfigSource] = []

    private let isPreviewMode: Bool
    private let defaultConfigFileName = "default.conf"
    private let fileManager = FileManager.default
    private let store = AppGroupStore.shared
    private let configSourcesKey = "config_sources"
    private let subscriptionImportService = SubscriptionNodeImportService()

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
        loadConfigSourcesFromStore()
    }

    // MARK: - Subscription import (dual-UA: ClashX YAML + generic UA node list)

    func importNodes(from urlString: String, configName: String?) async -> Bool {
        isImportingConfigFile = true
        importErrorMessage = nil
        configOperationMessage = nil
        defer { isImportingConfigFile = false }

        let trimmedName = (configName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            importErrorMessage = "请输入配置名称"
            return false
        }

        do {
            let result = try await subscriptionImportService.importNodes(from: urlString, configName: trimmedName)

            guard let yaml = result.rawYAMLConfig else {
                throw SubscriptionNodeImportError.requiresYAMLConfig
            }

            // Merge parsed proxy nodes into the downloaded YAML, then persist as runtime config.
            let mergedYAML = MihomoYAMLProxyInjector.injecting(result.nodes, into: yaml)
            try MihomoConfigFileStore.save(mergedYAML)

            let source = ProxyConfigSource(
                name: result.sourceName,
                url: result.sourceURL,
                nodes: result.nodes,
                updatedAt: Date(),
                yamlConfig: mergedYAML
            )
            configSources = [source]
            persistSourceState()
            refreshLocalConfigFile()

            configOperationMessage = "导入成功，已更新 \(defaultConfigFileName)"
            return true
        } catch {
            importErrorMessage = (error as? SubscriptionNodeImportError)?.localizedDescription ?? error.localizedDescription
            return false
        }
    }

    func deleteSource(_ source: ProxyConfigSource) {
        guard let index = configSources.firstIndex(where: { $0.id == source.id }) else { return }
        configSources.remove(at: index)
        persistSourceState()
    }

    // MARK: - Default config

    func restoreDefaultConfigFile() {
        do {
            try writeConfigFile(contents: defaultTemplate)
            configSources = []
            persistSourceState()
            refreshLocalConfigFile()
            configOperationMessage = "已恢复默认配置"
            importErrorMessage = nil
        } catch {
            importErrorMessage = "恢复默认配置失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    func loadConfigSourcesFromStore() {
        if let saved = store.load([ProxyConfigSource].self, forKey: configSourcesKey), !saved.isEmpty {
            configSources = saved
            return
        }
        // Fall back: synthesize a source from the saved default.conf if it has proxies.
        if let yaml = MihomoConfigFileStore.loadText() {
            let parsedNodes = MihomoYAMLConfigParser.parseProxies(from: yaml)
            if !parsedNodes.isEmpty {
                let source = ProxyConfigSource(
                    name: "本地配置",
                    url: "local://default.conf",
                    nodes: parsedNodes,
                    updatedAt: Date(),
                    yamlConfig: yaml
                )
                configSources = [source]
            } else {
                configSources = []
            }
        } else {
            configSources = []
        }
    }

    private func persistSourceState() {
        try? store.save(configSources, forKey: configSourcesKey)
    }

    // MARK: - File helpers

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
        try MihomoConfigFileStore.save(contents)
    }

    private func defaultConfigFileURL() -> URL {
        MihomoConfigFileStore.fileURL
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
