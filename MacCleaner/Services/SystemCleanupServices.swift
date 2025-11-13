import Foundation
import Darwin

final class SystemCacheCleanupService: CleanupService {
    var step: CleanupStep { .systemCaches }

    private let fileManager: FileManager
    private let deletionGuard: DeletionGuarding
    private let privilegedDeletion: PrivilegedDeletionHandling
    private let targets: [(path: String, name: String)]

    init(
        fileManager: FileManager = .default,
        deletionGuard: DeletionGuarding = DeletionGuard.shared,
        privilegedDeletion: PrivilegedDeletionHandling = PrivilegedDeletionService(),
        targets: [(path: String, name: String)]? = nil
    ) {
        self.fileManager = fileManager
        self.deletionGuard = deletionGuard
        self.privilegedDeletion = privilegedDeletion
        if let targets {
            self.targets = targets.map { (URL(fileURLWithPath: $0.path).path, $0.name) }
        } else {
            self.targets = [
                (NSTemporaryDirectory(), "Temporary Items"),
                ("/var/folders", "Shared Cache Containers")
            ]
        }
    }

    func scan() async -> CleanupCategory {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let targets = self.targets
                let fileManager = self.fileManager
                var items: [CleanupCategory.CleanupItem] = []
                var failures: [String] = []

                for target in targets {
                    let normalizedPath = URL(fileURLWithPath: target.path).path
                    guard fileManager.fileExists(atPath: normalizedPath) else { continue }
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: normalizedPath)
                        let detail = contents.isEmpty ? "Empty" : "\(contents.count) top-level items"
                        items.append(CleanupCategory.CleanupItem(
                            path: normalizedPath,
                            name: target.name,
                            size: nil,
                            detail: detail
                        ))
                    } catch {
                        failures.append(target.name)
                    }
                }

                if !failures.isEmpty {
                    Diagnostics.warning(
                        category: .cleanup,
                        message: "System cache scan skipped targets due to permissions.",
                        metadata: ["targets": failures.joined(separator: ", ")]
                    )
                } else {
                    Diagnostics.info(
                        category: .cleanup,
                        message: "System cache scan completed.",
                        metadata: ["targets": targets.map { $0.name }.joined(separator: ", ")]
                    )
                }

                let error = failures.isEmpty ? nil : "Limited preview access for: \(failures.joined(separator: ", "))."
                continuation.resume(returning: CleanupCategory(step: .systemCaches, items: items, error: error))
            }
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
                let fileManager = self.fileManager
                let step = self.step
                let deletionGuard = self.deletionGuard
                let privilegedDeletion = self.privilegedDeletion
                Diagnostics.info(
                    category: .cleanup,
                    message: "System cache cleanup requested.",
                    metadata: [
                        "dryRun": dryRun ? "true" : "false",
                        "selectionCount": "\(items.count)"
                    ]
                )

                guard !items.isEmpty else {
                    Diagnostics.info(
                        category: .cleanup,
                        message: "System cache cleanup skipped (no selections).",
                        metadata: ["dryRun": dryRun ? "true" : "false"]
                    )
                    continuation.resume(returning: CleanupOutcome(success: true, message: "No system cache targets selected.", recoverySuggestion: nil))
                    return
                }

                let actionableItems: [CleanupCategory.CleanupItem]
                var skippedProtected = 0
                var excludedSelections = Set<String>()
                var guardResult: DeletionGuardResult?

                do {
                    let result = try deletionGuard.filter(paths: items.map(\.path))
                    guardResult = result
                    let permitted = Set(result.permitted)
                    actionableItems = items.filter { permitted.contains($0.path) }
                    skippedProtected = result.excluded.count
                    excludedSelections.formUnion(result.excluded)
                } catch let error as DeletionGuardError {
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Cleanup blocked by deletion guard.",
                        error: error
                    )
                    continuation.resume(returning: CleanupOutcome(
                        success: false,
                        message: error.errorDescription ?? "Cleanup blocked.",
                        recoverySuggestion: error.recoverySuggestion
                    ))
                    return
                } catch {
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Cleanup failed while filtering selections.",
                        error: error
                    )
                    continuation.resume(returning: CleanupOutcome(
                        success: false,
                        message: "Cleanup blocked.",
                        recoverySuggestion: error.localizedDescription
                    ))
                    return
                }

                if let guardResult {
                    var metadata: [String: String] = [
                        "requested": "\(items.count)",
                        "permitted": "\(guardResult.permitted.count)",
                        "excluded": "\(guardResult.excluded.count)"
                    ]
                    if !guardResult.excluded.isEmpty {
                        metadata["excludedSamples"] = Array(guardResult.excluded.prefix(3)).joined(separator: ", ")
                    }
                    Diagnostics.info(
                        category: .cleanup,
                        message: "System cache guard evaluation completed.",
                        metadata: metadata
                    )
                }

                guard !actionableItems.isEmpty else {
                    let message: String
                    let recovery: String?
                    if dryRun {
                        message = "Dry run: no cache items processed because selections are protected."
                        recovery = "Update your exclusion list before running the cleanup."
                    } else {
                        message = "Cleanup skipped. The selected cache paths are protected by exclusions."
                        recovery = "Adjust your exclusion list and retry."
                    }

                    var metadata: [String: String] = [
                        "step": step.title,
                        "dryRun": dryRun ? "true" : "false",
                        "requested": "\(items.count)",
                        "excluded": "\(skippedProtected)"
                    ]
                    if let guardResult, !guardResult.excluded.isEmpty {
                        metadata["excludedSamples"] = Array(guardResult.excluded.prefix(3)).joined(separator: ", ")
                    }

                    Diagnostics.warning(
                        category: .cleanup,
                        message: "Cleanup skipped due to protected selections.",
                        metadata: metadata
                    )
                    continuation.resume(returning: CleanupOutcome(success: false, message: message, recoverySuggestion: recovery))
                    return
                }

                var removedCount = 0
                var failures: [String] = []
                var privilegedTargets: Set<String> = []
                var privilegedCancelled = false
                var privilegedFailureMessage: String?
                var restrictedPaths: [String] = []
                var systemProtectedPaths: Set<String> = []

                let syncQueue = DispatchQueue(label: "com.maccleaner.systemCleanup.sync")
                let workerQueue = DispatchQueue(label: "com.maccleaner.systemCleanup.worker", qos: .userInitiated, attributes: .concurrent)
                let concurrencyLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)
                let semaphore = DispatchSemaphore(value: concurrencyLimit)
                let logSampleLimit = 5
                var excludedLogCount = 0
                var restrictedLogCount = 0
                var privilegedLogCount = 0
                var failureLogCount = 0
                var directoryLogCount = 0
                var systemProtectedLogCount = 0

                for item in actionableItems {
                    let directory = item.path
                    guard fileManager.fileExists(atPath: directory) else {
                        Diagnostics.warning(
                            category: .cleanup,
                            message: "System cache directory no longer exists.",
                            metadata: ["path": directory]
                        )
                        continue
                    }

                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: directory)

                        if directoryLogCount < logSampleLimit {
                            Diagnostics.info(
                                category: .cleanup,
                                message: "Scanning system cache directory.",
                                metadata: ["path": directory, "entries": "\(contents.count)"]
                            )
                        }
                        directoryLogCount += 1

                        if !contents.isEmpty {
                            progressTracker.registerAdditionalUnits(contents.count, update: progressUpdate)
                        }

                        let group = DispatchGroup()

                        for entry in contents {
                            group.enter()
                            semaphore.wait()
                            workerQueue.async {
                                defer {
                                    progressTracker.advance(by: 1, update: progressUpdate)
                                    semaphore.signal()
                                    group.leave()
                                }

                                let path = (directory as NSString).appendingPathComponent(entry)

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
                                            message: "Skipping cache item due to exclusion preferences.",
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
                                            message: "Encountered restricted cache path.",
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
                                                    message: "Cache item is protected by macOS and cannot be removed automatically.",
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
                                                    message: "Cache item requires administrator privileges.",
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
                                                message: "Failed to remove cache item.",
                                                error: error,
                                                metadata: ["path": path]
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        group.wait()
                    } catch {
                        if !dryRun && requiresAdministratorPrivileges(error) {
                            if isSystemProtectedCachePath(directory) {
                                var shouldLog = false
                                syncQueue.sync {
                                    let inserted = systemProtectedPaths.insert(directory).inserted
                                    if inserted {
                                        if systemProtectedLogCount < logSampleLimit {
                                            systemProtectedLogCount += 1
                                            shouldLog = true
                                        }
                                    }
                                }
                                if shouldLog {
                                    Diagnostics.warning(
                                        category: .cleanup,
                                        message: "Cache directory is protected by macOS and cannot be inspected automatically.",
                                        metadata: ["path": directory]
                                    )
                                }
                            } else {
                                syncQueue.sync {
                                    privilegedTargets.insert(directory)
                                }
                                Diagnostics.warning(
                                    category: .cleanup,
                                    message: "Administrator permission required to inspect cache directory.",
                                    metadata: ["path": directory]
                                )
                            }
                        } else {
                            syncQueue.sync {
                                if !failures.contains(directory) {
                                    failures.append(directory)
                                }
                            }
                            Diagnostics.error(
                                category: .cleanup,
                                message: "Unable to inspect cache directory.",
                                error: error,
                                metadata: ["path": directory]
                            )
                        }
                    }
                }

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
                    var message = "Dry run: \(removedCount) cache items selected."
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
                        metadata["excludedSamples"] = Array(excludedSample).joined(separator: ", ")
                    }
                    let failureSample = Array(failures.prefix(logSampleLimit))
                    if !failureSample.isEmpty {
                        metadata["failureSamples"] = Array(failureSample).joined(separator: ", ")
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
                    var message = "Removed \(removedCount) cache items."
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
                        metadata["excludedSamples"] = Array(excludedSample).joined(separator: ", ")
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
                    metadata["excludedSamples"] = Array(excludedSample).joined(separator: ", ")
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
    }
}

final class LargeFileScanner: CleanupService {
    var step: CleanupStep { .largeFiles }

    private let fileManager: FileManager
    private let deletionGuard: DeletionGuarding
    private let privilegedDeletion: PrivilegedDeletionHandling

    init(
        fileManager: FileManager = .default,
        deletionGuard: DeletionGuarding = DeletionGuard.shared,
        privilegedDeletion: PrivilegedDeletionHandling = PrivilegedDeletionService()
    ) {
        self.fileManager = fileManager
        self.deletionGuard = deletionGuard
        self.privilegedDeletion = privilegedDeletion
    }

    func scan() async -> CleanupCategory {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let homeDirectory = NSHomeDirectory()
                let candidateDirectories = [
                    homeDirectory,
                    (homeDirectory as NSString).appendingPathComponent("Downloads"),
                    (homeDirectory as NSString).appendingPathComponent("Movies"),
                    (homeDirectory as NSString).appendingPathComponent("Desktop")
                ]

                let fileManager = self.fileManager
                let thresholdBytes: Int64 = 50 * 1_048_576
                let maxAgeDays = 30
                let maxResults = 200
                var items: [CleanupCategory.CleanupItem] = []
                var failures: [String] = []

                directoryLoop: for path in candidateDirectories {
                    guard fileManager.fileExists(atPath: path) else { continue }
                    let url = URL(fileURLWithPath: path)
                    guard let enumerator = fileManager.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else { continue }

                    for case let fileURL as URL in enumerator {
                        if items.count >= maxResults {
                            break directoryLoop
                        }

                        do {
                            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                            guard values.isRegularFile == true,
                                  let size = values.fileSize,
                                  let modified = values.contentModificationDate else { continue }

                            let age = Calendar.current.dateComponents([.day], from: modified, to: Date()).day ?? 0
                            if Int64(size) >= thresholdBytes && age >= maxAgeDays {
                                let detail = age > 0 ? "Last modified \(age) days ago" : "Recently modified"
                                items.append(CleanupCategory.CleanupItem(
                                    path: fileURL.path,
                                    name: fileURL.lastPathComponent,
                                    size: Int64(size),
                                    detail: detail
                                ))
                            }
                        } catch {
                            failures.append(fileURL.deletingLastPathComponent().path)
                        }
                    }
                }

                if !failures.isEmpty {
                    Diagnostics.warning(
                        category: .cleanup,
                        message: "Large file quick scan skipped locations due to permissions.",
                        metadata: ["paths": Array(failures.prefix(3)).joined(separator: ", ")]
                    )
                } else {
                    Diagnostics.info(
                        category: .cleanup,
                        message: "Large file quick scan completed.",
                        metadata: ["results": "\(items.count)"]
                    )
                }

                var error: String?
                if failures.isEmpty {
                    error = nil
                } else if items.isEmpty {
                    error = "Unable to scan some folders. Grant access and try again."
                } else {
                    error = "Skipped \(failures.count) items due to permissions."
                }

                // Sort by size (largest first) so the most impactful files appear at the top.
                items.sort { lhs, rhs in
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

                let note = items.count >= maxResults ? "Showing the first \(maxResults) results." : nil
                continuation.resume(returning: CleanupCategory(step: .largeFiles, items: items, error: error, note: note))
            }
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
                let deletionGuard = self.deletionGuard
                let privilegedDeletion = self.privilegedDeletion

                guard !items.isEmpty else {
                    continuation.resume(returning: CleanupOutcome(success: true, message: "No large files selected.", recoverySuggestion: nil))
                    return
                }

                let actionableItems: [CleanupCategory.CleanupItem]
                var skippedProtected = 0

                do {
                    let guardResult = try deletionGuard.filter(paths: items.map(\.path))
                    let permitted = Set(guardResult.permitted)
                    actionableItems = items.filter { permitted.contains($0.path) }
                    skippedProtected = guardResult.excluded.count
                } catch let error as DeletionGuardError {
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Large file cleanup blocked by deletion guard.",
                        error: error
                    )
                    continuation.resume(returning: CleanupOutcome(
                        success: false,
                        message: error.errorDescription ?? "Cleanup blocked.",
                        recoverySuggestion: error.recoverySuggestion
                    ))
                    return
                } catch {
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Large file cleanup failed during filtering.",
                        error: error
                    )
                    continuation.resume(returning: CleanupOutcome(
                        success: false,
                        message: "Cleanup blocked.",
                        recoverySuggestion: error.localizedDescription
                    ))
                    return
                }

                guard !actionableItems.isEmpty else {
                    let message: String
                    let recovery: String?
                    if dryRun {
                        message = "Dry run: no files processed because selections are protected."
                        recovery = "Update your exclusion list before running the cleanup."
                    } else {
                        message = "Cleanup skipped. The selected files are protected by exclusions."
                        recovery = "Adjust your exclusion list and retry."
                    }
                    continuation.resume(returning: CleanupOutcome(success: false, message: message, recoverySuggestion: recovery))
                    return
                }

                progressTracker.registerAdditionalUnits(actionableItems.count, update: progressUpdate)

                var removedCount = 0
                var failures: [String] = []
                var privilegedTargets: Set<String> = []
                var privilegedCancelled = false
                var privilegedFailureMessage: String?
                var restrictedPaths: [String] = []

                let syncQueue = DispatchQueue(label: "com.maccleaner.largeFiles.sync")
                let workerQueue = DispatchQueue(label: "com.maccleaner.largeFiles.worker", qos: .userInitiated, attributes: .concurrent)
                let concurrencyLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)
                let semaphore = DispatchSemaphore(value: concurrencyLimit)
                let group = DispatchGroup()

                for item in actionableItems {
                    group.enter()
                    semaphore.wait()
                    workerQueue.async {
                        defer {
                            progressTracker.advance(by: 1, update: progressUpdate)
                            semaphore.signal()
                            group.leave()
                        }

                        let path = item.path
                        let decision = deletionGuard.decision(for: path)
                        switch decision {
                        case .allow:
                            break
                        case .excluded:
                            syncQueue.sync {
                                skippedProtected += 1
                            }
                            return
                        case .restricted:
                            syncQueue.sync {
                                restrictedPaths.append(path)
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
                                syncQueue.sync {
                                    privilegedTargets.insert(path)
                                }
                            } else {
                                syncQueue.sync {
                                    failures.append(path)
                                }
                            }
                        }
                    }
                }

                group.wait()

                if !restrictedPaths.isEmpty {
                    let error = DeletionGuardError.restricted(paths: Array(Set(restrictedPaths)))
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Large file cleanup blocked due to restricted paths.",
                        error: error
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
                    var message = "Dry run: \(removedCount) files selected."
                    if skippedProtected > 0 {
                        message += " Skipped \(skippedProtected) protected item(s)."
                    }
                    let recovery: String?
                    if success {
                        recovery = skippedProtected > 0 ? "Adjust your exclusion list if you want to include the skipped paths." : nil
                    } else {
                        recovery = "Some files could not be inspected. Adjust your selection and retry."
                    }

                    Diagnostics.info(
                        category: .cleanup,
                        message: "Dry run completed for Large & Old Files.",
                        metadata: ["success": success ? "true" : "false", "selected": "\(removedCount)"]
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
                    switch privilegedDeletion.remove(paths: elevatedPaths) {
                    case .success:
                        removedCount += elevatedPaths.count
                    case .cancelled:
                        privilegedCancelled = true
                        failures.append(contentsOf: elevatedPaths)
                        Diagnostics.warning(
                            category: .cleanup,
                            message: "Administrator prompt was cancelled during large file cleanup.",
                            metadata: ["paths": elevatedPaths.joined(separator: ", ")]
                        )
                    case let .failure(message):
                        privilegedFailureMessage = message
                        Diagnostics.error(
                            category: .cleanup,
                            message: "Privileged large file cleanup failed.",
                            suggestion: message,
                            metadata: ["paths": elevatedPaths.joined(separator: ", ")]
                        )
                        failures.append(contentsOf: elevatedPaths)
                    }
                }

                if failures.isEmpty {
                    var message = "Removed \(removedCount) large files."
                    if skippedProtected > 0 {
                        message += " Skipped \(skippedProtected) protected item(s)."
                    }
                    Diagnostics.info(
                        category: .cleanup,
                        message: "Large file cleanup succeeded.",
                        metadata: ["removed": "\(removedCount)", "skipped": "\(skippedProtected)"]
                    )
                    continuation.resume(returning: CleanupOutcome(success: true, message: message, recoverySuggestion: nil))
                    return
                }

                let message = privilegedCancelled
                    ? "Administrator permission was required to remove \(failures.count) selected files."
                    : "Unable to remove \(failures.count) selected files."

                var recovery: String
                if privilegedCancelled {
                    recovery = "Re-run the cleanup and approve the administrator prompt to delete the flagged files."
                } else if let privilegedFailureMessage, !privilegedFailureMessage.isEmpty {
                    recovery = privilegedFailureMessage
                } else {
                    recovery = "Check permissions or close applications using the files before retrying."
                }

                if skippedProtected > 0 {
                    recovery += " Protected selections were skipped due to exclusions."
                }

                Diagnostics.error(
                    category: .cleanup,
                    message: message,
                    suggestion: recovery,
                    metadata: ["failures": failures.joined(separator: ", ")]
                )
                continuation.resume(returning: CleanupOutcome(success: false, message: message, recoverySuggestion: recovery))
            }
        }
    }
}

final class XcodeCacheCleaner: CleanupService {
    var step: CleanupStep { .xcodeArtifacts }

    private let fileManager: FileManager
    private let deletionGuard: DeletionGuarding
    private let privilegedDeletion: PrivilegedDeletionHandling
    private let targets: [(suffix: String, name: String)]

    init(
        fileManager: FileManager = .default,
        deletionGuard: DeletionGuarding = DeletionGuard.shared,
        privilegedDeletion: PrivilegedDeletionHandling = PrivilegedDeletionService(),
        targets: [(suffix: String, name: String)]? = nil
    ) {
        self.fileManager = fileManager
        self.deletionGuard = deletionGuard
        self.privilegedDeletion = privilegedDeletion
        if let targets {
            self.targets = targets
        } else {
            self.targets = [
                ("Library/Developer/Xcode/DerivedData", "Derived Data"),
                ("Library/Caches/com.apple.dt.Xcode", "Build Caches"),
                ("Library/Developer/Xcode/Archives", "Archives"),
                ("Library/Developer/Xcode/Products", "Build Products"),
                ("Library/Developer/Xcode/UserData/Previews/Simulator Devices", "Preview Simulators")
            ]
        }
    }

    func scan() async -> CleanupCategory {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let home = NSHomeDirectory()
                let targets = self.targets
                let fileManager = self.fileManager
                var items: [CleanupCategory.CleanupItem] = []
                var failures: [String] = []

                for target in targets {
                    let path = (home as NSString).appendingPathComponent(target.suffix)
                    guard fileManager.fileExists(atPath: path) else { continue }
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: path)
                        let detail = contents.isEmpty ? "Empty" : "\(contents.count) items"
                        items.append(CleanupCategory.CleanupItem(
                            path: path,
                            name: target.name,
                            size: nil,
                            detail: detail
                        ))
                    } catch {
                        failures.append(target.name)
                    }
                }

                if !failures.isEmpty {
                    Diagnostics.warning(
                        category: .cleanup,
                        message: "Xcode artifact scan skipped targets.",
                        metadata: ["targets": failures.joined(separator: ", ")]
                    )
                } else {
                    Diagnostics.info(
                        category: .cleanup,
                        message: "Xcode artifact scan completed.",
                        metadata: ["targets": targets.map { $0.name }.joined(separator: ", ")]
                    )
                }

                let error = failures.isEmpty ? nil : "Close Xcode to scan: \(failures.joined(separator: ", "))."
                continuation.resume(returning: CleanupCategory(step: .xcodeArtifacts, items: items, error: error))
            }
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
                let deletionGuard = self.deletionGuard
                let privilegedDeletion = self.privilegedDeletion
                let fileManager = self.fileManager

                guard !items.isEmpty else {
                    continuation.resume(returning: CleanupOutcome(success: true, message: "No Xcode artifacts selected.", recoverySuggestion: nil))
                    return
                }

                let actionableItems: [CleanupCategory.CleanupItem]
                var skippedProtected = 0

                do {
                    let guardResult = try deletionGuard.filter(paths: items.map(\.path))
                    let permitted = Set(guardResult.permitted)
                    actionableItems = items.filter { permitted.contains($0.path) }
                    skippedProtected = guardResult.excluded.count
                } catch let error as DeletionGuardError {
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Xcode cleanup blocked by deletion guard.",
                        error: error
                    )
                    continuation.resume(returning: CleanupOutcome(
                        success: false,
                        message: error.errorDescription ?? "Cleanup blocked.",
                        recoverySuggestion: error.recoverySuggestion
                    ))
                    return
                } catch {
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Xcode cleanup failed during filtering.",
                        error: error
                    )
                    continuation.resume(returning: CleanupOutcome(
                        success: false,
                        message: "Cleanup blocked.",
                        recoverySuggestion: error.localizedDescription
                    ))
                    return
                }

                guard !actionableItems.isEmpty else {
                    let message: String
                    let recovery: String?
                    if dryRun {
                        message = "Dry run: no Xcode items processed because selections are protected."
                        recovery = "Update your exclusion list before running the cleanup."
                    } else {
                        message = "Cleanup skipped. The selected Xcode paths are protected by exclusions."
                        recovery = "Adjust your exclusion list and retry."
                    }
                    continuation.resume(returning: CleanupOutcome(success: false, message: message, recoverySuggestion: recovery))
                    return
                }

                var deletedItems = 0
                var failures: [String] = []
                var privilegedTargets: Set<String> = []
                var privilegedCancelled = false
                var privilegedFailureMessage: String?
                var restrictedPaths: [String] = []

                let syncQueue = DispatchQueue(label: "com.maccleaner.xcodeCleanup.sync")
                let workerQueue = DispatchQueue(label: "com.maccleaner.xcodeCleanup.worker", qos: .userInitiated, attributes: .concurrent)
                let concurrencyLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)
                let semaphore = DispatchSemaphore(value: concurrencyLimit)

                for item in actionableItems {
                    let directory = item.path
                    guard FileManager.default.fileExists(atPath: directory) else { continue }

                    do {
                        let contents = try FileManager.default.contentsOfDirectory(atPath: directory)
                        if !contents.isEmpty {
                            progressTracker.registerAdditionalUnits(contents.count, update: progressUpdate)
                        }

                        let group = DispatchGroup()

                        for entry in contents {
                            group.enter()
                            semaphore.wait()
                            workerQueue.async {
                                defer {
                                    progressTracker.advance(by: 1, update: progressUpdate)
                                    semaphore.signal()
                                    group.leave()
                                }

                                let path = (directory as NSString).appendingPathComponent(entry)
                                let decision = deletionGuard.decision(for: path)
                                switch decision {
                                case .allow:
                                    break
                                case .excluded:
                                    syncQueue.sync {
                                        skippedProtected += 1
                                    }
                                    return
                                case .restricted:
                                    syncQueue.sync {
                                        restrictedPaths.append(path)
                                    }
                                    return
                                }

                                if dryRun {
                                    syncQueue.sync {
                                        deletedItems += 1
                                    }
                                    return
                                }

                                do {
                                    try FileManager().removeItem(atPath: path)
                                    syncQueue.sync {
                                        deletedItems += 1
                                    }
                                } catch {
                                    if requiresAdministratorPrivileges(error) {
                                        syncQueue.sync {
                                            privilegedTargets.insert(path)
                                        }
                                    } else {
                                        syncQueue.sync {
                                            failures.append(path)
                                        }
                                    }
                                }
                            }
                        }

                        group.wait()
                    } catch {
                        if !dryRun && requiresAdministratorPrivileges(error) {
                            syncQueue.sync {
                                privilegedTargets.insert(directory)
                            }
                        } else {
                            syncQueue.sync {
                                failures.append(directory)
                            }
                        }
                    }
                }

                if !restrictedPaths.isEmpty {
                    let error = DeletionGuardError.restricted(paths: Array(Set(restrictedPaths)))
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Xcode cleanup blocked due to restricted paths.",
                        error: error
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
                    var message = "Dry run: \(deletedItems) Xcode items selected."
                    if skippedProtected > 0 {
                        message += " Skipped \(skippedProtected) protected item(s)."
                    }
                    let recovery: String?
                    if success {
                        recovery = skippedProtected > 0 ? "Adjust your exclusion list if you want to include the skipped paths." : nil
                    } else {
                        recovery = "Close Xcode or grant full disk access before retrying."
                    }

                    Diagnostics.info(
                        category: .cleanup,
                        message: "Dry run completed for Xcode artifacts.",
                        metadata: ["success": success ? "true" : "false", "selected": "\(deletedItems)"]
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
                    switch privilegedDeletion.remove(paths: elevatedPaths) {
                    case .success:
                        deletedItems += elevatedPaths.count
                    case .cancelled:
                        privilegedCancelled = true
                        failures.append(contentsOf: elevatedPaths)
                        Diagnostics.warning(
                            category: .cleanup,
                            message: "Administrator prompt was cancelled during Xcode cleanup.",
                            metadata: ["paths": elevatedPaths.joined(separator: ", ")]
                        )
                    case let .failure(message):
                        privilegedFailureMessage = message
                        failures.append(contentsOf: elevatedPaths)
                        Diagnostics.error(
                            category: .cleanup,
                            message: "Privileged Xcode cleanup failed.",
                            suggestion: message,
                            metadata: ["paths": elevatedPaths.joined(separator: ", ")]
                        )
                    }
                }

                if failures.isEmpty {
                    var message = "Removed \(deletedItems) Xcode items."
                    if skippedProtected > 0 {
                        message += " Skipped \(skippedProtected) protected item(s)."
                    }
                    Diagnostics.info(
                        category: .cleanup,
                        message: "Xcode cleanup succeeded.",
                        metadata: ["removed": "\(deletedItems)", "skipped": "\(skippedProtected)"]
                    )
                    continuation.resume(returning: CleanupOutcome(success: true, message: message, recoverySuggestion: nil))
                    return
                }

                let message = privilegedCancelled
                    ? "Administrator permission was required to remove \(failures.count) Xcode items."
                    : "Unable to remove \(failures.count) Xcode items."

                var recovery: String
                if privilegedCancelled {
                    recovery = "Re-run the cleanup and approve the administrator prompt to purge protected Xcode artifacts."
                } else if let privilegedFailureMessage, !privilegedFailureMessage.isEmpty {
                    recovery = privilegedFailureMessage
                } else {
                    recovery = "Ensure Xcode is closed and MacCleaner has the required permissions."
                }

                if skippedProtected > 0 {
                    recovery += " Protected selections were skipped due to exclusions."
                }

                Diagnostics.error(
                    category: .cleanup,
                    message: message,
                    suggestion: recovery,
                    metadata: ["failures": failures.joined(separator: ", ")]
                )
                continuation.resume(returning: CleanupOutcome(success: false, message: message, recoverySuggestion: recovery))
            }
        }
    }
}

private func isSystemProtectedCachePath(_ path: String) -> Bool {
    guard path.hasPrefix("/var/folders/") else { return false }

    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }

    if let attributes = try? fileManager.attributesOfItem(atPath: path) {
        if let ownerID = attributes[.ownerAccountID] as? NSNumber, ownerID.intValue == 0 {
            return true
        }
        if let ownerName = attributes[.ownerAccountName] as? String, ownerName == "root" {
            return true
        }
    } else {
        // Attribute lookups failing typically indicate SIP-protected locations; treat them as protected.
        return true
    }

    let components = path.split(separator: "/")
    if let tempIndex = components.firstIndex(where: { $0 == "T" }), tempIndex < components.count - 1 {
        if let tail = components.last, tail.hasPrefix("com.apple.") {
            return true
        }
    }

    return false
}

private func requiresAdministratorPrivileges(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        return nsError.code == Int(EPERM) || nsError.code == Int(EACCES)
    }
    if nsError.domain == NSCocoaErrorDomain {
        let cocoaPermissionCodes: Set<Int> = [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
            NSFileWriteVolumeReadOnlyError
        ]
        if cocoaPermissionCodes.contains(nsError.code) {
            return true
        }
    }
    return false
}
