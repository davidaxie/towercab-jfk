import XCTest

// =============================================================================
// SettingsUITests — the persisted sound setting, through the real UI.
//
// Covers what a player actually experiences: sound is OFF on a fresh install
// (the slice's soundscape is programmer-synthesized, PRD §5 budgets a real
// audio pass), the toggle flips it, and the choice survives a relaunch.
//
// Run against a freshly installed app so the "default" assertion is meaningful:
//   xcrun simctl uninstall <dev> com.davidxie.towercab-slammed
//   xcodebuild test -only-testing:TowerCabSlammedUITests/SettingsUITests ...
// =============================================================================

final class SettingsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// The start-screen toggle, which doubles as the readout of the setting.
    private func soundToggle(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["soundToggle"]
    }

    private func launchToStartScreen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(soundToggle(app).waitForExistence(timeout: 20),
                      "start screen should offer the sound toggle")
        return app
    }

    func testSoundDefaultsOffAndPersistsAcrossLaunches() {
        // 1. Fresh install ⇒ sound off.
        var app = launchToStartScreen()
        XCTAssertEqual(soundToggle(app).label, "SOUND OFF",
                       "sound must default to OFF while the soundscape is programmer audio")

        // 2. Turning it on takes effect immediately.
        soundToggle(app).tap()
        XCTAssertEqual(soundToggle(app).label, "SOUND ON")
        app.terminate()

        // 3. …and survives a relaunch.
        app = launchToStartScreen()
        XCTAssertEqual(soundToggle(app).label, "SOUND ON",
                       "the ON choice should persist across launches")

        // 4. Turning it back off persists too (so the default isn't just
        //    "nothing was ever written").
        soundToggle(app).tap()
        XCTAssertEqual(soundToggle(app).label, "SOUND OFF")
        app.terminate()

        app = launchToStartScreen()
        XCTAssertEqual(soundToggle(app).label, "SOUND OFF",
                       "the OFF choice should persist across launches")
    }

    /// The in-shift speaker button mirrors the same setting, so the player can
    /// silence the game without leaving the cab.
    func testTopBarSoundButtonMirrorsTheSetting() {
        let app = launchToStartScreen()
        let startingState = soundToggle(app).label

        app.buttons["startShift"].tap()
        let speaker = app.buttons["soundButton"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 20),
                      "the top bar should carry the sound control in-shift")
        XCTAssertEqual(speaker.label,
                       startingState == "SOUND ON" ? "Sound on" : "Sound off",
                       "the top-bar speaker must reflect the same persisted setting")

        speaker.tap()
        XCTAssertEqual(speaker.label,
                       startingState == "SOUND ON" ? "Sound off" : "Sound on",
                       "tapping the speaker should flip the setting in place")
    }
}
