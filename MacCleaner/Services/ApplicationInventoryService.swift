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

protocol ApplicationInventoryService {
    func fetchApplications() async -> [Application]
    func uninstall(application: Application) async throws
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
