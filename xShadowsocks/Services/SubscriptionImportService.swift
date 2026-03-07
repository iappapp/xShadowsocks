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
    case noNodesFound
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接无效，请输入完整的 http(s) 链接"
        case .invalidText:
            return "下载内容不是有效文本"
        case .noNodesFound:
            return "未识别到可用节点（已尝试 YAML、trojan URI、Base64 解码后再解析）"
        case let .httpStatus(statusCode):
            return "下载失败，HTTP 状态码 \(statusCode)"
        }
    }
}

// MARK: - Service (HTTP + orchestration only)

struct SubscriptionNodeImportService {

    /// A dedicated session with a 30-second timeout and a realistic User-Agent.
    /// Subscription servers sometimes reject requests without a recognisable UA.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": "ClashX/1.0 CFNetwork Safari"
        ]
        return URLSession(configuration: config)
    }()

    func importNodes(from urlString: String, configName: String?) async throws -> SubscriptionImportResult {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            throw SubscriptionNodeImportError.invalidURL
        }

        let (data, response) = try await Self.session.data(from: url)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SubscriptionNodeImportError.httpStatus(http.statusCode)
        }

        // Try UTF-8 first; fall back to ISO-8859-1 for some legacy servers
        guard let payload = String(data: data, encoding: .utf8)
                         ?? String(data: data, encoding: .isoLatin1) else {
            throw SubscriptionNodeImportError.invalidText
        }

        let parseResult = SubscriptionContentParser.parse(payload)
        guard !parseResult.nodes.isEmpty else {
            throw SubscriptionNodeImportError.noNodesFound
        }

        let resolvedName = resolvedSourceName(url: url, configName: configName)
        return SubscriptionImportResult(
            sourceName: resolvedName,
            sourceURL: trimmedURL,
            nodes: parseResult.nodes,
            rawYAMLConfig: parseResult.rawYAML
        )
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
