//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import SwiftUI

@main
struct MacCleanerApp: App {
    init() {
        if ProcessInfo.processInfo.environment["UITEST_SEED_DIAGNOSTICS"] == "1" {
            DiagnosticsCenter.shared.preloadForUITests()
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
