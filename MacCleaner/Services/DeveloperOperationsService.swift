import Foundation

protocol DeveloperOperationsService {
    func run(operation: DeveloperOperation) async -> OperationBanner
}

final class FileSystemDeveloperOperationsService: DeveloperOperationsService {
    func run(operation: DeveloperOperation) async -> OperationBanner {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: OperationBanner

                switch operation {
                case .clearDerivedData:
                    result = self.clearDirectoryContents(
                        paths: ["Library/Developer/Xcode/DerivedData"],
                        description: "DerivedData"
                    )
                case .clearXcodeCaches:
                    result = self.clearDirectoryContents(
                        paths: [
                            "Library/Caches/com.apple.dt.Xcode",
                            "Library/Developer/Xcode/Index/DataStore"
                        ],
                        description: "Xcode caches"
                    )
                case .clearVSCodeCaches:
                    result = self.clearDirectoryContents(
                        paths: [
                            "Library/Application Support/Code/Cache",
                            "Library/Caches/com.microsoft.VSCode",
                            "Library/Caches/com.microsoft.VSCode.ShipIt"
                        ],
                        description: "VS Code caches"
                    )
                case .resetSimulatorCaches:
                    result = self.clearDirectoryContents(
                        paths: ["Library/Developer/CoreSimulator/Caches"],
                        description: "Simulator caches"
                    )
                case .purgeSimulatorDevices:
                    result = self.removeDirectories(
                        paths: ["Library/Developer/CoreSimulator/Devices"],
                        description: "Simulator devices"
                    )
                case .clearToolchainLogs:
                    result = self.clearDirectoryContents(
                        paths: ["Library/Developer/Toolchains/Logs"],
                        description: "Toolchain logs"
                    )
                case .purgeCustomToolchains:
                    result = self.purgeCustomToolchains()
                }

                continuation.resume(returning: result)
            }
        }
    }

    private func clearDirectoryContents(paths: [String], description: String) -> OperationBanner {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default
        var removedItems = 0
        var failures: [String] = []
        var permissionDeniedPaths: [String] = []

        for relativePath in paths {
            for path in expandedPaths(for: relativePath, home: home) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: path)
                        for item in contents {
                            let target = (path as NSString).appendingPathComponent(item)
                            do {
                                try fileManager.removeItem(atPath: target)
                                removedItems += 1
                            } catch {
                                if isPermissionError(error) {
                                    permissionDeniedPaths.append(target)
                                } else {
                                    failures.append(target)
                                }
                            }
                        }
                    } catch {
                        if isPermissionError(error) {
                            permissionDeniedPaths.append(path)
                        } else {
                            failures.append(path)
                        }
                    }
                } else {
                    do {
                        try fileManager.removeItem(atPath: path)
                        removedItems += 1
                    } catch {
                        if isPermissionError(error) {
                            permissionDeniedPaths.append(path)
                        } else {
                            failures.append(path)
                        }
                    }
                }
            }
        }

        if !permissionDeniedPaths.isEmpty {
            let privilegeResult = PrivilegedDeletionHelper.remove(paths: permissionDeniedPaths)
            switch privilegeResult {
            case .success:
                removedItems += permissionDeniedPaths.count
            case .cancelled:
                failures.append(contentsOf: permissionDeniedPaths)
            case .failure(let message):
                failures.append(contentsOf: permissionDeniedPaths)
                return OperationBanner(
                    success: false,
                    message: "Failed to clean \(description): \(message)",
                    requiresFullDiskAccess: true
                )
            }
        }

        if failures.isEmpty {
            let message = removedItems == 0
                ? "No files found for \(description)."
                : "Removed \(removedItems) items from \(description)."
            return OperationBanner(success: true, message: message, requiresFullDiskAccess: false)
        }

        return OperationBanner(
            success: false,
            message: "Failed to clean \(failures.count) paths in \(description).",
            requiresFullDiskAccess: !permissionDeniedPaths.isEmpty
        )
    }

    private func removeDirectories(paths: [String], description: String) -> OperationBanner {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default
        var removedCount = 0
        var failures: [String] = []
        var permissionDenied: [String] = []

        for relativePath in paths {
            for path in expandedPaths(for: relativePath, home: home) {
                guard fileManager.fileExists(atPath: path) else { continue }
                do {
                    try fileManager.removeItem(atPath: path)
                    removedCount += 1
                } catch {
                    if isPermissionError(error) {
                        permissionDenied.append(path)
                    } else {
                        failures.append(path)
                    }
                }
            }
        }

        if !permissionDenied.isEmpty {
            let privilegeResult = PrivilegedDeletionHelper.remove(paths: permissionDenied)
            switch privilegeResult {
            case .success:
                removedCount += permissionDenied.count
            case .cancelled:
                failures.append(contentsOf: permissionDenied)
            case .failure(let message):
                failures.append(contentsOf: permissionDenied)
                return OperationBanner(
                    success: false,
                    message: "Failed to remove \(description): \(message)",
                    requiresFullDiskAccess: true
                )
            }
        }

        if failures.isEmpty {
            let message = removedCount == 0
                ? "No directories removed from \(description)."
                : "Removed \(removedCount) directories from \(description)."
            return OperationBanner(success: true, message: message, requiresFullDiskAccess: false)
        }

        return OperationBanner(
            success: false,
            message: "Failed to remove \(failures.count) directories in \(description).",
            requiresFullDiskAccess: !permissionDenied.isEmpty
        )
    }

    private func purgeCustomToolchains() -> OperationBanner {
        let toolchainsPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Developer/Toolchains")
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(atPath: toolchainsPath) else {
            return OperationBanner(success: true, message: "No custom toolchains found.", requiresFullDiskAccess: false)
        }

        let targets = contents.filter { item in
            !item.lowercased().contains("xcodedefault") && !item.hasSuffix(".log")
        }

        var removed = 0
        var failures: [String] = []
        var permissionDenied: [String] = []

        for item in targets {
            let path = (toolchainsPath as NSString).appendingPathComponent(item)
            do {
                try fileManager.removeItem(atPath: path)
                removed += 1
            } catch {
                if isPermissionError(error) {
                    permissionDenied.append(path)
                } else {
                    failures.append(item)
                }
            }
        }

        if !permissionDenied.isEmpty {
            let privilegeResult = PrivilegedDeletionHelper.remove(paths: permissionDenied)
            switch privilegeResult {
            case .success:
                removed += permissionDenied.count
            case .cancelled:
                failures.append(contentsOf: permissionDenied)
            case .failure(let message):
                failures.append(contentsOf: permissionDenied)
                return OperationBanner(
                    success: false,
                    message: "Failed to remove toolchains: \(message)",
                    requiresFullDiskAccess: true
                )
            }
        }

        if failures.isEmpty {
            let message = removed == 0
                ? "No third-party toolchains to remove."
                : "Removed \(removed) custom toolchain\(removed == 1 ? "" : "s")."
            return OperationBanner(success: true, message: message, requiresFullDiskAccess: false)
        }

        return OperationBanner(
            success: false,
            message: "Failed to remove \(failures.count) toolchains: \(failures.joined(separator: ", ")).",
            requiresFullDiskAccess: !permissionDenied.isEmpty
        )
    }

    private func expandedPaths(for path: String, home: String) -> [String] {
        let resolved = (path as NSString).expandingTildeInPath
        if resolved.hasPrefix("/") {
            return [resolved]
        }
        return [(home as NSString).appendingPathComponent(resolved)]
    }
}
