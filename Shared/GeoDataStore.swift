import Foundation
import os

/// Keeps the GeoIP database next to the runtime config, in the App Group workdir the
/// core is started with.
///
/// A subscription using `GEOIP,CN,...` rules makes the core look for `Country.mmdb`
/// in its home directory; if it is missing mihomo tries to download it, which inside
/// a Network Extension is both slow and unreliable. The bundled copy is therefore
/// installed by the app before the tunnel starts, and re-checked by the extension.
///
/// There is no download path on purpose — the database is versioned with the app.
public struct GeoDataStore {
    private static let logger = Logger(
        subsystem: "com.github.iappapp.xShadowsocks",
        category: "GeoDataStore"
    )

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies every bundled geo database that is missing from the shared workdir.
    /// Returns the names that could not be installed.
    @discardableResult
    public func ensureAvailable(bundle: Bundle = .main) -> [String] {
        guard MihomoSharedPaths.ensureDirectory() else {
            Self.logger.error("shared working directory unavailable")
            return ["工作目录不可用"]
        }
        return Self.bundledGeoFiles.compactMap { file in
            installIfNeeded(file, bundle: bundle) ? nil : "\(file.resource).\(file.extension)"
        }
    }

    /// Ship these in the app bundle; each name must match the file exactly, since
    /// that is what the core looks for in its home directory.
    public static let bundledGeoFiles: [(resource: String, extension: String)] = [
        ("Country", "mmdb")
    ]

    private func installIfNeeded(_ file: (resource: String, extension: String), bundle: Bundle) -> Bool {
        let destination = MihomoSharedPaths.directoryURL
            .appendingPathComponent("\(file.resource).\(file.extension)", isDirectory: false)

        if fileManager.fileExists(atPath: destination.path) {
            return true
        }

        guard let source = bundle.url(forResource: file.resource, withExtension: file.extension) else {
            Self.logger.error("\(file.resource).\(file.extension, privacy: .public) missing from bundle")
            return false
        }

        do {
            // Stage then move, so a concurrently starting tunnel never reads a
            // half-written database.
            let staging = destination.appendingPathExtension("staging")
            try? fileManager.removeItem(at: staging)
            try fileManager.copyItem(at: source, to: staging)
            try fileManager.moveItem(at: staging, to: destination)
            Self.logger.info("installed \(file.resource, privacy: .public).\(file.extension, privacy: .public)")
            return true
        } catch {
            Self.logger.error("copy failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
