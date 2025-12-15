//  Copyright © 2025 TidyMac, LLC. All rights reserved.

import Foundation

protocol CleanupService {
    var step: CleanupStep { get }
    func scan() async -> CleanupCategory
    func execute(
        items: [CleanupCategory.CleanupItem],
        dryRun: Bool,
        progressTracker: CleanupProgress,
        progressUpdate: @escaping (Double) -> Void
    ) async -> CleanupOutcome
}

struct AnyCleanupService: CleanupService {
    let step: CleanupStep

    private let scanHandler: () async -> CleanupCategory
    private let executeHandler: (
        [CleanupCategory.CleanupItem],
        Bool,
        CleanupProgress,
        @escaping (Double) -> Void
    ) async -> CleanupOutcome

    init<T: CleanupService>(_ service: T) {
        step = service.step
        scanHandler = { await service.scan() }
        executeHandler = { items, dryRun, tracker, update in
            await service.execute(items: items, dryRun: dryRun, progressTracker: tracker, progressUpdate: update)
        }
    }

    func scan() async -> CleanupCategory {
        await scanHandler()
    }

    func execute(
        items: [CleanupCategory.CleanupItem],
        dryRun: Bool,
        progressTracker: CleanupProgress,
        progressUpdate: @escaping (Double) -> Void
    ) async -> CleanupOutcome {
        await executeHandler(items, dryRun, progressTracker, progressUpdate)
    }
}
