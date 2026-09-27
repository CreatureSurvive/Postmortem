import XCTest

final class PostmortemUITests: XCTestCase {
    @MainActor
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor
    func testBrowsesAndSymbolicatesReports() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadSamples"]
        app.launch()

        // Every diagnostic kind from the MetricKit-generated fixture is listed.
        XCTAssertTrue(app.staticTexts["NSRangeException"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Hang 4 s"].exists)
        XCTAssertTrue(scrollTo(app.staticTexts["Launch took 2.5 s"], in: app))
        app.swipeDown(); app.swipeDown(); app.swipeDown()

        // The live crash is symbolicated on device, including app code.
        app.staticTexts["EXC_BREAKPOINT (SIGTRAP)"].firstMatch.tap()
        let appSymbol = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'demoLoadUserProfile'")).firstMatch
        XCTAssertTrue(appSymbol.waitForExistence(timeout: 5), "app frames should resolve to their Swift names")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'demoRefreshLibrary'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'force-unwrapping nil'")).firstMatch.exists)
        let uikit = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'UIApplicationMain'")).firstMatch
        XCTAssertTrue(scrollTo(uikit, in: app), "UIKit frames resolve too")
        app.navigationBars.buttons.firstMatch.tap()

        // Metrics.
        let metrics = app.buttons["postmortem.metrics"].firstMatch
        XCTAssertTrue(scrollTo(metrics, in: app))
        metrics.tap()
        XCTAssertTrue(app.staticTexts["Peak Memory"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["310 MB"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'MB'")).firstMatch.exists)
        XCTAssertTrue(scrollTo(app.staticTexts["App Watchdog"], in: app))
    }
}
