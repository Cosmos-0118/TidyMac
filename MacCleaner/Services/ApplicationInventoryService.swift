import Foundation

struct ApplicationUninstallError: LocalizedError {
    enum Reason {
        case permissionDenied
        case administratorRequired(message: String?)
        case userCancelled
        case generic(message: String)
    }

    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .permissionDenied:
            return "Permission was denied while attempting to uninstall the application."
        case .administratorRequired(let message):
            return message ?? "Administrator privileges are required to remove the selected application."
        case .userCancelled:
            return "The uninstall request was cancelled."
        case .generic(let message):
            return message
        }
    }

    var requiresFullDiskAccess: Bool {
        switch reason {
        case .permissionDenied, .administratorRequired:
            return true
        default:
            return false
        }
    }

    static func permissionDenied() -> ApplicationUninstallError {
        ApplicationUninstallError(reason: .permissionDenied)
    }

    static func administratorRequired(message: String? = nil) -> ApplicationUninstallError {
        ApplicationUninstallError(reason: .administratorRequired(message: message))
    }

    static func userCancelled() -> ApplicationUninstallError {
        ApplicationUninstallError(reason: .userCancelled)
    }

    static func generic(_ message: String) -> ApplicationUninstallError {
        ApplicationUninstallError(reason: .generic(message: message))
    }
}

struct ApplicationRelatedItem: Identifiable, Equatable {
    let id: String
    let path: String
    let description: String
    let isDirectory: Bool

    init(path: String, description: String, isDirectory: Bool) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = standardized
        self.path = standardized
        self.description = description
        self.isDirectory = isDirectory
    }
}

protocol ApplicationInventoryService {
    func fetchApplications() async -> [Application]
    func uninstall(application: Application) async throws
    func relatedItems(for application: Application) async -> [ApplicationRelatedItem]
}

extension ApplicationInventoryService {
    func relatedItems(for application: Application) async -> [ApplicationRelatedItem] { [] }
}

final class FileSystemApplicationInventoryService: ApplicationInventoryService {
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

    func fetchApplications() async -> [Application] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = self.fileManager
                let home = fileManager.homeDirectoryForCurrentUser
                let scanLocations: [URL] = [
                    URL(fileURLWithPath: "/Applications"),
                    URL(fileURLWithPath: "/Applications/Utilities"),
                    URL(fileURLWithPath: "/System/Applications"),
                    home.appendingPathComponent("Applications")
                ]

                var discovered: [Application] = []
                var seenIdentifiers: Set<String> = []

                for location in scanLocations {
                    guard fileManager.fileExists(atPath: location.path) else { continue }
                    guard let urls = try? fileManager.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }

                    for url in urls where url.pathExtension == "app" {
                        let bundle = Bundle(url: url)
                        let bundleID = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
                        let identifier = bundleID + url.path
                        guard seenIdentifiers.insert(identifier).inserted else { continue }

                        let appName = url.deletingPathExtension().lastPathComponent
                        let application = Application(
                            name: appName,
                            bundleID: bundleID,
                            bundlePath: url.path
                        )
                        discovered.append(application)
                    }
                }

                discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                continuation.resume(returning: discovered)
            }
        }
    }

    func relatedItems(for application: Application) async -> [ApplicationRelatedItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let items = self.collectRelatedItems(for: application)
                continuation.resume(returning: items)
            }
        }
    }

    func uninstall(application: Application) async throws {
        let fileManager = self.fileManager
        let path = application.resolvedBundlePath

        do {
            try deletionGuard.ensureAllowed(path: path)
        } catch let guardError as DeletionGuardError {
            switch guardError {
            case .excluded:
                Diagnostics.warning(
                    category: .uninstaller,
                    message: "Uninstall blocked by exclusion list.",
                    metadata: ["application": application.name, "path": path]
                )
                throw ApplicationUninstallError.generic("\(application.name) is protected by your exclusion list.")
            case .restricted:
                Diagnostics.error(
                    category: .uninstaller,
                    message: "Uninstall blocked due to restricted path.",
                    error: guardError,
                    metadata: ["application": application.name, "path": path]
                )
                throw ApplicationUninstallError.generic("Uninstall blocked to protect critical system paths.")
            }
        }

        do {
            try fileManager.removeItem(atPath: path)
            Diagnostics.info(
                category: .uninstaller,
                message: "Uninstalled application without privilege escalation.",
                metadata: ["application": application.name, "path": path]
            )
            return
        } catch {
            if isPermissionError(error) {
                Diagnostics.warning(
                    category: .uninstaller,
                    message: "Attempting privileged uninstall due to permission error.",
                    metadata: ["application": application.name, "path": path]
                )

                let privilegeResult = privilegedDeletion.remove(paths: [path])
                switch privilegeResult {
                case .success:
                    Diagnostics.info(
                        category: .uninstaller,
                        message: "Privileged uninstall succeeded.",
                        metadata: ["application": application.name]
                    )
                    return
                case .cancelled:
                    Diagnostics.warning(
                        category: .uninstaller,
                        message: "Privileged uninstall cancelled by user.",
                        metadata: ["application": application.name]
                    )
                    throw ApplicationUninstallError.userCancelled()
                case .failure(let message):
                    Diagnostics.error(
                        category: .uninstaller,
                        message: "Privileged uninstall failed.",
                        suggestion: message,
                        metadata: ["application": application.name]
                    )
                    throw ApplicationUninstallError.administratorRequired(message: message)
                }
            }

            Diagnostics.error(
                category: .uninstaller,
                message: "Failed to uninstall \(application.name).",
                error: error,
                metadata: ["path": path]
            )
            throw ApplicationUninstallError.generic("Failed to uninstall \(application.name): \(error.localizedDescription)")
        }
    }
}

private extension FileSystemApplicationInventoryService {
    func collectRelatedItems(for application: Application) -> [ApplicationRelatedItem] {
        var results: [ApplicationRelatedItem] = []
        var seen: Set<String> = []
        let fileManager = self.fileManager

        func appendIfExists(_ url: URL, description: String) {
            let standardized = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory) else { return }
            guard seen.insert(standardized).inserted else { return }
            results.append(ApplicationRelatedItem(path: standardized, description: description, isDirectory: isDirectory.boolValue))
        }

        let bundleURL = application.resolvedBundleURL
        var isBundleDirectory: ObjCBool = false
        let bundleExists = fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isBundleDirectory)
        results.append(
            ApplicationRelatedItem(
                path: bundleURL.path,
                description: "Application Bundle",
                isDirectory: bundleExists ? isBundleDirectory.boolValue : true
            )
        )
        seen.insert(bundleURL.standardizedFileURL.path)

        let libraries = libraryRoots()
        // Inspect common Library locations to surface supporting data tied to the application.
        let directoryNames = candidateDirectoryNames(for: application)
        let groupNames = candidateGroupContainerNames(for: application)
        let preferenceIdentifiers = candidatePreferenceIdentifiers(for: application)

        for library in libraries {
            let applicationSupportRoot = library.appendingPathComponent("Application Support", isDirectory: true)
            let cachesRoot = library.appendingPathComponent("Caches", isDirectory: true)
            let logsRoot = library.appendingPathComponent("Logs", isDirectory: true)
            let containersRoot = library.appendingPathComponent("Containers", isDirectory: true)
            let webKitRoot = library.appendingPathComponent("WebKit", isDirectory: true)
            let preferencesRoot = library.appendingPathComponent("Preferences", isDirectory: true)
            let savedStateRoot = library.appendingPathComponent("Saved Application State", isDirectory: true)
            let groupContainersRoot = library.appendingPathComponent("Group Containers", isDirectory: true)

            for name in directoryNames {
                appendIfExists(applicationSupportRoot.appendingPathComponent(name, isDirectory: true), description: "Application Support")
                appendIfExists(cachesRoot.appendingPathComponent(name, isDirectory: true), description: "Caches")
                appendIfExists(logsRoot.appendingPathComponent(name, isDirectory: true), description: "Logs")
                appendIfExists(containersRoot.appendingPathComponent(name, isDirectory: true), description: "Containers")
                appendIfExists(webKitRoot.appendingPathComponent(name, isDirectory: true), description: "WebKit")
            }

            for name in groupNames {
                appendIfExists(groupContainersRoot.appendingPathComponent(name, isDirectory: true), description: "Group Containers")
            }

            for identifier in preferenceIdentifiers {
                appendIfExists(preferencesRoot.appendingPathComponent("\(identifier).plist", isDirectory: false), description: "Preferences")
                appendIfExists(savedStateRoot.appendingPathComponent("\(identifier).savedState", isDirectory: true), description: "Saved Application State")
            }
        }

        let categoryPriority: [String: Int] = [
            "Application Bundle": 0,
            "Containers": 1,
            "Group Containers": 2,
            "Application Support": 3,
            "Caches": 4,
            "Preferences": 5,
            "Saved Application State": 6,
            "Logs": 7,
            "WebKit": 8
        ]

        results.sort { lhs, rhs in
            let leftPriority = categoryPriority[lhs.description] ?? Int.max
            let rightPriority = categoryPriority[rhs.description] ?? Int.max
            if leftPriority == rightPriority {
                return lhs.path < rhs.path
            }
            return leftPriority < rightPriority
        }

        return results
    }

    func libraryRoots() -> [URL] {
        let potentialRoots = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true),
            URL(fileURLWithPath: "/Library", isDirectory: true)
        ]

        return potentialRoots.filter { fileManager.fileExists(atPath: $0.path) }
    }

    func candidateDirectoryNames(for application: Application) -> [String] {
        var names: Set<String> = []

        for candidate in normalizedCandidates(for: application.bundleID) {
            names.insert(candidate)
        }

        for candidate in normalizedCandidates(for: application.name) {
            names.insert(candidate)
        }

        let bundleBase = application.resolvedBundleURL.deletingPathExtension().lastPathComponent
        for candidate in normalizedCandidates(for: bundleBase) {
            names.insert(candidate)
        }

        return names.filter { !$0.isEmpty }.sorted()
    }

    func candidateGroupContainerNames(for application: Application) -> [String] {
        var names: Set<String> = []
        let bundleID = application.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)

        if bundleID.hasPrefix("group.") {
            names.insert(bundleID)
        } else if !bundleID.isEmpty {
            names.insert("group.\(bundleID)")
        }

        return names.sorted()
    }

    func candidatePreferenceIdentifiers(for application: Application) -> [String] {
        var identifiers: Set<String> = []

        for candidate in normalizedCandidates(for: application.bundleID) {
            identifiers.insert(candidate)
        }

        let collapsedName = application.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")

        if !collapsedName.isEmpty {
            identifiers.insert(collapsedName)
        }

        return identifiers.sorted()
    }

    func normalizedCandidates(for rawValue: String) -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var variants: Set<String> = [trimmed]

        let noSpaces = trimmed.replacingOccurrences(of: " ", with: "")
        if !noSpaces.isEmpty {
            variants.insert(noSpaces)
        }

        let dashed = trimmed.replacingOccurrences(of: " ", with: "-")
        if !dashed.isEmpty {
            variants.insert(dashed)
        }

        let underscored = trimmed.replacingOccurrences(of: " ", with: "_")
        if !underscored.isEmpty {
            variants.insert(underscored)
        }

        variants.insert(trimmed.lowercased())

        return variants.filter { !$0.isEmpty }.sorted()
    }
}
