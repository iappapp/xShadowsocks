import Foundation

/// Reads mihomo's cumulative traffic totals over its RESTful API.
///
/// The core is started with `external-controller: 127.0.0.1:<port>` and a `secret`,
/// so the extension can ask it for `/connections`, whose snapshot carries
/// `uploadTotal`/`downloadTotal` — the byte counts mihomo has forwarded since it
/// started. That is the authoritative source: with the `system` tun stack the
/// packets never pass through Swift, so the extension cannot count them itself.
///
/// The listener is bound to loopback, so it stays inside the tunnel.
struct MihomoAPIClient {
    let port: Int
    let secret: String
    var timeout: TimeInterval = 4

    struct Totals {
        let upload: Int64
        let download: Int64
    }

    private struct ConnectionsResponse: Decodable {
        let uploadTotal: Int64?
        let downloadTotal: Int64?
    }

    func fetchTotals() async throws -> Totals {
        guard let url = URL(string: "http://127.0.0.1:\(port)/connections") else {
            throw APIError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ConnectionsResponse.self, from: data)
        return Totals(upload: decoded.uploadTotal ?? 0, download: decoded.downloadTotal ?? 0)
    }

    enum APIError: LocalizedError {
        case invalidEndpoint
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "无效的外部控制器地址"
            case .httpStatus(let status):
                return "外部控制器返回 HTTP \(status)"
            }
        }
    }
}
