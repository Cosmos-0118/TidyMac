@testable import MacCleaner
import Foundation
import XCTest

final class CleanupInventoryServiceTests: XCTestCase {
    private var fileManager: FileManager!
    private var tempRoot: URL!
    private var environment: CleanupInventoryEnvironment!

    override func setUpWithError() throws {
        fileManager = FileManager()
        tempRoot = fileManager.temporaryDirectory.appendingPathComponent("cleanup-inventory-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let home = tempRoot.appendingPathComponent("Home", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let applicationSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        let webKit = library.appendingPathComponent("WebKit", isDirectory: true)
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        let shared = tempRoot.appendingPathComponent("Shared", isDirectory: true)

        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: webKit, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: preferences, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)

        environment = CleanupInventoryEnvironment(
            homeDirectory: home,
            libraryDirectory: library,
            applicationSupportDirectory: applicationSupport,
            cachesDirectory: caches,
            webKitDirectory: webKit,
            preferencesDirectory: preferences,
            sharedDirectory: shared
        )
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? fileManager.removeItem(at: tempRoot)
        }
        environment = nil
        fileManager = nil
        tempRoot = nil
    }

    func testPhaseOneInventoryFindsExpectedCandidates() throws {
        let orphanSupport = environment.applicationSupportDirectory.appendingPathComponent("OrphanedHelper", isDirectory: true)
        try fileManager.createDirectory(at: orphanSupport, withIntermediateDirectories: true)
        let orphanFile = orphanSupport.appendingPathComponent("data.cache")
        try Data("sample".utf8).write(to: orphanFile)

        let staleDate = Calendar.current.date(byAdding: .day, value: -200, to: Date()) ?? Date(timeIntervalSince1970: 0)
        try fileManager.setAttributes([.modificationDate: staleDate], ofItemAtPath: orphanFile.path)
        try fileManager.setAttributes([.modificationDate: staleDate], ofItemAtPath: orphanSupport.path)

        let preferenceFile = environment.preferencesDirectory.appendingPathComponent("com.example.Orphaned.plist")
        try Data("{}".utf8).write(to: preferenceFile)
        try fileManager.setAttributes([.modificationDate: staleDate], ofItemAtPath: preferenceFile.path)

        let chromeCache = environment.cachesDirectory.appendingPathComponent("com.google.Chrome", isDirectory: true)
        try fileManager.createDirectory(at: chromeCache, withIntermediateDirectories: true)
        let cacheFile = chromeCache.appendingPathComponent("Cache.data")
        try Data(repeating: 0x0, count: 64).write(to: cacheFile)

        let sharedInstaller = environment.sharedDirectory.appendingPathComponent("LegacyInstaller.dmg")
        try Data(repeating: 0x1, count: 128).write(to: sharedInstaller)

        let installedApplications: [Application] = [
            Application(name: "Google Chrome", bundleID: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app"),
            Application(name: "ExampleApp", bundleID: "com.example.App", bundlePath: "/Applications/ExampleApp.app")
        ]

        let runningProvider = StubRunningApplicationsProvider(applications: [])

        let service = CleanupInventoryService(
            fileManager: fileManager,
            environment: environment,
            installedApplications: installedApplications,
            runningApplicationsProvider: runningProvider
        )

        let result = service.discoverCandidates()
        XCTAssertTrue(result.permissionDenied.isEmpty)

        let paths = Set(result.candidates.map { $0.path })
        XCTAssertTrue(paths.contains(orphanSupport.path), "Expected orphaned Application Support directory to be flagged")
        XCTAssertTrue(paths.contains(preferenceFile.path), "Expected orphaned preference to be flagged")
        XCTAssertTrue(paths.contains(chromeCache.path), "Expected browser cache to be included")
        XCTAssertTrue(paths.contains(sharedInstaller.path), "Expected shared installer to be detected")

        let categories = Dictionary(grouping: result.candidates, by: \CleanupCandidate.category)
        XCTAssertNotNil(categories[.browserCaches])
        XCTAssertNotNil(categories[.orphanedApplicationSupport])
        XCTAssertNotNil(categories[.orphanedPreferences])
        XCTAssertNotNil(categories[.sharedInstallers])

        if let preferenceCandidate = result.candidates.first(where: { $0.path == preferenceFile.path }) {
            XCTAssertEqual(preferenceCandidate.reasons.first?.id, "orphan-preference")
        }
    }
}

private struct StubRunningApplicationsProvider: RunningApplicationsProviding {
    let applications: [RunningApplicationSnapshot]

    init(applications: [RunningApplicationSnapshot]) {
        self.applications = applications
    }

    func runningApplications() -> [RunningApplicationSnapshot] {
        applications
    }
}
