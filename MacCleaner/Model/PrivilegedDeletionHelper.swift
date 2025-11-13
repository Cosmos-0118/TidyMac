//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
import ServiceManagement
import Security

/// Handles elevated removal of protected filesystem items by coordinating with a privileged helper when available,
/// and falling back to AppleScript escalation otherwise.
enum PrivilegedDeletionHelper {
    enum Result {
        case success
        case cancelled
        case failure(message: String)
    }

    static func remove(paths: [String]) -> Result {
        let sanitized = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return .success }

        guard requestUserConfirmation(for: sanitized) else {
            return .cancelled
        }

        let blessedResult = PrivilegedBlessedRemover.shared.remove(paths: sanitized)
        switch blessedResult {
        case .success, .cancelled:
            return blessedResult
        case .failure:
            // Fall back to the AppleScript-based approach so destructive operations still complete when the helper is unavailable.
            return AppleScriptFallbackRemover().remove(paths: sanitized)
        }
    }

    private static func requestUserConfirmation(for paths: [String]) -> Bool {
        #if canImport(AppKit)
        func presentAlert() -> Bool {
            let itemCount = paths.count
            let previewPath = paths.first ?? ""
            let message: String
            if itemCount == 1 {
                message = previewPath
            } else {
                message = "\(previewPath) and \(itemCount - 1) more items"
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Administrator Access Required"
            alert.informativeText = "MacCleaner needs administrator privileges to remove \(itemCount) protected item\(itemCount == 1 ? "" : "s").\n\nAffected path: \(message)"
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            if let app = NSApp, !app.isActive {
                app.activate(ignoringOtherApps: true)
            }

            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }

        if Thread.isMainThread {
            return presentAlert()
        } else {
            var result = false
            DispatchQueue.main.sync {
                result = presentAlert()
            }
            return result
        }
        #else
        return true
        #endif
    }
}

protocol PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result
}

struct PrivilegedDeletionService: PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        PrivilegedDeletionHelper.remove(paths: paths)
    }
}

@objc
private protocol PrivilegedDeletionXPCProtocol {
    func removeItems(at paths: [String], withReply reply: @escaping (Bool, String?) -> Void)
}

private final class PrivilegedBlessedRemover {
    static let shared = PrivilegedBlessedRemover()

    private let helperIdentifier = "com.maccleaner.cleanuphelper"

    private init() { }

    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        guard helperExecutableExists() else {
            #if DEBUG
            NSLog("Privileged helper %@ is not bundled with the app – falling back to AppleScript escalation.", helperIdentifier)
            #endif
            return .failure(message: "Privileged helper is unavailable.")
        }

        let authorizationResult = obtainAuthorization()
        switch authorizationResult {
        case .cancelled:
            return .cancelled
        case .failure:
            return .failure(message: "Unable to obtain administrator authorization.")
        case .success(let authorization):
            defer { AuthorizationFree(authorization, []) }

            // Best-effort helper installation. If this fails we still attempt a connection to detect existing helpers.
            _ = blessHelperIfNeeded(with: authorization)

            var response: PrivilegedDeletionHelper.Result?
            let semaphore = DispatchSemaphore(value: 0)

            guard let connection = PrivilegedHelperConnection(
                helperIdentifier: helperIdentifier,
                errorHandler: { errorMessage in
                    if response == nil {
                        response = .failure(message: errorMessage)
                        semaphore.signal()
                    }
                }
            ) else {
                return .failure(message: "Privileged helper is unavailable.")
            }

            connection.proxy.removeItems(at: paths) { success, message in
                if response == nil {
                    response = success ? .success : .failure(message: message ?? "Privileged helper failed to delete the selected items.")
                    semaphore.signal()
                }
            }

            if semaphore.wait(timeout: .now() + 30) == .timedOut {
                response = .failure(message: "Timed out waiting for privileged helper response.")
            }

            connection.invalidate()
            return response ?? .failure(message: "Privileged helper did not return a response.")
        }
    }

    private func helperExecutableExists() -> Bool {
        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
            .appendingPathComponent(helperIdentifier, isDirectory: false)
            .path
        return FileManager.default.fileExists(atPath: helperPath)
    }

    private enum AuthorizationRequestResult {
        case success(AuthorizationRef)
        case cancelled
        case failure
    }

    private func obtainAuthorization() -> AuthorizationRequestResult {
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [.interactionAllowed], &authRef)
        guard status == errAuthorizationSuccess, let authRef else { return .failure }

        var right = AuthorizationItem(name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0)
        var rights = AuthorizationRights(count: 1, items: &right)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let copyStatus = AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
        switch copyStatus {
        case errAuthorizationSuccess:
            return .success(authRef)
        case errAuthorizationCanceled:
            AuthorizationFree(authRef, [])
            return .cancelled
        default:
            AuthorizationFree(authRef, [])
            return .failure
        }
    }

    private func blessHelperIfNeeded(with authorization: AuthorizationRef) -> Bool {
        var cfError: Unmanaged<CFError>?
        let blessed = SMJobBless(kSMDomainSystemLaunchd, helperIdentifier as CFString, authorization, &cfError)
        if !blessed, let error = cfError?.takeRetainedValue() {
            // For now we simply log the error for debugging builds; functional fallback occurs later.
            #if DEBUG
            NSLog("SMJobBless failed: %@", error.localizedDescription)
            #endif
        }
        return blessed
    }
}

private final class PrivilegedHelperConnection {
    let connection: NSXPCConnection
    let proxy: PrivilegedDeletionXPCProtocol

    init?(helperIdentifier: String, errorHandler: @escaping (String) -> Void) {
        connection = NSXPCConnection(machServiceName: helperIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDeletionXPCProtocol.self)
        connection.interruptionHandler = {
            errorHandler("Privileged helper communication was interrupted.")
        }
        connection.invalidationHandler = {
            errorHandler("Privileged helper connection was invalidated.")
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            errorHandler(error.localizedDescription)
        }) as? PrivilegedDeletionXPCProtocol else {
            connection.invalidate()
            return nil
        }

        self.proxy = proxy
    }

    func invalidate() {
        connection.invalidate()
    }
}

private final class AppleScriptFallbackRemover {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        let quoted = paths.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let command = "rm -rf " + quoted.joined(separator: " ")
        let script = "do shell script \"\(command)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .failure(message: "Unable to request administrator privileges: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch process.terminationStatus {
        case 0:
            return .success
        default:
            if output.localizedCaseInsensitiveContains("User canceled") {
                return .cancelled
            }
            let message = output.isEmpty ? "Administrator command failed." : output
            return .failure(message: message)
        }
    }
}
#else
enum PrivilegedDeletionHelper {
    enum Result {
        case success
        case cancelled
        case failure(message: String)
    }

    static func remove(paths: [String]) -> Result { .failure(message: "Elevated deletion unavailable on this platform.") }
}

protocol PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result
}

struct PrivilegedDeletionService: PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        PrivilegedDeletionHelper.remove(paths: paths)
    }
}
#endif
