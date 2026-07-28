# TowerCab: Slammed — KJFK Player-Seat Audit

*2026-07-28. The previous audit (`AUDIT.md`) was run against the **KAVX Catalina** slice
and all four of its stages landed. The game has since re-based to **KJFK + an all-airliner
fleet** (commits `acc5264` → `451a53a`), and that re-base changed the two numbers every
tuned constant depended on: the runway went from **914 m to 4,423 m** and approach speeds
from **65–85 kt to 113–155 kt**. This audit re-runs the method against the current build.*

**Method.** Static read of the sim + world layers; a new 40-seed measurement harness
(`Tools/probe-kjfk.swift`) driving the same competent auto-controller `simharness` uses;
and a reproducible screenshot matrix through the real gesture layer
(`UITests/CaptureMatrixUITests.swift`, XCUITest). Every number below is measured, not
estimated. Evidence frames are in `Screenshots/kjfk-audit-*.png`.

**Severity.** **P0** = the player sees a broken world, or is scored dishonestly ·
**P1** = unfair / PRD-violating · **P2** = polish.

---

## The headline

**The airport is invisible.** At KJFK the player cannot see the runway they are working,
the taxiways they route on, the markings, the hold bars, or the three crossing runways.
The field reads as a featureless pale plain with edge-light poles standing on nothing.
Everything else in this document is downstream of, or secondary to, that.

The geometry is all built correctly — it is simply buried under the ground plane.

---

## A. World & rendering

### A1 — The field plate occludes every piece of pavement · **P0**

`Terrain.fieldPlate` is built at `groundHeight + 0.12` m and is an opaque, depth-writing
mesh covering the whole 5,000 × 3,500 m field footprint (`Terrain.swift:141`). Every piece
of pavement is authored **below** it:

| Surface | Lift (m) | Source |
|---|---|---|
| `fieldPlate` (the ground) | **0.120** | `Terrain.swift:141` |
| Active runway 13R/31L | 0.060 | `AirportGeometry.pavementLift:17` |
| Taxiways / apron | 0.060 | `AirportGeometry.swift:286, 384` |
| Taxiway stripes | ~0.065 | `AirportGeometry.swift:309` |
| JFK box runways (13L/31R, 04L/22R, 04R/22L) | 0.040 | `jfkBoxRunwayLift:27` |
| Box taxiway stripes | 0.030 | `jfkBoxTaxiStripeLift:29` |
| Box taxiways | 0.020 | `jfkBoxTaxiLift:28` |
| Dirt infield | 0.030 | `AirportGeometry.swift:413` |

KJFK sets `flat = true`, so `groundHeight(at:) ≡ 0.0` everywhere
(`KAVXAirport.swift:198`). The plate therefore sits a clean 55–100 mm **above** all of it
and wins every depth test.

**This never showed at KAVX** because the mesa profile and knolls made `groundHeight` vary
under the pavement, so the runway crest pushed through the plate in most views.

*Verified* by a matched pair — identical seed, sim clock and camera, one node's difference:

- `Screenshots/kjfk-audit-A1-plate-present.png` — a featureless slab. The only things
  visible on the entire airport are one airborne A321 and two light glints.
- `Screenshots/kjfk-audit-A2-plate-hidden.png` — the Bay Runway with its markings and
  designators, the Papa parallel, all three crossing runways, the connectors and hold
  bars, Terminal City, the gates and the parked fleet. All of it is there.

**Fix.** Make the vertical ordering one source of truth instead of eight scattered
literals — a single `Lift` enum (`ground = 0`, `boxTaxi`, `boxRunway`, `pavement`,
`stripe`) with the field plate at the bottom of the ladder. Dropping the plate to
`groundHeight + 0.0` and leaving the pavement ladder as-is is the one-line version; the
enum is the version that stops this recurring. Add a build-time assertion that every
pavement lift exceeds the plate lift.

### A2 — What that costs in the seat · **P0** (resolves with A1)

- `kjfk-audit-B3-look-at-runway.png` — panned from the cab eye toward the active runway:
  blank lavender ground, no centerline, no threshold, no taxiway, no terminal.
- `kjfk-audit-B4-crescendo.png` — the **SLAMMED** crescendo, the loudest beat in the game:
  an empty plain, no aircraft in frame, edge-light poles floating on nothing.

Pillar 4 ("Atmosphere Is Mechanics") and the "Luminous Diorama" bar both fail outright —
not because the art is weak but because it is not being drawn.

### A3 — Hard horizon seam · **P1**

A dark band sits where the land band / fog meets the sky dome, in every cab frame. This is
the old `D8` seam (fog color ≠ dome horizon color) returning at the new field scale.

### A4 — Golden hour grades milky lavender, not golden · **P1**

At 18:01–18:19 the field, sky and water all sit in a desaturated violet-pink. The old `D6`
finding ("milky grey-lavender, not golden") is back — expected, since the KAVX fix was
tuned against a mesa albedo and a 488 m sea drop, and KJFK is a flat 4 m-above-water
coastal field with completely different bounce.

---

## B. Platform

### B1 — Portrait window on iPadOS 26; the strip rail is clipped off-screen · **P0**

`Info.plist` correctly declares landscape-only + `UIRequiresFullScreen: true`, yet on the
iPadOS 26.0.1 simulator the app presents in a **portrait** window. Reproduced independently
through two capture paths (`simctl io screenshot` and XCUITest with
`XCUIDevice.orientation = .landscapeLeft`), and it survives shutting the device down and
forcing the Simulator's own orientation preference.

The consequence is not cosmetic: the **strip rail — the game's primary interaction
surface — is cut off the right edge**, and at the crescendo it is entirely absent from the
frame (`kjfk-audit-B4-crescendo.png`).

iPadOS 26 makes all iPad apps resizable and no longer honours `UIRequiresFullScreen`, which
is the likely cause. **This needs confirming on hardware before it is treated as fact** —
but if it reproduces on a real iPad it is a launch blocker, and the fix (a layout that
survives an arbitrary window aspect, or an explicit geometry request) is architectural
rather than a tweak.

---

## C. Simulation & scoring — 40 seeds, competent auto-controller

Reproduce with:

```bash
swiftc -O -o /tmp/probekjfk TowerCabSlammed/Sim/*.swift Tools/probe-kjfk.swift && /tmp/probekjfk
```

### C1 — Arrivals float 1,490 m and 21 seconds down the runway · **P0**

| Measured | Value | Real-world |
|---|---|---|
| Touchdown point past the 31L threshold | **1,370 m** mean (p10 1,253 · p90 1,505) | ~300 m |
| Float distance, flare entry → touchdown | **1,490 m** mean | — |
| Float **time** at flare attitude | **21.4 s** mean (p90 25.4 s) | 4–7 s |

Cause: `ShiftScript.swift:130` authors the touchdown point as a **fraction of runway
length** — `runway.length × 0.275…0.348`. On KAVX's 914 m runway that is a correct ~250 m.
On KJFK's 4,423 m runway it is 1,216–1,539 m. The flare then begins on schedule (130 m out
/ 22 m AGL) and `updateFlare` stretches the descent across the remaining distance
(`ttd = remaining / speed`), so a widebody hangs a metre off the concrete for twenty-one
seconds. This is the most-watched moment in the game.

**Fix.** Author touchdown as an absolute distance band per size class (regional ~250–350 m,
narrowbody ~300–400 m, widebody ~350–450 m). Nothing downstream should read
`runway.length` for this.

### C2 — Runway occupancy 89 s · **P0** (largely resolves with C1 + C3)

Mean threshold-to-clear is **89.1 s** (p90 86.3 s). Arrivals are authored a minimum of 55 s
apart in projected landing time (`ShiftScript.swift:108`), so the runway is occupied
essentially continuously. Arrival-vs-arrival amber stops being authored pressure the player
created and becomes a structural constant, and departures rarely see a legal window.

### C3 — The preferred exit is unreachable; SLICK EXIT is a dead verb · **P1**

Exits sit at 1,800 m (preferred, the SLICK EXIT target) and 3,200 m.

- **95%** of landings roll to the far exit at 3,200 m.
- **2%** make the 1,800 m preferred exit.
- **2 SLICK EXIT badges across 40 seeds** — and only because the probe expedites *every*
  rollout. The shipped `simharness` policy only expedites non-jets, which at KJFK means
  just the ATR 72 and Dash 8: **6.2%** of the spawn table by weight.

Touching down at 1,370 m at ~68 m/s, a widebody needs ~1,040 m to reach turnoff speed —
reach ≈ 2,410 m, past the 1,800 m exit. Expediting only pulls it back to ~2,060 m. This is
the KAVX `B15` finding ("the verb is a scam for that type") regressed to the whole fleet.

**Fix.** Once C1 lands, touchdown at ~350 m puts the 1,800 m exit in genuine reach for
regionals and narrowbodies and keeps it a real *choice* for heavies. Re-check the exit
stations against the corrected rollout after fixing C1 rather than moving them first.

### C4 — Taxi-in takes 337 s of a 420 s shift · **P0**

`routeExitEnd` runs 3,200 m → the parallel → back down to the ramp at station 500: about
**3.0 km** at 9 m/s. Measured taxi-in (exit → parked) is **337 s** mean (p90 360 s), against
a 420 s shift. **84 of 100 landings never reached a gate** inside the probe window.

Every landed aircraft therefore holds a rail slot for five and a half minutes after the
interesting part of its life is over.

### C5 — Strip-cap saturation: less than half the authored traffic is ever handled · **P0**

| | Mean per shift |
|---|---|
| Orders authored | 15.6 |
| Actually spawned | 13.0 |
| **Movements scored** | **7.2** |
| Max active strips | 12.0 (**the cap, in every seed**) |
| Share of shift spent at the cap | 28.3% (worst seed 53.7%) |

C4 is the direct cause: taxiing arrivals occupy the cap, `processSpawns` refuses to spawn
at the cap, and ~17% of authored traffic never appears at all.

### C6 — The grade lies about all of this · **P0**

Par accrues only from orders that actually spawn (`spawnedParScore`, the old `B11` fix), and
the grade keys off `positiveScore / parScore`. So when throughput collapses, **par collapses
with it** and the player is graded against the little they were allowed to do:

- Grades over 40 seeds: **S × 11, A × 17**, B × 10, C × 2 — **70% grade A or better**
- while the report's own **Flow axis reads 54/100**
- and **CLEAN SHIFT fired in 40 of 40 seeds.**

A player handling 7 of 15.6 authored movements is being told they ran an S-grade shift.
`B11` was the right fix for cap-abandoned orders punishing the player; it is the wrong
behaviour when the cap is saturating structurally.

**Fix.** Separate the two ideas: par for *grading* should come from authored traffic, with
cap-abandoned orders excluded only when the abandonment is not the player's doing. Until
C4/C5 land, a saturated cap should be surfaced to the player (and suppress CLEAN SHIFT)
rather than silently deflating par.

### C7 — Ground traffic drives through itself in every seed · **P0**

Measuring **all** moving ground traffic (not just the hold-short queue):

- **40 / 40 seeds** contain at least one wingtip overlap.
- Worst wingtip clearance: **−70 m** — i.e. fuselages fully interpenetrating.
- **27 / 40 seeds** show an opposed head-on pass inside 60 m on the shared parallel.

At KAVX this was a documented, momentary junction limitation. At KJFK arrivals taxi ~2.7 km
back down the *same single parallel* that departures use to reach the threshold, so the
opposing flow is continuous and the overlaps are gross rather than glancing.

The existing `simharness` cannot see this: its ground metric samples only `holdingShort` /
`lineUpWait` (`simharness.swift:231`) — by construction it measures the queue, not the
taxiways. It has been passing while this was true.

**Fix.** This is the reservation-based ground planner already named as the top backlog item
in `AUDIT.md`, and it is no longer deferrable. A cheaper interim: give the parallel
directional segments (arrivals exit outboard, departures inboard) so opposing flows never
share a lane.

### C8 — The shift cannot drain; the force-end does the work · **P2**

`checkShiftEnd` waits `duration + 150 s`, then force-resolves everything unresolved,
banking base points for arrivals the player never landed. Given C4, this is not an edge
case — it is how essentially every shift ends.

---

## D. Accuracy & hygiene

**Correct, verified against the FAA diagram** — 13R/31L true heading 301°, 4,423 m
(14,511 ft), 60 m width, field elevation datum, Jamaica Bay just below the field. The
layout work is sound; the tower cab height (90 m eye) is in the right neighbourhood for
JFK's 321 ft tower.

- **D1 · P2** — `straightInFraction = 0.85` means 15% of KJFK airliners fly a VFR downwind
  at 1,500 ft. No A380 flies a downwind at JFK. Defensible as a game call, but it should be
  an explicit decision rather than a KAVX inheritance.
- **D2 · P2** — The geometry API is still KAVX-named and now actively misleading:
  `heading22`, `dir22`, `point(atStationFrom22:)`, `RunwayExit.stationFrom22` (which at
  KJFK measures from the **31L** threshold), `routeExitMidfield` (at KJFK it is the near
  exit, not midfield), and the file itself is `Sim/KAVXAirport.swift`.
- **D3 · P2** — Docs describe a game that no longer exists: `AUDIT.md` and
  `towercab-slammed/README.md` are written for the KAVX Catalina slice (the README's
  "Known punch list" and "Screenshots" sections both describe Catalina), and the private
  `CLAUDE.md` still says "this folder has no git repo of its own", which stopped being true
  when the project became standalone.

---

## Fix plan (staged)

**S1 — Make the airport visible.** A1. One ordering fix plus an assertion. Everything else
in this document is easier to judge afterwards, and no art or layout work should be
attempted before it. *Exit: the A1/A2 matched pair is indistinguishable; the runway,
markings and Terminal City are visible from the cab and from above.*

**S2 — Make the landing true.** C1 (absolute touchdown band), then re-derive C2 occupancy
and re-check C3 exit stations against the corrected rollout. *Exit: touchdown 250–450 m by
class; flare 4–7 s; occupancy ≤ 55 s; the preferred exit is reachable by regionals and
narrowbodies without expediting, and by heavies with it.*

**S3 — Make the shift drain.** C4 (near-side exits and/or a ramp reachable without a 3 km
back-taxi), then C5 falls out, then fix C6's par honesty. *Exit: ≥ 80% of authored traffic
spawns; movements scored ≥ 80% of spawned; the cap is hit only during the crescendo; grade
distribution across 40 seeds is centred on B/C for the auto-controller, not S/A.*

**S4 — Ground routing.** C7 — the reservation planner, or directional lanes as the interim.
*Exit: zero wingtip overlaps across 200 seeds; no opposed pass inside one wingspan.*

**S5 — Look and window.** A3, A4, B1. *Exit: golden hour grades golden; no horizon seam;
the rail is fully on-screen at every window aspect the OS can hand us — confirmed on
hardware.*

**S6 — Verify and re-baseline.** Extend `simharness` with the invariants that would have
caught all of this: ground separation over **all** moving traffic (not just the queue),
float time, occupancy, taxi-in duration, cap-saturation share, and a grade-distribution
sanity bound. Re-run `probe-kjfk`, refresh the screenshot matrix, and rewrite `AUDIT.md` /
`README.md` for KJFK (D3).

---

## Progress — 2026-07-28

### S1 · LANDED and verified

The lift ladder is now one source of truth in `WorldAirportBuilder` with the field
plate as the datum (`fieldPlateLift = 0.0`), and `assertLiftLadder()` fails the debug
build if any paved surface ever sinks to or below it again.

*Verified:* re-shot the same matched pair. With the plate **present**, the Bay Runway,
Papa parallel, all three crossing runways, connectors, hold bars, designators and
Terminal City are all drawn. Compare `Screenshots/kjfk-audit-A1-plate-present.png`
(before) with the current build.

A2 resolves with it. **A3 (horizon seam) and A4 (milky grade) remain open** — the field
still reads desaturated violet rather than golden.

### S2 · LANDED and measured

`ShiftScript.touchdownStation(kind:airport:rng:)` now authors an absolute band per size
class (light 120–200 m → widebody 350–450 m, clamped to a third of the runway) instead
of a fraction of runway length.

While measuring the result, a second bug surfaced and was fixed: `legalCommands` still
refused `EXPEDITE EXIT` to any jet — a KAVX-era stereotype ("jets can't make an early
turnoff") that S2 had just made false. It is now a capability test,
`expediteBuysEarlierExit(_:)`, that asks whether harder braking would actually buy this
aircraft an earlier turnoff. Before the fix the verb was unavailable to 93.8% of the
KJFK fleet by spawn weight.

| Metric | Before | After | Target |
|---|---|---|---|
| Touchdown past threshold | 1,370 m | **344 m** | 250–450 m |
| Float time at flare attitude | 21.4 s | **6.3 s** | 4–7 s |
| Runway occupancy | 89.1 s | **56.7 s** | ≤ 55 s (p90 still 69 s) |
| Landings taking the preferred exit | 2% | **81.4%** | a real choice |
| SLICK EXIT badges / 40 seeds | 2 | **13** | reachable |
| Taxi-in | 337 s | **199 s** | — |
| Pilot go-arounds / shift | 1.82 | **0.53** | — |

### S3 · attempted, reverted — the bottleneck is not the rail

Freeing the strip cap by handing arrivals to Ground at the runway exit (rather than
after the full taxi to the gate) raised spawns **13.0 → 14.6** but left completions flat
at **7.3**. The cap is a symptom; the binding constraint is ground congestion on the
single shared parallel (C7). Reverted rather than left half-tuned, because it also
changes the core loop — the tower/ground handoff point is a design decision for the
owner, not a tuning knob. It is worth revisiting **after** S4, and it is independently
attractive (it stops the rail filling with five TAXI OUT strips).

C6 is confirmed independent of the landing fix and got *worse* as the shift got
smoother: grades over 40 seeds are now **S × 18, A × 21 — 97.5% A-or-better** while Flow
still reads 49.5/100. Par honesty needs fixing on its own terms.

### Known-red test

`simharness` scenario A now fails: **`movements 7 < 8`**. This is not a regression from
S1/S2 — aggregate throughput across 40 seeds is unchanged (7.2 → 7.3). The assertion was
already sitting exactly on the boundary (it read exactly 8 before), and it is now
reporting C5 honestly: the auto-controller cannot complete 8 movements at KJFK. **The
threshold has deliberately not been lowered.** It should go green when S3 lands; if it
does not, the bar was wrong rather than the game.

### Also landed

- **Sound is off by default, and settable.** `App/GameSettings.swift` persists
  `soundEnabled` (default OFF while the soundscape is programmer-synthesized, per PRD
  §5). When off the `AVAudioEngine` is never started rather than started and muted — no
  audio session, no render thread, no battery cost — and toggling takes effect mid-shift
  without a restart. Exposed on the start screen (`SOUND OFF` / `SOUND ON`) and as a
  speaker button in the top bar. Covered by `UITests/SettingsUITests.swift`: default,
  persistence in both directions, and the top-bar mirror.
- The start screen said **`RWY 22`**, naming a runway that does not exist at KJFK. Now
  `RWY 31L`.

---

## Tools added by this audit

- **`Tools/probe-kjfk.swift`** — 40-seed measurement rig. Prints the distributions above;
  no pass/fail, it is for looking at. Build alongside `Sim/*.swift` as shown in §C.
- **`UITests/CaptureMatrixUITests.swift`** — reproducible screenshot matrix. Note that
  `-campos` moves `world.cabMount` and the cab interior is parented to it, so any
  repositioned camera must also pass `-hide cab`; the hide token is a lowercased
  **substring** match over node names.
