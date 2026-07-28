import XCTest

// =============================================================================
// CaptureMatrixUITests — the audit screenshot rig (KJFK re-base audit, 2026-07).
//
// simctl screenshots come out portrait-letterboxed because the booted device
// sits in portrait; XCUIDevice forces landscape, which is the only orientation
// the app ships. Each capture relaunches the app with a different debug pose so
// the matrix is reproducible.
//
// NOTE on posed cameras: -campos moves `world.cabMount`, and the cab interior
// is parented to it — so ANY repositioned camera must also pass `-hide cab` or
// the frame is the inside of the cab. The hide token is a lowercased SUBSTRING
// match over node names ("cab" catches cabInterior *and* cabMount).
//
// Run:
//   xcodebuild test -project TowerCabSlammed.xcodeproj -scheme TowerCabSlammed \
//     -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
//     -only-testing:TowerCabSlammedUITests/CaptureMatrixUITests -derivedDataPath <dd> \
//     -resultBundlePath <out>.xcresult
// Then:
//   xcrun xcresulttool export attachments --path <out>.xcresult --output-path shots/
// =============================================================================

final class CaptureMatrixUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func capture(_ name: String, args: [String], settle: TimeInterval = 6) {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = app.wait(for: .runningForeground, timeout: 30)
        Thread.sleep(forTimeInterval: settle)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    // MARK: The decisive pair — is the airport surface buried under the field plate?

    /// Top-down with the cab hidden. `fieldPlate` (ground, lift 0.12 m) is still
    /// present; every piece of pavement is authored at lift 0.02–0.065 m, so on
    /// the FLAT KJFK field (groundHeight ≡ 0) the plate should occlude all of it.
    func testA1TopDownPlatePresent() {
        capture("A1-topdown-plate-present",
                args: ["-autostart", "-autopilot", "-ff", "150", "-seed", "4242",
                       "-campos", "0,3000,0", "-pitch", "-89", "-yaw", "301", "-fov", "65",
                       "-hide", "cab"])
    }

    /// Same pose with the field plate (and its skirt) hidden. If the runway,
    /// taxiways, apron and box runways appear here but not above, the pavement
    /// is being buried rather than missing.
    func testA2TopDownPlateHidden() {
        capture("A2-topdown-plate-hidden",
                args: ["-autostart", "-autopilot", "-ff", "150", "-seed", "4242",
                       "-campos", "0,3000,0", "-pitch", "-89", "-yaw", "301", "-fov", "65",
                       "-hide", "cab,field"])
    }

    /// Oblique, plate hidden — layout legibility, Terminal City, skyline.
    func testA3ObliquePlateHidden() {
        capture("A3-oblique-plate-hidden",
                args: ["-autostart", "-autopilot", "-ff", "150", "-seed", "4242",
                       "-campos", "1500,700,2600", "-pitch", "-16", "-yaw", "301", "-fov", "65",
                       "-hide", "cab,field"])
    }

    // MARK: The real player view (cab eye, no camera relocation)

    /// The frame a player actually opens the game to — nothing posed.
    func testB1DefaultFirstImpression() {
        capture("B1-default-first-impression", args: ["-autostart", "-seed", "4242"])
    }

    /// Mid-shift from the shipped default pose, traffic flowing.
    func testB2CabMidShift() {
        capture("B2-cab-mid-shift",
                args: ["-autostart", "-autopilot", "-ff", "150", "-seed", "4242"])
    }

    /// Panned from the cab eye toward the runway (the cab sits ~900 m off the
    /// centerline at station 2200): can the player see the surface they work?
    func testB3LookAtRunway() {
        capture("B3-look-at-runway",
                args: ["-autostart", "-autopilot", "-ff", "180", "-seed", "4242",
                       "-yaw", "211", "-pitch", "-11", "-fov", "62"])
    }

    /// The crescendo — the rail at its fullest, the busiest frame in the game.
    func testB4Crescendo() {
        capture("B4-crescendo",
                args: ["-autostart", "-autopilot", "-ff", "240", "-seed", "4242"])
    }

    /// The radial bloom open on a live aircraft (verb legibility under pressure).
    func testB5RadialBloom() {
        capture("B5-radial-bloom",
                args: ["-autostart", "-autopilot", "-ff", "200", "-seed", "4242", "-openbloom"])
    }

    /// The end-of-shift score card.
    func testB6ScoreScreen() {
        capture("B6-score-screen",
                args: ["-autostart", "-autopilot", "-ff", "600", "-seed", "4242"],
                settle: 12)
    }
}
