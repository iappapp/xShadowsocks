import Foundation



@MainActor
final class ConfigViewModel: ObservableObject {
    @Published var importErrorMessage: String?
    @Published var isImportingConfigFile = false
    @Published var localConfigFile: LocalConfigFileModel?
    @Published var configSources: [ConfigSourceModel] = []

    private let isPreviewMode: Bool
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
                localConfigFile = LocalConfigFileModel(
                    name: MihomoConfigFileStore.defaultTemplateFileName,
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
            let fileName = MihomoConfigFileStore.fileName(forConfigName: trimmedName)
            try MihomoConfigFileStore.save(mergedYAML, as: fileName)
            MihomoConfigFileStore.activeFileName = fileName

            let source = ConfigSourceModel(
                name: result.sourceName,
                url: result.sourceURL,
                nodes: result.nodes,
                updatedAt: Date(),
                yamlConfig: mergedYAML,
                fileName: fileName
            )
            // Append to the list of configs; if a config with the same filename
            // already exists (re-import of the same name), replace it in place
            // instead of wiping the whole list.
            if let existingIndex = configSources.firstIndex(where: { $0.fileName == fileName }) {
                configSources[existingIndex] = source
            } else {
                configSources.append(source)
            }
            persistSourceState()
            refreshLocalConfigFile()

            return true
        } catch {
            importErrorMessage = (error as? SubscriptionNodeImportError)?.localizedDescription ?? error.localizedDescription
            return false
        }
    }

    func deleteSource(_ source: ConfigSourceModel) {
        guard let index = configSources.firstIndex(where: { $0.id == source.id }) else { return }
        configSources.remove(at: index)
        persistSourceState()
    }

    // MARK: - Persistence

    func loadConfigSourcesFromStore() {
        // The subscription URL is owned by the saved ConfigSourceModel (set at
        // import time). Never synthesize a placeholder URL here — if there is
        // no saved source, show nothing.
        if let saved = store.load([ConfigSourceModel].self, forKey: configSourcesKey), !saved.isEmpty {
            configSources = saved
            return
        }
        configSources = []
    }

    private func persistSourceState() {
        try? store.save(configSources, forKey: configSourcesKey)
    }

    // MARK: - File helpers

    private func ensureDefaultConfigFileIfNeeded() {
        let activeFileName = MihomoConfigFileStore.activeFileName
        let url = MihomoConfigFileStore.fileURL(forFileName: activeFileName)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        // Active file missing: write the default template to default.yaml and activate it.
        let templateName = MihomoConfigFileStore.defaultTemplateFileName
        try? writeConfigFile(contents: defaultTemplate, as: templateName)
        MihomoConfigFileStore.activeFileName = templateName
    }

    private func refreshLocalConfigFile() {
        let activeFileName = MihomoConfigFileStore.activeFileName
        let url = MihomoConfigFileStore.fileURL(forFileName: activeFileName)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            localConfigFile = nil
            return
        }

        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        localConfigFile = LocalConfigFileModel(name: activeFileName, modifiedAt: modifiedAt, sizeInBytes: size)
    }

    private func writeConfigFile(contents: String, as fileName: String) throws {
        try MihomoConfigFileStore.save(contents, as: fileName)
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
        let nodes: [ServerNode] = [
            .init(name: "🇭🇰 香港 01", host: "hk1.example.com", port: 443,
                  password: "demo-pass", nodeType: "vless", sni: "cdn.example.com", latency: 72),
            .init(name: "🇯🇵 日本 01", host: "jp1.example.com", port: 443,
                  password: "demo-pass", nodeType: "vless", sni: "cdn.example.com", latency: 124),
            .init(name: "🇺🇸 美国 01", host: "us1.example.com", port: 443,
                  password: "demo-pass", nodeType: "anytls", sni: "cdn.example.com", latency: -1)
        ]
        let sampleYAML = """
        port: 7890
        socks-port: 7891
        mode: rule
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        """
        viewModel.configSources = [
            ConfigSourceModel(
                name: "XFLTD 订阅",
                url: "https://api.xfltd.net/import",
                nodes: nodes,
                updatedAt: Date(),
                yamlConfig: sampleYAML,
                fileName: "XFLTD.yaml"
            )
        ]
        return viewModel
    }

    static func previewEmpty() -> ConfigViewModel {
        ConfigViewModel(isPreviewMode: true)
    }
}
