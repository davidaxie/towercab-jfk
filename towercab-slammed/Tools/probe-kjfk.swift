import Foundation
import simd

// =============================================================================
// probe-kjfk — measurement rig for the KJFK re-base audit (2026-07-28).
//
// Not a pass/fail harness: it instruments a competent auto-controller across
// many seeds and PRINTS the distributions the audit needs — touchdown/float
// geometry, runway occupancy, exit selection, taxi-in duration, strip-cap
// saturation, throughput vs authored traffic, and ground separation among ALL
// moving aircraft (the existing simharness deliberately measures only the
// hold-short queue).
//
// Build:
//   swiftc -O -o /tmp/probekjfk TowerCabSlammed/Sim/*.swift Tools/probe-kjfk.swift
// =============================================================================

let airport = AirportLayout.kjfk

// MARK: - Geometry helpers (mirrors simharness)

func perpTower(_ a: AirportLayout) -> V2 {
    let d = a.runway.dir22
    let p = V2(d.y, -d.x)
    let toCab = V2(a.towerCabEye.x, a.towerCabEye.z) - a.runway.thresholdB
    return simd_dot(toCab, p) >= 0 ? p : -p
}
func stationOf(_ st: AircraftState) -> Double {
    let p = V2(st.position.x, st.position.z)
    return simd_dot(p - airport.runway.thresholdB, airport.runway.dir22)
}
func crossOf(_ st: AircraftState) -> Double {
    let p = V2(st.position.x, st.position.z)
    return simd_dot(p - airport.runway.thresholdB, perpTower(airport))
}
func nearestArrivalTa(_ snap: SimSnapshot) -> Double? {
    var best: Double? = nil
    for st in snap.aircraft {
        switch st.phase {
        case .inboundFinal, .finalApproach, .shortFinal:
            let d = -stationOf(st)
            guard d > 0 else { continue }
            let ta = d / max(st.speed, 10)
            if best == nil || ta < best! { best = ta }
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
func etaEstimate(_ st: AircraftState) -> Double? {
    let rw = airport.runway
    let p = V2(st.position.x, st.position.z)
    let v = max(st.speed, 15)
    let s = simd_dot(p - rw.thresholdB, rw.dir22)
    switch st.phase {
    case .inboundFinal, .finalApproach, .shortFinal: return max(0, -s) / v
    case .base:
        let lateral = abs(simd_dot(p - rw.thresholdB, perpTower(airport)))
        return (lateral - airport.baseTurnStation) / v
    case .downwind:
        return max(0, s - airport.baseTurnStation) / v
            + (airport.downwindOffset - airport.baseTurnStation) / v
    default: return nil
    }
}

/// Same competent policy simharness uses, so probe numbers describe the same
/// build behaviour the existing tests bless.
func autoPolicy(_ engine: SimEngine) {
    let snap = engine.current
    let ta = nearestArrivalTa(snap)
    let busy = runwayBusy(snap)

    var sequenced: [(id: Int, eta: Double, st: AircraftState)] = []
    for st in snap.aircraft {
        if let e = etaEstimate(st) { sequenced.append((st.id.raw, e, st)) }
    }
    sequenced.sort { $0.eta == $1.eta ? $0.id < $1.id : $0.eta < $1.eta }
    var leaderEta = -100.0
    var spacingRank: [Int: Int] = [:]
    var bunchDepth = 0
    for entry in sequenced {
        let s = stationOf(entry.st)
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
            // Probe deviation: ask EVERY rollout to expedite when pressed, so we
            // measure whether SLICK EXIT is reachable at all (simharness gates
            // this on !engineIsJet, which at an all-jet field never fires).
            if (ta ?? .infinity) < 90 {
                engine.apply(CommandEnvelope(aircraft: st.id, command: .expediteExit,
                                             timestamp: engine.simTime))
            }
        case .parkedArrival, .departedHandoff:
            engine.apply(CommandEnvelope(aircraft: st.id, command: .handoff,
                                         timestamp: engine.simTime))
        case .holdingShort:
            if !clearedOneTakeoff && !busy && (ta ?? .infinity) > 45 {
                clearedOneTakeoff = true
                engine.apply(CommandEnvelope(aircraft: st.id,
                                             command: .clearedForTakeoff(immediate: false),
                                             timestamp: engine.simTime))
            }
        case .lineUpWait:
            if !busy && (ta ?? .infinity) > 40 {
                engine.apply(CommandEnvelope(aircraft: st.id,
                                             command: .clearedForTakeoff(immediate: false),
                                             timestamp: engine.simTime))
            }
        default: break
        }
    }
}

// MARK: - Per-landing record

struct Landing {
    var callsign = ""
    var type = ""
    var flareStation = Double.nan     // station where .flare began (negative = before threshold)
    var flareTime = Double.nan
    var touchdownStation = Double.nan // station where .rollout began
    var touchdownTime = Double.nan
    var thresholdTime = Double.nan    // time station crossed 0
    var exitStation = Double.nan
    var exitTime = Double.nan         // time .exitingRunway began
    var parkedTime = Double.nan
    var floatDistance: Double { touchdownStation - flareStation }
    var floatTime: Double { touchdownTime - flareTime }
    var occupancy: Double { exitTime - thresholdTime }
    var taxiIn: Double { parkedTime - exitTime }
}

struct Probe {
    var landings: [Landing] = []
    var maxActiveStrips = 0
    var ticksAtCap = 0
    var totalTicks = 0
    var spawned = 0
    var authoredOrders = 0
    var movements = 0
    var slickExits = 0
    var badges: [String: Int] = [:]
    var report: ShiftReport? = nil
    var minGroundTipClear = Double.infinity
    var groundConflictEvents = 0      // ticks with any moving-ground pair < 0 m tip clearance
    var headOnEvents = 0              // opposed-direction pairs on the parallel < 60 m
    var unfinishedAtReport = 0
    var stillTaxiingAtReport = 0
    var departuresQueuedAtReport = 0
    var goArounds = 0
    var selfPres = 0
}

let groundMoving: Set<Int> = []   // placeholder to keep the enum switch explicit below
func isGroundMoving(_ p: FlightPhase) -> Bool {
    switch p {
    case .rollout, .exitingRunway, .taxiToApron, .taxiToRunway, .takeoffRoll: return true
    default: return false
    }
}
func isGroundAny(_ p: FlightPhase) -> Bool {
    switch p {
    case .rollout, .exitingRunway, .taxiToApron, .taxiToRunway, .takeoffRoll,
         .holdingShort, .lineUpWait, .parkedArrival, .startingUp: return true
    default: return false
    }
}

func runProbe(seed: UInt64, maxTime: Double = 900) -> Probe {
    let engine = SimEngine(airport: airport, seed: seed)
    var p = Probe()
    p.authoredOrders = ShiftScript.standardShift(seed: seed, airport: airport).orders.count

    var rec: [Int: Landing] = [:]
    var prevPhase: [Int: FlightPhase] = [:]
    var prevStation: [Int: Double] = [:]
    var reported = false

    while engine.simTime < maxTime {
        autoPolicy(engine)
        let events = engine.advance(by: SimEngine.tickInterval)
        for e in events {
            switch e {
            case .movementCompleted: p.movements += 1
            case .aircraftSpawned: p.spawned += 1
            case .shiftEnded(let r):
                if !reported {
                    p.report = r
                    reported = true
                    let live = engine.current.aircraft
                    p.unfinishedAtReport = live.filter {
                        $0.phase != .parkedArrival && $0.phase != .departedHandoff
                    }.count
                    p.stillTaxiingAtReport = live.filter {
                        $0.phase == .taxiToApron || $0.phase == .exitingRunway
                    }.count
                    p.departuresQueuedAtReport = live.filter {
                        $0.phase == .startingUp || $0.phase == .taxiToRunway
                            || $0.phase == .holdingShort
                    }.count
                }
            case .badge(let a):
                p.badges[a.badge.label, default: 0] += 1
                if a.badge == .slickExit { p.slickExits += 1 }
            case .selfPreservation: p.selfPres += 1
            case .radio(let call):
                if case .pilot = call.speaker, call.text.lowercased().contains("going around") {
                    p.goArounds += 1
                }
            default: break
            }
        }

        let snap = engine.current
        let now = snap.simTime
        p.totalTicks += 1

        // Strip-cap pressure: same definition the engine gates spawns on.
        let active = snap.aircraft.filter {
            switch $0.phase {
            case .parkedArrival, .departedHandoff, .removed: return false
            default: return true
            }
        }.count
        p.maxActiveStrips = max(p.maxActiveStrips, active)
        if active >= 12 { p.ticksAtCap += 1 }

        // Landing lifecycle.
        for st in snap.aircraft {
            let id = st.id.raw
            let s = stationOf(st)
            let was = prevPhase[id]
            if st.phase == .flare && was != .flare {
                var l = rec[id] ?? Landing()
                l.callsign = st.callsign.display
                l.type = st.kind.displayType
                l.flareStation = s
                l.flareTime = now
                rec[id] = l
            }
            if let ps = prevStation[id], ps < 0, s >= 0, st.phase.isArrivalFlow {
                var l = rec[id] ?? Landing()
                if l.thresholdTime.isNaN { l.thresholdTime = now }
                rec[id] = l
            }
            if st.phase == .rollout && was != .rollout {
                var l = rec[id] ?? Landing()
                l.touchdownStation = s
                l.touchdownTime = now
                rec[id] = l
            }
            if st.phase == .exitingRunway && was != .exitingRunway {
                var l = rec[id] ?? Landing()
                l.exitStation = s
                l.exitTime = now
                rec[id] = l
            }
            if st.phase == .parkedArrival && was != .parkedArrival {
                var l = rec[id] ?? Landing()
                l.parkedTime = now
                rec[id] = l
            }
            prevPhase[id] = st.phase
            prevStation[id] = s
        }

        // Ground separation among ALL moving ground traffic (not just the queue).
        let ground = snap.aircraft.filter { isGroundMoving($0.phase) }
        var conflictThisTick = false
        var headOnThisTick = false
        for i in 0..<ground.count {
            for j in (i + 1)..<ground.count {
                let a = ground[i], b = ground[j]
                let pa = V2(a.position.x, a.position.z), pb = V2(b.position.x, b.position.z)
                let d = simd_length(pa - pb)
                let tip = d - (a.kind.wingspanMeters + b.kind.wingspanMeters) / 2
                p.minGroundTipClear = min(p.minGroundTipClear, tip)
                if tip < 0 { conflictThisTick = true }
                // Head-on on the shared parallel: both off the runway centerline,
                // closing head-to-head within 60 m.
                let onParallel = abs(crossOf(a) - 120) < 45 && abs(crossOf(b) - 120) < 45
                let opposed = simd_dot(headingDirection(a.heading), headingDirection(b.heading)) < -0.5
                if onParallel && opposed && d < 60 { headOnThisTick = true }
            }
        }
        if conflictThisTick { p.groundConflictEvents += 1 }
        if headOnThisTick { p.headOnEvents += 1 }

        if reported && snap.aircraft.isEmpty { break }
    }
    p.landings = rec.values.filter { !$0.touchdownStation.isNaN }
    return p
}

// MARK: - Stats

func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }
func pct(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let i = max(0, min(s.count - 1, Int((Double(s.count - 1) * q).rounded())))
    return s[i]
}
func f(_ x: Double, _ d: Int = 1) -> String {
    x.isNaN ? "n/a" : String(format: "%.\(d)f", x)
}
func line(_ title: String) { print("\n── \(title) " + String(repeating: "─", count: max(0, 58 - title.count))) }

// MARK: - Main

@main
struct ProbeKJFK {
    static func main() {
        let seedCount = 40
        var probes: [Probe] = []
        for i in 0..<seedCount {
            let seed = 0x7A11_0000 ^ UInt64(i) &* 0x9E3779B1
            probes.append(runProbe(seed: seed))
        }

        let allLandings = probes.flatMap { $0.landings }
        let rw = airport.runway

        print("KJFK probe — \(seedCount) seeds, competent auto-controller")
        print("runway \(rw.nameB)/\(rw.nameA)  length \(f(rw.length)) m  exits at "
              + airport.exits.map { "\(Int($0.stationFrom22))m\($0.isPreferred ? "*" : "")" }
                .joined(separator: ", "))

        line("Touchdown & float")
        let td = allLandings.map { $0.touchdownStation }
        let fl = allLandings.map { $0.floatDistance }
        let ft = allLandings.map { $0.floatTime }
        print("landings sampled            \(allLandings.count)")
        print("touchdown station  (m past 31L thr)  mean \(f(mean(td)))  p10 \(f(pct(td,0.1)))  p90 \(f(pct(td,0.9)))")
        print("float distance     (flare→touchdown) mean \(f(mean(fl)))  p90 \(f(pct(fl,0.9)))")
        print("float TIME         (seconds)         mean \(f(mean(ft),2))  p90 \(f(pct(ft,0.9),2))")
        print("  reference: real airliners touch down ~300 m past the threshold, flare ~4-7 s")

        line("Exit selection & runway occupancy")
        var exitHist: [Int: Int] = [:]
        for l in allLandings where !l.exitStation.isNaN {
            let nearest = airport.exits.min { abs($0.stationFrom22 - l.exitStation)
                                            < abs($1.stationFrom22 - l.exitStation) }!
            exitHist[Int(nearest.stationFrom22), default: 0] += 1
        }
        for (st, n) in exitHist.sorted(by: { $0.key < $1.key }) {
            let preferred = airport.exits.first { Int($0.stationFrom22) == st }?.isPreferred ?? false
            let share = Double(n) / Double(max(1, allLandings.count)) * 100
            print("exit \(st) m\(preferred ? " (preferred / SLICK EXIT target)" : "")  \(n) landings  \(f(share))%")
        }
        let occ = allLandings.map { $0.occupancy }.filter { !$0.isNaN && $0 > 0 }
        print("runway occupancy (threshold→clear)   mean \(f(mean(occ)))s  p90 \(f(pct(occ,0.9)))s")
        print("SLICK EXIT badges awarded            \(probes.reduce(0) { $0 + $1.slickExits }) across \(seedCount) seeds")

        line("Taxi-in & shift completion")
        let taxi = allLandings.map { $0.taxiIn }.filter { !$0.isNaN && $0 > 0 }
        print("taxi-in duration (exit→parked)       mean \(f(mean(taxi)))s  p90 \(f(pct(taxi,0.9)))s")
        print("  shift duration is \(f(ShiftScript.standardShift(seed: 1, airport: airport).duration))s")
        print("landings that never parked in-probe  \(allLandings.filter { $0.parkedTime.isNaN }.count)/\(allLandings.count)")
        print("unfinished aircraft at report        mean \(f(mean(probes.map { Double($0.unfinishedAtReport)}),2))")
        print("  of which still taxiing in          mean \(f(mean(probes.map { Double($0.stillTaxiingAtReport)}),2))")
        print("  of which departures never launched mean \(f(mean(probes.map { Double($0.departuresQueuedAtReport)}),2))")

        line("Throughput vs authored traffic")
        print("authored orders   mean \(f(mean(probes.map { Double($0.authoredOrders) }),1))")
        print("actually spawned  mean \(f(mean(probes.map { Double($0.spawned) }),1))")
        print("movements scored  mean \(f(mean(probes.map { Double($0.movements) }),1))")
        print("max active strips mean \(f(mean(probes.map { Double($0.maxActiveStrips) }),1))  (cap 12)")
        let capShare = probes.map { Double($0.ticksAtCap) / Double(max(1,$0.totalTicks)) * 100 }
        print("time spent AT the strip cap  mean \(f(mean(capShare)))%  max \(f(capShare.max() ?? 0))%")
        let flows = probes.compactMap { $0.report.map { Double($0.flow) } }
        let grades = probes.compactMap { $0.report?.grade.rawValue }
        var gradeHist: [String: Int] = [:]
        for g in grades { gradeHist[g, default: 0] += 1 }
        print("reported Flow axis  mean \(f(mean(flows)))/100")
        print("grades              " + gradeHist.sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }.joined(separator: "  "))

        line("Ground separation (ALL moving traffic)")
        let mg = probes.map { $0.minGroundTipClear }.filter { $0.isFinite }
        print("min wingtip clearance  worst \(f(mg.min() ?? .nan))m  mean-of-seed-worst \(f(mean(mg)))m")
        print("seeds with an overlap (<0 m)   \(probes.filter { $0.groundConflictEvents > 0 }.count)/\(seedCount)")
        print("seeds with a head-on <60 m on the parallel  \(probes.filter { $0.headOnEvents > 0 }.count)/\(seedCount)")

        line("Pressure & badges")
        print("pilot go-arounds  mean \(f(mean(probes.map { Double($0.goArounds) }),2))")
        print("self-preservations mean \(f(mean(probes.map { Double($0.selfPres) }),2))")
        var allBadges: [String: Int] = [:]
        for p in probes { for (k, v) in p.badges { allBadges[k, default: 0] += v } }
        print("badges: " + (allBadges.isEmpty ? "none"
            : allBadges.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "  ")))
    }
}
