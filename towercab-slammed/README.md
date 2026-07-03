# TowerCab: Slammed — Vertical-Slice Prototype (iPad)

A premium, entertainment-only 3D tower-control game. You stand in a fictional
tower cab above **KAVX — Catalina "Airport in the Sky"** at golden hour and run
a 6-minute score-attack shift: sequencing arrivals and departures with a
strip rail and radial-bloom touch verbs, chasing tight-but-safe gaps.

This is the playable **vertical-slice prototype** for the full PRD at
`docs/TowerCab-Slammed-PRD.md` (in the project folder, outside this repo path):
one airport, one shift, strips + clearances + streak scoring, POV locked to the
cab. Entertainment only — no training claims, no realism toggles.

## Run it

Requirements: Xcode 26+, iPad simulator (or any iPad on iPadOS 17+). No
external dependencies, no assets — every texture and model is generated in code.

```bash
cd towercab-slammed
xcodegen generate          # only needed if you add/remove source files
open TowerCabSlammed.xcodeproj
# Build & run the TowerCabSlammed scheme on an iPad destination (landscape)
```

Headless sim tests (pure Swift, no Xcode project needed):

```bash
cd towercab-slammed
swiftc -O -o /tmp/simtest TowerCabSlammed/Sim/*.swift Tools/simharness.swift && /tmp/simtest
```

## How to play

- **Tap a strip (right rail) or an aircraft** → a radial of context-legal verbs
  blooms around the plane: cleared to land, go around, extend downwind, 360,
  line up & wait, cleared for (immediate) takeoff, hold, expedite exit.
- **Drag** to look around the cab, **pinch** to zoom (20°–110° FOV),
  **double-tap a strip** to swing the camera onto that aircraft.
- **Swipe a completed (teal) strip right** to hand it off and clean your rail.
- Scoring is style over survival: tight gaps pay in the **amber band**
  (watch the Gap Arc seconds on the strips), go-arounds on a projected conflict
  mint a **SAVE +750**, sustained red kills your streak. The shift ramps to a
  "slammed" crescendo, then the score screen grades Flow / Precision / Cool /
  Frequency.

## Architecture (mirrors PRD §9)

- `Sim/` — **deterministic fixed 10 Hz sim core**, pure Swift (Foundation+simd
  only, seeded xoshiro RNG, no wall clock). Commands are timestamped at input
  and applied on the next tick; presentation interpolates. Runs headless on
  macOS for the test harness in `Tools/`.
- `World/` — SceneKit "Luminous Diorama": procedural Catalina mesa + Pacific,
  physically-based golden-hour sky/sun driven at 12× time (a dawn shift ends in
  dusk light), PBR airport surfaces sampling the same `groundHeight()` the sim
  uses (the midfield hump genuinely hides the far threshold), procedural
  aircraft (Lark 72 / Vela 22 / Comet 60) with fictional liveries, and the cab
  interior (static geometry around the eye — panning gives parallax for free).
- `UI/` — SwiftUI HUD over the SCNView: strip rail (≤9 strips, Gap Arcs),
  world-anchored radial bloom, badge toasts, radio log, score screen. Talks to
  the game only through `UIState`/`GameActions` (`UI/UIStateBridge.swift`).
- `App/` + `Presentation/` — the loop: CADisplayLink at 60 fps drives sim
  advance → interpolated render states → entities → HUD sync; `CameraRig` owns
  the cab cam (inertial pan/zoom, 400 ms strip-snap framing).

### Engine note (deviation from PRD §9.1, deliberate)

The PRD locks **Unity 6 + URP** as the production engine — that call stands for
the full build (team iteration speed, contractor pool, editor-driven art).
This slice is **native Swift + SceneKit** because it was built and visually
verified on a machine with Xcode but no Unity installed, and the slice's job is
to validate the loop and the look on real iPad hardware as fast as possible.
The load-bearing architecture decision (deterministic fixed-tick sim decoupled
from presentation) is engine-agnostic and ports to the pure-C# sim assembly
per §9.3. Treat this codebase as the playable spec for the Unity build, not as
its foundation. (SceneKit is deprecated as of iOS 26 but fully functional; if
the native track ever becomes the product, migrate presentation to RealityKit.)

## Screenshots

`Screenshots/` holds captures from the iPad Pro simulator. `00`–`06` are the first
build; `07`–`11` are after the audit-fix pass (golden-hour cab, Comet on short final,
the accurate top-down map, the dusk SLAMMED crescendo, the compact score screen).

## Audit & fixes

`AUDIT.md` is the full player-seat audit (~110 findings across real-world KAVX/aircraft
accuracy, sim behavior, touch/HUD, and art) and the staged fix plan. All four stages
have landed and are verified — see the "Resolution status" section at the bottom of
`AUDIT.md`, including the one documented ground-routing limitation. Headlines:

- **Sim fairness:** conflicts now warn ~40 s out across *all* committed arrivals (no
  more zero-warning penalties); the self-preservation penalty is −600, once per
  episode, and never nukes the grade; taxiing aircraft queue at the hold-short; the
  strip phase ladder tells the truth (FINAL → SHORT FINAL → LANDING); random seed per
  shift; SAVE-farming, force-end-while-flying, and cap-abandoned-par bugs closed.
- **Map accuracy:** rebuilt against FAA/Conservancy data — 055/235° true, 914 m
  concrete, SE parallel taxiway + dirt tiedown infield, single hangar, Spanish-Colonial
  terminal, REIL/PVASI, the real 2.1 % hump, fBm island silhouette, cliff foam.
- **Graphics:** cab-glass sky shafts gone, planted aircraft with contact shadows,
  landing-light pearls on final, warm-and-lifted golden-hour/dusk grades.
- **Build:** fixed a wide-gamut Metal pixel-format crash (procedural textures forced
  to standard 8-bit range).

## Debug launch arguments (dev/screenshot harness)

`-autostart` skip the start screen · `-ff <s>` fast-forward the sim
· `-autopilot` a demo controller plays the shift · `-openbloom` open the radial
on the first airborne aircraft · `-hour <h>` pin the sky clock (e.g. `18.4`)
· `-yaw/-pitch/-fov <v>` pose the camera · `-hide <name,…>` hide scene nodes
· `-nobloom` disable camera bloom.

## Known punch list (next session)

- **Ground routing at the taxiway exit junction** — the top backlog item; see the
  documented limitation in `AUDIT.md` (reservation-based ground planner).
- Upper-sky gradient still reads a touch flat at midday; grass a little muddy from
  straight overhead (fine from the cab). Ridge close-up detail could use more variation.
- On-device gesture *feel* still wants a hands-on pass (touch is verified through the
  `UITests/` XCUITest gesture layer, not by finger).
- Voice (PRD pillar 2), audio, weather set pieces, Duty Cards, career: next
  milestones, per slice scope below.

## Slice scope (what's deliberately missing)

Voice/ASR (PRD introduces voice in shift two; the slice is touch-first — touch
is voice's equal by pillar), audio, weather set pieces (fog/rain/gusts), Duty
Cards, career/checkrides, Daily Rush Hour, replays, crashes (pilots always
self-preserve; the −2000 penalty carries the pressure), iPhone layout.
