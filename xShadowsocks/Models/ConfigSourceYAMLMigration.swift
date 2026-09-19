import Foundation

extension Array where Element == ConfigSourceModel {
    /// Moves YAML out of UserDefaults-backed models onto disk and clears `yamlConfig`.
    ///
    /// Full subscription YAML is too large/lossy for App Group UserDefaults; keeping it
    /// there previously caused truncated configs to overwrite good on-disk files at start.
    /// Returns `true` when the array was mutated and should be re-persisted.
    mutating func migrateYAMLToDiskIfNeeded() -> Bool {
        var changed = false

        for index in indices {
            let fileName = self[index].fileName
                ?? MihomoConfigFileStore.fileName(forConfigName: self[index].name)

            if self[index].fileName != fileName {
                self[index].fileName = fileName
                changed = true
            }

            if !MihomoConfigFileStore.fileExists(forFileName: fileName),
               let yaml = self[index].yamlConfig,
               !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? MihomoConfigFileStore.save(
                    MihomoConfigFileStore.normalizeForMihomoYAML(yaml),
                    as: fileName
                )
            }

            if self[index].yamlConfig != nil {
                self[index].yamlConfig = nil
                changed = true
            }
        }

        return changed
    }
}
