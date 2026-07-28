import Foundation
import simd

// =============================================================================
// fuzz — adversarial robustness pass over the sim core.
//
// simharness proves the sim behaves under a COMPETENT controller and under
// total neglect. This proves it survives a hostile one: a player mashing every
// legal verb at every aircraft, in any order, at any moment.
//
// Checks, per tick, across many seeds:
//   • no NaN / non-finite state anywhere
//   • no aircraft below ground or above a sane ceiling
//   • speeds and altitudes stay inside believable envelopes
//   • the shift always terminates (no hang, no infinite phase)
//   • the score never runs away
//   • determinism holds even under a (seeded) random command stream
//
// Build:
//   swiftc -O -o /tmp/fuzz TowerCabSlammed/Sim/*.swift Tools/fuzz.swift && /tmp/fuzz
// =============================================================================

let airport = AirportLayout.kjfk

struct Violation: CustomStringConvertible {
    let seed: UInt64
    let tick: Int
    let what: String
    var description: String { "seed 0x\(String(seed, radix: 16)) tick \(tick): \(what)" }
}

/// Hostile policy: every tick, pick a random subset of aircraft and fire a
/// random LEGAL command at each. Seeded, so a failure reproduces exactly.
func chaosPolicy(_ engine: SimEngine, rng: inout SeededRNG) {
    let snap = engine.current
    for st in snap.aircraft.sorted(by: { $0.id.raw < $1.id.raw }) {
        // Command roughly one aircraft in four per tick — busy but not a
        // solid wall of input, so aircraft still get to fly between orders.
        guard rng.chance(0.25) else { continue }
        let legal = engine.legalCommands(for: st)
        guard !legal.isEmpty else { continue }
        let cmd = legal[Int(rng.double(in: 0...Double(legal.count) - 0.001))]
        engine.apply(CommandEnvelope(aircraft: st.id, command: cmd,
                                     timestamp: engine.simTime))
    }
}

func finite(_ d: Double) -> Bool { d.isFinite }

func check(_ snap: SimSnapshot, seed: UInt64, into out: inout [Violation]) {
    guard out.count < 6 else { return }          // a few examples are enough
    let t = snap.tickIndex
    if !finite(Double(snap.score)) { out.append(Violation(seed: seed, tick: t, what: "score not finite")) }
    if abs(snap.score) > 10_000_000 {
        out.append(Violation(seed: seed, tick: t, what: "score ran away: \(snap.score)"))
    }
    for st in snap.aircraft {
        let p = st.position
        let tag = "\(st.callsign.display) [\(st.kind.displayType)] \(st.phase.stripLabel)"
        if !finite(p.x) || !finite(p.y) || !finite(p.z) {
            out.append(Violation(seed: seed, tick: t, what: "\(tag) non-finite position")); continue
        }
        if !finite(st.heading) || !finite(st.speed) || !finite(st.verticalSpeed)
            || !finite(st.bank) || !finite(st.pitch) || !finite(st.crab) {
            out.append(Violation(seed: seed, tick: t, what: "\(tag) non-finite attitude/speed")); continue
        }
        // Envelope sanity. Ground datum is y = 0 at KJFK; allow a small epsilon
        // for the flare/rollout settle.
        if p.y < -1.0 {
            out.append(Violation(seed: seed, tick: t,
                                 what: "\(tag) below ground: y = \(String(format: "%.1f", p.y))"))
        }
        if p.y > 6000 {
            out.append(Violation(seed: seed, tick: t,
                                 what: "\(tag) absurd altitude: y = \(Int(p.y))"))
        }
        if st.speed < -0.001 {
            out.append(Violation(seed: seed, tick: t,
                                 what: "\(tag) negative speed \(String(format: "%.2f", st.speed))"))
        }
        // Nothing in this fleet exceeds ~300 kt (154 m/s) in the pattern.
        if st.speed > 200 {
            out.append(Violation(seed: seed, tick: t,
                                 what: "\(tag) speed \(Int(st.speed)) m/s exceeds envelope"))
        }
        // A grounded aircraft must not be flying and vice versa.
        switch st.phase {
        case .rollout, .exitingRunway, .taxiToApron, .taxiToRunway,
             .holdingShort, .lineUpWait, .parkedArrival, .startingUp:
            if p.y > 3.0 {
                out.append(Violation(seed: seed, tick: t,
                                     what: "\(tag) is on the ground but y = \(String(format: "%.1f", p.y))"))
            }
        default: break
        }
        // Sane distance from the field — nothing should wander to the moon.
        let horiz = (p.x * p.x + p.z * p.z).squareRoot()
        if horiz > 80_000 {
            out.append(Violation(seed: seed, tick: t,
                                 what: "\(tag) \(Int(horiz / 1000)) km from the field"))
        }
    }
}

/// Run one hostile shift. Returns violations plus the tick-by-tick score trace
/// (for the determinism check) and whether the shift ever ended.
func fuzzRun(seed: UInt64, maxTicks: Int = 12_000)
    -> (violations: [Violation], trace: [Int], ended: Bool) {
    let engine = SimEngine(airport: airport, seed: seed)
    var rng = SeededRNG(seed: seed ^ 0xF0FF_1234_5678)
    var out: [Violation] = []
    var trace: [Int] = []
    var ended = false
    var ticks = 0
    while ticks < maxTicks {
        chaosPolicy(engine, rng: &rng)
        for e in engine.advance(by: SimEngine.tickInterval) {
            if case .shiftEnded = e { ended = true }
        }
        let snap = engine.current
        check(snap, seed: seed, into: &out)
        trace.append(snap.score)
        ticks += 1
        if ended && snap.aircraft.isEmpty { break }
    }
    return (out, trace, ended)
}

@main
struct Fuzz {
    static func main() {
        let seeds = 120
        var violations: [Violation] = []
        var neverEnded: [UInt64] = []
        var nonDeterministic: [UInt64] = []

        for i in 0..<seeds {
            let seed = 0xF0FF_0000 ^ UInt64(i) &* 0x9E3779B1
            let a = fuzzRun(seed: seed)
            violations.append(contentsOf: a.violations)
            if !a.ended { neverEnded.append(seed) }
            // Determinism must hold under a hostile, seeded command stream too.
            let b = fuzzRun(seed: seed)
            if a.trace != b.trace { nonDeterministic.append(seed) }
        }

        var failed = false
        print("fuzz: \(seeds) seeds, hostile controller (random legal verbs)")

        if violations.isEmpty {
            print("PASS state envelope: no NaN, no below-ground, no runaway score/speed/altitude")
        } else {
            failed = true
            print("FAIL state envelope — \(violations.count) violation(s), first few:")
            for v in violations.prefix(6) { print("   \(v)") }
        }

        if neverEnded.isEmpty {
            print("PASS termination: every hostile shift ended and drained")
        } else {
            failed = true
            print("FAIL termination: \(neverEnded.count) shift(s) never ended, e.g. 0x"
                  + String(neverEnded[0], radix: 16))
        }

        if nonDeterministic.isEmpty {
            print("PASS determinism under chaos: identical score traces on replay")
        } else {
            failed = true
            print("FAIL determinism: \(nonDeterministic.count) seed(s) diverged, e.g. 0x"
                  + String(nonDeterministic[0], radix: 16))
        }

        if failed { exit(1) }
        print("fuzz: all checks passed")
    }
}
