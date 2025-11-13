import Foundation

enum CleanupStep: Int, CaseIterable {
    case systemCaches
    case largeFiles
    case xcodeArtifacts

    var title: String {
        switch self {
        case .systemCaches:
            return "System Caches"
        case .largeFiles:
            return "Large & Old Files"
        case .xcodeArtifacts:
            return "Xcode Artifacts"
        }
    }

    var detail: String {
        switch self {
        case .systemCaches:
            return "Clears temporary items under /var and system caches."
        case .largeFiles:
            return "Scans home folders for large, stale files."
        case .xcodeArtifacts:
            return "Removes DerivedData, archives, and build caches."
        }
    }

    var icon: String {
        switch self {
        case .systemCaches:
            return "internaldrive"
        case .largeFiles:
            return "doc.richtext"
        case .xcodeArtifacts:
            return "hammer"
        }
    }
}

struct CleanupCategory: Identifiable, Equatable {
    struct CleanupItem: Identifiable, Equatable {
        let id: String
        let name: String
        let path: String
        let size: Int64?
        let detail: String?
        var isSelected: Bool

        init(path: String, name: String, size: Int64?, detail: String?, isSelected: Bool = true) {
            let normalizedPath = URL(fileURLWithPath: path).path
            self.id = normalizedPath
            self.name = name
            self.path = normalizedPath
            self.size = size
            self.detail = detail
            self.isSelected = isSelected
        }
    }

    let step: CleanupStep
    var items: [CleanupItem]
    var isEnabled: Bool
    var error: String?
    var note: String?

    init(step: CleanupStep, items: [CleanupItem] = [], isEnabled: Bool? = nil, error: String? = nil, note: String? = nil) {
        self.step = step
        self.items = items
        let computedEnabled = isEnabled ?? !items.isEmpty
        self.isEnabled = items.isEmpty ? false : computedEnabled
        self.error = error
        self.note = note
    }

    var id: CleanupStep { step }

    var selectedItems: [CleanupItem] {
        guard isEnabled else { return [] }
        return items.filter { $0.isSelected }
    }

    var selectedCount: Int { selectedItems.count }
    var totalCount: Int { items.count }

    var selectedSize: Int64? {
        let total = selectedItems.compactMap { $0.size }.reduce(0, +)
        return total > 0 ? total : nil
    }

    var totalSize: Int64? {
        let total = items.compactMap { $0.size }.reduce(0, +)
        return total > 0 ? total : nil
    }

    var hasSelection: Bool {
        isEnabled && selectedCount > 0
    }
}

enum CleanupStepState: Equatable {
    case pending
    case running
    case success(message: String)
    case failure(message: String, recovery: String?)
}

struct CleanupRunSummary: Equatable {
    let success: Bool
    let headline: String
    let details: [String]
    let recovery: String?
    let dryRun: Bool
}

struct CleanupOutcome {
    let success: Bool
    let message: String
    let recoverySuggestion: String?
}

extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
