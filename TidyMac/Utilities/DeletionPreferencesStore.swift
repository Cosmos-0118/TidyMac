import Foundation

final class DeletionPreferencesStore {
    static let shared = DeletionPreferencesStore()

    private let queue = DispatchQueue(label: "com.tidymac.deletionPreferences")
    private let storageURL: URL
    private var preferences: DeletionPreferences

    private init() {
        storageURL = AppSupportStorage.fileURL(named: "deletion-preferences.json")

        if let data = try? Data(contentsOf: storageURL) {
            do {
                preferences = try JSONDecoder().decode(DeletionPreferences.self, from: data)
            } catch {
                preferences = DeletionPreferences()
            }
        } else {
            preferences = DeletionPreferences()
        }
    }

    // MARK: - Exclusions

    func isExcluded(path: String) -> Bool {
        queue.sync {
            preferences.excludedPaths.contains(normalize(path))
        }
    }

    func excludedPaths() -> Set<String> {
        queue.sync { preferences.excludedPaths }
    }

    func updateExclusion(for path: String, excluded: Bool) {
        let normalized = normalize(path)
        queue.async {
            if excluded {
                self.preferences.excludedPaths.insert(normalized)
            } else {
                self.preferences.excludedPaths.remove(normalized)
            }
            self.persistChanges()
        }
    }

    func clearExclusion(for path: String) {
        updateExclusion(for: path, excluded: false)
    }

    // MARK: - Helpers

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func persistChanges() {
        let snapshot = preferences
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            #if DEBUG
                NSLog("Failed to persist deletion preferences: %@", error.localizedDescription)
            #endif
        }
    }
}
