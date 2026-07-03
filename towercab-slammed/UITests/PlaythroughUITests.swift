import XCTest

// =============================================================================
// Real-touch playthrough — exercises the actual gesture layer the way a
// player's fingers would: start button, strip tap → bloom → verb, camera pan,
// scene-tap dismissal, and the end-of-shift score screen.
// =============================================================================

final class PlaythroughUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdStartToFirstCommand() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. Start screen → START SHIFT tap works.
        let start = app.buttons["startShift"]
        XCTAssertTrue(start.waitForExistence(timeout: 12), "start screen should show")
        start.tap()
        attach(app, "01-after-start")

        // 2. A strip appears on the rail within the first spawn window.
        let strip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'strip-'")).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 40), "first strip should appear")

        // 3. Tap the strip → radial bloom opens with at least one verb.
        strip.tap()
        let verb = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'verb-'")).firstMatch
        XCTAssertTrue(verb.waitForExistence(timeout: 6),
                      "tapping a strip should open the verb bloom")
        attach(app, "02-bloom-open")

        // 4. Fire the verb — bloom should dismiss (command accepted).
        verb.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'verb-'"))
                .firstMatch.exists,
            "bloom should dismiss after issuing a verb")
        attach(app, "03-after-verb")

        // 5. Camera pan across empty scene must not be blocked by the HUD.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        from.press(forDuration: 0.05, thenDragTo: to)
        attach(app, "04-after-pan")

        // 6. Tap open sky — no bloom should appear, nothing should crash.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "05-end")
    }

    func testShiftEndsAtScoreScreenAndNextShiftRestarts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-autostart", "-autopilot", "-ff", "555"]
        app.launch()

        let next = app.buttons["nextShift"]
        XCTAssertTrue(next.waitForExistence(timeout: 30),
                      "score screen should appear after the shift resolves")
        attach(app, "06-score-screen")

        next.tap()
        let strip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'strip-'")).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 40),
                      "NEXT SHIFT should start a fresh playable shift")
        attach(app, "07-next-shift-running")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
