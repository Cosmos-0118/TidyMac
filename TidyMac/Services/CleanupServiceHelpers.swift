import Foundation
import Darwin
#if canImport(CryptoKit)
import CryptoKit
#endif

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

/// Generates a stable content hash for the file at `path` using SHA256. Returns `nil` if the file cannot be read.
func contentHash(forFileAt path: String, bufferSize: Int = 64 * 1024) -> String? {
#if canImport(CryptoKit)
    guard let stream = InputStream(fileAtPath: path) else { return nil }
    stream.open()
    defer { stream.close() }

    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var hasher = CryptoKit.SHA256()
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read < 0 { return nil }
        if read == 0 { break }
        hasher.update(data: Data(buffer[0..<read]))
    }
    return digestToHex(hasher.finalize())
#else
    return nil
#endif
}

#if canImport(CryptoKit)
private func digestToHex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
#endif

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
