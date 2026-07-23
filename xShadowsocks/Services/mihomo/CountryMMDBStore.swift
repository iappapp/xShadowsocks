import Foundation
import os

/// Owns the `Country.mmdb` GeoIP database lifecycle for the mihomo runtime.
///
/// Responsibilities (single, cohesive concern):
///   1. Ensure the mmdb file is present in a given working directory.
///   2. Prefer copying a bundled `Country.mmdb` (offline, instant).
///   3. Fall back to downloading the latest release from the upstream CDN.
///
/// Extracted from `MihomoRuntimeManager` so the runtime manager stays focused
/// on start/reload/stop orchestration.
final class CountryMMDBStore {
    static let fileName = "Country.mmdb"

    /// Upstream release asset; kept here so the URL lives next to the download
    /// code that consumes it.
    private static let downloadURL = URL(
        string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
    )!

    private static let logger = Logger(
        subsystem: "com.github.iappapp.xShadowsocks",
        category: "CountryMMDBStore"
    )

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Guarantees `Country.mmdb` exists in `directoryURL` and returns its file URL.
    /// Order of resolution: existing file → bundled copy → remote download.
    func ensureMMDB(in directoryURL: URL) async throws -> URL {
        try ensureDirectoryIfNeeded(directoryURL)
        let destinationURL = directoryURL.appendingPathComponent(Self.fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            Self.logger.info("mmdb already present at \(destinationURL.path, privacy: .public)")
            return destinationURL
        }

        if let bundledURL = Bundle.main.url(forResource: "Country", withExtension: "mmdb") {
            do {
                try fileManager.copyItem(at: bundledURL, to: destinationURL)
                Self.logger.info("mmdb copied from bundle")
                return destinationURL
            } catch {
                    Self.logger.error("bundle copy failed: \(error.localizedDescription, privacy: .public)")
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try? fileManager.removeItem(at: destinationURL)
                    }
                // Fall through to download.
            }
        }

        return try await download(into: directoryURL)
    }

    /// Downloads `Country.mmdb` into `directoryURL` and returns its file URL.
    func download(into directoryURL: URL) async throws -> URL {
        try ensureDirectoryIfNeeded(directoryURL)
        let destinationURL = directoryURL.appendingPathComponent(Self.fileName)

        Self.logger.info("downloading mmdb from \(Self.downloadURL.absoluteString, privacy: .public)")
        var request = URLRequest(url: Self.downloadURL)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "CountryMMDBStore",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "下载 Country.mmdb 失败，状态码: \(http.statusCode)"]
            )
        }

        try data.write(to: destinationURL, options: .atomic)
        Self.logger.info("mmdb downloaded bytes=\(data.count)")
        return destinationURL
    }

    private func ensureDirectoryIfNeeded(_ directoryURL: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw NSError(
                    domain: "CountryMMDBStore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "工作目录路径不是文件夹: \(directoryURL.path)"]
                )
            }
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
