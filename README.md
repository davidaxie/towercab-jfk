# TowerCab: Slammed

A premium, entertainment-only **3D air-traffic-control game for iPad**. You stand in the tower cab
at **KJFK — John F. Kennedy International** at golden hour and run a fast, stylish arrival/departure
rush: sequencing an all-airliner fleet with a flight-strip rail and a radial of touch clearances,
chasing tight-but-safe gaps. POV is locked to the cab — no cuts. Entertainment only; no training
claims.

The game lives in **[`towercab-slammed/`](towercab-slammed/)**.

## Highlights

- **KJFK, to scale** — the flat Jamaica Bay field, the Bay Runway (13R/31L), Terminal City, airfield
  lighting, and a hazy Manhattan skyline, all procedural (no external assets).
- **All-airliner fleet** — ~30 real aircraft types from regional turboprops (ATR 72, Dash 8) through
  narrowbodies (A320/737/757) and widebodies (777, 787, A350, A330) to the heavies (747, A380) and
  heritage (MD-80, DC-10). Real type silhouettes, **fictional airlines** (no real liveries).
- **Real-world rarity** — spawn weights mirror actual traffic: narrowbodies dominate, widebodies are
  frequent, 747/A380 are rare heavies.
- **Deterministic sim** — a fixed 10 Hz simulation core (seeded RNG, no wall clock) decoupled from a
  60 fps presentation layer, so a shift replays identically.

## Build & run

Requirements: **Xcode 26+**, an iPad simulator or device (iPadOS 17+). No external dependencies —
every texture and model is generated in code.

```bash
cd towercab-slammed
xcodegen generate          # regenerate the Xcode project (only if you add/remove files)
open TowerCabSlammed.xcodeproj
# Build & run the TowerCabSlammed scheme on an iPad destination (landscape)
```

Headless deterministic sim tests (pure Swift, no Xcode project needed):

```bash
cd towercab-slammed
swiftc -O -o /tmp/simtest TowerCabSlammed/Sim/*.swift Tools/simharness.swift && /tmp/simtest
```

See [`towercab-slammed/README.md`](towercab-slammed/README.md) for architecture, debug launch
arguments, and the on-device / put-down-test notes.

## Status

Playable vertical-slice prototype. Native Swift + SceneKit (the load-bearing decision — a
deterministic fixed-tick sim decoupled from presentation — is engine-agnostic).
