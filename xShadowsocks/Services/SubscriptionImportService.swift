import Foundation

// MARK: - Models

struct SubscriptionImportResult {
    let sourceName: String
    let sourceURL: String
    let nodes: [ServerNode]
    /// Non-nil when the subscription payload was a full mihomo YAML config file.
    /// The caller should persist this to the local config file path.
    let rawYAMLConfig: String?
}

enum SubscriptionNodeImportError: LocalizedError {
    case invalidURL
    case invalidText
    case requiresYAMLConfig
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接无效，请输入完整的 http(s) 链接"
        case .invalidText:
            return "下载内容不是有效文本"
        case .requiresYAMLConfig:
            return "需要完整的 mihomo/Clash YAML 配置文件（含 proxies:）"
        case let .httpStatus(statusCode):
            return "下载失败，HTTP 状态码 \(statusCode)"
        }
    }
}

// MARK: - Service (HTTP + orchestration only)

struct SubscriptionNodeImportService {

    /// Requests with ClashX UA usually return full Clash/Mihomo YAML.
    private static let clashSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": "ClashX/1.0 CFNetwork Safari"
        ]
        return URLSession(configuration: config)
    }()

    /// Requests without a Clash UA usually return Base64 encoded proxy nodes.
    private static let nodeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": "PostmanRuntime/7.54.0"
        ]
        return URLSession(configuration: config)
    }()

    func importNodes(from urlString: String, configName: String?) async throws -> SubscriptionImportResult {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            throw SubscriptionNodeImportError.invalidURL
        }

        let yamlResult = SubscriptionContentParser.parse(
            try await fetchPayload(from: url, session: Self.clashSession)
        )
        guard let rawYAML = yamlResult.rawYAML else {
            throw SubscriptionNodeImportError.requiresYAMLConfig
        }

        // The downloaded YAML is stored as-is; the node list is only what the UI shows.
        let displayNodes = await nodeListNodes(from: url) ?? yamlResult.nodes

        return SubscriptionImportResult(
            sourceName: resolvedSourceName(url: url, configName: configName),
            sourceURL: trimmedURL,
            nodes: displayNodes,
            rawYAMLConfig: rawYAML
        )
    }

    /// Nodes from the generic-UA request, or nil when it fails or carries none —
    /// subscriptions that gate on User-Agent answer that second request with a plain
    /// node list, which labels the Home tab better than the config's own entries.
    private func nodeListNodes(from url: URL) async -> [ServerNode]? {
        guard let payload = try? await fetchPayload(from: url, session: Self.nodeSession) else { return nil }
        let nodes = SubscriptionContentParser.parse(payload).nodes
        return nodes.isEmpty ? nil : nodes
    }

    private func fetchPayload(from url: URL, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(from: url)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SubscriptionNodeImportError.httpStatus(http.statusCode)
        }

        // Try UTF-8 first; fall back to ISO-8859-1 for some legacy servers.
        guard let payload = String(data: data, encoding: .utf8)
                         ?? String(data: data, encoding: .isoLatin1) else {
            throw SubscriptionNodeImportError.invalidText
        }
        return payload
    }

    private func resolvedSourceName(url: URL, configName: String?) -> String {
        if let configName,
           !configName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        let name = url.lastPathComponent
        return name.isEmpty ? "配置源" : name
    }
}
