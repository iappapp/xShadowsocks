import Foundation
import os

/// Owns bundled geo data lifecycle for the mihomo runtime.
///
/// Responsibilities:
///   1. Ensure `Country.mmdb` and `GeoSite.dat` exist in the working directory.
///   2. Copy them from app bundle resources when missing.
///
/// Both files ship inside the app bundle, so no network download is needed.
final class CountryMMDBStore {
    static let fileName = "Country.mmdb"
    static let geoSiteFileName = "GeoSite.dat"

    private static let logger = Logger(
        subsystem: "com.github.iappapp.xShadowsocks",
        category: "CountryMMDBStore"
    )

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Guarantees geo data files exist in `directoryURL`.
    /// Order of resolution per file: existing file → bundled copy. Never downloads.
    func ensureMMDB(in directoryURL: URL) async throws -> URL {
        try ensureDirectoryIfNeeded(directoryURL)
        let mmdbURL = try ensureBundledFile(
            resourceName: "Country",
            resourceExtension: "mmdb",
            destinationFileName: Self.fileName,
            in: directoryURL
        )
        _ = try ensureBundledFile(
            resourceName: "GeoSite",
            resourceExtension: "dat",
            destinationFileName: Self.geoSiteFileName,
            in: directoryURL
        )
        return mmdbURL
    }

    private func ensureBundledFile(
        resourceName: String,
        resourceExtension: String,
        destinationFileName: String,
        in directoryURL: URL
    ) throws -> URL {
        let destinationURL = directoryURL.appendingPathComponent(destinationFileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            Self.logger.info("\(destinationFileName, privacy: .public) already present at \(destinationURL.path, privacy: .public)")
            return destinationURL
        }

        guard let bundledURL = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else {
            Self.logger.error("bundled \(destinationFileName, privacy: .public) not found in app resources")
            throw NSError(
                domain: "CountryMMDBStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "应用资源中缺少 \(destinationFileName)，请确认已加入 Bundle Resources"]
            )
        }

        do {
            try fileManager.copyItem(at: bundledURL, to: destinationURL)
            Self.logger.info("\(destinationFileName, privacy: .public) copied from bundle")
            return destinationURL
        } catch {
            Self.logger.error("\(destinationFileName, privacy: .public) copy failed: \(error.localizedDescription, privacy: .public)")
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw error
        }
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
