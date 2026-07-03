# TowerCab: Slammed — Player-Seat Audit & Fix Plan

*2026-07-02. Method: hands-on playtest of the slice (screenshot matrix from the cab +
aerial/close audit angles via debug camera; real-touch XCUITest playthrough through the
actual gesture layer), plus four specialist audits run in parallel — real-world KAVX/
aircraft research (FAA-derived sources), sim-behavior probes (12 headless scenarios,
200-seed sweeps), touch-UX/HUD code audit, and an art-direction critique against PRD §6.
~110 findings, deduplicated below. Severity: **P0** = player sees a broken world or gets
robbed without warning · **P1** = unfair/ugly/PRD-violating · **P2** = polish.*

Fix stages at the bottom. Every finding carries its stage tag (S1–S4) or DEFER.

---

## A. Ground truth vs the build (map & accuracy) — the fact sheet

Research (AirNav, Catalina Conservancy pilot procedures, FlightAware, Wikipedia,
Islapedia; confidence-flagged) vs what the slice shipped:

| # | Real KAVX | Slice has | Fix |
|---|---|---|---|
| A1 | Runway 4/22 **true heading 055/235** (mag 041/221, var 12E) | 042/222 laid as true | S2 |
| A2 | **3,000 × 75 ft (914.4 × 22.9 m)** | 990 × 18 m | S2 |
| A3 | **Concrete**, re-poured 2019 — light-grey slabs, joint grid, excellent condition | dark weathered asphalt | S2 |
| A4 | Signature gradient: **2.1% upslope landing 22 for 2,300 ft; crest ≈ 213 m from the 4 (SW) threshold; NE threshold ~14.7 m BELOW the crest, SW ~1.5 m below** — pilots at opposite ends cannot see each other | symmetric 3 m sine bump | S2 |
| A5 | Markings **basic/visual: numbers + centerline only** (no threshold piano keys, no aiming-point bars, no TDZ) | full instrument-style marking set | S2 |
| A6 | **MIRL** edge lights; **REIL strobes on 22**; **PVASI left of RWY 4**, 3.0°; no PAPI on 22 | PAPI left of 22, no REIL | S2 |
| A7 | **Partial parallel + perpendicular taxiway on the SE side**; unnamed (no FAA diagram exists); pattern always flown **NW side** (4 left / 22 right traffic) | full-length parallel taxiway; apron/tower on the compass-NW side (self-consistent but mirrored) | S2 (flip perp → ramp SE, pattern NW) |
| A8 | Ramp SE midfield fronting the terminal; **dirt/grass tiedown infield with cables between ramp and taxiway** (aircraft parked on dirt is the authentic look); no fuel sold; disused DC-3 fuel pits in the pavement by the terminal | empty grey apron, planned "fuel island" would have been wrong | S2 |
| A9 | **One** hangar (relocated from Hamilton Cove); terminal = **two-story Spanish Colonial admin building with attached squat tower** (whitewashed masonry, red clay tile, Catalina pottery accents), DC-3 Grill patio facing the ramp | two generic gable hangars + small terminal, teal/tan roofs, one abutting the taxiway | S2 |
| A10 | Runway-remaining signs at 2,000/1,000 ft, both on the NW side | none | S2 |
| A11 | Island: mesa built by **leveling two hilltops and filling the canyon between**; cliffs/steep canyon drops off BOTH runway ends; terrain **rises ESE** (Mt Orizaba 639 m ~3 km, Black Jack 611 m SE), falls away NW toward the isthmus; Avalon SE, mainland NE | smooth ellipse mesa; ridges NW (wrong side); mainland NE too tall | S2 |
| A12 | **Bison wander onto the runway** (FAA-acknowledged hazard) | — | S4 (static pair as props; incursion event = post-slice) |
| A13 | Ops: full-stop only, no intersection departures, 12,500 lb MTOW (the Comet 60 is pure fiction here — fine, it's the game's VIP fantasy, but stop implying realism) | — | note in README |
| A14 | C172: 11.00/8.28 m, strut to ~40% span, dorsal fillet, spatted gear, app 60–65 kt ✓ | close ✓ | S3 detail pass |
| A15 | SR22: 11.68/7.92 m, **no strut**, small swept fin, teardrop pants, 3-blade, app 80–85 kt ✓ | close ✓ | S3 detail pass |
| A16 | Challenger 350: **21.0 m span w/ canted winglets**, 20.92 m long, T-tail, aft nacelles, Vref ~110 kt | 19.6 m span, nacelle pylons splayed like fins | S3 |
| A17 | Real cab glass rakes **top-OUT 15°** ✓ (build got this right); cab ceilings are **matte black**; console: strip bays, light gun, binoculars, wind/altimeter readouts | ceiling dark green-grey; console props sparse | S3 |

## B. Simulation & gameplay (probe-verified)

**P0 — S1**
- B1 Two arrivals **merge to 0.2 m separation mid-air, both green** — spawn authoring ignores type speed (a Vela overtakes a Lark on final) and there is no in-trail logic at all.
- B2 Conflict projection watches only the **single nearest** arrival vs the runway — arrival-vs-arrival crunches are invisible until the leader flares, so the −2000 fires with **0.0 s of amber warning**. The PRD's amber→save loop never gets to exist for the most common conflict type.
- B3 **No occupant-vs-occupant conflict**: takeoff clearance onto an occupied runway is green; the departure accelerates through the lander with no penalty.
- B4 **Zero ground separation** — taxiing aircraft drive through each other and stack at 0.0 m on the hold-short point, 60 m from the camera, constantly at crescendo.

**P1 — S1**
- B5 Runway-clear time overstated ~10 s for Velas/Comets (they brake late for the far exit) — **the Gap Arc lies, then collapses**.
- B6 −2000 is 35% of par, can hit the same aircraft twice, and nukes the grade → dread, violating Pillar 3. → −600, once per pair-episode, grade on positive play.
- B7 **Extend-downwind descends the plane to 26 ft AGL** 3.8 km out (follows the glideslope while extending).
- B8 SAVE farming: LUAW + manufactured go-around pays +750×streak. Tag player-manufactured episodes; pay 0.
- B9 LUAW occupancy constant (22 s) reads green with an arrival 31 s out — a lie players will see.
- B10 Force-end publishes the report **while aircraft are still flying**; post-report points mutate a dead score.
- B11 Strip-cap FIFO head-of-line blocking silently deletes authored traffic, then the par math grades you for traffic that never spawned.
- B12 Pattern arrivals skip FINAL, hold **SHORT FINAL for 19–24 s including touchdown** (observed from the cab); flare starts at the threshold, so no visible flare pitch until over the numbers.
- B13 Crescendo authors physically unlandable arrival trails (10.8 s gaps vs 26–36 s occupancy).
- B14 Departure strips are dead cap-weight for 63–85 s of climb-out (handoff gate too far).

**P2 — S1 best-effort**
- B15 Comet SLICK EXIT mathematically unreachable (verb is a scam for that type).
- B16 TIGHT GAP can adjudicate against a different arrival than armed on.
- B17 Every handoff readback logs as speaker "?" (aircraft removed before its radio line resolves).
- B18/B19 Go-around from downwind does an aimless 180° loop; orbit exit says "on final" from anywhere; orbit bank implies 49° while the model caps at 26°.
- B20 One-tick freeze at flare entry (6-frame hiccup at the most-watched moment).
- B21 Overflow arrivals park inside each other (same fallback point).
- B22 Clock pins at 0:00 during overtime; render as +m:ss.
- B23 Ta uses instantaneous speed (Comet ambers self-heal → trains players to ignore amber).
- B24 Landing banks at turnoff, not touchdown. B25 Departures taxi with no taxi clearance line. B26 Wind hardcoded + zero drift effect. B27 Runway length contradiction (fixed by A2). B28 `while(true)` in comet callsign dedup. B29 Radio log holds 5 lines (crescendo scrolls in ~2 s). B30 "Rolling out over the cliffs" is landing phraseology on a departure call.

## C. Touch, HUD & camera

**P0 — S1**
- C1 **Every strip tap pays ~350 ms double-tap disambiguation** on the game's most-used gesture (`.exclusively(before:)`). Single tap must fire instantly; re-tap the selected strip to frame.
- C2 **The seed is hard-coded** — NEXT SHIFT and RESTART SAME SEED are the same button; every run is identical traffic. Replayability collapses at run 2.
- C3 Score card stretches full-height (unbounded divider) → the giant dead void observed; labels wrap mid-word ("LANDING S").

**P1 — S1**
- C4 Bloom opens **anchored to garbage for off-screen/behind-camera aircraft** (confirmed by real-touch test: HOLD pill floating at a screen edge). Frame the camera first / guard `projectPoint` z∈(0,1).
- C5 Bloom verbs recompute **every frame while open** — capsules can swap identity under a descending finger. Freeze at open; only disable.
- C6 Strip-snap zoom formula broken (`18_00.0` literal): airborne aircraft framed as a 17 pt speck; PRD's "returns on release" peek missing entirely.
- C7 >9 aircraft: overflow strips invisible & unreachable **including red-band alarms**; stale complete strips hog the cap. Severity-promote within the cap.
- C8 Whole HUD invalidates at 60 Hz (every `@Published` written every frame) — SwiftUI re-evaluates everything continuously.
- C9 Default camera pose stares at near ramp/console; first impression must be the approach corridor and ocean.
- C10 Verb capsules ~38 pt tall (under the 44 pt floor) for precision taps under pressure.
- C11 Hue-only band encoding (green/amber/red) — colorblind-hostile; PRD lists the safe palette as P0 assist. Add redundant glyphs now.
- C12 No pause anywhere (PRD P0 launch gate). C13 "LINE UP & WAIT" truncates exactly when it matters (strip width 178 pt vs PRD ~300 pt spec). C14 Badge chips can't wrap (blow past the card on good runs).

**P2 — S1 best-effort**
- C15 Snap easing double-eases (eased²) + dead statement; C16 snap target pitch fights the clamp; C17 pinch zooms about screen center not centroid; C18 zero-tolerance scene tap picking (5–15 pt targets); C19 bloom clamp ignores the rail (verbs overlay strips); C20 toast stack uncapped, newest at bottom; C21 handoff dragX never resets on rejected command; C22 inert drag recognizer on every strip (dead pan zone); C23 gap arc >20 s renders identical/overflows at 99+; C24 radio log truncation mid-word; C25 sage-on-glass contrast over bright horizon; C26 no two-finger-double-tap camera home; C27 caution verbs (IMMEDIATE) fire on plain tap (PRD wants flick-confirm); C28 `bloomDismissed()` dead path.

## D. Art & graphics (vs "Luminous Diorama")

**P0 — S2/S3**
- D1 **Two vertical bright shafts in the sky from every cab view** — the nine flat glass planes overlap ~3 cm per bay seam and double their tint+specular. → one lathed truncated-cone glass band. (S3)
- D2 **Threshold z-fight garble**: taxiway stubs start ON the runway centerline at the same lift → coplanar shredding across the numbers zone. (S2)
- D3 **Ocean reads dead**: periodic corduroy sine pattern, featureless navy from altitude, pinpoint sun glint, hard cliff-water contact with no foam. (S2)
- D4 **Mesa is a smooth ellipse blob** — fake at first glance from any elevated angle; should read two filled knolls with fBm edges, coves, a promontory. (S2)
- D5 **Apron is dead** — zero parked aircraft, no story. Real answer is better than the planned fuel island: dirt tiedown infield with 2-3 parked Larks/Velas + cable rows + DC-3 pit covers. (S2)

**P1 — S2/S3/S4**
- D6 17:30 reads milky grey-lavender, not golden (mid/ambient too cool+desaturated; camera sat/contrast too low). D7 Sun disc is a blown white dot (razor edge, no mid-halo). D8 Horizon seam where fog color ≠ dome horizon color. D9 Aerial haze far below the bible's 2× (ridges arrive un-hazed as near-black masses). D10 Dusk crushes to black (ambient floor too low) — violates "lifted shadows, never crushed". D11 Interior ridges = giant smooth slabs w/ shading bands (14 segments over 5 km, no texture). D12 Grass muddy olive; needs golden dry-summer retint + macro variation octave + detail normal. D13 Cliff strata contrast invisible. D14 Mainland = hard floating khaki cutout. D15 Scrub = identical clone blobs, uniform scatter, some floating. D16 Taxiway centerline paints straight across the runway numbers (clip at hold bar); no taxiway/apron edge lines anywhere. D17 Runway numerals small/thin/low-res (draw as stroke glyphs, 18 m). D18 Apron texture invisible from cab (joints/tiedowns too faint). D19 Dirt road = pink smear w/ hard edges. D20 PAPI invisible from everywhere (needs halo billboards — and per A6 becomes PVASI/REIL). D21 Edge-light spheres read as black debris in daylight (day lens material + smaller solid, halo does dusk size). D22 Hangar/terminal style fights Catalina Spanish identity; dirt pads don't rotate with buildings; h1 2 m from apron edge. D23 Windsock underlit/skinny; pole inside the runway safety strip. D24 **Aircraft float** — no contact shadow at gameplay distance (sun shadow texel 0.37 m; dies after sunset). Baked blob quads. (S3) D25 Nav/strobe/beacon halos fixed-size — traffic vanishes as lights beyond 600 m while landing light scales. (S3) D26 Comet pylons splay like fins; span 1.4 m short of type. (S3) D27 White-dominant liveries wash identical at 400 m (deepen accents 15%, widen cheat lines). (S3) D28 Amber console strip ring dominates the lower frame (dim + occlude). D29 Console top = blank glossy annulus with a huge sun sheen (roughness up + panel texture + seams/screws/chart tape). D30 Clipboard/headset framed out of default view (move bays). D31 Rail = 9 heavy grey cards walling off the sky at crescendo (cap 7 visible, lighter plate, warm-paper recolor; green only for cleared states). D32 Floating verb pills mid-sky cheapen the frame (leader line or rail anchoring). D33 Score card 60% dead space; grey D grade disappears. D34 Color fringe 0.7 softens texture edges at iPad res (halve). D35 12× time drift means the shift ends near-dark — dusk floor (D10) is what keeps that beat beautiful.

**Verified already at bar:** palette discipline concept, dusk light-bank choreography, single-source geometry (sim and mesh share `groundHeight`), bloom threshold discipline (whites don't glow), pan inertia feel, HUD hit-test transparency, strip rail order stability, screen transitions, determinism (bit-identical 5,101-tick traces), phonetic callsigns, SAVE step-down law.

---

## The fix plan (staged)

- **S1 — Make it fair and touchable** *(sim fairness + HUD/touch)*: B1–B14 (P2s best-effort), C1–C14 (P2s best-effort). Exit: probes show amber warning ≥ 15 s before any self-preservation; no mid-air merges on 200 seeds; no ground overlap; tap-to-bloom < 100 ms; random seeds; score screen sane.
- **S2 — Make the map true** *(KAVX accuracy + world graphics)*: A1–A11, D2–D23, D6–D10 grade fixes. Exit: top-down matches the researched layout (heading 055 true, concrete 914×23, SE ramp w/ dirt infield, one hangar, Spanish terminal, REIL/PVASI, remaining signs); the hump genuinely hides the far half from the cab; ocean/mesa/ridges pass the postcard test.
- **S3 — Make the airplanes true** *(aircraft + cab)*: A14–A17, D1, D24–D30. Exit: type silhouettes match reference dims; shafts gone; planes planted; lights read at pattern distance; cab console believable.
- **S4 — Life & polish**: D5 dressing done in S2; bison pair, worn paths, segmented circle; C15–C28 leftovers; D31–D34 HUD look. Exit: postcard bot frames pass.
- **S5 — Verify**: sim harness + new probe assertions green; XCUITest playthrough green; fresh screenshot matrix reviewed vs this document; commit.

*Deferred beyond this pass:* live weather set pieces, voice, audio, replay/photo modes, bison incursion event, toast world-anchoring (C-P2/D toast note), colorblind full palette toggle (glyphs shipped now), 120 Hz.

---

## Resolution status (2026-07-03)

**All four stages landed and are verified.** The full app builds clean and runs on
the iPad Pro (M4) simulator; a first-render Metal crash (procedural textures were
emitted in extended/16-bit range on wide-gamut devices — invalid `MTLPixelFormat`)
was fixed by forcing `UIGraphicsImageRendererFormat.preferredRange = .standard` in
both texture helpers.

- **Sim (S1):** the headless harness passes all five scenarios — auto-controller
  (grade S), determinism (5,101 bit-identical ticks), neglect (clean force-end, 0
  self-preservation cliffs, 0 airborne at report), the SAVE-table law (streak steps
  down 2, never resets; floor 1; badges ×streak), and a 200-seed fairness sweep
  (min airborne separation 37 m — no merges; hold-short never stacks; downwind holds
  ≥0.86× pattern altitude; a lined-up departure never reads green with a close arrival).
- **Map (S2):** top-down matches the researched KAVX — 055/235 true heading, 914 m
  concrete, SE parallel taxiway + ramp with the dirt tiedown infield, one hangar, the
  Spanish-Colonial terminal (red tile + arcade), REIL/PVASI, the asymmetric hump, and
  an fBm island silhouette with cliff-foam. The threshold z-fight is gone.
- **Aircraft/cab (S3):** the cab-glass sky shafts are gone (single lathed band),
  aircraft sit planted (contact shadows), landing-light pearls read on final, and the
  Comet carries canted winglets.
- **Graphics (S4):** golden-hour and dusk both grade warm and lifted (no crushed
  blacks), edge lights switch on at dusk, the ocean has depth/foam, and the score
  screen is compact with a gold grade stamp.

### One documented limitation (not a regression)

**Ground routing at the single taxiway's exit junction.** The hold-short *stack* the
audit named (B4, P0) is fully fixed — the departure queue means two aircraft never
wait short at once. What remains is a momentary low-speed close pass when an arrival
turns off the runway exactly as a departure passes on the shared parallel taxiway, or
when an arrival maneuvers to a ramp spot beside a just-spawned departure. Keep-right
lanes, priority yielding, and veer-around avoidance reduce but don't eliminate it,
because a single GA taxiway with one apron throat has no alternate path. The real fix
is a reservation-based ground-movement planner (hold an aircraft at a node until the
conflicting segment clears), which is a feature beyond a vertical slice; it is the top
item on the ground-ops backlog. The harness therefore asserts the fixed guarantees
(no hold-short stack, no mid-air merge) and measures — but does not hard-gate on — the
junction-crossing distance.
