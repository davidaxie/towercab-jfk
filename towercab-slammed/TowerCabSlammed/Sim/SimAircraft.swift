import Foundation
import simd

// =============================================================================
// Aircraft — mutable per-aircraft sim entity, owned by SimEngine.
// Pure state + small kinematic helpers; all behavior decisions live in
// SimEngine+Tick.swift so the tick order is one readable narrative.
// =============================================================================

final class Aircraft {
    let id: AircraftID
    var kind: AircraftKind
    var livery: Livery
    var callsign: Callsign
    let isArrival: Bool
    let straightIn: Bool

    var phase: FlightPhase = .removed {
        didSet { if phase != oldValue { phaseTime = 0 } }
    }

    // Kinematics (world meters / radians / m/s)
    var position: V3
    var heading: Double
    var speed: Double = 0
    var verticalSpeed: Double = 0
    var bank: Double = 0
    var pitch: Double = 0
    /// Nose-vs-ground-track yaw offset for crosswind (radians). PRESENTATION-ONLY:
    /// the fuselage points at heading+crab; the deterministic ground track stays
    /// on `heading`. Never feeds position/verticalSpeed/heading/scoring/RNG.
    var crab: Double = 0
    /// Engine power 0–1 for prop/fan blur + exhaust. PRESENTATION-ONLY.
    var throttle: Double = 0
    var gearDown = true
    var landingLightsOn = false

    // Clearances
    var clearedToLand = false
    var clearedForTakeoff = false
    var holdingPosition = false
    var immediateTakeoff = false

    // HUD / ledger
    var delaySeconds: Double = 0
    var band: ConflictBand = .green
    var gapSeconds: Double? = nil
    var urgency: Double? = nil

    // Guidance
    var route: [V2] = []
    var routeIndex = 0
    var phaseTime: Double = 0        // seconds since entering current phase
    var waitSeconds: Double = 0      // continuous wait (drives nags)
    var lastNagAt: Double = -1
    var nagCount = 0
    var extendRemaining: Double = 0  // extra downwind seconds still owed
    var extendUsed = false
    var orbitRemaining: Double = 0   // radians left in a commanded 360
    var orbitLeft = false
    var resumePhase: FlightPhase = .finalApproach
    var expedited = false            // expedite-exit acknowledged
    var expeditedHonored = false     // made the preferred exit under expedite
    var touchdownStation: Double = 0 // chosen at spawn (determinism)
    var exitStation: Double = 0      // rollout target, picked at touchdown
    var exitIsPreferred = false
    /// B15 — chosen exit is the earliest THIS type could physically make
    /// under expedite braking (the honest SLICK EXIT condition).
    var exitIsEarliestReachable = false
    var exitTaxiwayName: String? = nil
    /// B8 — last commit-shaped command (LUAW / takeoff) put THIS aircraft on
    /// the runway; a departure whose commit is newer than an arrival's is the
    /// player's own manufactured gap and pays nothing.
    var lastCommitAt: Double = -100
    /// B8 — when this arrival became committed (cleared to land / short final).
    var committedAt: Double = -100
    /// B6 — a pilot self-preservation bail fires at most once per aircraft.
    var selfPresFired = false
    /// B16 — the specific arrival a TIGHT GAP was armed against.
    var tightGapArmedArrival: AircraftID? = nil
    /// B21 — nth overflow arrival with no free apron spot (parking offset).
    var overflowIndex = 0
    /// B18 — go-around issued from the pattern rejoins the downwind directly.
    var gaFromPattern = false
    /// B2/merge — staggered downwind station a go-around rejoins at, so two
    /// rejoining aircraft never stack on the entry point.
    var rejoinEntryStation: Double = .nan
    var apronSpot: Int = -1
    var preRollPause: Double = 0     // seconds left before brake release
    var lineupComplete = false
    var tightGapArmed = false
    var saveAwarded = false
    var dirty = false                // was party to a sustained red
    var spawnedAt: Double = 0
    var movementScored = false
    var goAroundCount = 0            // pilot-forced only

    init(id: AircraftID, kind: AircraftKind, livery: Livery, callsign: Callsign,
         isArrival: Bool, straightIn: Bool, position: V3, heading: Double) {
        self.id = id; self.kind = kind; self.livery = livery; self.callsign = callsign
        self.isArrival = isArrival; self.straightIn = straightIn
        self.position = position; self.heading = heading
    }

    var pos2: V2 {
        get { V2(position.x, position.z) }
        set { position.x = newValue.x; position.z = newValue.y }
    }
    var altitude: Double {
        get { position.y }
        set { position.y = newValue }
    }

    var isResolved: Bool {
        phase == .parkedArrival || phase == .departedHandoff || phase == .removed
    }

    /// Rate-limited turn toward a heading; updates bank as the presentation hint.
    /// `maxBank` is the coordinated-bank ceiling for this type (GA ~0.65 rad,
    /// Comet ~0.5 rad). Bank is PRESENTATION-ONLY — it eases toward the TRUE
    /// coordinated value for the turn actually being flown and never affects the
    /// (rate-limited) heading integration, so determinism is untouched.
    func steer(toward target: Double, maxRate: Double, dt: Double, maxBank: Double = 0.65) {
        let d = angleDelta(from: heading, to: target)
        let rate = max(-maxRate, min(maxRate, d / dt))
        heading += rate * dt
        heading = heading.truncatingRemainder(dividingBy: .pi * 2)
        // TRUE coordinated bank for the turn rate being flown, ceiling per type.
        let idealBank = atan((rate * max(speed, 15)) / 9.81)
        let targetBank = max(-maxBank, min(maxBank, idealBank))
        rollBank(toward: targetBank, dt: dt)
    }

    /// Steer toward a 2D point (pure pursuit).
    func steer(toPoint p: V2, maxRate: Double, dt: Double, maxBank: Double = 0.65) {
        let d = p - pos2
        guard simd_length(d) > 1 else { return }
        steer(toward: directionHeading(simd_normalize(d)), maxRate: maxRate, dt: dt, maxBank: maxBank)
    }

    /// Ease `bank` toward a target with an aileron-roll rate limit (~0.6 rad/s),
    /// so roll-in/roll-out reads as a real ~0.6–1 s roll rather than a snap.
    /// PRESENTATION-ONLY.
    func rollBank(toward target: Double, dt: Double, rollRate: Double = 0.6) {
        let maxStep = rollRate * dt
        let delta = target - bank
        bank += max(-maxStep, min(maxStep, delta))
    }

    /// Accelerate/decelerate toward a target speed with a rate cap.
    func driveSpeed(toward target: Double, accel: Double, decel: Double, dt: Double) {
        if speed < target {
            speed = min(target, speed + accel * dt)
        } else {
            speed = max(target, speed - decel * dt)
        }
    }

    /// Move along the current heading; ground code overrides Y afterwards.
    func integrate(dt: Double) {
        let dir = headingDirection(heading)
        pos2 += dir * (speed * dt)
        altitude += verticalSpeed * dt
    }

    /// Follow `route` from `routeIndex`. Returns true when the last point is
    /// reached. Turns are heading-rate-limited so taxi corners look alive.
    /// `laneOffset` shifts the tracked line to the right of travel — a taxi
    /// keep-right convention so opposing traffic passes side-by-side rather
    /// than driving through each other on a shared centerline (B4).
    func followRoute(speed target: Double, accel: Double, turnRate: Double,
                     laneOffset: Double = 0, dt: Double) -> Bool {
        guard routeIndex < route.count else { return true }
        var wp = route[routeIndex]
        var remaining = simd_length(wp - pos2)
        while remaining < 4, routeIndex < route.count - 1 {
            routeIndex += 1
            wp = route[routeIndex]
            remaining = simd_length(wp - pos2)
        }
        let isLast = routeIndex == route.count - 1
        if isLast && remaining < 1.5 {
            speed = 0
            return true
        }
        // Slow into the final stop and into corners.
        var desired = target
        if isLast { desired = min(desired, max(1.2, remaining * 0.55)) }
        else if remaining < 14 { desired = min(desired, max(2.5, target * 0.55)) }
        driveSpeed(toward: desired, accel: accel, decel: accel * 1.6, dt: dt)
        var aim = wp
        if laneOffset != 0, !isLast {
            // Track a line offset to the RIGHT of the segment, held the whole
            // way (not a vanishing steer nudge): aim at a lookahead point on the
            // offset line so opposing traffic passes side-by-side.
            let segStart = routeIndex > 0 ? route[routeIndex - 1] : pos2
            let seg = wp - segStart
            if simd_length(seg) > 0.5 {
                let segDir = simd_normalize(seg)
                let right = V2(segDir.y, -segDir.x)
                let along = simd_dot(pos2 - segStart, segDir)
                let look = segStart + segDir * min(along + 12, simd_length(seg))
                aim = look + right * laneOffset
            }
        }
        steer(toPoint: aim, maxRate: turnRate, dt: dt)
        integrate(dt: dt)
        return false
    }

    /// Snapshot for the public state array.
    func snapshotState() -> AircraftState {
        AircraftState(id: id, kind: kind, livery: livery, callsign: callsign,
                      phase: phase, position: position, heading: heading, speed: speed,
                      verticalSpeed: verticalSpeed, bank: bank, pitch: pitch,
                      crab: crab, throttle: throttle,
                      gearDown: gearDown, landingLightsOn: landingLightsOn,
                      clearedToLand: clearedToLand, clearedForTakeoff: clearedForTakeoff,
                      holdingPosition: holdingPosition, delaySeconds: delaySeconds,
                      band: band, gapSeconds: gapSeconds, urgency: urgency)
    }
}
