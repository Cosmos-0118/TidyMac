import Foundation

struct DeletionPreferences: Codable {
    var excludedPaths: Set<String>

    init(excludedPaths: Set<String> = []) {
        self.excludedPaths = excludedPaths
    }
}

extension CleanupStep: Codable { }
