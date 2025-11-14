import Foundation

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
                                let reasons: [CleanupReason] = [
                                    CleanupReason(code: "size", label: "Larger than threshold", detail: formatByteCount(Int64(size))),
                                    CleanupReason(code: "age", label: "Stale file", detail: detail)
                                ]
                                items.append(CleanupCategory.CleanupItem(
                                    path: fileURL.path,
                                    name: fileURL.lastPathComponent,
                                    size: Int64(size),
                                    detail: detail,
                                    reasons: reasons
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
                let fileManager = self.fileManager

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
                            try moveToTrash(path, fileManager: fileManager)
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
                        let reasons = [CleanupReason(code: "xcode", label: target.name, detail: detail)]
                        items.append(CleanupCategory.CleanupItem(
                            path: path,
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
                    guard fileManager.fileExists(atPath: directory) else { continue }

                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: directory)
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
                                    try moveToTrash(path, fileManager: fileManager)
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