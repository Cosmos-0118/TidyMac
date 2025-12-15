import XCTest

@testable import TidyMac

final class LargeFileScanningServiceTests: XCTestCase {
    func testScanFindsLargeFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("sample.dat")
        let data = Data(repeating: 1, count: 2_048)
        FileManager.default.createFile(atPath: fileURL.path, contents: data)

        let oldDate = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? Date()
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: fileURL.path)

        let service = FileSystemLargeFileScanningService(
            fileManager: FileManager.default,
            candidateDirectories: [directory]
        )

        let result = await service.scan(
            thresholdBytes: 1_024,
            olderThanDays: 30,
            maxResults: 10
        ) { _ in }

        XCTAssertEqual(result.files.count, 1)
        let actualPath = (result.files.first?.path ?? "") as NSString
        let expectedPath = fileURL.path as NSString
        XCTAssertEqual(actualPath.resolvingSymlinksInPath, expectedPath.resolvingSymlinksInPath)
        XCTAssertFalse(result.permissionIssue)
    }

    func testDeleteThrowsForExcludedPaths() {
        let path = "/tmp/protected"
        let guardMock = MockDeletionGuard(
            result: DeletionGuardResult(permitted: [], excluded: [path]))
        let service = FileSystemLargeFileScanningService(
            fileManager: FileManager.default,
            deletionGuard: guardMock,
            privilegedDeletion: StubPrivilegedDeletionHandler()
        )

        XCTAssertThrowsError(try service.delete(paths: [path])) { error in
            guard case DeletionGuardError.excluded(let paths) = error else {
                return XCTFail("Expected exclusion error")
            }
            XCTAssertEqual(paths, [path])
        }
    }

    func testDeletePropagatesPrivilegedFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("locked.log")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("lock".utf8))

        let guardMock = MockDeletionGuard(
            result: DeletionGuardResult(permitted: [fileURL.path], excluded: []))
        let fileManager = MockFileManager()
        fileManager.permissionErrorPaths.insert(fileURL.path)

        let privileged = MockPrivilegedDeletionHandler(result: .failure(message: "Mock failure"))
        let service = FileSystemLargeFileScanningService(
            fileManager: fileManager,
            deletionGuard: guardMock,
            privilegedDeletion: privileged
        )

        XCTAssertThrowsError(try service.delete(paths: [fileURL.path])) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "com.tidymac.largefiles")
            XCTAssertEqual(nsError.code, 3)
            XCTAssertEqual(nsError.userInfo[NSLocalizedDescriptionKey] as? String, "Mock failure")
        }
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Test Doubles

private final class MockDeletionGuard: DeletionGuarding {
    var lastFilteredPaths: [String] = []
    let result: DeletionGuardResult

    init(result: DeletionGuardResult) {
        self.result = result
    }

    func filter(paths: [String]) throws -> DeletionGuardResult {
        lastFilteredPaths = paths
        if result.permitted.isEmpty, result.excluded.isEmpty {
            throw DeletionGuardError.restricted(paths: paths)
        }
        return result
    }

    func ensureAllowed(path: String) throws {
        _ = try filter(paths: [path])
    }

    func decision(for path: String) -> DeletionGuard.Decision {
        if result.excluded.contains(path) {
            return .excluded
        }
        if result.permitted.contains(path) {
            return .allow
        }
        return .restricted
    }
}

private struct StubPrivilegedDeletionHandler: PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result { .success }
}

private final class MockPrivilegedDeletionHandler: PrivilegedDeletionHandling {
    var lastPaths: [String] = []
    let result: PrivilegedDeletionHelper.Result

    init(result: PrivilegedDeletionHelper.Result) {
        self.result = result
    }

    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        lastPaths = paths
        return result
    }
}

private final class MockFileManager: FileManager {
    var permissionErrorPaths: Set<String> = []
    var trashedPaths: [String] = []

    override func removeItem(atPath path: String) throws {
        if permissionErrorPaths.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        }
        try super.removeItem(atPath: path)
    }

    override func trashItem(
        at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        if permissionErrorPaths.contains(url.path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        }
        trashedPaths.append(url.path)
        try super.removeItem(at: url)
    }
}
