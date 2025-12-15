import XCTest

@testable import TidyMac

final class ApplicationInventoryServiceTests: XCTestCase {
    func testUninstallRespectsExclusionList() async {
        let application = Application(
            name: "DemoApp", bundleID: "com.tidymac.demo", bundlePath: "/Applications/Demo.app")
        let guardMock = BlockingDeletionGuard()
        let service = FileSystemApplicationInventoryService(
            fileManager: FileManager.default,
            deletionGuard: guardMock,
            privilegedDeletion: StubPrivilegedDeletionHandler()
        )

        do {
            try await service.uninstall(application: application)
            XCTFail("Expected uninstall to throw for excluded app")
        } catch let error as ApplicationUninstallError {
            switch error.reason {
            case .generic(let message):
                XCTAssertTrue(message.contains("protected"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertTrue(guardMock.ensureCalled)
    }

    func testUninstallEscalatesPrivilegesOnPermissionError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("NeedsAdmin.app", isDirectory: false)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(repeating: 1, count: 8))

        let guardMock = AllowingDeletionGuard()
        let fileManager = PermissionFailingFileManager()
        fileManager.permissionPaths.insert(fileURL.path)

        let privilegedHandler = RecordingPrivilegedDeletionHandler(result: .success)
        let service = FileSystemApplicationInventoryService(
            fileManager: fileManager,
            deletionGuard: guardMock,
            privilegedDeletion: privilegedHandler
        )

        try await service.uninstall(
            application: Application(
                name: "NeedsAdmin", bundleID: "com.tidymac.demo", bundlePath: fileURL.path))

        XCTAssertEqual(privilegedHandler.lastPaths, [fileURL.path])
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

private final class BlockingDeletionGuard: DeletionGuarding {
    private(set) var ensureCalled = false

    func filter(paths: [String]) throws -> DeletionGuardResult {
        throw DeletionGuardError.excluded(paths: paths)
    }

    func ensureAllowed(path: String) throws {
        ensureCalled = true
        throw DeletionGuardError.excluded(paths: [path])
    }

    func decision(for path: String) -> DeletionGuard.Decision { .excluded }
}

private final class AllowingDeletionGuard: DeletionGuarding {
    func filter(paths: [String]) throws -> DeletionGuardResult {
        DeletionGuardResult(permitted: paths, excluded: [])
    }

    func ensureAllowed(path: String) throws {}

    func decision(for path: String) -> DeletionGuard.Decision { .allow }
}

private struct StubPrivilegedDeletionHandler: PrivilegedDeletionHandling {
    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result { .success }
}

private final class RecordingPrivilegedDeletionHandler: PrivilegedDeletionHandling {
    private(set) var lastPaths: [String] = []
    let result: PrivilegedDeletionHelper.Result

    init(result: PrivilegedDeletionHelper.Result) {
        self.result = result
    }

    func remove(paths: [String]) -> PrivilegedDeletionHelper.Result {
        lastPaths = paths
        return result
    }
}

private final class PermissionFailingFileManager: FileManager {
    var permissionPaths: Set<String> = []

    override func removeItem(atPath path: String) throws {
        if permissionPaths.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        }
        try super.removeItem(atPath: path)
    }
}
