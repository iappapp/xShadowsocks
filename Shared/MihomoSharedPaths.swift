import Foundation

/// Locations shared by the app and (when it is in use) the packet-tunnel extension.
///
/// Both processes must agree on where mihomo's working directory is, because the app
/// writes the user's subscription YAML there and whichever process runs the core reads
/// it from there.
///
/// The App Group container is preferred: it is the only directory both processes can
/// see. When the entitlement is unavailable — which is always the case on a free Apple
/// Developer account, where the extension cannot be signed at all — the app falls back
/// to its own Application Support directory. That keeps the loopback mode working, at
/// the cost of sharing (which loopback mode does not need).
public enum MihomoSharedPaths {
    /// Folder handed to the core as its working directory (`CLASH_HOME_DIR`).
    public static var directoryURL: URL {
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupStore.shared.appGroupID) {
            return groupURL.appendingPathComponent("mihomo", isDirectory: true)
        }
        return privateDirectoryURL
    }

    /// True when the App Group container is actually reachable, i.e. the app is signed
    /// with the entitlement and can therefore hand files to the extension.
    public static var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupStore.shared.appGroupID) != nil
    }

    /// App-private working directory, used when no App Group is available.
    public static var privateDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("mihomo", isDirectory: true)
    }

    /// `Country.mmdb` for GeoIP rule matching; the core reads it from the workdir.
    public static var mmdbURL: URL {
        directoryURL.appendingPathComponent("Country.mmdb", isDirectory: false)
    }

    /// The config the core is started with in tunnel mode: the user's selected YAML
    /// with the tunnel-specific top-level keys forced. Never shown to the user.
    public static var runtimeConfigFileName: String { "runtime.yaml" }

    public static var runtimeConfigURL: URL {
        directoryURL.appendingPathComponent(runtimeConfigFileName, isDirectory: false)
    }

    /// The equivalent for loopback mode. A separate name so switching modes (or a paid
    /// account being used later) cannot leave a stale config behind for the other mode.
    public static var localRuntimeConfigFileName: String { "runtime-local.yaml" }

    public static var localRuntimeConfigURL: URL {
        directoryURL.appendingPathComponent(localRuntimeConfigFileName, isDirectory: false)
    }

    public static func configFileURL(forFileName fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func fileExists(forFileName fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: configFileURL(forFileName: fileName).path)
    }

    /// Creates the working directory if needed. Safe to call from either process.
    @discardableResult
    public static func ensureDirectory() -> Bool {
        let url = directoryURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Moves anything left in the app-private directory into the shared one. Covers the
    /// case where the app ran in loopback mode and later gained a paid account.
    public static func migratePrivateDirectoryIfNeeded() {
        guard isAppGroupAvailable else { return }
        let source = privateDirectoryURL
        let destination = directoryURL
        guard source.path != destination.path,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: source, includingPropertiesForKeys: nil
              ) else {
            return
        }

        ensureDirectory()
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? FileManager.default.moveItem(at: entry, to: target)
        }
    }
}