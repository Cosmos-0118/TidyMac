//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

@main
struct MacCleanerApp: App {
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
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            AppCacheCleaner.clean()
        }
#endif
    }
}
