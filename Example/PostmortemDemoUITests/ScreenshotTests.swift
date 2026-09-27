import XCTest

/// Captures the README screenshots. Run with `Scripts/screenshots.sh`.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func capture(_ name: String) {
        sleep(1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testViewer() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadSamples"]
        app.launch()
        XCTAssertTrue(app.staticTexts["NSRangeException"].waitForExistence(timeout: 10))
        capture("list")

        app.staticTexts["EXC_BREAKPOINT (SIGTRAP)"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'demoLoadUserProfile'")).firstMatch.waitForExistence(timeout: 5))
        capture("crash")
        app.navigationBars.buttons.firstMatch.tap()

        let metrics = app.buttons["postmortem.metrics"].firstMatch
        for _ in 0..<6 where !(metrics.exists && metrics.isHittable) { app.swipeUp() }
        metrics.tap()
        XCTAssertTrue(app.staticTexts["Peak Memory"].waitForExistence(timeout: 5))
        capture("metrics")
    }
}
