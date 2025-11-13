@testable import MacCleaner
import Foundation
import XCTest

final class SystemCacheCleanupServiceTests: XCTestCase {
    func testScanReturnsDirectorySummary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheDirectory = directory.appendingPathComponent("CacheTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let fileURL = cacheDirectory.appendingPathComponent("sample.cache")
        try Data("cache".utf8).write(to: fileURL)

        let service = SystemCacheCleanupService(
            fileManager: FileManager.default,
            deletionGuard: AllowingDeletionGuard(),
            privilegedDeletion: NoopPrivilegedDeletionHandler(),
            targets: [(path: cacheDirectory.path, name: "TempCache")]
        )

        let category = await service.scan()

        XCTAssertEqual(category.items.count, 1)
        XCTAssertEqual(category.items.first?.name, "TempCache")
        XCTAssertEqual(category.items.first?.path, cacheDirectory.path)
        XCTAssertEqual(category.items.first?.detail, "1 top-level items")
        XCTAssertNil(category.error)
    }

    func testExecuteDryRunCountsItems() async throws {
        let (root, cacheDirectory, _) = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = CleanupCategory.CleanupItem(path: cacheDirectory.path, name: "TempCache", size: nil, detail: nil)
        let service = SystemCacheCleanupService(
            fileManager: FileManager.default,
            deletionGuard: AllowingDeletionGuard(),
            privilegedDeletion: NoopPrivilegedDeletionHandler(),
            targets: [(path: cacheDirectory.path, name: "TempCache")]
        )

        let outcome = await service.execute(
            items: [item],
            dryRun: true,
            progressTracker: CleanupProgress(initialTotal: 1),
            progressUpdate: { _ in }
        )

        XCTAssertTrue(outcome.success)
        XCTAssertTrue(outcome.message.contains("Dry run: 2 cache items selected"))
    }

    func testExecuteHandlesRestrictedPaths() async throws {
        let (root, cacheDirectory, _) = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = CleanupCategory.CleanupItem(path: cacheDirectory.path, name: "TempCache", size: nil, detail: nil)
        let service = SystemCacheCleanupService(
            fileManager: FileManager.default,
            deletionGuard: RestrictedDeletionGuard(),
            privilegedDeletion: NoopPrivilegedDeletionHandler(),
            targets: [(path: cacheDirectory.path, name: "TempCache")]
        )

        let outcome = await service.execute(
            items: [item],
            dryRun: false,
            progressTracker: CleanupProgress(initialTotal: 1),
            progressUpdate: { _ in }
        )

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.message.contains("Deletion blocked"))
        XCTAssertNotNil(outcome.recoverySuggestion)
    }

    func testExecuteDeletesFilesWhenAllowed() async throws {
        let (root, cacheDirectory, fileURLs) = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let privilegedHandler = TrackingPrivilegedDeletionHandler()
        let item = CleanupCategory.CleanupItem(path: cacheDirectory.path, name: "TempCache", size: nil, detail: nil)
        let service = SystemCacheCleanupService(
            fileManager: FileManager.default,
            deletionGuard: AllowingDeletionGuard(),
            privilegedDeletion: privilegedHandler,
            targets: [(path: cacheDirectory.path, name: "TempCache")]
        )

        let outcome = await service.execute(
            items: [item],
            dryRun: false,
            progressTracker: CleanupProgress(initialTotal: 1),
            progressUpdate: { _ in }
        )

        XCTAssertTrue(outcome.success)
        XCTAssertTrue(outcome.message.contains("Removed 2 cache items"))
        XCTAssertTrue(privilegedHandler.requestedPaths.isEmpty)
        for url in fileURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    let remaining = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeCacheDirectory() throws -> (root: URL, cache: URL, files: [URL]) {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("CacheTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let first = directory.appendingPathComponent("a.tmp")
        let second = directory.appendingPathComponent("b.tmp")
        try Data("alpha".utf8).write(to: first)
        try Data("beta".utf8).write(to: second)

        return (root, directory, [first, second])
    }
}

// MARK: - Test Doubles

private final class AllowingDeletionGuard: DeletionGuarding {
    func filter(paths: [String]) throws -> DeletionGuardResult {
        DeletionGuardResult(permitted: paths.map(normalize), excluded: [])
    }

    func ensureAllowed(path: String) throws { }

    func decision(for path: String) -> DeletionGuard.Decision { .allow }

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private final class RestrictedDeletionGuard: DeletionGuarding {
    func filter(paths: [String]) throws -> DeletionGuardResult {
        throw DeletionGuardError.restricted(paths: paths)
    }

    func ensureAllowed(path: String) throws {
        throw DeletionGuardError.restricted(paths: [path])
    }

    func decision(for path: String) -> DeletionGuard.Decision { .restricted }
}

private struct NoopPrivilegedDeletionHandler: PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result { .success }
}

private final class TrackingPrivilegedDeletionHandler: PrivilegedDeletionHandling {
    private(set) var requestedPaths: [String] = []

    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        requestedPaths.append(contentsOf: paths)
        return .success
    }
}
