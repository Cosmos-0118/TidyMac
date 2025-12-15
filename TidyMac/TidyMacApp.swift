//  Copyright © 2024 TidyMac, LLC. All rights reserved.

import Combine
import SwiftUI

@main
struct TidyMacApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if ProcessInfo.processInfo.environment["UITEST_SEED_DIAGNOSTICS"] == "1" {
            DiagnosticsCenter.shared.preloadForUITests()
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .inactive || phase == .background else { return }
            AppCacheCleaner.clean()
        }
    }
}

// Lightweight cache cleanup invoked during app exit/background transitions.
private enum AppCacheCleaner {
    static func clean(fileManager: FileManager = .default) {
        let bundleID = Bundle.main.bundleIdentifier ?? "TidyMac"
        var targets: [URL] = []

        if let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            targets.append(cacheRoot.appendingPathComponent(bundleID, isDirectory: true))
            targets.append(cacheRoot.appendingPathComponent("TidyMac", isDirectory: true))
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        targets.append(tempRoot.appendingPathComponent(bundleID, isDirectory: true))
        targets.append(tempRoot.appendingPathComponent("TidyMac", isDirectory: true))

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        {
            let container = appSupport.appendingPathComponent("TidyMac", isDirectory: true)
            targets.append(contentsOf: contents(of: container, fileManager: fileManager))
        }

        for target in targets {
            removeIfExists(target, fileManager: fileManager)
        }
    }

    private static func contents(of directory: URL, fileManager: FileManager) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return []
        }
        do {
            return try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            Diagnostics.warning(
                category: .cleanup,
                message: "Failed to enumerate app support cache directory.",
                metadata: ["path": directory.path, "error": String(describing: error)]
            )
            return []
        }
    }

    private static func removeIfExists(_ url: URL, fileManager: FileManager) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        do {
            try fileManager.removeItem(at: url)
            Diagnostics.info(
                category: .cleanup, message: "Cleared app cache on exit.",
                metadata: ["path": url.path])
        } catch {
            Diagnostics.warning(
                category: .cleanup,
                message: "Failed to clear cache on exit.",
                metadata: ["path": url.path, "error": String(describing: error)]
            )
        }
    }
}
