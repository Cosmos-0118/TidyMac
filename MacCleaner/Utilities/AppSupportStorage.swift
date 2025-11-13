import Foundation

enum AppSupportStorage {
    private static let directoryName = "MacCleaner"

    private static var containerURL: URL {
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let baseURL = urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let container = baseURL.appendingPathComponent(directoryName, isDirectory: true)

        if !fileManager.fileExists(atPath: container.path) {
            do {
                try fileManager.createDirectory(at: container, withIntermediateDirectories: true, attributes: nil)
            } catch {
                let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent(directoryName, isDirectory: true)
                if !fileManager.fileExists(atPath: fallback.path) {
                    try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: nil)
                }
                return fallback
            }
        }

        return container
    }

    static func fileURL(named fileName: String) -> URL {
        containerURL.appendingPathComponent(fileName, isDirectory: false)
    }
}
