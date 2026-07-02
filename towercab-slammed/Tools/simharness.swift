import Foundation
import simd

// =============================================================================
// simharness — headless macOS test rig for the TowerCab: Slammed sim core.
// Compiled together with TowerCabSlammed/Sim/*.swift (Foundation + simd only).
//
// Scenarios:
//   A. auto-controller shift  → ≥8 movements, no NaN, all resolve, score > 0
//   B. determinism            → same seed ⇒ identical tick-by-tick score/report
//   C. neglect                → pilot go-arounds fire, shift force-ends
//   D. engineered save        → amber conflict + goAround ⇒ SAVE, streak −2
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
}

func nearestArrivalTa(_ snap: SimSnapshot, airport: AirportLayout) -> Double? {
    var best: Double? = nil
    for st in snap.aircraft {
        switch st.phase {
        case .inboundFinal, .finalApproach, .shortFinal:
            let p = V2(st.position.x, st.position.z)
            let d = -simd_dot(p - airport.runway.thresholdB, airport.runway.dir22)
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

/// Rough seconds-to-threshold estimate for sequencing decisions.
func etaEstimate(_ st: AircraftState, airport: AirportLayout) -> Double? {
    let rw = airport.runway
    let p = V2(st.position.x, st.position.z)
    let v = max(st.speed, 15)
    let s = simd_dot(p - rw.thresholdB, rw.dir22)
    switch st.phase {
    case .inboundFinal, .finalApproach, .shortFinal:
        return max(0, -s) / v
    case .base:
        let lateral = abs(simd_dot(p - rw.thresholdB, V2(-rw.dir22.y, rw.dir22.x)))
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

    // Sequence arrivals by ETA so the pattern can be spaced with extends/360s.
    var sequenced: [(id: Int, eta: Double, st: AircraftState)] = []
    for st in snap.aircraft {
        if let e = etaEstimate(st, airport: airport) {
            sequenced.append((st.id.raw, e, st))
        }
    }
    sequenced.sort { $0.eta == $1.eta ? $0.id < $1.id : $0.eta < $1.eta }
    var leaderEta = -100.0
    var spacingRank: [Int: Int] = [:]   // id → depth in the bunch (1 = first follower)
    var bunchDepth = 0
    for entry in sequenced {
        let p = V2(entry.st.position.x, entry.st.position.z)
        let s = simd_dot(p - airport.runway.thresholdB, airport.runway.dir22)
        // Only space aircraft still meaningfully before the base turn;
        // past it, geometry has already committed them.
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
                // Play the game: resolve projected conflicts with a go-around.
                engine.apply(CommandEnvelope(aircraft: st.id, command: .goAround,
                                             timestamp: engine.simTime))
            } else if let rank = spacingRank[st.id.raw], st.phase == .downwind, !spacedOne {
                // One spacing action per tick so followers stagger, not couple.
                spacedOne = true
                let legal = engine.legalCommands(for: st)
                if rank == 1 && legal.contains(.extendDownwind) {
                    engine.apply(CommandEnvelope(aircraft: st.id, command: .extendDownwind,
                                                 timestamp: engine.simTime))
                } else if legal.contains(.make360(left: false)) {
                    engine.apply(CommandEnvelope(aircraft: st.id,
                                                 command: .make360(left: false),
                                                 timestamp: engine.simTime))
                }
            } else if !st.clearedToLand {
                engine.apply(CommandEnvelope(aircraft: st.id, command: .clearedToLand,
                                             timestamp: engine.simTime))
            }
        case .rollout:
            if (ta ?? .infinity) < 65 {
                engine.apply(CommandEnvelope(aircraft: st.id, command: .expediteExit,
                                             timestamp: engine.simTime))
            }
        case .parkedArrival, .departedHandoff:
            engine.apply(CommandEnvelope(aircraft: st.id, command: .handoff,
                                         timestamp: engine.simTime))
        case .holdingShort:
            if !clearedOneTakeoff && !busy && (ta ?? .infinity) > 60 {
                clearedOneTakeoff = true
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

func runShift(seed: UInt64, policy: ((SimEngine) -> Void)?, maxTime: Double = 560) -> RunResult {
    let airport = AirportLayout.kavx
    let engine = SimEngine(airport: airport, seed: seed)
    var result = RunResult()
    while engine.simTime < maxTime {
        policy?(engine)
        let events = engine.advance(by: SimEngine.tickInterval)
        drain(events, into: &result)
        if checkNaN(engine.current) { result.sawNaN = true }
        result.scoreTrace.append(engine.current.score)
        if result.report != nil { break }
    }
    // The sim keeps living after the report; give late taxiers time to park
    // and let the policy flick the final strips.
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
    let airport = AirportLayout.kavx
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
    if result.removed + leftover.count != result.spawned {
        print("  FAIL: spawned \(result.spawned) ≠ removed \(result.removed) + leftover \(leftover.count)")
        ok = false
    }
    print(ok
        ? "PASS auto-controller: \(result.movements) movements, score \(report.totalScore), grade \(report.grade.rawValue), all \(result.spawned) aircraft resolved"
        : "FAIL auto-controller")
    return ok
}

// MARK: - Scenario B: determinism

func scenarioDeterminism() -> Bool {
    let airport = AirportLayout.kavx
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
    let result = runShift(seed: kSeed, policy: nil, maxTime: 600)
    var ok = true
    if result.pilotGoAroundCalls == 0 && result.selfPreservations == 0 {
        print("  FAIL: no pilot go-arounds under total neglect"); ok = false
    }
    if result.report == nil { print("  FAIL: neglected shift never force-ended"); ok = false }
    if result.sawNaN { print("  FAIL: NaN under neglect"); ok = false }
    print(ok
        ? "PASS neglect: \(result.pilotGoAroundCalls) pilot go-around calls, force-ended with score \(result.report?.totalScore ?? 0)"
        : "FAIL neglect")
    return ok
}

// MARK: - Scenario D: engineered SAVE

func scenarioSave() -> Bool {
    let airport = AirportLayout.kavx
    let engine = SimEngine(airport: airport, seed: kSeed)
    var result = RunResult()
    var trapDeparture: AircraftID? = nil
    var trapArrival: AircraftID? = nil
    var trapPhase = 0            // 0 build streak, 1 armed lineup, 2 done
    var streakBefore = 1
    var streakAfterSave: Int? = nil
    var sawSave = false

    while engine.simTime < 560 && trapPhase < 2 {
        let snap = engine.current
        let ta = nearestArrivalTa(snap, airport: airport)
        let busy = runwayBusy(snap)

        for st in snap.aircraft.sorted(by: { $0.id.raw < $1.id.raw }) {
            switch st.phase {
            case .inboundFinal, .finalApproach, .shortFinal, .downwind, .base:
                if !st.clearedToLand && st.id != trapArrival {
                    engine.apply(CommandEnvelope(aircraft: st.id, command: .clearedToLand,
                                                 timestamp: engine.simTime))
                }
            case .parkedArrival, .departedHandoff:
                engine.apply(CommandEnvelope(aircraft: st.id, command: .handoff,
                                             timestamp: engine.simTime))
            case .holdingShort:
                // Keep one departure in reserve as the trap once the streak is up.
                let reserve = snap.streakMultiplier >= 3 && trapDeparture == nil
                if reserve {
                    trapDeparture = st.id
                } else if st.id != trapDeparture && !busy && (ta ?? .infinity) > 60 {
                    engine.apply(CommandEnvelope(aircraft: st.id,
                                                 command: .clearedForTakeoff(immediate: false),
                                                 timestamp: engine.simTime))
                }
            default: break
            }
        }

        // Spring the trap: arrival committed 23–27 s out, trap departure ready.
        if trapPhase == 0, let dep = trapDeparture, let taNow = ta, (23...27).contains(taNow),
           let arr = snap.aircraft.first(where: {
               ($0.phase == .finalApproach || $0.phase == .shortFinal) && $0.clearedToLand
           }),
           snap.aircraft.contains(where: { $0.id == dep && $0.phase == .holdingShort }) {
            trapArrival = arr.id
            engine.apply(CommandEnvelope(aircraft: dep, command: .lineUpAndWait,
                                         timestamp: engine.simTime))
            trapPhase = 1
        } else if trapPhase == 1, let arrID = trapArrival {
            // Wait for the amber projection, then resolve it by hand.
            if let arr = snap.aircraft.first(where: { $0.id == arrID }), arr.band >= .amber {
                streakBefore = snap.streakMultiplier
                engine.apply(CommandEnvelope(aircraft: arrID, command: .goAround,
                                             timestamp: engine.simTime))
                trapPhase = 2
            }
        }

        let events = engine.advance(by: SimEngine.tickInterval)
        drain(events, into: &result)
        for e in events {
            if case .badge(let a) = e, a.badge == .save { sawSave = true }
            if case .streakChanged(let m) = e, trapPhase == 2, streakAfterSave == nil {
                streakAfterSave = m
            }
        }
    }
    // Let the goAround's tick land the badge if the loop exited on trapPhase.
    if trapPhase == 2 && !sawSave {
        let events = engine.advance(by: SimEngine.tickInterval)
        drain(events, into: &result)
        for e in events {
            if case .badge(let a) = e, a.badge == .save { sawSave = true }
            if case .streakChanged(let m) = e, streakAfterSave == nil { streakAfterSave = m }
        }
    }

    var ok = true
    if trapPhase < 2 { print("  FAIL: never found an amber window to engineer"); ok = false }
    if !sawSave { print("  FAIL: SAVE badge not awarded"); ok = false }
    let expected = max(1, streakBefore - 2)
    if streakBefore >= 3 {
        if streakAfterSave != expected {
            print("  FAIL: streak \(streakBefore) → \(String(describing: streakAfterSave)), expected step-down to \(expected)")
            ok = false
        }
        if streakAfterSave == 1 && expected != 1 {
            print("  FAIL: streak was RESET, not stepped down"); ok = false
        }
    }
    print(ok
        ? "PASS save: amber engineered, SAVE +750 awarded, streak \(streakBefore) → \(streakAfterSave ?? streakBefore) (step-down, not reset)"
        : "FAIL save")
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
        if failures > 0 {
            print("simharness: \(failures) scenario(s) FAILED")
            exit(1)
        }
        print("simharness: all scenarios passed")
    }
}
