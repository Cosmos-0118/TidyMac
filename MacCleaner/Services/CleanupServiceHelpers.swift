import Foundation
import Darwin

/// Moves the item at `path` to the user's Trash, preserving safety semantics.
func moveToTrash(_ path: String, fileManager: FileManager = .default) throws {
    var resultingURL: NSURL?
    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
}

/// Formats a byte count for human readable logs and telemetry.
func formatByteCount(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB, .useKB]
    return formatter.string(fromByteCount: bytes)
}

/// Returns `true` when the path appears to be an Apple-managed cache protected by SIP or root ownership.
func isSystemProtectedCachePath(_ path: String) -> Bool {
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

/// Determines whether the provided error indicates elevated permissions are required.
func requiresAdministratorPrivileges(_ error: Error) -> Bool {
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
        return cocoaPermissionCodes.contains(nsError.code)
    }
    return false
}
