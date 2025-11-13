//  Copyright © 2024 MacCleaner, LLC. All rights reserved.

import XCTest

final class MacCleanerUITests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests
        // before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_DIAGNOSTICS"] = "1"
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testDiagnosticsButtonExists() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_SEED_DIAGNOSTICS"] = "1"
        app.launch()

        let diagnosticsButton = app.buttons.matching(identifier: "DiagnosticsButton").firstMatch
        XCTAssertTrue(diagnosticsButton.waitForExistence(timeout: 3))
        diagnosticsButton.click()

    let categoryFilter = app.popUpButtons["Diagnostics category filter"]
    XCTAssertTrue(categoryFilter.waitForExistence(timeout: 5))
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
