# TowerCab: Slammed, developer notes

Notes for working on the code. What the game is and how to play it are in the
[root README](../README.md).

## Build

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPad
Simulator or iPad on iPadOS 17 or later. There are no third-party dependencies and no asset files:
every model, texture and sound is generated in code.

```bash
cd towercab-slammed
xcodegen generate               # only needed after adding or removing source files
open TowerCabSlammed.xcodeproj   # run the TowerCabSlammed scheme on an iPad, landscape
```

## Source layout

- `TowerCabSlammed/Sim/`: the deterministic core. Pure Swift (Foundation and simd only), a fixed
  10 Hz tick, a seeded xoshiro256** generator and no wall clock. Commands are timestamped at input
  and applied on the next tick.
- `TowerCabSlammed/World/`: the SceneKit world, built in code (airport, terrain, water, sky, cab
  interior and every aircraft model).
- `TowerCabSlammed/UI/`: the SwiftUI HUD (strip rail, radial verb menu, radio log, start and score
  screens). It talks to the game only through `UIState` and `GameActions`
  (`UI/UIStateBridge.swift`).
- `TowerCabSlammed/App/` and `TowerCabSlammed/Presentation/`: the loop. A CADisplayLink at 60 fps
  advances the sim, interpolates render states, updates entities and syncs the HUD. `CameraRig`
  owns the cab camera.
- `TowerCabSlammed/Audio/`: the procedural `AVAudioEngine` soundscape. Sound is off by default
  (`App/GameSettings.swift`); when it is off the engine is never started.

## Headless harnesses

The sim imports no UI frameworks, so it compiles on its own with the tools in `Tools/`. Run these
from `towercab-slammed/`:

```bash
swiftc -O -o /tmp/simtest   TowerCabSlammed/Sim/*.swift Tools/simharness.swift && /tmp/simtest
swiftc -O -o /tmp/fuzz      TowerCabSlammed/Sim/*.swift Tools/fuzz.swift       && /tmp/fuzz
swiftc -O -o /tmp/probekjfk TowerCabSlammed/Sim/*.swift Tools/probe-kjfk.swift && /tmp/probekjfk
```

- `simharness.swift`: five scenarios. A, a competent auto-controller shift (at least 8 movements,
  no NaN, everything resolves, score above zero); B, determinism (same seed, identical tick by
  tick); C, neglect (pilot go-arounds fire, the shift force-ends cleanly); D, an engineered SAVE;
  E, a 200-seed separation sweep. Scenario A currently reports `movements 7 < 8` at KJFK. That is
  the known ground-throughput finding in `AUDIT-KJFK.md` (section C5), and the threshold is left
  as it is on purpose.
- `fuzz.swift`: random legal commands at random aircraft every tick across 120 seeds. It asserts
  no non-finite state, nothing below ground or outside the speed and altitude envelope, no runaway
  score, that every shift terminates, and that determinism holds.
- `probe-kjfk.swift`: not pass or fail. It prints 40-seed distributions of touchdown point, float,
  runway occupancy, exit choice, taxi-in time, strip-cap saturation and throughput.

## UI tests

`UITests/` drives XCUITest through the real touch layer:

- `PlaythroughUITests`: cold start to first command, and a full shift to the score screen and a
  restart.
- `SettingsUITests`: sound defaults to off, persists across launches, and the top-bar button
  mirrors the setting.
- `CaptureMatrixUITests`: a reproducible screenshot matrix. Each capture relaunches the app with
  a different debug pose. A camera moved with `-campos` also needs `-hide cab`, or the frame is
  the inside of the cab.

```bash
xcodebuild test -project TowerCabSlammed.xcodeproj -scheme TowerCabSlammed \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -derivedDataPath <dd>
```

Keep the DerivedData path outside any cloud-synced folder. Add
`-only-testing:TowerCabSlammedUITests/CaptureMatrixUITests -resultBundlePath <out>.xcresult` to
run just the matrix, then `xcrun xcresulttool export attachments --path <out>.xcresult
--output-path shots/` to pull out the images.

## Debug launch arguments

Set these on the scheme's Run arguments (or pass them from a UI test).

| Argument | Effect |
| --- | --- |
| `-autostart` | Skip the start screen and begin a shift |
| `-seed <n>` | Fix the shift seed |
| `-ff <s>` | Fast-forward the sim by `s` seconds after `-autostart` |
| `-autopilot` | A demo controller plays the shift |
| `-openbloom` | Open the radial menu on the first airborne aircraft |
| `-hour <h>` | Pin the sky clock, for example `18.4` |
| `-yaw <deg>`, `-pitch <deg>`, `-fov <deg>` | Pose the camera |
| `-campos x,y,z` | Move the camera mount (pair it with `-hide cab`) |
| `-hide <a,b>` | Hide scene nodes whose names contain any of the tokens |
| `-follow <phase> [KIND]` | Lock the camera onto the first aircraft in that strip phase, optionally of that type |
| `-turntable <KIND> [PHASE]` | Skip the shift and spin one posed aircraft in front of the cab |
| `-nobloom` | Turn off camera bloom |
| `-stats` | Show SceneKit statistics |
| `-audiolog` | Log the master mix level |

## Running on an iPad

`scripts/run-on-device.sh <TEAM_ID> [--launch]` regenerates the project (when XcodeGen is
installed), builds with your signing team and installs to a connected iPad. A free personal team works for a 7-day build. Frame rate,
touch feel and spatial audio on headphones can only be checked on hardware.

## Audits

`AUDIT.md` is the first player-seat audit, run against the KAVX Catalina build (about 110 findings,
all four fix stages landed). `AUDIT-KJFK.md` re-runs it after the move to KJFK, with measured
before and after numbers and the open items. The two commit hashes it cites (`acc5264` and
`451a53a`) are from before this repository's history was rewritten; in this history they are
`2157cc4` ("Graphics overhaul + 16-type real-aircraft fleet foundation") and `2c0ed8a` ("Re-base
to KJFK + all-airliner fleet").
