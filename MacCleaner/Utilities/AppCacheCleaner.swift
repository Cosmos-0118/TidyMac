import Foundation

enum AppCacheCleaner {
    static func clean(fileManager: FileManager = .default) {
        let bundleID = Bundle.main.bundleIdentifier ?? "MacCleaner"
        var targets: [URL] = []

        if let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            targets.append(cacheRoot.appendingPathComponent(bundleID, isDirectory: true))
            targets.append(cacheRoot.appendingPathComponent("MacCleaner", isDirectory: true))
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        targets.append(tempRoot.appendingPathComponent(bundleID, isDirectory: true))
        targets.append(tempRoot.appendingPathComponent("MacCleaner", isDirectory: true))

        for target in targets {
            removeIfExists(target, fileManager: fileManager)
        }
    }

    private static func removeIfExists(_ url: URL, fileManager: FileManager) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        do {
            try fileManager.removeItem(at: url)
            Diagnostics.info(category: .cleanup, message: "Cleared app cache on exit.", metadata: ["path": url.path])
        } catch {
            Diagnostics.warning(
                category: .cleanup,
                message: "Failed to clear cache on exit.",
                metadata: ["path": url.path, "error": String(describing: error)]
            )
        }
    }
}
