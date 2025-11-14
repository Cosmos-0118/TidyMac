import Foundation

struct LargeFileScanProgress {
    let totalFiles: Int
    let scannedFiles: Int
}

struct LargeFileScanResult {
    let files: [FileDetail]
    let totalFiles: Int
    let permissionIssue: Bool
    let permissionMessage: String?
}

protocol LargeFileScanningService {
    func scan(
        thresholdBytes: Int64,
        olderThanDays: Int,
        maxResults: Int,
        progress: @escaping (LargeFileScanProgress) -> Void
    ) async -> LargeFileScanResult

    func delete(paths: [String]) throws
}

final class FileSystemLargeFileScanningService: LargeFileScanningService {
    private let fileManager: FileManager
    private let candidateDirectories: [URL]
    private let deletionGuard: DeletionGuarding
    private let privilegedDeletion: PrivilegedDeletionHandling

    init(
        fileManager: FileManager = .default,
        candidateDirectories: [URL]? = nil,
        deletionGuard: DeletionGuarding = DeletionGuard.shared,
        privilegedDeletion: PrivilegedDeletionHandling = PrivilegedDeletionService()
    ) {
        self.fileManager = fileManager
        self.candidateDirectories = candidateDirectories ?? FileSystemLargeFileScanningService.defaultCandidateDirectories(fileManager: fileManager)
        self.deletionGuard = deletionGuard
        self.privilegedDeletion = privilegedDeletion
    }

    func scan(
        thresholdBytes: Int64,
        olderThanDays: Int,
        maxResults: Int,
        progress: @escaping (LargeFileScanProgress) -> Void
    ) async -> LargeFileScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let manager = FileManager()
                let directories = self.candidateDirectories

                var permissionIssue = false
                var permissionMessage: String?
                var permissionPaths: Set<String> = []
                var aggregatedFiles: [FileDetail] = []
                var totalCount = 0
                var processedCount = 0

                for directory in directories {
                    let path = directory.path
                    guard manager.fileExists(atPath: path) else { continue }
                    guard let enumerator = manager.enumerator(
                        at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else {
                        permissionIssue = true
                        permissionPaths.insert(path)
                        if permissionMessage == nil {
                            permissionMessage = "Grant Full Disk Access to scan \(path)."
                        }
                        continue
                    }

                    var localURLs: [URL] = []
                    for case let fileURL as URL in enumerator {
                        localURLs.append(fileURL)
                    }

                    totalCount += localURLs.count

                    for fileURL in localURLs {
                        do {
                            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                            guard values.isRegularFile == true,
                                  let size = values.fileSize,
                                  let modified = values.contentModificationDate else { continue }

                            let age = Calendar.current.dateComponents([.day], from: modified, to: Date()).day ?? 0
                            if Int64(size) >= thresholdBytes && age >= olderThanDays {
                                aggregatedFiles.append(FileDetail(
                                    name: fileURL.lastPathComponent,
                                    size: Int64(size),
                                    modificationDate: modified,
                                    path: fileURL.path
                                ))
                            }
                        } catch {
                            permissionIssue = true
                            let parentPath = fileURL.deletingLastPathComponent().path
                            permissionPaths.insert(parentPath)
                            if permissionMessage == nil {
                                permissionMessage = "MacCleaner needs permission to inspect \(parentPath)."
                            }
                        }

                        processedCount += 1
                        progress(LargeFileScanProgress(totalFiles: totalCount, scannedFiles: processedCount))

                        if aggregatedFiles.count >= maxResults {
                            break
                        }
                    }

                    if aggregatedFiles.count >= maxResults {
                        break
                    }
                }

                if aggregatedFiles.count > maxResults {
                    aggregatedFiles = Array(aggregatedFiles.prefix(maxResults))
                }

                progress(LargeFileScanProgress(totalFiles: totalCount, scannedFiles: totalCount))

                if permissionIssue, !permissionPaths.isEmpty {
                    Diagnostics.warning(
                        category: .cleanup,
                        message: "Large file scan skipped locations due to permissions.",
                        metadata: ["paths": permissionPaths.sorted().prefix(3).joined(separator: ", ")]
                    )
                }

                Diagnostics.info(
                    category: .cleanup,
                    message: "Large file scan completed.",
                    metadata: ["totalFiles": "\(totalCount)", "results": "\(aggregatedFiles.count)"]
                )

                continuation.resume(returning: LargeFileScanResult(
                    files: aggregatedFiles,
                    totalFiles: totalCount,
                    permissionIssue: permissionIssue,
                    permissionMessage: permissionMessage
                ))
            }
        }
    }

    func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }

        let guardResult: DeletionGuardResult
        do {
            guardResult = try deletionGuard.filter(paths: paths)
        } catch {
            Diagnostics.error(
                category: .cleanup,
                message: "Deletion guard blocked removing selected files.",
                error: error
            )
            throw error
        }

        let permittedPaths = guardResult.permitted

        if permittedPaths.isEmpty {
            if !guardResult.excluded.isEmpty {
                Diagnostics.warning(
                    category: .cleanup,
                    message: "Deletion skipped for excluded paths.",
                    metadata: ["paths": guardResult.excluded.joined(separator: ", ")]
                )
                throw DeletionGuardError.excluded(paths: guardResult.excluded)
            }
            return
        }

    let manager = self.fileManager
        var privilegedTargets: [String] = []
        var failures: [String] = []

        for path in permittedPaths {
            do {
                var resultingURL: NSURL?
                try manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
            } catch {
                if isPermissionError(error) {
                    privilegedTargets.append(path)
                } else {
                    failures.append(path)
                    Diagnostics.error(
                        category: .cleanup,
                        message: "Failed to delete \(path).",
                        error: error
                    )
                }
            }
        }

        if !privilegedTargets.isEmpty {
            switch privilegedDeletion.remove(paths: privilegedTargets) {
            case .success:
                break
            case .cancelled:
                failures.append(contentsOf: privilegedTargets)
                Diagnostics.warning(
                    category: .cleanup,
                    message: "Administrator prompt was cancelled during privileged deletion.",
                    metadata: ["paths": privilegedTargets.joined(separator: ", ")]
                )
            case .failure(let message):
                Diagnostics.error(
                    category: .cleanup,
                    message: "Privileged deletion failed.",
                    suggestion: message,
                    metadata: ["paths": privilegedTargets.joined(separator: ", ")]
                )
                throw NSError(domain: "com.maccleaner.largefiles", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        if !failures.isEmpty {
            Diagnostics.error(
                category: .cleanup,
                message: "Unable to delete some files.",
                metadata: ["paths": failures.joined(separator: ", ")]
            )
            throw NSError(domain: "com.maccleaner.largefiles", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to delete \(failures.count) file(s)."])
        }

        Diagnostics.info(
            category: .cleanup,
            message: "Deleted \(permittedPaths.count) item(s)."
        )
    }

    private static func defaultCandidateDirectories(fileManager: FileManager) -> [URL] {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        return [
            homeDirectory,
            homeDirectory.appendingPathComponent("Downloads"),
            homeDirectory.appendingPathComponent("Movies"),
            homeDirectory.appendingPathComponent("Desktop")
        ]
    }
}
