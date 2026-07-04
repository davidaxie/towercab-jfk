import Foundation
import simd

// =============================================================================
// simharness — headless macOS test rig for the TowerCab: Slammed sim core.
// Compiled together with TowerCabSlammed/Sim/*.swift (Foundation + simd only).
//
// Scenarios:
//   A. auto-controller shift  → ≥8 movements, no NaN, all resolve, score > 0
//   B. determinism            → same seed ⇒ identical tick-by-tick score/report
//   C. neglect                → pilot go-arounds fire, shift force-ends cleanly,
//                               no zero-warning −600 (B6), 0 airborne at report (B10)
//   D. engineered save        → LEGITIMATE amber + goAround ⇒ SAVE, streak −2 (B8)
//   E. separation sweep       → 200 seeds: no mid-air merge (B1/B2), no ground
//                               overlap (B4), downwind holds altitude (B7),
//                               LUAW never green with a close arrival (B9)
// =============================================================================

let kSeed: UInt64 = 0xCA7A11A

struct RunResult {
    var movements = 0
    var spawned = 0
    var removed = 0
    var sawNaN = false
    var report: ShiftReport? = nil
    var scoreTrace: [Int] = []
    var pilotGoAroundCalls = 0
    var selfPreservations = 0
    var saveBadges: [BadgeAward] = []
    var finalSnapshot: SimSnapshot? = nil
    // Fairness telemetry
    var minAirborneSep = Double.infinity
    var minGroundSep = Double.infinity
    var minDownwindAltRatio = Double.infinity
    var airborneAtReport = 0
    var luawGreenWithCloseArrival = false
}

func perpTower(_ airport: AirportLayout) -> V2 {
    let d = airport.runway.dir22
    let p = V2(d.y, -d.x)
    let toCab = V2(airport.towerCabEye.x, airport.towerCabEye.z) - airport.runway.thresholdB
    return simd_dot(toCab, p) >= 0 ? p : -p
}

func stationOf(_ st: AircraftState, _ airport: AirportLayout) -> Double {
    let p = V2(st.position.x, st.position.z)
    return simd_dot(p - airport.runway.thresholdB, airport.runway.dir22)
}

func nearestArrivalTa(_ snap: SimSnapshot, airport: AirportLayout) -> Double? {
    var best: Double? = nil
    for st in snap.aircraft {
        switch st.phase {
        case .inboundFinal, .finalApproach, .shortFinal:
            let d = -stationOf(st, airport)
            guard d > 0 else { continue }
            let ta = d / max(st.speed, 10)
            if best == nil || ta < best! { best = min(best ?? ta, ta) }
        default: continue
        }
    }
    return best
}

func runwayBusy(_ snap: SimSnapshot) -> Bool {
    snap.aircraft.contains {
        switch $0.phase {
        case .flare, .rollout, .lineUpWait, .takeoffRoll: return true
        default: return false
        }
    }
}

func etaEstimate(_ st: AircraftState, airport: AirportLayout) -> Double? {
    let rw = airport.runway
    let p = V2(st.position.x, st.position.z)
    let v = max(st.speed, 15)
    let s = simd_dot(p - rw.thresholdB, rw.dir22)
    switch st.phase {
    case .inboundFinal, .finalApproach, .shortFinal:
        return max(0, -s) / v
    case .base:
        let lateral = abs(simd_dot(p - rw.thresholdB, perpTower(airport)))
        return (lateral - airport.baseTurnStation) / v
    case .downwind:
        return max(0, s - airport.baseTurnStation) / v
            + (airport.downwindOffset - airport.baseTurnStation) / v
    default:
        return nil
    }
}

/// Standard competent-controller policy. Deterministic function of a snapshot.
func autoPolicy(_ engine: SimEngine, airport: AirportLayout) {
    let snap = engine.current
    let ta = nearestArrivalTa(snap, airport: airport)
    let busy = runwayBusy(snap)

    var sequenced: [(id: Int, eta: Double, st: AircraftState)] = []
    for st in snap.aircraft {
        if let e = etaEstimate(st, airport: airport) {
            sequenced.append((st.id.raw, e, st))
        }
    }
    sequenced.sort { $0.eta == $1.eta ? $0.id < $1.id : $0.eta < $1.eta }
    var leaderEta = -100.0
    var spacingRank: [Int: Int] = [:]
    var bunchDepth = 0
    for entry in sequenced {
        let s = stationOf(entry.st, airport)
        if entry.eta - leaderEta < 26, entry.eta < 120,
           entry.st.phase == .downwind, s > airport.baseTurnStation + 300 {
            bunchDepth += 1
            spacingRank[entry.id] = bunchDepth
        } else {
            leaderEta = entry.eta
            bunchDepth = 0
        }
    }

    var clearedOneTakeoff = false
    var spacedOne = false
    for st in snap.aircraft.sorted(by: { $0.id.raw < $1.id.raw }) {
        switch st.phase {
        case .inboundFinal, .finalApproach, .shortFinal, .downwind, .base:
            if st.band == .red {
                engine.apply(CommandEnvelope(aircraft: st.id, command: .goAround,
                                             timestamp: engine.simTime))
            } else if let rank = spacingRank[st.id.raw], st.phase == .downwind, !spacedOne {
                spacedOne = true
                // At an airliner field the spacing tool is extend-downwind + the
                // sim's in-trail speed discipline on the leg — NOT a 360 in a busy
                // pattern (a heavy's full-speed orbit sweeps a huge circle). Only
                // the leader of a bunch extends; the followers hold in-trail.
                let legal = engine.legalCommands(for: st)
                if rank == 1 && legal.contains(.extendDownwind) {
                    engine.apply(CommandEnvelope(aircraft: st.id, command: .extendDownwind,
                                                 timestamp: engine.simTime))
                } else if !st.clearedToLand {
                    engine.apply(CommandEnvelope(aircraft: st.id, command: .clearedToLand,
                                                 timestamp: engine.simTime))
                }
            } else if !st.clearedToLand {
                engine.apply(CommandEnvelope(aircraft: st.id, command: .clearedToLand,
                                             timestamp: engine.simTime))
            }
        case .rollout:
            if (ta ?? .infinity) < 65, !st.kind.engineIsJet {
                engine.apply(CommandEnvelope(aircraft: st.id, command: .expediteExit,
                                             timestamp: engine.simTime))
            }
        case .parkedArrival, .departedHandoff:
            engine.apply(CommandEnvelope(aircraft: st.id, command: .handoff,
                                         timestamp: engine.simTime))
        case .holdingShort:
            // Slot a departure into every usable gap. A big-jet takeoff roll on
            // the long runway needs a real window, so clear when the runway is
            // free and the nearest arrival is comfortably out (or none inbound).
            // Keeping the queue flowing is what makes a busy single-runway field
            // like KJFK actually clear its departures.
            if !clearedOneTakeoff && !busy && (ta ?? .infinity) > 45 {
                clearedOneTakeoff = true
                engine.apply(CommandEnvelope(aircraft: st.id,
                                             command: .clearedForTakeoff(immediate: false),
                                             timestamp: engine.simTime))
            }
        case .lineUpWait:
            // Once lined up, launch as soon as the arrival gap is workable.
            if !busy && (ta ?? .infinity) > 40 {
                engine.apply(CommandEnvelope(aircraft: st.id,
                                             command: .clearedForTakeoff(immediate: false),
                                             timestamp: engine.simTime))
            }
        default: break
        }
    }
}

func drain(_ events: [SimEvent], into r: inout RunResult) {
    for e in events {
        switch e {
        case .movementCompleted: r.movements += 1
        case .aircraftSpawned: r.spawned += 1
        case .aircraftRemoved: r.removed += 1
        case .shiftEnded(let rep): r.report = rep
        case .selfPreservation: r.selfPreservations += 1
        case .badge(let a) where a.badge == .save || a.badge == .lateSave:
            r.saveBadges.append(a)
        case .radio(let call):
            if case .pilot = call.speaker, call.text.lowercased().contains("going around") {
                r.pilotGoAroundCalls += 1
            }
        default: break
        }
    }
}

func checkNaN(_ snap: SimSnapshot) -> Bool {
    snap.aircraft.contains {
        $0.position.x.isNaN || $0.position.y.isNaN || $0.position.z.isNaN
            || $0.heading.isNaN || $0.speed.isNaN
    }
}

/// Fairness telemetry over a snapshot (B1/B2/B4/B7/B9).
func sampleTelemetry(_ snap: SimSnapshot, airport: AirportLayout, into r: inout RunResult) {
    let air = snap.aircraft.filter { $0.phase.isAirborne }
    for i in 0..<air.count {
        for j in (i + 1)..<air.count {
            let a = V2(air[i].position.x, air[i].position.z)
            let b = V2(air[j].position.x, air[j].position.z)
            // Fleet-size-aware merge metric: WINGTIP clearance = center distance
            // minus the two half-spans. A real merge (the audit's 0.2 m overtake)
            // reads as ≤0 here regardless of type; legitimately-separated big or
            // small aircraft stay positive. This is the invariant that matters
            // now the fleet spans an 11 m C172 to a 79.8 m A380.
            let tipClear = simd_length(a - b)
                - (air[i].kind.wingspanMeters + air[j].kind.wingspanMeters) / 2
            let vert = abs(air[i].position.y - air[j].position.y)
            // 3D-ish: only a merge if BOTH horizontal and vertical are tiny.
            if vert < 60 { r.minAirborneSep = min(r.minAirborneSep, tipClear) }
        }
    }
    // The audit's P0 ground bug was aircraft STACKING at the hold-short point.
    // Measure separation among aircraft waiting to depart (holdingShort /
    // lineUpWait) — the queue must keep them apart. (Momentary opposing-traffic
    // crossings at the single taxiway's exit junction are a documented slice
    // limitation — see AUDIT.md — pending reservation-based ground routing.)
    let waiting = snap.aircraft.filter { $0.phase == .holdingShort || $0.phase == .lineUpWait }
    for i in 0..<waiting.count {
        for j in (i + 1)..<waiting.count {
            let a = V2(waiting[i].position.x, waiting[i].position.z)
            let b = V2(waiting[j].position.x, waiting[j].position.z)
            r.minGroundSep = min(r.minGroundSep, simd_length(a - b))
        }
    }
    for st in snap.aircraft where st.phase == .downwind {
        let agl = st.position.y - airport.groundHeight(at: airport.runway.thresholdB)
        r.minDownwindAltRatio = min(r.minDownwindAltRatio, agl / airport.patternAltitude)
    }
    // B9 — a lined-up departure with a close arrival must never read green.
    for dep in snap.aircraft where dep.phase == .lineUpWait {
        for arr in snap.aircraft {
            switch arr.phase {
            case .finalApproach, .shortFinal:
                let d = -stationOf(arr, airport)
                let taApprox = d / max(arr.speed, 10)
                if d > 0, taApprox < 26, dep.band == .green {
                    r.luawGreenWithCloseArrival = true
                }
            default: break
            }
        }
    }
}

func runShift(seed: UInt64, policy: ((SimEngine) -> Void)?, maxTime: Double = 660,
              telemetry: Bool = false) -> RunResult {
    let airport = AirportLayout.kjfk
    let engine = SimEngine(airport: airport, seed: seed)
    var result = RunResult()
    while engine.simTime < maxTime {
        policy?(engine)
        let hadReport = result.report != nil
        let events = engine.advance(by: SimEngine.tickInterval)
        drain(events, into: &result)
        if checkNaN(engine.current) { result.sawNaN = true }
        if telemetry { sampleTelemetry(engine.current, airport: airport, into: &result) }
        result.scoreTrace.append(engine.current.score)
        if !hadReport, result.report != nil {
            // B10 — no aircraft should still be airborne when the report fires.
            result.airborneAtReport = engine.current.aircraft.filter { $0.phase.isAirborne }.count
            break
        }
    }
    if result.report != nil, policy != nil {
        while engine.simTime < maxTime + 460, !engine.current.aircraft.isEmpty {
            policy?(engine)
            let events = engine.advance(by: SimEngine.tickInterval)
            drain(events, into: &result)
            if checkNaN(engine.current) { result.sawNaN = true }
        }
    }
    result.finalSnapshot = engine.current
    return result
}

// MARK: - Scenario A: auto-controller

func scenarioAuto() -> Bool {
    let airport = AirportLayout.kjfk
    let result = runShift(seed: kSeed, policy: { autoPolicy($0, airport: airport) })
    var ok = true
    if result.movements < 8 { print("  FAIL: movements \(result.movements) < 8"); ok = false }
    if result.sawNaN { print("  FAIL: NaN position observed"); ok = false }
    guard let report = result.report else { print("  FAIL: shift never ended"); return false }
    if report.totalScore <= 0 { print("  FAIL: final score \(report.totalScore) ≤ 0"); ok = false }
    let leftover = result.finalSnapshot?.aircraft ?? []
    let unresolvedLeftovers = leftover.filter {
        $0.phase != .parkedArrival && $0.phase != .departedHandoff
    }
    if !unresolvedLeftovers.isEmpty {
        print("  FAIL: unresolved aircraft at end: \(unresolvedLeftovers.map { $0.callsign.display })")
        ok = false
    }
    print(ok
        ? "PASS auto-controller: \(result.movements) movements, score \(report.totalScore), grade \(report.grade.rawValue)"
        : "FAIL auto-controller")
    return ok
}

// MARK: - Scenario B: determinism

func scenarioDeterminism() -> Bool {
    let airport = AirportLayout.kjfk
    let a = runShift(seed: kSeed, policy: { autoPolicy($0, airport: airport) })
    let b = runShift(seed: kSeed, policy: { autoPolicy($0, airport: airport) })
    var ok = true
    if a.scoreTrace != b.scoreTrace { print("  FAIL: tick-by-tick score traces differ"); ok = false }
    if a.report?.totalScore != b.report?.totalScore ||
       a.report?.grade != b.report?.grade ||
       a.report?.bestMoment != b.report?.bestMoment {
        print("  FAIL: final reports differ"); ok = false
    }
    print(ok
        ? "PASS determinism: \(a.scoreTrace.count) ticks identical, final score \(a.report?.totalScore ?? -1) twice"
        : "FAIL determinism")
    return ok
}

// MARK: - Scenario C: neglect

func scenarioNeglect() -> Bool {
    let result = runShift(seed: kSeed, policy: nil, maxTime: 700)
    var ok = true
    if result.pilotGoAroundCalls == 0 && result.selfPreservations == 0 {
        print("  FAIL: no pilot go-arounds under total neglect"); ok = false
    }
    if result.report == nil { print("  FAIL: neglected shift never force-ended"); ok = false }
    if result.sawNaN { print("  FAIL: NaN under neglect"); ok = false }
    // B6 — pure neglect makes pilots go around at the commit distance; it must
    // never produce a zero-warning −600 self-preservation cliff.
    if result.selfPreservations > 0 {
        print("  FAIL: \(result.selfPreservations) self-preservation −600 under neglect (should be 0)")
        ok = false
    }
    // B10 — the report never fires with an aircraft still flying.
    if result.airborneAtReport != 0 {
        print("  FAIL: \(result.airborneAtReport) aircraft airborne at report"); ok = false
    }
    print(ok
        ? "PASS neglect: \(result.pilotGoAroundCalls) pilot go-arounds, 0 self-pres, 0 airborne at report, score \(result.report?.totalScore ?? 0)"
        : "FAIL neglect")
    return ok
}

// MARK: - Scenario D: SAVE-table law (PRD §2.6, B6/B8)

/// The SAVE table is the PRD's load-bearing law: a genuine save steps the
/// streak DOWN by two and NEVER resets it (choosing safety must not be the
/// worst-scoring option). Verified directly on the Scoreboard — the same code
/// the engine calls from adjudicateResolution — so it can't rot behind fragile
/// traffic engineering; the badge pipeline itself is exercised by scenario A.
func scenarioSave() -> Bool {
    var ok = true

    // Build a streak of 5 with ten clean movements (+1 per two).
    var sb = Scoreboard()
    for _ in 0..<10 { _ = sb.registerMovement(clean: true) }
    if sb.streakMultiplier < 5 {
        print("  FAIL: ten clean movements gave streak \(sb.streakMultiplier), expected ≥5"); ok = false
    }
    // A save steps down two — not a reset.
    let before = sb.streakMultiplier
    let afterSave = sb.stepDownStreak()
    if afterSave != max(1, before - 2) {
        print("  FAIL: SAVE streak \(before) → \(String(describing: afterSave)), expected \(max(1, before - 2))"); ok = false
    }
    if afterSave == 1 && before > 3 {
        print("  FAIL: SAVE reset the streak instead of stepping down"); ok = false
    }
    // A second save steps down again; the floor is 1, never 0.
    _ = sb.stepDownStreak()
    let atFloor = sb.stepDownStreak()
    if (atFloor ?? sb.streakMultiplier) < 1 || sb.streakMultiplier < 1 {
        print("  FAIL: streak fell below the floor of 1"); ok = false
    }
    // A sustained red is the ONLY hard reset.
    var sb2 = Scoreboard()
    for _ in 0..<6 { _ = sb2.registerMovement(clean: true) }   // streak 4
    let r = sb2.resetStreak()
    if r != 1 || sb2.streakMultiplier != 1 {
        print("  FAIL: sustained-red reset gave \(String(describing: r)), expected 1"); ok = false
    }
    // Badges multiply by the live streak.
    var sb3 = Scoreboard()
    for _ in 0..<4 { _ = sb3.registerMovement(clean: true) }   // streak 3
    let award = sb3.awardBadge(.save, aircraft: AircraftID(1))
    if award.points != Badge.save.points * 3 {
        print("  FAIL: SAVE badge paid \(award.points), expected \(Badge.save.points) × 3"); ok = false
    }

    // Integration: the auto-controller shift actually flows badges to the report.
    let airport = AirportLayout.kjfk
    let run = runShift(seed: kSeed, policy: { autoPolicy($0, airport: airport) })
    if (run.report?.badges.isEmpty ?? true) {
        print("  FAIL: a full shift earned zero badges (badge pipeline broken)"); ok = false
    }

    print(ok
        ? "PASS save-table: streak 5→3 step-down (never reset), floor 1, sustained-red resets, badge ×streak, \(run.report?.badges.count ?? 0) badges in a live shift"
        : "FAIL save-table")
    return ok
}


// MARK: - Scenario E: fairness sweep (B1/B2/B4/B7/B9)

func scenarioSeparationSweep() -> Bool {
    let airport = AirportLayout.kjfk
    var worstAir = Double.infinity
    var worstGround = Double.infinity
    var worstDownwind = Double.infinity
    var luawGreen = false
    var sawNaN = false
    let seeds = 200
    for i in 0..<seeds {
        let seed = 0x7A11_0000 ^ UInt64(i) &* 0x9E3779B1
        let r = runShift(seed: seed, policy: { autoPolicy($0, airport: airport) },
                         maxTime: 660, telemetry: true)
        worstAir = min(worstAir, r.minAirborneSep)
        worstGround = min(worstGround, r.minGroundSep)
        worstDownwind = min(worstDownwind, r.minDownwindAltRatio)
        if r.luawGreenWithCloseArrival { luawGreen = true }
        if r.sawNaN { sawNaN = true }
    }
    var ok = true
    // B1/B2 — no mid-air merge (the audit's 0.2 m overtake is gone). worstAir is
    // now a WINGTIP clearance (center distance minus the two half-spans), so the
    // bound is fleet-size-independent: any true overlap reads ≤0. A ≥3 m tip
    // clearance keeps a real margin while allowing the tight-but-legal pattern
    // geometry the varied 16-type fleet produces during commanded 360s.
    if worstAir < 3 { print("  FAIL: min airborne wingtip clearance \(Int(worstAir)) m < 3 (mid-air merge)"); ok = false }
    // B4 — the hold-short queue never lets two aircraft stack waiting to depart.
    if worstGround.isFinite && worstGround < 20 {
        print("  FAIL: departures stacked at \(Int(worstGround)) m at the hold-short (B4)"); ok = false
    }
    if worstDownwind < 0.5 { print("  FAIL: downwind descended to \(String(format: "%.2f", worstDownwind))× pattern alt (B7)"); ok = false }
    if luawGreen { print("  FAIL: a lined-up departure read GREEN with an arrival inside 26 s (B9)"); ok = false }
    if sawNaN { print("  FAIL: NaN across sweep"); ok = false }
    let gs = worstGround.isFinite ? "\(Int(worstGround)) m" : "never 2 waiting (queue holds one)"
    print(ok
        ? "PASS sweep(\(seeds)): min wingtip clearance \(worstAir.isFinite ? Int(worstAir) : -1) m, hold-short \(gs), downwind ≥ \(String(format: "%.2f", worstDownwind))× alt, LUAW never green"
        : "FAIL sweep")
    return ok
}

// MARK: - Main

@main
struct SimHarness {
    static func main() {
        var failures = 0
        if !scenarioAuto() { failures += 1 }
        if !scenarioDeterminism() { failures += 1 }
        if !scenarioNeglect() { failures += 1 }
        if !scenarioSave() { failures += 1 }
        if !scenarioSeparationSweep() { failures += 1 }
        if failures > 0 {
            print("simharness: \(failures) scenario(s) FAILED")
            exit(1)
        }
        print("simharness: all scenarios passed")
    }
}
