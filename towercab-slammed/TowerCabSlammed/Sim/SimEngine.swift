import Foundation
import simd

// =============================================================================
// SimEngine — the deterministic core (PRD §9.3).
//
// Fixed 10 Hz tick, seeded RNG, zero UIKit/SceneKit imports. Commands are
// timestamped at input and applied at the next tick; presentation interpolates
// between the last two ticks. The production build ports this to fixed-point
// C# per the PRD — the slice validates behavior, not bit-exactness.
//
// Contract stub: the full implementation lives in SimEngine+Tick.swift,
// ShiftScript.swift, Conflict.swift and Scoring.swift (owned by the sim
// subsystem). This file defines the public surface everything else calls.
// =============================================================================

public final class SimEngine {

    public static let tickInterval: Double = 0.1   // 10 Hz, PRD-canonical

    public let airport: AirportLayout
    public let seed: UInt64

    public private(set) var tickIndex: Int = 0
    public var simTime: Double { Double(tickIndex) * Self.tickInterval }

    /// State after the most recent tick.
    public private(set) var current: SimSnapshot
    /// State one tick earlier (interpolation source).
    public private(set) var previous: SimSnapshot

    // Internal mutable world — owned by the sim implementation files.
    var rng: SeededRNG
    var aircraft: [Aircraft] = []
    var pendingCommands: [CommandEnvelope] = []
    var scoreboard = Scoreboard()
    var script: ShiftScript
    var accumulator: Double = 0
    var eventQueue: [SimEvent] = []
    var shiftPhase: ShiftPhase = .ramp
    var wind: Wind
    var radio: RadioVoice
    var conflicts = ConflictTracker()
    var delayedRadio: [(time: Double, call: RadioCall)] = []
    var spawnCursor = 0
    var nextAircraftNumber = 1
    var shiftEndedFired = false
    /// Most recent expedited compliance (immediate takeoff / slick exit) for
    /// the NO DELAY chain: (completion time, complying aircraft).
    var lastExpedite: (time: Double, id: AircraftID)? = nil
    var retiredDelaySum: Double = 0
    var retiredCount = 0
    var lastSpawnAt: Double = -100
    // B11 — par accumulated from traffic that ACTUALLY spawned, so cap-
    // abandoned orders never grade against the player.
    var spawnedParScore: Int = 0
    var spawnedParMovements: Int = 0
    // B21 — running count of arrivals that parked with no free spot.
    var overflowCount = 0

    public init(airport: AirportLayout, seed: UInt64) {
        self.airport = airport
        self.seed = seed
        self.rng = SeededRNG(seed: seed)
        self.script = ShiftScript.standardShift(seed: seed, airport: airport)
        // B26 — seed-derived so every shift's wind reads a little different.
        var wrng = SeededRNG(seed: seed ^ 0xA17C0DE_5EED_9E37)
        let dir = (wrng.double(in: 210...260) / 10).rounded() * 10
        let spd = wrng.double(in: 4...12).rounded()
        let wind = Wind(directionDeg: dir, speedKts: spd, gustKts: spd + 5)
        self.wind = wind
        self.radio = RadioVoice(seed: seed, wind: wind,
                                towerName: airport.towerName,
                                runwayName: airport.runway.nameB)
        let empty = SimSnapshot(simTime: 0, tickIndex: 0, aircraft: [], score: 0,
                                streakMultiplier: 1, shiftPhase: .ramp,
                                shiftTimeRemaining: script.duration, wind: wind)
        self.current = empty
        self.previous = empty
    }

    /// Advance real time; runs zero or more fixed ticks. Returns events fired.
    public func advance(by dt: Double) -> [SimEvent] {
        accumulator += min(dt, 0.5)   // clamp huge hitches; sessions never explode
        var fired: [SimEvent] = []
        while accumulator >= Self.tickInterval {
            accumulator -= Self.tickInterval
            previous = current
            tick()
            tickIndex += 1
            current = makeSnapshot()
            fired.append(contentsOf: eventQueue)
            eventQueue.removeAll()
        }
        return fired
    }

    /// Issue a player command. Validated against the aircraft's phase.
    @discardableResult
    public func apply(_ envelope: CommandEnvelope) -> CommandResult {
        guard let ac = aircraft.first(where: { $0.id == envelope.aircraft }), ac.phase != .removed else {
            return .invalid(reason: "no such aircraft")
        }
        guard legalCommands(for: ac).contains(where: { $0 == envelope.command }) else {
            return .invalid(reason: "not valid for \(ac.phase.stripLabel)")
        }
        pendingCommands.append(envelope)
        return .accepted
    }

    /// Interpolation fraction within the current tick for a presentation clock.
    public var interpolationAlpha: Double { accumulator / Self.tickInterval }

    /// Per-frame render states, interpolated between the last two ticks.
    public func renderStates(alpha: Double) -> [AircraftRenderState] {
        let a = max(0, min(1, alpha))
        var prevByID: [AircraftID: AircraftState] = [:]
        for s in previous.aircraft { prevByID[s.id] = s }
        return current.aircraft.compactMap { cur in
            guard cur.phase != .removed else { return nil }
            let prev = prevByID[cur.id] ?? cur
            let pos = prev.position + (cur.position - prev.position) * a
            let hdg = prev.heading + angleDelta(from: prev.heading, to: cur.heading) * a
            let bank = prev.bank + (cur.bank - prev.bank) * a
            let pitch = prev.pitch + (cur.pitch - prev.pitch) * a
            let crab = prev.crab + angleDelta(from: prev.crab, to: cur.crab) * a
            let thr = prev.throttle + (cur.throttle - prev.throttle) * a
            let spd = prev.speed + (cur.speed - prev.speed) * a
            // World velocity from the last tick — lets the presentation layer
            // extrapolate past alpha=1 to kill the 10 Hz seam for fast movers.
            let vel = (cur.position - prev.position) / Self.tickInterval
            return AircraftRenderState(id: cur.id, kind: cur.kind, livery: cur.livery,
                                       phase: cur.phase, position: pos, heading: hdg,
                                       bank: bank, pitch: pitch, crab: crab, throttle: thr,
                                       speed: spd, velocity: vel,
                                       gearDown: cur.gearDown,
                                       landingLightsOn: cur.landingLightsOn, band: cur.band)
        }
    }

    /// Context-legal verbs for the radial bloom (≤6, PRD §2.3).
    public func legalCommands(for state: AircraftState) -> [Command] {
        guard let ac = aircraft.first(where: { $0.id == state.id }) else { return [] }
        return legalCommands(for: ac)
    }
}
