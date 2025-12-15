import Foundation

@MainActor
final class SystemCleanupViewModel: ObservableObject {
    static let shared = SystemCleanupViewModel()

    @Published var categories: [CleanupCategory] {
        didSet { persistCache() }
    }
    @Published var stepStates: [CleanupStep: CleanupStepState]
    @Published var stepProgress: [CleanupStep: Double]
    @Published var isScanning: Bool
    @Published var isRunning: Bool
    @Published var overallProgress: Double
    @Published var runSummary: CleanupRunSummary?

    private let services: [AnyCleanupService]
    private let safePathFilter = SafePathFilter()
    private let cacheURL = AppSupportStorage.fileURL(named: "system_cleanup_cache.json")
    private var hasPerformedInitialScan = false

    private struct CachedCategory: Codable {
        let step: Int
        let isEnabled: Bool
        let error: String?
        let note: String?
        let items: [CachedItem]
    }

    private struct CachedItem: Codable {
        let path: String
        let name: String
        let size: Int64?
        let detail: String?
        let isSelected: Bool
        let reasons: [CachedReason]
        let confidence: CleanupConfidence?
    }

    private struct CachedReason: Codable {
        let id: String
        let label: String
        let detail: String?
    }

    private enum CachedStepState: Codable {
        case pending
        case running
        case success(message: String)
        case failure(message: String, recovery: String?)
    }

    private struct CachedSummary: Codable {
        let success: Bool
        let headline: String
        let details: [String]
        let recovery: String?
    }

    private struct CachePayload: Codable {
        let categories: [CachedCategory]
        let stepStates: [Int: CachedStepState]
        let stepProgress: [Int: Double]
        let runSummary: CachedSummary?
        let overallProgress: Double
    }

    init(services: [AnyCleanupService] = CleanupServiceRegistry.default) {
        self.services = services
        self.categories = []
        self.stepStates = Dictionary(uniqueKeysWithValues: CleanupStep.allCases.map { ($0, .pending) })
        self.stepProgress = [:]
        self.isScanning = false
        self.isRunning = false
        self.overallProgress = 0
        self.runSummary = nil

        loadCacheIfAvailable()
    }

    func handleAppear(autoScan: Bool) {
        guard autoScan else { return }
        guard !hasPerformedInitialScan else { return }
        hasPerformedInitialScan = true
        Task { await scanServices() }
    }

    func scanServices(preservingSummary: Bool = false) async {
        guard !isScanning else { return }

        let previousSelections = categories.reduce(into: [CleanupStep: (isEnabled: Bool, ids: Set<String>)]()) { result, category in
            let selected = Set(category.selectedItems.map { $0.id })
            result[category.step] = (isEnabled: category.isEnabled, ids: selected)
        }

        isScanning = true
        if !preservingSummary {
            runSummary = nil
        }

        var updatedCategories: [CleanupCategory] = []
        for service in services {
            var scannedCategory = await service.scan()
            scannedCategory.items = safePathFilter.filter(scannedCategory.items)

            if let previous = previousSelections[scannedCategory.step] {
                scannedCategory.isEnabled = previous.isEnabled && !scannedCategory.items.isEmpty
                if !previous.ids.isEmpty {
                    for index in scannedCategory.items.indices {
                        scannedCategory.items[index].isSelected = previous.ids.contains(scannedCategory.items[index].id)
                    }
                }
            }

            updatedCategories.append(scannedCategory)
        }

        categories = updatedCategories.sorted { $0.step.rawValue < $1.step.rawValue }
        stepStates = Dictionary(uniqueKeysWithValues: CleanupStep.allCases.map { ($0, .pending) })
        stepProgress.removeAll(keepingCapacity: true)
        overallProgress = 0
        isScanning = false
        persistCache()
    }

    func runCleanup() async {
        guard !isRunning else { return }

        let activeCategories = categories.filter { $0.hasSelection }
        guard !activeCategories.isEmpty else { return }

        let selectionTotal = activeCategories.reduce(into: 0) { $0 += $1.selectedCount }
        let selectedSteps = activeCategories.map { $0.step.title }.joined(separator: ", ")
        Diagnostics.info(
            category: .cleanup,
            message: "User initiated cleanup run.",
            metadata: [
                "steps": selectedSteps,
                "selectedItems": "\(selectionTotal)"
            ]
        )

        for category in activeCategories {
            for item in category.selectedItems {
                Diagnostics.info(
                    category: .cleanup,
                    message: "Queued cleanup item.",
                    metadata: telemetryMetadata(for: item, step: category.step)
                )
            }
        }

        isRunning = true
        runSummary = nil
        overallProgress = 0

        let weights = Dictionary(uniqueKeysWithValues: activeCategories.map { ($0.step, max($0.selectedCount, 1)) })
        let totalWeight = Double(weights.values.reduce(0, +))

        stepStates = categories.reduce(into: [:]) { result, category in
            result[category.step] = category.hasSelection ? .running : .pending
        }
        stepProgress = Dictionary(uniqueKeysWithValues: activeCategories.map { ($0.step, 0) })

        var details: [String] = []
        var failures: [String] = []
        var recoveries: [String] = []

        for service in services {
            guard let index = categories.firstIndex(where: { $0.step == service.step }) else { continue }
            let category = categories[index]
            guard category.hasSelection else { continue }

            let step = category.step
            let selectedItems = category.selectedItems
            stepStates[step] = .running

            if step == .systemCaches {
                Diagnostics.info(
                    category: .cleanup,
                    message: "Executing system cache cleanup step.",
                    metadata: [
                        "selected": "\(selectedItems.count)"
                    ]
                )
            }

            let tracker = CleanupProgress(initialTotal: max(selectedItems.count, 1))
            let outcome = await service.execute(items: selectedItems, dryRun: false, progressTracker: tracker) { progress in
                Task { @MainActor in
                    self.stepProgress[step] = progress
                    self.overallProgress = self.weightedProgress(weights: weights, progress: self.stepProgress, totalWeight: totalWeight)
                }
            }

            Diagnostics.info(
                category: .cleanup,
                message: "Cleanup step completed: \(step.title)",
                metadata: cleanupOutcomeMetadata(step: step, outcome: outcome, selectedItems: selectedItems)
            )

            if outcome.success {
                stepStates[step] = .success(message: outcome.message)
            } else {
                stepStates[step] = .failure(message: outcome.message, recovery: outcome.recoverySuggestion)
                failures.append(step.title)
                if let recovery = outcome.recoverySuggestion {
                    recoveries.append(recovery)
                }
            }

            details.append("\(step.title): \(outcome.message)")
        }

        let success = failures.isEmpty
        let headline = success ? "Cleanup completed successfully." : "Cleanup completed with issues."

        runSummary = CleanupRunSummary(
            success: success,
            headline: headline,
            details: details,
            recovery: recoveries.isEmpty ? nil : recoveries.uniqued().joined(separator: " ")
        )

        isRunning = false
        overallProgress = success ? 1 : overallProgress

        persistCache()

    }

    func selectAll(_ enabled: Bool) {
        categories = categories.map { category in
            var updated = category
            updated.isEnabled = enabled && !updated.items.isEmpty
            for index in updated.items.indices {
                updated.items[index].isSelected = enabled
            }
            return updated
        }
    }

    func refreshSelections() {
        categories = categories
    }

    private func weightedProgress(weights: [CleanupStep: Int], progress: [CleanupStep: Double], totalWeight: Double) -> Double {
        guard totalWeight > 0 else { return 0 }
        let accumulated = progress.reduce(0.0) { partial, entry in
            let clamped = min(max(entry.value, 0), 1)
            let weight = Double(weights[entry.key] ?? 0)
            return partial + (clamped * weight)
        }
        return min(max(accumulated / totalWeight, 0), 1)
    }

    private func telemetryMetadata(for item: CleanupCategory.CleanupItem, step: CleanupStep) -> [String: String] {
        var metadata: [String: String] = [
            "step": step.title,
            "path": item.path,
            "decision": item.guardDecision.telemetryValue
        ]
        if let size = item.size {
            metadata["sizeBytes"] = String(size)
            metadata["sizeReadable"] = formatByteCount(size)
        }
        if !item.reasons.isEmpty {
            metadata["reasonCodes"] = item.reasons.map { $0.id }.joined(separator: ",")
            metadata["reasonLabels"] = item.reasons.map { $0.label }.joined(separator: " | ")
        }
        return metadata
    }

    private func cleanupOutcomeMetadata(step: CleanupStep, outcome: CleanupOutcome, selectedItems: [CleanupCategory.CleanupItem]) -> [String: String] {
        var metadata: [String: String] = [
            "step": step.title,
            "success": outcome.success ? "true" : "false",
            "message": outcome.message
        ]
        if let recovery = outcome.recoverySuggestion, !recovery.isEmpty {
            metadata["recovery"] = recovery
        }
        let decisions = selectedItems.map { $0.guardDecision.telemetryValue }
        metadata["decisions"] = decisions.joined(separator: ",")
        let sizeTotal = selectedItems.compactMap { $0.size }.reduce(Int64(0), +)
        if sizeTotal > 0 {
            metadata["sizeBytes"] = String(sizeTotal)
            metadata["sizeReadable"] = formatByteCount(sizeTotal)
        }
        return metadata
    }

    private func loadCacheIfAvailable() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            let payload = try JSONDecoder().decode(CachePayload.self, from: data)

            let restoredCategories: [CleanupCategory] = payload.categories.compactMap { cached in
                guard let step = CleanupStep(rawValue: cached.step) else { return nil }
                var items: [CleanupCategory.CleanupItem] = cached.items.map { item in
                    var reasons: [CleanupReason] = item.reasons.map { CleanupReason(code: $0.id, label: $0.label, detail: $0.detail) }
                    return CleanupCategory.CleanupItem(
                        path: item.path,
                        name: item.name,
                        size: item.size,
                        detail: item.detail,
                        isSelected: item.isSelected,
                        reasons: reasons,
                        confidence: item.confidence,
                        metadata: nil
                    )
                }
                items = safePathFilter.filter(items)
                var category = CleanupCategory(step: step, items: items, isEnabled: cached.isEnabled, error: cached.error, note: cached.note)
                category.isEnabled = cached.isEnabled && !items.isEmpty
                return category
            }

            if !restoredCategories.isEmpty {
                categories = restoredCategories.sorted { $0.step.rawValue < $1.step.rawValue }
            }

            let restoredStates: [CleanupStep: CleanupStepState] = Dictionary(uniqueKeysWithValues: payload.stepStates.compactMap { entry in
                guard let step = CleanupStep(rawValue: entry.key) else { return nil }
                return (step, mapCachedState(entry.value))
            })

            if !restoredStates.isEmpty {
                stepStates = restoredStates
            }

            let restoredProgress: [CleanupStep: Double] = Dictionary(uniqueKeysWithValues: payload.stepProgress.compactMap { entry in
                guard let step = CleanupStep(rawValue: entry.key) else { return nil }
                return (step, entry.value)
            })
            if !restoredProgress.isEmpty {
                stepProgress = restoredProgress
                overallProgress = payload.overallProgress
            }

            if let summary = payload.runSummary {
                runSummary = CleanupRunSummary(
                    success: summary.success,
                    headline: summary.headline,
                    details: summary.details,
                    recovery: summary.recovery
                )
            }
        } catch {
            Diagnostics.error(
                category: .cleanup,
                message: "Failed to load cleanup cache",
                error: error,
                metadata: ["path": cacheURL.path]
            )
        }
    }

    private func persistCache() {
        let cachedCategories: [CachedCategory] = categories.map { category in
            CachedCategory(
                step: category.step.rawValue,
                isEnabled: category.isEnabled,
                error: category.error,
                note: category.note,
                items: category.items.map { item in
                    CachedItem(
                        path: item.path,
                        name: item.name,
                        size: item.size,
                        detail: item.detail,
                        isSelected: item.isSelected,
                        reasons: item.reasons.map { CachedReason(id: $0.id, label: $0.label, detail: $0.detail) },
                        confidence: item.confidence
                    )
                }
            )
        }

        let cachedStates: [Int: CachedStepState] = Dictionary(uniqueKeysWithValues: stepStates.map { entry in
            (entry.key.rawValue, mapState(entry.value))
        })

        let cachedProgress: [Int: Double] = Dictionary(uniqueKeysWithValues: stepProgress.map { ($0.key.rawValue, $0.value) })

        let cachedSummary: CachedSummary?
        if let summary = runSummary {
            cachedSummary = CachedSummary(
                success: summary.success,
                headline: summary.headline,
                details: summary.details,
                recovery: summary.recovery
            )
        } else {
            cachedSummary = nil
        }

        let payload = CachePayload(
            categories: cachedCategories,
            stepStates: cachedStates,
            stepProgress: cachedProgress,
            runSummary: cachedSummary,
            overallProgress: overallProgress
        )

        let url = cacheURL
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                Diagnostics.error(
                    category: .cleanup,
                    message: "Failed to persist cleanup cache",
                    error: error,
                    metadata: ["path": url.path]
                )
            }
        }
    }

    private func mapState(_ state: CleanupStepState) -> CachedStepState {
        switch state {
        case .pending:
            return .pending
        case .running:
            return .running
        case .success(let message):
            return .success(message: message)
        case .failure(let message, let recovery):
            return .failure(message: message, recovery: recovery)
        }
    }

    private func mapCachedState(_ state: CachedStepState) -> CleanupStepState {
        switch state {
        case .pending:
            return .pending
        case .running:
            return .running
        case .success(let message):
            return .success(message: message)
        case .failure(let message, let recovery):
            return .failure(message: message, recovery: recovery)
        }
    }
}

private struct SafePathFilter {
    private let deletionGuard: DeletionGuarding
    private let allowedPrefixes: [String]

    init(
        deletionGuard: DeletionGuarding = DeletionGuard.shared,
        fileManager: FileManager = .default
    ) {
        self.deletionGuard = deletionGuard
        let home = fileManager.homeDirectoryForCurrentUser.path
        allowedPrefixes = [
            home,
            home + "/Library/Caches",
            home + "/Library/Logs",
            home + "/Library/Application Support",
            "/Users/Shared",
            "/tmp",
            "/private/tmp",
            "/private/var/tmp",
            "/private/var/folders",
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log"
        ]
    }

    func filter(_ items: [CleanupCategory.CleanupItem]) -> [CleanupCategory.CleanupItem] {
        items.filter { item in
            let normalized = URL(fileURLWithPath: item.path).standardizedFileURL.path
            return isAllowed(normalized) && deletionGuard.decision(for: normalized) != .restricted
        }
    }

    private func isAllowed(_ path: String) -> Bool {
        allowedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

