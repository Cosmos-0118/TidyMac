import Foundation

final class SystemCacheCleanupService: CleanupService {
    var step: CleanupStep { .systemCaches }

    private let fileManager: FileManager
    private let deletionGuard: DeletionGuarding
    private let privilegedDeletion: PrivilegedDeletionHandling
    private let customTargets: [(path: String, name: String)]?
    private let inventoryService: CleanupInventoryServicing

    init(
        fileManager: FileManager = .default,
        deletionGuard: DeletionGuarding = DeletionGuard.shared,
        privilegedDeletion: PrivilegedDeletionHandling = PrivilegedDeletionService(),
        targets: [(path: String, name: String)]? = nil,
        inventoryService: CleanupInventoryServicing = CleanupInventoryService()
    ) {
        self.fileManager = fileManager
        self.deletionGuard = deletionGuard
        self.privilegedDeletion = privilegedDeletion
        if let targets {
            self.customTargets = targets.map { (URL(fileURLWithPath: $0.path).path, $0.name) }
        } else {
            self.customTargets = nil
        }
        self.inventoryService = inventoryService
    }

    func scan() async -> CleanupCategory {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let category: CleanupCategory
                if let customTargets = self.customTargets {
                    category = self.scanCustomTargets(customTargets)
                } else {
                    category = self.scanComprehensiveTargets()
                }
                continuation.resume(returning: category)
            }
        }
    }

    private func scanCustomTargets(_ targets: [(path: String, name: String)]) -> CleanupCategory {
        var items: [CleanupCategory.CleanupItem] = []
        var failures: [String] = []

        for target in targets {
            let normalizedPath = URL(fileURLWithPath: target.path).path
            guard fileManager.fileExists(atPath: normalizedPath) else { continue }
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: normalizedPath)
                let detail = contents.isEmpty ? "Empty" : "\(contents.count) top-level items"
                let reasons = [CleanupReason(code: "target", label: "Targeted directory", detail: detail)]
                items.append(CleanupCategory.CleanupItem(
                    path: normalizedPath,
                    name: target.name,
                    size: nil,
                    detail: detail,
                    reasons: reasons
                ))
            } catch {
                failures.append(target.name)
            }
        }

        if !failures.isEmpty {
            Diagnostics.warning(
                category: .cleanup,
                message: "Cleanup scan skipped custom targets due to permissions.",
                metadata: ["targets": failures.joined(separator: ", ")]
            )
        } else {
            Diagnostics.info(
                category: .cleanup,
                message: "Cleanup scan completed for custom targets.",
                metadata: ["targets": targets.map { $0.name }.joined(separator: ", ")]
            )
        }

        let error = failures.isEmpty ? nil : "Limited preview access for: \(failures.joined(separator: ", "))."
        return CleanupCategory(step: .systemCaches, items: items, error: error)
    }

    private func scanComprehensiveTargets() -> CleanupCategory {
        var failures: [String] = []
        var aggregatedItems: [CleanupCategory.CleanupItem] = []

        let homeLibrary = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let userCaches = homeLibrary.appendingPathComponent("Caches", isDirectory: true)
        let systemCaches = URL(fileURLWithPath: "/Library/Caches", isDirectory: true)
        let groupContainers = homeLibrary.appendingPathComponent("Group Containers", isDirectory: true)
        let applicationSupport = homeLibrary.appendingPathComponent("Application Support", isDirectory: true)
        let userLogs = homeLibrary.appendingPathComponent("Logs", isDirectory: true)
        let systemLogs = URL(fileURLWithPath: "/Library/Logs", isDirectory: true)

        aggregatedItems.append(contentsOf: collectChildEntries(
            under: userCaches,
            includeFiles: false,
            directoryDetail: "User cache directory",
            fileDetail: "User cache file",
            failures: &failures,
            nameTransform: { url in "User Cache • \(self.displayName(for: url))" }
        ))

        aggregatedItems.append(contentsOf: collectChildEntries(
            under: systemCaches,
            includeFiles: false,
            directoryDetail: "Shared cache directory",
            fileDetail: "Shared cache file",
            failures: &failures,
            nameTransform: { url in "System Cache • \(self.displayName(for: url))" }
        ))

        aggregatedItems.append(contentsOf: collectMatchingDirectories(
            startingAt: applicationSupport,
            keywords: ["cache", "caches", "tmp", "temp"],
            depth: 2,
            detail: "Application Support cache directory",
            namePrefix: "App Support",
            failures: &failures
        ))

        aggregatedItems.append(contentsOf: collectMatchingDirectories(
            startingAt: groupContainers,
            keywords: ["cache", "caches", "tmp", "temp"],
            depth: 1,
            detail: "Group container cache directory",
            namePrefix: "Group Container",
            failures: &failures
        ))

        aggregatedItems.append(contentsOf: collectChildEntries(
            under: userLogs,
            includeFiles: true,
            directoryDetail: "User log directory",
            fileDetail: "User log file",
            failures: &failures,
            nameTransform: { url in "User Logs • \(self.displayName(for: url))" }
        ))

        aggregatedItems.append(contentsOf: collectChildEntries(
            under: systemLogs,
            includeFiles: true,
            directoryDetail: "System log directory",
            fileDetail: "System log file",
            failures: &failures,
            nameTransform: { url in "System Logs • \(self.displayName(for: url))" }
        ))

        let temporaryRoots: [URL] = [
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            URL(fileURLWithPath: "/var/tmp", isDirectory: true),
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
        ]

        for root in temporaryRoots {
            aggregatedItems.append(contentsOf: collectChildEntries(
                under: root,
                includeFiles: true,
                directoryDetail: "Temporary directory",
                fileDetail: "Temporary file",
                failures: &failures,
                nameTransform: { url in "Temp • \(self.displayName(for: url))" }
            ))
        }

        aggregatedItems.append(contentsOf: collectMatchingDirectories(
            startingAt: applicationSupport,
            keywords: ["log", "logs", "crash"],
            depth: 2,
            detail: "Application Support logs",
            namePrefix: "App Support",
            failures: &failures
        ))

        let inventoryResult = inventoryService.discoverCandidates(sources: [.browserCaches, .orphanedApplicationSupport, .orphanedPreferences, .sharedInstallers])
        if !inventoryResult.candidates.isEmpty {
            let inventoryItems = inventoryResult.candidates.map { CleanupCategory.CleanupItem(candidate: $0) }
            aggregatedItems.append(contentsOf: inventoryItems)
            Diagnostics.info(
                category: .cleanup,
                message: "Inventory service contributed \(inventoryItems.count) candidate(s).",
                metadata: ["sources": "browser,app-support,preferences,shared"]
            )
        }
        failures.append(contentsOf: inventoryResult.permissionDenied)

        let uniqueItems = sortDiscoveredItems(dedupe(aggregatedItems))

        let note = "Caches, logs, and temporary files are regenerated automatically by macOS and your apps."

        let error: String?
        if failures.isEmpty {
            error = nil
        } else {
            let limited = failures.uniqued().prefix(5)
            error = "Limited access to: \(limited.joined(separator: ", ")). Grant Full Disk Access for more results."
        }

        Diagnostics.info(
            category: .cleanup,
            message: "Comprehensive cleanup scan completed.",
            metadata: [
                "discovered": "\(uniqueItems.count)",
                "failures": "\(failures.count)"
            ]
        )

        return CleanupCategory(step: .systemCaches, items: uniqueItems, error: error, note: note)
    }

    private func collectChildEntries(
        under root: URL,
        includeFiles: Bool,
        directoryDetail: String,
        fileDetail: String,
        failures: inout [String],
        nameTransform: ((URL) -> String)? = nil,
        maxEntries: Int? = nil
    ) -> [CleanupCategory.CleanupItem] {
        var results: [CleanupCategory.CleanupItem] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return results
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )

            for entry in contents {
                if let maxEntries, results.count >= maxEntries {
                    break
                }

                let values = try entry.resourceValues(forKeys: resourceKeys)
                let entryIsDirectory = values.isDirectory == true

                if entryIsDirectory {
                    let name = nameTransform?(entry) ?? displayName(for: entry)
                    let reasons = [CleanupReason(code: "category", label: directoryDetail)]
                    results.append(CleanupCategory.CleanupItem(
                        path: entry.path,
                        name: name,
                        size: nil,
                        detail: directoryDetail,
                        reasons: reasons
                    ))
                } else if includeFiles {
                    let name = nameTransform?(entry) ?? displayName(for: entry)
                    let sizeValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
                    let size = sizeValue.map { Int64($0) }
                    let detail = values.contentModificationDate.map {
                        detailTextWithModification(base: fileDetail, date: $0)
                    } ?? fileDetail
                    let reasons = [CleanupReason(code: "file", label: fileDetail, detail: detail)]

                    results.append(CleanupCategory.CleanupItem(
                        path: entry.path,
                        name: name,
                        size: size,
                        detail: detail,
                        reasons: reasons
                    ))
                }
            }
        } catch {
            failures.append(root.path)
        }

        return results
    }

    private func collectMatchingDirectories(
        startingAt root: URL,
        keywords: [String],
        depth: Int,
        detail: String,
        namePrefix: String,
        failures: inout [String],
        maxEntries: Int? = nil
    ) -> [CleanupCategory.CleanupItem] {
        var results: [CleanupCategory.CleanupItem] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return results
        }

        collectMatchingDirectories(
            current: root,
            keywords: keywords,
            remainingDepth: depth,
            detail: detail,
            namePrefix: namePrefix,
            maxEntries: maxEntries,
            failures: &failures,
            results: &results
        )

        return results
    }

    private func collectMatchingDirectories(
        current: URL,
        keywords: [String],
        remainingDepth: Int,
        detail: String,
        namePrefix: String,
        maxEntries: Int?,
        failures: inout [String],
        results: inout [CleanupCategory.CleanupItem]
    ) {
        if let maxEntries, results.count >= maxEntries { return }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for entry in contents {
                if let maxEntries, results.count >= maxEntries {
                    break
                }

                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }

                let lowercased = entry.lastPathComponent.lowercased()
                if let match = keywords.first(where: { lowercased.contains($0) }) {
                    let baseName = displayName(for: entry)
                    let name = namePrefix.isEmpty ? baseName : "\(namePrefix) • \(baseName)"
                    let reasons = [CleanupReason(code: "keyword", label: "Matches \"\(match)\"", detail: detail)]
                    results.append(CleanupCategory.CleanupItem(
                        path: entry.path,
                        name: name,
                        size: nil,
                        detail: detail,
                        reasons: reasons
                    ))
                    continue
                }

                if remainingDepth > 0 {
                    collectMatchingDirectories(
                        current: entry,
                        keywords: keywords,
                        remainingDepth: remainingDepth - 1,
                        detail: detail,
                        namePrefix: namePrefix,
                        maxEntries: maxEntries,
                        failures: &failures,
                        results: &results
                    )
                }
            }
        } catch {
            failures.append(current.path)
        }
    }

    private func detailTextWithModification(base: String, date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "\(base) • Modified \(relative)"
    }

    private func displayName(for url: URL) -> String {
        fileManager.displayName(atPath: url.path)
    }

    private func dedupe(_ items: [CleanupCategory.CleanupItem]) -> [CleanupCategory.CleanupItem] {
        var seen: Set<String> = []
        var result: [CleanupCategory.CleanupItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            if seen.insert(item.id).inserted {
                result.append(item)
            }
        }

        return result
    }

    private func sortDiscoveredItems(_ items: [CleanupCategory.CleanupItem]) -> [CleanupCategory.CleanupItem] {
        items.sorted { lhs, rhs in
            switch (lhs.size, rhs.size) {
            case let (left?, right?) where left != right:
                return left > right
            case (nil, nil):
                break
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func execute(
        items: [CleanupCategory.CleanupItem],
        dryRun: Bool,
        progressTracker: CleanupProgress,
        progressUpdate: @escaping (Double) -> Void
    ) async -> CleanupOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.performCleanup(
                    items: items,
                    dryRun: dryRun,
                    progressTracker: progressTracker,
                    progressUpdate: progressUpdate,
                    continuation: continuation
                )
            }
        }
    }

    private func performCleanup(
        items: [CleanupCategory.CleanupItem],
        dryRun: Bool,
        progressTracker: CleanupProgress,
        progressUpdate: @escaping (Double) -> Void,
        continuation: CheckedContinuation<CleanupOutcome, Never>
    ) {
        Diagnostics.info(
            category: .cleanup,
            message: "Cleanup sweep requested.",
            metadata: [
                "dryRun": dryRun ? "true" : "false",
                "selectionCount": "\(items.count)"
            ]
        )

        guard !items.isEmpty else {
            Diagnostics.info(
                category: .cleanup,
                message: "Cleanup sweep skipped (no selections).",
                metadata: ["dryRun": dryRun ? "true" : "false"]
            )
            continuation.resume(returning: CleanupOutcome(success: true, message: "No cleanup targets selected.", recoverySuggestion: nil))
            return
        }

        let filtering = filterActionableItems(from: items)
        switch filtering {
        case .failure(let outcome):
            continuation.resume(returning: outcome)
            return
        case .success(let actionable):
            if actionable.items.isEmpty {
                continuation.resume(returning: actionable.emptyOutcome)
                return
            }
            executeCleanup(
                actionable: actionable,
                dryRun: dryRun,
                progressTracker: progressTracker,
                progressUpdate: progressUpdate,
                continuation: continuation
            )
        }
    }

    private enum FilterResult {
        case success(ActionableItems)
        case failure(CleanupOutcome)
    }

    private struct ActionableItems {
        let items: [CleanupCategory.CleanupItem]
        let excludedSelections: Set<String>
        let skippedProtected: Int

        var metadata: [String: String] {
            [
                "requested": "\(items.count + skippedProtected)",
                "permitted": "\(items.count)",
                "excluded": "\(skippedProtected)"
            ]
        }

        var emptyOutcome: CleanupOutcome {
            let dryRunMessage = "Dry run: no cleanup items processed because selections are protected."
            let liveMessage = "Cleanup skipped. The selected paths are protected by exclusions."
            return CleanupOutcome(
                success: false,
                message: skippedProtected > 0 ? liveMessage : dryRunMessage,
                recoverySuggestion: "Adjust your exclusion list and retry."
            )
        }
    }

    private func filterActionableItems(from items: [CleanupCategory.CleanupItem]) -> FilterResult {
        do {
            let result = try deletionGuard.filter(paths: items.map(\.path))
            let permitted = Set(result.permitted)
            let actionableItems = items.filter { permitted.contains($0.path) }
            let excludedSelections = Set(result.excluded)
            let skippedProtected = result.excluded.count

            var metadata: [String: String] = [
                "requested": "\(items.count)",
                "permitted": "\(actionableItems.count)",
                "excluded": "\(skippedProtected)"
            ]
            if !excludedSelections.isEmpty {
                metadata["excludedSamples"] = Array(excludedSelections.prefix(3)).joined(separator: ", ")
            }

            Diagnostics.info(
                category: .cleanup,
                message: "System cache guard evaluation completed.",
                metadata: metadata
            )

            return .success(ActionableItems(
                items: actionableItems,
                excludedSelections: excludedSelections,
                skippedProtected: skippedProtected
            ))
        } catch let error as DeletionGuardError {
            Diagnostics.error(
                category: .cleanup,
                message: "Cleanup blocked by deletion guard.",
                error: error
            )
            return .failure(CleanupOutcome(
                success: false,
                message: error.errorDescription ?? "Cleanup blocked.",
                recoverySuggestion: error.recoverySuggestion
            ))
        } catch {
            Diagnostics.error(
                category: .cleanup,
                message: "Cleanup failed while filtering selections.",
                error: error
            )
            return .failure(CleanupOutcome(
                success: false,
                message: "Cleanup blocked.",
                recoverySuggestion: error.localizedDescription
            ))
        }
    }

    private func executeCleanup(
        actionable: ActionableItems,
        dryRun: Bool,
        progressTracker: CleanupProgress,
        progressUpdate: @escaping (Double) -> Void,
        continuation: CheckedContinuation<CleanupOutcome, Never>
    ) {
        let fileManager = self.fileManager
        let deletionGuard = self.deletionGuard
        let privilegedDeletion = self.privilegedDeletion
        let step = self.step

        var removedCount = 0
        var failures: [String] = []
        var privilegedTargets: Set<String> = []
        var privilegedCancelled = false
        var privilegedFailureMessage: String?
        var restrictedPaths: [String] = []
        var systemProtectedPaths: Set<String> = []
        var excludedSelections = actionable.excludedSelections
        var skippedProtected = actionable.skippedProtected

        let logSampleLimit = 5

        let syncQueue = DispatchQueue(label: "com.maccleaner.systemCleanup.sync")
        let workerQueue = DispatchQueue(label: "com.maccleaner.systemCleanup.worker", qos: .userInitiated, attributes: .concurrent)
        let concurrencyLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let semaphore = DispatchSemaphore(value: concurrencyLimit)
        let group = DispatchGroup()

        var excludedLogCount = 0
        var restrictedLogCount = 0
        var privilegedLogCount = 0
        var failureLogCount = 0
        var directoryLogCount = 0
        var systemProtectedLogCount = 0
        var fileLogCount = 0

        func enqueueRemoval(for path: String) {
            group.enter()
            semaphore.wait()
            workerQueue.async {
                defer {
                    progressTracker.advance(by: 1, update: progressUpdate)
                    semaphore.signal()
                    group.leave()
                }

                let decision = deletionGuard.decision(for: path)
                switch decision {
                case .allow:
                    break
                case .excluded:
                    var shouldLog = false
                    syncQueue.sync {
                        skippedProtected += 1
                        excludedSelections.insert(path)
                        if excludedLogCount < logSampleLimit {
                            excludedLogCount += 1
                            shouldLog = true
                        }
                    }
                    if shouldLog {
                        Diagnostics.info(
                            category: .cleanup,
                            message: "Skipping system cache path due to exclusion preferences.",
                            metadata: ["path": path]
                        )
                    }
                    return
                case .restricted:
                    var shouldLog = false
                    syncQueue.sync {
                        restrictedPaths.append(path)
                        if restrictedLogCount < logSampleLimit {
                            restrictedLogCount += 1
                            shouldLog = true
                        }
                    }
                    if shouldLog {
                        Diagnostics.warning(
                            category: .cleanup,
                            message: "Encountered restricted system cache path.",
                            metadata: ["path": path]
                        )
                    }
                    return
                }

                if dryRun {
                    syncQueue.sync {
                        removedCount += 1
                    }
                    return
                }

                do {
                    try FileManager().removeItem(atPath: path)
                    syncQueue.sync {
                        removedCount += 1
                    }
                } catch {
                    if requiresAdministratorPrivileges(error) {
                        if isSystemProtectedCachePath(path) {
                            var shouldLog = false
                            syncQueue.sync {
                                let inserted = systemProtectedPaths.insert(path).inserted
                                if inserted, systemProtectedLogCount < logSampleLimit {
                                    systemProtectedLogCount += 1
                                    shouldLog = true
                                }
                            }
                            if shouldLog {
                                Diagnostics.warning(
                                    category: .cleanup,
                                    message: "Cache path is protected by macOS and cannot be removed automatically.",
                                    metadata: ["path": path]
                                )
                            }
                        } else {
                            var shouldLog = false
                            syncQueue.sync {
                                privilegedTargets.insert(path)
                                if privilegedLogCount < logSampleLimit {
                                    privilegedLogCount += 1
                                    shouldLog = true
                                }
                            }
                            if shouldLog {
                                Diagnostics.warning(
                                    category: .cleanup,
                                    message: "Cache path requires administrator privileges.",
                                    metadata: ["path": path]
                                )
                            }
                        }
                    } else {
                        var shouldLog = false
                        syncQueue.sync {
                            if !failures.contains(path) {
                                failures.append(path)
                            }
                            if failureLogCount < logSampleLimit {
                                failureLogCount += 1
                                shouldLog = true
                            }
                        }
                        if shouldLog {
                            Diagnostics.error(
                                category: .cleanup,
                                message: "Failed to remove cache path.",
                                error: error,
                                metadata: ["path": path]
                            )
                        }
                    }
                }
            }
        }

        for item in actionable.items {
            let path = item.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                Diagnostics.warning(
                    category: .cleanup,
                    message: "System cache target no longer exists.",
                    metadata: ["path": path]
                )
                continue
            }

            if !isDirectory.boolValue {
                progressTracker.registerAdditionalUnits(1, update: progressUpdate)
                if fileLogCount < logSampleLimit {
                    Diagnostics.info(
                        category: .cleanup,
                        message: "Scheduling removal for system cache file.",
                        metadata: ["path": path]
                    )
                }
                fileLogCount += 1
                enqueueRemoval(for: path)
                continue
            }

            do {
                let contents = try fileManager.contentsOfDirectory(atPath: path)

                if directoryLogCount < logSampleLimit {
                    Diagnostics.info(
                        category: .cleanup,
                        message: "Scanning system cache directory.",
                        metadata: ["path": path, "entries": "\(contents.count)"]
                    )
                }
                directoryLogCount += 1

                if !contents.isEmpty {
                    progressTracker.registerAdditionalUnits(contents.count, update: progressUpdate)
                }

                for entry in contents {
                    let entryPath = (path as NSString).appendingPathComponent(entry)
                    enqueueRemoval(for: entryPath)
                }
            } catch {
                if !dryRun && requiresAdministratorPrivileges(error) {
                    if isSystemProtectedCachePath(path) {
                        var shouldLog = false
                        syncQueue.sync {
                            let inserted = systemProtectedPaths.insert(path).inserted
                            if inserted, systemProtectedLogCount < logSampleLimit {
                                systemProtectedLogCount += 1
                                shouldLog = true
                            }
                        }
                        if shouldLog {
                            Diagnostics.warning(
                                category: .cleanup,
                                message: "Cache directory is protected by macOS and cannot be inspected automatically.",
                                metadata: ["path": path]
                            )
                        }
                    } else {
                        syncQueue.sync {
                            privilegedTargets.insert(path)
                        }
                        Diagnostics.warning(
                            category: .cleanup,
                            message: "Administrator permission required to inspect cache directory.",
                            metadata: ["path": path]
                        )
                    }
                } else {
                    syncQueue.sync {
                        if !failures.contains(path) {
                            failures.append(path)
                        }
                    }
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Unable to inspect cache directory.",
                        error: error,
                        metadata: ["path": path]
                    )
                }
            }
        }

        group.wait()

        let blockedPaths = Array(Set(restrictedPaths))
        if !blockedPaths.isEmpty {
            let error = DeletionGuardError.restricted(paths: blockedPaths)
            Diagnostics.error(
                category: .cleanup,
                message: "Cleanup blocked due to restricted paths.",
                error: error,
                metadata: ["paths": Array(blockedPaths.prefix(3)).joined(separator: ", ")]
            )
            continuation.resume(returning: CleanupOutcome(
                success: false,
                message: error.errorDescription ?? "Cleanup blocked.",
                recoverySuggestion: error.recoverySuggestion
            ))
            return
        }

        if dryRun {
            let success = failures.isEmpty && privilegedTargets.isEmpty
            var message = "Dry run: \(removedCount) cache item(s) selected."
            if skippedProtected > 0 {
                message += " Skipped \(skippedProtected) protected item(s)."
            }
            let recovery: String?
            if success {
                recovery = skippedProtected > 0 ? "Adjust your exclusion list if you want to include the skipped paths." : nil
            } else {
                recovery = "Grant access to the highlighted locations and try again."
            }

            var metadata: [String: String] = [
                "success": success ? "true" : "false",
                "selected": "\(removedCount)",
                "skippedProtected": "\(skippedProtected)",
                "failures": "\(failures.count)",
                "privilegedCandidates": "\(privilegedTargets.count)"
            ]
            let excludedSample = Array(excludedSelections).prefix(logSampleLimit)
            if !excludedSample.isEmpty {
                metadata["excludedSamples"] = excludedSample.joined(separator: ", ")
            }
            let failureSample = Array(failures.prefix(logSampleLimit))
            if !failureSample.isEmpty {
                metadata["failureSamples"] = failureSample.joined(separator: ", ")
            }

            Diagnostics.info(
                category: .cleanup,
                message: "Dry run completed for \(step.title).",
                metadata: metadata
            )

            continuation.resume(returning: CleanupOutcome(
                success: success,
                message: message,
                recoverySuggestion: recovery
            ))
            return
        }

        if !privilegedTargets.isEmpty {
            let elevatedPaths = Array(privilegedTargets)
            Diagnostics.info(
                category: .cleanup,
                message: "Requesting privileged removal for system cache items.",
                metadata: [
                    "count": "\(elevatedPaths.count)",
                    "sample": Array(elevatedPaths.prefix(3)).joined(separator: ", ")
                ]
            )
            switch privilegedDeletion.remove(paths: elevatedPaths) {
            case .success:
                removedCount += elevatedPaths.count
                Diagnostics.info(
                    category: .cleanup,
                    message: "Privileged removal succeeded for system cache items.",
                    metadata: ["removed": "\(elevatedPaths.count)"]
                )
            case .cancelled:
                privilegedCancelled = true
                let newFailures = elevatedPaths.filter { !failures.contains($0) }
                failures.append(contentsOf: newFailures)
                Diagnostics.warning(
                    category: .cleanup,
                    message: "Administrator prompt was cancelled during cache cleanup.",
                    metadata: ["paths": elevatedPaths.joined(separator: ", ")]
                )
            case let .failure(message):
                privilegedFailureMessage = message
                Diagnostics.error(
                    category: .cleanup,
                    message: "Privileged cache cleanup failed.",
                    suggestion: message,
                    metadata: ["paths": elevatedPaths.joined(separator: ", ")]
                )
                let newFailures = elevatedPaths.filter { !failures.contains($0) }
                failures.append(contentsOf: newFailures)
            }
        }

        if failures.isEmpty {
            var message = "Removed \(removedCount) cache item(s)."
            if skippedProtected > 0 {
                message += " Skipped \(skippedProtected) protected item(s)."
            }
            if !systemProtectedPaths.isEmpty {
                message += " macOS protected \(systemProtectedPaths.count) item(s); they remain for safety."
            }
            var metadata: [String: String] = [
                "removed": "\(removedCount)",
                "skipped": "\(skippedProtected)",
                "privilegedRequested": "\(privilegedTargets.count)"
            ]
            if !systemProtectedPaths.isEmpty {
                metadata["systemProtected"] = "\(systemProtectedPaths.count)"
                let sample = Array(systemProtectedPaths).sorted().prefix(logSampleLimit)
                if !sample.isEmpty {
                    metadata["systemProtectedSamples"] = sample.joined(separator: ", ")
                }
            }
            let excludedSample = Array(excludedSelections).prefix(logSampleLimit)
            if !excludedSample.isEmpty {
                metadata["excludedSamples"] = excludedSample.joined(separator: ", ")
            }

            Diagnostics.info(
                category: .cleanup,
                message: "System cache cleanup succeeded.",
                metadata: metadata
            )
            continuation.resume(returning: CleanupOutcome(success: true, message: message, recoverySuggestion: nil))
            return
        }

        let uniqueFailures = Array(Set(failures)).sorted()
        let failureCount = uniqueFailures.count
        let systemProtectedList = Array(systemProtectedPaths).sorted()
        let hasSystemProtectedFailures = !systemProtectedList.isEmpty

        let message: String
        if privilegedCancelled {
            message = "Administrator permission was required to remove \(failureCount) cache item(s)."
        } else if hasSystemProtectedFailures && failureCount == systemProtectedList.count {
            message = "Some cache items are protected by macOS and could not be removed."
        } else {
            message = "Unable to remove \(failureCount) cache item(s)."
        }

        var recoveryComponents: [String] = []
        if hasSystemProtectedFailures {
            recoveryComponents.append("Some cache paths are protected by macOS System Integrity Protection and can't be removed automatically.")
        }
        if privilegedCancelled {
            recoveryComponents.append("Re-run the cleanup and approve the administrator prompt to finish removing protected items.")
        } else if let privilegedFailureMessage, !privilegedFailureMessage.isEmpty {
            recoveryComponents.append(privilegedFailureMessage)
        } else if failureCount > systemProtectedList.count {
            recoveryComponents.append("Grant access or run MacCleaner with elevated permissions.")
        }
        if skippedProtected > 0 {
            recoveryComponents.append("Protected selections were skipped due to exclusions.")
        }

        let recovery = recoveryComponents.isEmpty
            ? "Grant access or run MacCleaner with elevated permissions."
            : recoveryComponents.joined(separator: " ")

        var metadata: [String: String] = [
            "failures": uniqueFailures.joined(separator: ", "),
            "skippedProtected": "\(skippedProtected)",
            "privilegedRequested": "\(privilegedTargets.count)"
        ]
        if hasSystemProtectedFailures {
            metadata["systemProtected"] = "\(systemProtectedList.count)"
            let sipSample = Array(systemProtectedList.prefix(logSampleLimit))
            if !sipSample.isEmpty {
                metadata["systemProtectedSamples"] = sipSample.joined(separator: ", ")
            }
        }
        let excludedSample = Array(excludedSelections).prefix(logSampleLimit)
        if !excludedSample.isEmpty {
            metadata["excludedSamples"] = excludedSample.joined(separator: ", ")
        }

        Diagnostics.error(
            category: .cleanup,
            message: message,
            suggestion: recovery,
            metadata: metadata
        )
        continuation.resume(returning: CleanupOutcome(success: false, message: message, recoverySuggestion: recovery))
    }
}