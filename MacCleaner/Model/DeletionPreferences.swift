import Foundation

struct DeletionPreferences: Codable {
    var excludedPaths: Set<String>
    var dryRunPreview: DryRunPreviewSnapshot?

    init(excludedPaths: Set<String> = [], dryRunPreview: DryRunPreviewSnapshot? = nil) {
        self.excludedPaths = excludedPaths
        self.dryRunPreview = dryRunPreview
    }
}

struct DryRunPreviewSnapshot: Codable, Equatable {
    struct Category: Codable, Equatable {
        let step: CleanupStep
        let title: String
        let totalItems: Int
        let selectedCount: Int
        let items: [Item]
    }

    struct Item: Codable, Equatable {
        let path: String
        let name: String
        let size: Int64?
        let detail: String?
    }

    let generatedAt: Date
    let categories: [Category]

    var isEmpty: Bool { categories.isEmpty }
}

extension CleanupStep: Codable { }

extension DryRunPreviewSnapshot {
    static func fromCleanupCategories(_ categories: [CleanupCategory]) -> DryRunPreviewSnapshot {
        let mappedCategories = categories.compactMap { category -> Category? in
            let selectedItems = category.selectedItems
            guard !selectedItems.isEmpty else { return nil }

            let items = selectedItems.map { item in
                Item(
                    path: item.path,
                    name: item.name,
                    size: item.size,
                    detail: item.detail
                )
            }

            return Category(
                step: category.step,
                title: category.step.title,
                totalItems: category.items.count,
                selectedCount: selectedItems.count,
                items: items
            )
        }

        return DryRunPreviewSnapshot(
            generatedAt: Date(),
            categories: mappedCategories
        )
    }
}
