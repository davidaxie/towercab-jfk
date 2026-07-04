import Foundation
import simd

// =============================================================================
// SimEngine+Tick — the deterministic heart. One fixed 10 Hz tick:
//   shift phase → spawns → commands → per-aircraft flight/ground update →
//   conflict projection → deferred radio → shift end.
// All iteration over aircraft is in AircraftID order; all randomness comes
// from SeededRNG streams. Same seed ⇒ identical run.
//
// Audit fairness pass (see AUDIT.md §B): the conflict model now watches every
// committed arrival against every occupant AND every arrival ahead of it (B2),
// projects departures onto occupied runways (B3), gives taxiing aircraft a
// queue so they never overlap (B4), computes honest runway-clear times from
// distance-to-exit (B5), softens and de-dupes the self-preservation penalty
// (B6), and tells the truth on the strip phase ladder (B12).
// =============================================================================

extension SimEngine {

    // MARK: Tuning

    private enum Tune {
        static let maxActiveStrips = 12
        static let minSpawnSeparation = 8.0
        static let patternTurnRate = 0.14        // rad/s ≈ a 45 s orbit
        static let cometTurnRate = 0.105
        static let taxiTurnRate = 0.9
        static let approachLookahead = 260.0     // final-track aim distance, m
        static let speedBleedStart = 2000.0      // begin decel to Vref here
        static let exitSpeed = 7.0               // runway turnoff speed, m/s
        static let thresholdCrossAGL = 15.0
        static let commitDistance = 500.0        // uncleared inside this → pilot GA
        static let shortFinalDistance = 600.0    // B12 — truthful SHORT FINAL
        static let flareDistance = 130.0         // B12 — flare begins here…
        static let flareAGL = 22.0               // …or at this height, whichever first
        static let nagAfter = 45.0
        static let nagRepeat = 40.0
        static let preRollPauseSeconds = 3.0
        static let departHandoffDistance = 1800.0 // B14 — strips clear the rail sooner
        static let departHandoffAltitude = 250.0
        static let goAroundPenalty = 250
        static let selfPreservationPenalty = 600  // B6 — was 2000; never nukes a shift
        static let tightGapWindow = 90.0
        static let noDelayWindow = 25.0
        static let forceEndGrace = 150.0
        static let groundQueueGap = 28.0          // B4 — taxi queue spacing, m
        static let taxiLaneOffset = 3.5           // B4 — keep-right taxi lane, m
        static let downwindStagger = 600.0        // rejoin spacing on the leg, m (big-jet scale)
        static let goAroundTransitClimb = 120.0   // rejoin transits this far ABOVE pattern alt
        static let goAroundTierSpacing = 150.0    // vertical stack between simultaneous go-arounds
    }

    // MARK: Geometry sugar

    private var rw: Runway { airport.runway }

    /// Unit perpendicular pointing to the tower/apron side of the runway.
    /// Derived from the cab position so the pattern is always flown on the far
    /// (over-water) side regardless of the layout's compass handedness (B-flip).
    private var perpTower: V2 {
        let p = V2(rw.dir22.y, -rw.dir22.x)
        let toCab = V2(airport.towerCabEye.x, airport.towerCabEye.z) - rw.thresholdB
        return simd_dot(toCab, p) >= 0 ? p : -p
    }
    /// Pattern (downwind) side — opposite the tower, over the water.
    private var perpPattern: V2 { -perpTower }
    private var gsRad: Double { degToRad(airport.finalGlideSlopeDeg) }
    /// Ground elevation of the RWY 22 threshold (≈ −14.7 m below the crest).
    private var thrGroundY: Double { groundY(rw.thresholdB) }

    /// Signed distance along the runway axis from threshold 22 (+ = toward SW).
    private func station(of p: V2) -> Double { simd_dot(p - rw.thresholdB, rw.dir22) }
    /// Lateral offset from centerline (+ = tower side).
    private func cross(of p: V2) -> Double { simd_dot(p - rw.thresholdB, perpTower) }
    /// Glideslope altitude at a distance-to-threshold, referenced to the
    /// threshold's ground elevation (B: threshold is no longer the y=0 datum).
    private func glideAlt(_ dist: Double) -> Double {
        thrGroundY + Tune.thresholdCrossAGL + max(0, dist) * tan(gsRad)
    }
    /// Pattern altitude as an absolute (the crest datum ≈ field elevation).
    private var patternAbsAlt: Double { airport.patternAltitude }
    private func downwindPoint(station s: Double) -> V2 {
        rw.point(atStationFrom22: s) + perpPattern * airport.downwindOffset
    }
    /// In-trail speed cap for a downwind aircraft: keeps a wingspan-aware buffer
    /// behind the nearest hazard ahead on the leg. Leaders are pattern traffic at
    /// a LOWER station (ahead toward the base turn) OR any orbiting/going-around
    /// aircraft sitting on the leg near us (a commanded 360 parks an aircraft on
    /// the downwind that faster followers must hold behind, never merge through).
    /// A hard floor forces the follower toward a stop before overlap. Returns +∞
    /// when the leg is clear. Pure function of the snapshot ⇒ deterministic.
    private func downwindSpeedCap(_ ac: Aircraft, station s: Double) -> Double {
        var cap = Double.infinity
        let myLat = cross(of: ac.pos2)
        for other in aircraft where other.id != ac.id {
            switch other.phase {
            case .downwind, .base, .orbiting, .goingAround: break
            default: continue
            }
            // Skip anything far off our lateral band (final/base intercept, etc).
            guard abs(cross(of: other.pos2) - myLat) < 900 else { continue }
            let margin = (ac.kind.wingspanMeters + other.kind.wingspanMeters)
            let os = station(of: other.pos2)
            let gap = s - os                      // >0 ⇒ hazard is ahead of us
            let isOrbiter = other.phase == .orbiting || other.phase == .goingAround

            // In-trail rule: hold behind traffic ahead on the leg, and give
            // a bounded-orbit berth to any orbiting/going-around aircraft.
            let effGap = isOrbiter ? abs(gap) : gap
            guard isOrbiter || gap > 0 else { continue }
            let buffer = (isOrbiter ? 560.0 : 300.0) + margin
            let hardFloor = (isOrbiter ? 480.0 : 120.0) + margin / 2
            if effGap < buffer {
                if effGap < hardFloor {
                    cap = min(cap, 0)             // full stop — never overlap
                } else {
                    let closeness = max(0, min(1, (buffer - effGap) / (buffer - hardFloor)))
                    let leadSpeed = isOrbiter ? 0.0 : other.speed
                    cap = min(cap, leadSpeed * (1 - closeness))
                }
            }
        }
        return cap
    }
    /// In-trail speed cap for an arrival on final: hold behind the nearest
    /// arrival ahead (closer to the threshold) on the extended centerline so a
    /// faster follower never overruns a slower leader down the long ILS final.
    /// Returns +∞ when the final ahead is clear. Pure function of the snapshot.
    private func finalInTrailCap(_ ac: Aircraft, distToThr d: Double) -> Double {
        var cap = Double.infinity
        for other in aircraft where other.id != ac.id {
            switch other.phase {
            case .inboundFinal, .finalApproach, .shortFinal, .flare: break
            default: continue
            }
            let od = -station(of: other.pos2)     // leader's distance to threshold
            let gap = d - od                       // >0 ⇒ leader is ahead (closer in)
            guard gap > 0 else { continue }
            let margin = (ac.kind.wingspanMeters + other.kind.wingspanMeters)
            let buffer = 900.0 + margin            // required in-trail spacing on final
            let hardFloor = 250.0 + margin / 2
            if gap < buffer {
                if gap < hardFloor {
                    cap = min(cap, other.speed * 0.6)   // ease well back, keep flying
                } else {
                    let closeness = max(0, min(1, (buffer - gap) / (buffer - hardFloor)))
                    cap = min(cap, other.speed * (1 - 0.4 * closeness))
                }
            }
        }
        return cap
    }
    private func turnRate(_ ac: Aircraft) -> Double {
        ac.kind.engineIsJet ? Tune.cometTurnRate : Tune.patternTurnRate
    }
    private func groundY(_ p: V2) -> Double { airport.groundHeight(at: p) }

    // MARK: Attitude presentation (PRESENTATION-ONLY — never feeds sim state)

    /// Coordinated-bank ceiling per type: GA rolls to a genuine ~37°, the Comet
    /// stays a more sedate ~29° in the pattern. Read by `steer`.
    private func maxBank(_ ac: Aircraft) -> Double {
        ac.kind.engineIsJet ? 0.50 : 0.65
    }
    /// Cruise angle-of-attack per type, radians — the slight nose-up a wing
    /// carries in level flight, and the baseline the flight-path angle rides on.
    private func angleOfAttack(_ ac: Aircraft) -> Double {
        ac.kind.engineIsJet ? 0.045 : 0.05
    }
    /// ONE coherent pitch law. Pitch is a cosmetic readout of the flight-path
    /// angle (from verticalSpeed / speed) plus the wing's AoA, eased in at a
    /// believable pitch rate. It NEVER drives verticalSpeed — purely visual.
    private func drivePitch(_ ac: Aircraft, aoa: Double, dt: Double,
                            rate: Double = 0.35, vFloor: Double = 20) {
        let fpa = atan2(ac.verticalSpeed, max(ac.speed, vFloor))
        let target = fpa + aoa
        let maxStep = rate * dt
        let delta = target - ac.pitch
        ac.pitch += max(-maxStep, min(maxStep, delta))
    }

    // MARK: Wind (deterministic — seed-derived, constant per shift)

    /// The wind as a world vector pointing in the direction air is MOVING TOWARD
    /// (m/s). `wind.directionDeg` is the compass bearing the wind blows FROM, so
    /// the flow vector points the opposite way. Constant for the whole shift, so
    /// this is a pure function of the (seed-derived) wind — determinism-safe.
    private var windToVector: V2 {
        let fromRad = degToRad(wind.directionDeg)
        // Heading `fromRad` points where the wind comes from; flow is +180°.
        let flowHeading = fromRad + .pi
        return headingDirection(flowHeading) * ktsToMps(wind.speedKts)
    }

    /// Crab angle to hold a ground track along `groundHeading` in the current
    /// wind (radians, nose-into-wind). PRESENTATION-ONLY: the deterministic
    /// ground track stays on `heading`; the renderer points the nose at
    /// heading+crab. Clamped to ±0.3 rad so it never reads cartoonish.
    private func crabAngle(forGroundHeading groundHeading: Double, airspeed: Double) -> Double {
        // Crosswind = wind component perpendicular (to the right) of the track.
        let track = headingDirection(groundHeading)
        let right = V2(track.y, -track.x)
        let crosswind = simd_dot(windToVector, right)
        let ratio = max(-0.3, min(0.3, crosswind / max(airspeed, 20)))
        // Nose yaws INTO the wind: toward the side the crosswind comes from,
        // i.e. opposite the direction it pushes the aircraft.
        return -asin(ratio)
    }
    /// Ease `crab` toward a target at a gentle rate (radians/s). Presentation-only.
    private func easeCrab(_ ac: Aircraft, toward target: Double, dt: Double, rate: Double = 0.4) {
        let maxStep = rate * dt
        let delta = target - ac.crab
        ac.crab += max(-maxStep, min(maxStep, delta))
    }

    // MARK: - Tick

    func tick() {
        let now = simTime
        let dt = Self.tickInterval

        // After the shift report the world keeps living (late taxiers park,
        // strips can still be flicked) but nothing new is authored.
        updateShiftPhase(now)
        if !shiftEndedFired { processSpawns(now) }
        processCommands(now)
        for ac in aircraft where ac.phase != .removed {
            update(ac, dt: dt, now: now)
            ac.phaseTime += dt
        }
        updateConflicts(now)
        flushDelayedRadio(now)
        checkShiftEnd(now)
        aircraft.removeAll { $0.phase == .removed }
    }

    func makeSnapshot() -> SimSnapshot {
        SimSnapshot(simTime: simTime, tickIndex: tickIndex,
                    aircraft: aircraft.filter { $0.phase != .removed }.map { $0.snapshotState() },
                    score: scoreboard.score, streakMultiplier: scoreboard.streakMultiplier,
                    shiftPhase: shiftPhase,
                    // B22 — may go negative; the HUD renders it as +m:ss overtime.
                    shiftTimeRemaining: script.duration - simTime, wind: wind)
    }

    /// Count of strips that occupy a rail slot: everything except the resolved
    /// (parked / departed) ones, which are just waiting to be flicked (B11).
    private var activeStripCount: Int {
        aircraft.reduce(0) { $0 + ($1.phase == .removed || $1.isResolved ? 0 : 1) }
    }

    // MARK: - Shift phase & spawning

    private func updateShiftPhase(_ now: Double) {
        let desired: ShiftPhase
        if now >= ShiftScript.crescendoEnd { desired = .cooldown }
        else if now >= ShiftScript.crescendoStart { desired = .crescendo }
        else { desired = .ramp }
        if desired != shiftPhase && shiftPhase != .ended {
            shiftPhase = desired
            eventQueue.append(.shiftPhaseChanged(desired))
        }
    }

    private func processSpawns(_ now: Double) {
        // The traffic curve stops authoring 60 s before shift end; deferrals
        // past that point are abandoned, not backlogged.
        if now > ShiftScript.lastSpawnTime + 10 {
            spawnCursor = script.orders.count
            return
        }
        while spawnCursor < script.orders.count, script.orders[spawnCursor].time <= now {
            guard activeStripCount < Tune.maxActiveStrips,           // B11 — parked strips don't block
                  now - lastSpawnAt >= Tune.minSpawnSeparation
            else { return }

            // B11 — head-of-line leapfrog: if the next order is a departure with
            // no free apron spot, let a spawnable arrival within the next few
            // orders go first rather than stalling the whole queue.
            var index = spawnCursor
            if !script.orders[index].isArrival && freeApronSpot() == nil {
                if let a = (spawnCursor..<min(spawnCursor + 3, script.orders.count))
                    .first(where: { script.orders[$0].isArrival && script.orders[$0].time <= now }) {
                    index = a
                } else {
                    return   // nothing spawnable yet; try next tick
                }
            }

            let order = script.orders[index]
            if order.isArrival {
                spawnArrival(order)
            } else {
                guard let spot = freeApronSpot() else { return }
                spawnDeparture(order, spot: spot)
            }
            // B11 — par accrues only for orders that actually spawn.
            spawnedParMovements += 1
            spawnedParScore += Int((order.isArrival ? 250.0 : 200.0) * order.kind.movementWeight)
            lastSpawnAt = now
            if index == spawnCursor { spawnCursor += 1 }
            else { script.orders.remove(at: index) }   // leapfrogged order consumed
        }
    }

    private func occupiedSpots() -> Set<Int> {
        var used = Set<Int>()
        for ac in aircraft where ac.apronSpot >= 0 {
            switch ac.phase {
            case .startingUp, .exitingRunway, .taxiToApron, .parkedArrival:
                used.insert(ac.apronSpot)
            default: break
            }
        }
        return used
    }

    private func freeApronSpot() -> Int? {
        let used = occupiedSpots()
        for i in airport.apronSpots.indices where !used.contains(i) { return i }
        return nil
    }

    private func spawnArrival(_ order: SpawnOrder) {
        let id = AircraftID(nextAircraftNumber); nextAircraftNumber += 1
        let ac = Aircraft(id: id, kind: order.kind, livery: order.livery,
                          callsign: order.callsign, isArrival: true,
                          straightIn: order.straightIn,
                          position: .zero, heading: 0)
        if order.straightIn {
            let p = rw.point(atStationFrom22: -airport.finalSpawnDistance)
            ac.pos2 = p
            ac.altitude = glideAlt(airport.finalSpawnDistance)
            ac.heading = rw.heading22
            ac.phase = .inboundFinal
        } else {
            // Spawn behind any traffic already in the pattern so a fresh
            // arrival never materializes on top of a rejoining go-around.
            ac.pos2 = downwindPoint(station: freeDownwindEntryStation(excluding: id))
            ac.altitude = patternAbsAlt
            ac.heading = rw.heading04
            ac.phase = .downwind
        }
        ac.speed = order.kind.patternSpeed
        ac.verticalSpeed = order.straightIn ? -ac.speed * tan(gsRad) : 0
        ac.landingLightsOn = true
        ac.touchdownStation = order.touchdownStation
        ac.spawnedAt = simTime
        aircraft.append(ac)
        eventQueue.append(.aircraftSpawned(id))
        pilotSay(ac, radio.pilotArrivalCheckIn(ac.callsign, straightIn: ac.straightIn))
    }

    private func spawnDeparture(_ order: SpawnOrder, spot: Int) {
        let id = AircraftID(nextAircraftNumber); nextAircraftNumber += 1
        let s = airport.apronSpots[spot]
        let ac = Aircraft(id: id, kind: order.kind, livery: order.livery,
                          callsign: order.callsign, isArrival: false, straightIn: false,
                          position: V3(s.position.x, groundY(s.position), s.position.y),
                          heading: s.heading)
        ac.phase = .startingUp
        ac.apronSpot = spot
        ac.spawnedAt = simTime
        aircraft.append(ac)
        eventQueue.append(.aircraftSpawned(id))
    }

    // MARK: - Commands

    private func processCommands(_ now: Double) {
        guard !pendingCommands.isEmpty else { return }
        let batch = pendingCommands.sorted {
            $0.timestamp == $1.timestamp ? $0.aircraft.raw < $1.aircraft.raw
                                         : $0.timestamp < $1.timestamp
        }
        pendingCommands.removeAll()
        for env in batch {
            guard let ac = aircraft.first(where: { $0.id == env.aircraft }),
                  ac.phase != .removed,
                  legalCommands(for: ac).contains(where: { $0 == env.command })
            else { continue }
            execute(env.command, on: ac, now: now)
        }
    }

    private func execute(_ command: Command, on ac: Aircraft, now: Double) {
        switch command {
        case .clearedToLand:
            ac.clearedToLand = true
            if ac.committedAt < 0 { ac.committedAt = now }   // B8
            towerSay(radio.towerClearedToLand(ac.callsign), readback: command, ac: ac, now: now)

        case .goAround:
            towerSay(radio.towerGoAround(ac.callsign), readback: command, ac: ac, now: now)
            adjudicateResolution(ac, isGoAround: true)
            beginGoAround(ac)
            ac.delaySeconds += 60

        case .extendDownwind:
            ac.extendUsed = true
            ac.extendRemaining = 35
            ac.delaySeconds += 35
            towerSay(radio.towerExtend(ac.callsign), readback: command, ac: ac, now: now)

        case .make360(let left):
            ac.orbitRemaining = .pi * 2
            ac.orbitLeft = left
            ac.resumePhase = ac.phase
            ac.phase = .orbiting
            ac.delaySeconds += 45
            towerSay(radio.towerOrbit(ac.callsign, left: left), readback: command, ac: ac, now: now)

        case .lineUpAndWait:
            // B3 — refuse onto a runway a landing hasn't cleared yet.
            if runwayHasLandingOccupant() {
                pilotSay(ac, radio.pilotUnableTakeoff(ac.callsign))
                return
            }
            ac.phase = .lineUpWait
            ac.route = lineUpRoute()
            ac.routeIndex = 0
            ac.lineupComplete = false
            ac.lastCommitAt = now                            // B8
            resetWait(ac)
            towerSay(radio.towerLineUp(ac.callsign), readback: command, ac: ac, now: now)

        case .clearedForTakeoff(let immediate):
            // B3 — refuse onto an occupied runway.
            if runwayHasLandingOccupant() {
                pilotSay(ac, radio.pilotUnableTakeoff(ac.callsign))
                return
            }
            ac.clearedForTakeoff = true
            ac.immediateTakeoff = immediate
            ac.lastCommitAt = now                            // B8
            armTightGap(ac, now: now)
            if ac.phase == .holdingShort {
                ac.route = lineUpRoute()
                ac.routeIndex = 0
                ac.lineupComplete = false
            }
            ac.phase = .takeoffRoll
            ac.preRollPause = immediate ? 0.3 : Tune.preRollPauseSeconds
            resetWait(ac)
            towerSay(radio.towerTakeoff(ac.callsign, immediate: immediate),
                     readback: command, ac: ac, now: now)

        case .holdPosition:
            if ac.phase == .takeoffRoll {
                // Cancel takeoff — the SAVE-table hold.
                towerSay(radio.towerHold(ac.callsign), readback: command, ac: ac, now: now)
                adjudicateResolution(ac, isGoAround: false)
                ac.clearedForTakeoff = false
                ac.immediateTakeoff = false
                ac.tightGapArmed = false
                ac.phase = .lineUpWait
                ac.lineupComplete = true
            } else {
                ac.holdingPosition = true
                towerSay(radio.towerHold(ac.callsign), readback: command, ac: ac, now: now)
            }

        case .continueTaxi:
            ac.holdingPosition = false
            resetWait(ac)
            towerSay(radio.towerContinue(ac.callsign), readback: command, ac: ac, now: now)

        case .expediteExit:
            ac.expedited = true
            if ac.phase == .rollout { chooseExit(ac) }
            towerSay(radio.towerExpedite(ac.callsign, exitName: ac.exitTaxiwayName),
                     readback: command, ac: ac, now: now)

        case .handoff:
            scoreboard.award(base: 50)
            towerSay(ac.isArrival ? radio.towerHandoffArrival(ac.callsign)
                                  : radio.towerHandoffDeparture(ac.callsign),
                     readback: command, ac: ac, now: now)
            remove(ac)
        }
    }

    private func lineUpRoute() -> [V2] {
        var r = airport.routeLineUp
        if let last = r.last { r.append(last + rw.dir22 * 24) }
        return r
    }

    private func remove(_ ac: Aircraft) {
        retiredDelaySum += ac.delaySeconds
        retiredCount += 1
        conflicts.clear(involving: ac.id)
        ac.phase = .removed
        eventQueue.append(.aircraftRemoved(ac.id))
    }

    // MARK: - Radio plumbing

    private func towerSay(_ text: String, readback: Command, ac: Aircraft, now: Double) {
        // B17 — resolve display labels at emit time; the aircraft may despawn
        // before its readback is due (handoff).
        eventQueue.append(.radio(RadioCall(speaker: .tower, text: text, speakerLabel: "TWR")))
        let reply = radio.readback(ac.callsign, for: readback)
        delayedRadio.append((now + 0.7,
            RadioCall(speaker: .pilot(ac.id), text: reply, speakerLabel: ac.callsign.display)))
    }

    private func pilotSay(_ ac: Aircraft, _ text: String) {
        eventQueue.append(.radio(RadioCall(speaker: .pilot(ac.id), text: text,
                                           speakerLabel: ac.callsign.display)))
    }

    private func flushDelayedRadio(_ now: Double) {
        guard !delayedRadio.isEmpty else { return }
        var kept: [(Double, RadioCall)] = []
        for item in delayedRadio {
            if item.time <= now { eventQueue.append(.radio(item.call)) }
            else { kept.append(item) }
        }
        delayedRadio = kept
    }

    // MARK: - Per-aircraft update

    private func update(_ ac: Aircraft, dt: Double, now: Double) {
        switch ac.phase {
        case .inboundFinal, .finalApproach, .shortFinal:
            updateApproach(ac, dt: dt, now: now)
        case .downwind:
            updateDownwind(ac, dt: dt)
        case .base:
            updateBase(ac, dt: dt)
        case .orbiting:
            updateOrbit(ac, dt: dt)
        case .goingAround:
            updateGoAround(ac, dt: dt)
        case .flare:
            updateFlare(ac, dt: dt, now: now)
        case .rollout:
            updateRollout(ac, dt: dt, now: now)
        case .exitingRunway, .taxiToApron:
            updateTaxiIn(ac, dt: dt, now: now)
        case .startingUp:
            ac.throttle += (0.15 - ac.throttle) * min(1, dt * 2)
            if ac.phaseTime >= 4 {
                pilotSay(ac, radio.pilotReadyToTaxi(ac.callsign))
                // B25 — the tower answers with an actual taxi clearance.
                let via = airport.taxiways.first?.name ?? "Alpha"
                eventQueue.append(.radio(RadioCall(speaker: .tower,
                    text: radio.towerTaxiClearance(ac.callsign, via: via), speakerLabel: "TWR")))
                var r = airport.routeTaxiOut
                r.insert(ac.pos2, at: 0)
                ac.route = r
                ac.routeIndex = 0
                ac.phase = .taxiToRunway
            }
        case .taxiToRunway:
            updateTaxiOut(ac, dt: dt, now: now)
        case .holdingShort:
            updateWaiting(ac, dt: dt, now: now)
        case .lineUpWait:
            updateLineUpWait(ac, dt: dt, now: now)
        case .takeoffRoll:
            updateTakeoffRoll(ac, dt: dt, now: now)
        case .climbingOut, .departedHandoff:
            updateClimbout(ac, dt: dt)
        case .parkedArrival, .removed:
            break
        }
    }

    // MARK: Approach & landing

    private func updateApproach(_ ac: Aircraft, dt: Double, now: Double) {
        let d = -station(of: ac.pos2)   // distance to threshold, m

        // Phase ladder by distance (B12 — truthful FINAL → SHORT FINAL).
        if ac.phase == .inboundFinal && d <= 3500 { ac.phase = .finalApproach }
        if (ac.phase == .finalApproach || ac.phase == .inboundFinal) && d <= Tune.shortFinalDistance {
            ac.phase = .shortFinal
            if ac.committedAt < 0 { ac.committedAt = now }   // committed by proximity
        }
        ac.urgency = ac.phase == .shortFinal ? (1 - max(0, d) / Tune.shortFinalDistance) : nil

        // Frequency neglect: no clearance inside the commit distance.
        if d <= Tune.commitDistance && !ac.clearedToLand {
            pilotForcedGoAround(ac, penalty: Tune.goAroundPenalty, selfPreservation: false)
            return
        }

        // Speed: pattern speed bleeding to Vref inside 2 km, but never faster
        // than the in-trail cap behind the arrival ahead on final. On a long ILS
        // final a faster jet behind a slower one would otherwise close the gap
        // and merge; speed control holds the spacing (and avoids the double-red
        // that would pile two go-arounds together).
        let vRef = ac.kind.approachSpeed
        let blend = max(0, min(1, (d - 300) / (Tune.speedBleedStart - 300)))
        let vProfile = vRef + (ac.kind.patternSpeed - vRef) * blend
        ac.driveSpeed(toward: min(vProfile, finalInTrailCap(ac, distToThr: d)),
                      accel: 1.2, decel: 1.3, dt: dt)

        // Lateral: pursue a point on the centerline just ahead.
        let aim = rw.point(atStationFrom22: -(d - Tune.approachLookahead))
        ac.steer(toPoint: aim, maxRate: turnRate(ac), dt: dt, maxBank: maxBank(ac))
        driveGlide(ac, targetAlt: glideAlt(d), dt: dt)
        // Crosswind crab on final: point the nose into wind, ground track unchanged.
        easeCrab(ac, toward: crabAngle(forGroundHeading: rw.heading22, airspeed: ac.speed), dt: dt)
        ac.throttle += (0.5 - ac.throttle) * min(1, dt * 2)

        // B12/B20 — enter the flare at a truthful point and keep integrating
        // this tick (no one-frame freeze at the most-watched moment).
        let agl = ac.altitude - groundY(ac.pos2)
        if ac.clearedToLand && (d <= Tune.flareDistance || agl <= Tune.flareAGL) {
            ac.phase = .flare
            ac.urgency = nil
            updateFlare(ac, dt: dt, now: now)
            return
        }
        ac.integrate(dt: dt)
    }

    /// Smooth vertical guidance toward a target altitude with a glide feedforward.
    private func driveGlide(_ ac: Aircraft, targetAlt: Double, dt: Double, gentle: Bool = false) {
        let ff = -ac.speed * tan(gsRad)
        var desired = ff + (targetAlt - ac.altitude) * 0.30
        if targetAlt > ac.altitude { desired = min(desired + 2.5, ac.kind.climbRate) }
        desired = max(gentle ? -6 : -9, min(desired, 4))
        ac.verticalSpeed += (desired - ac.verticalSpeed) * min(1, dt * 2.2)
        // Cosmetic pitch: flight-path angle + AoA, eased by the one pitch law.
        drivePitch(ac, aoa: angleOfAttack(ac), dt: dt)
    }

    private func updateDownwind(_ ac: Aircraft, dt: Double) {
        let s = station(of: ac.pos2)
        if s <= airport.baseTurnStation {
            if ac.extendRemaining > 0 {
                ac.extendRemaining -= dt
            } else {
                ac.phase = .base
            }
        }
        // In-trail speed discipline: never overrun the aircraft ahead on the
        // downwind leg (lower station = closer to base = the leader). The
        // trailing aircraft caps to the leader's speed as the gap closes, so
        // a fast jet entering behind a slow one holds station rather than
        // merging into it. Deterministic (pure function of the snapshot).
        let targetSpeed = min(ac.kind.patternSpeed, downwindSpeedCap(ac, station: s))
        ac.driveSpeed(toward: targetSpeed, accel: 1.2, decel: 1.4, dt: dt)
        ac.steer(toPoint: downwindPoint(station: s - 320), maxRate: turnRate(ac), dt: dt,
                 maxBank: maxBank(ac))
        // B7 — hold pattern altitude on the downwind; the descent lives on base.
        driveGlide(ac, targetAlt: patternAbsAlt, dt: dt, gentle: true)
        easeCrab(ac, toward: crabAngle(forGroundHeading: ac.heading, airspeed: ac.speed), dt: dt)
        ac.throttle += (0.5 - ac.throttle) * min(1, dt * 2)
        ac.integrate(dt: dt)
    }

    private func updateBase(_ ac: Aircraft, dt: Double) {
        let intercept = rw.point(atStationFrom22: airport.baseTurnStation)
        ac.driveSpeed(toward: ac.kind.patternSpeed * 0.9, accel: 1.0, decel: 1.0, dt: dt)
        ac.steer(toPoint: intercept, maxRate: turnRate(ac), dt: dt, maxBank: maxBank(ac))
        let lateral = abs(cross(of: ac.pos2))
        let pathDist = lateral - airport.baseTurnStation
        driveGlide(ac, targetAlt: min(patternAbsAlt, glideAlt(pathDist)), dt: dt, gentle: true)
        easeCrab(ac, toward: crabAngle(forGroundHeading: ac.heading, airspeed: ac.speed), dt: dt)
        ac.throttle += (0.5 - ac.throttle) * min(1, dt * 2)
        ac.integrate(dt: dt)
        if lateral < 150 { ac.phase = .finalApproach }
    }

    private func updateOrbit(_ ac: Aircraft, dt: Double) {
        // B19 — orbit at the type's real turn rate (was a fixed 45 s that
        // implied a 49° bank on the Comet).
        let rate = turnRate(ac) * (ac.orbitLeft ? -1.0 : 1.0)
        ac.heading += rate * dt
        ac.orbitRemaining -= abs(rate * dt)
        // Bounded-radius orbit: a commanded 360 is flown as a tight, slowed
        // holding turn so the swept circle stays compact and never merges into
        // downwind traffic. r = v/ω, so cap v ≤ ω·R_max. This matters for the
        // big-jet fleet whose full pattern-speed 360 would otherwise sweep a
        // ~2 km circle across the leg. Deterministic (pure geometry).
        let orbitRadiusMax = 420.0
        let orbitSpeedCap = min(ac.kind.patternSpeed, abs(rate) * orbitRadiusMax)
        // TRUE coordinated bank for the orbit rate, ceiling per type, rate-limited.
        let idealBank = atan((abs(rate) * max(ac.speed, 20)) / 9.81) * (ac.orbitLeft ? -1 : 1)
        let mb = maxBank(ac)
        ac.rollBank(toward: max(-mb, min(mb, idealBank)), dt: dt)
        ac.driveSpeed(toward: orbitSpeedCap, accel: 1.0, decel: 1.2, dt: dt)
        ac.verticalSpeed += (0 - ac.verticalSpeed) * min(1, dt * 2)
        drivePitch(ac, aoa: angleOfAttack(ac), dt: dt)
        easeCrab(ac, toward: crabAngle(forGroundHeading: ac.heading, airspeed: ac.speed), dt: dt)
        ac.throttle += (0.5 - ac.throttle) * min(1, dt * 2)
        ac.integrate(dt: dt)
        if ac.orbitRemaining <= 0 {
            let resume = ac.resumePhase == .orbiting ? .finalApproach : ac.resumePhase
            ac.phase = resume
            // B19 — phase-aware resume phrase.
            switch resume {
            case .downwind: pilotSay(ac, radio.pilotBackOnDownwind(ac.callsign))
            default: pilotSay(ac, radio.pilotBackOnFinal(ac.callsign))
            }
        }
    }

    private func beginGoAround(_ ac: Aircraft) {
        ac.phase = .goingAround
        ac.clearedToLand = false
        ac.committedAt = -100
        ac.urgency = nil
        // B18 — a go-around commanded from the pattern rejoins the downwind
        // directly instead of flying an aimless 180° back to runway heading.
        ac.gaFromPattern = [.downwind, .base, .orbiting].contains(ac.resumePhase)
            || [.downwind, .base].contains(ac.phase)
        // Stagger the rejoin behind existing pattern traffic so two go-arounds
        // never stack on the entry point.
        ac.rejoinEntryStation = freeDownwindEntryStation(excluding: ac.id)
        // Assign a vertical transit tier above any go-around already climbing
        // out, so simultaneous go-arounds stack in altitude (never overlap in the
        // air) while they fly their rejoins. Deterministic (count-based).
        let climbingOutCount = aircraft.filter {
            $0.id != ac.id && $0.phase == .goingAround
        }.count
        ac.gaTransitTier = climbingOutCount
        conflicts.clear(involving: ac.id)
    }

    /// A downwind entry station clear of current pattern traffic — pushed back
    /// (higher station) once per aircraft already flying the pattern.
    private func freeDownwindEntryStation(excluding id: AircraftID) -> Double {
        // Enter behind ALL current pattern traffic: past the highest-station
        // aircraft already on/rejoining the leg, plus a big-jet stagger. Tracking
        // the actual max station (not just a count) stops a fresh entry from
        // materializing on top of traffic that has drifted up-leg (B18/B-merge).
        let inPattern = aircraft.filter {
            $0.id != id && [.downwind, .goingAround, .orbiting, .base].contains($0.phase)
        }
        let baseStation = airport.downwindEntryStation
        let maxOccupied = inPattern.map { station(of: $0.pos2) }.max() ?? -.infinity
        let behind = max(baseStation, maxOccupied + Tune.downwindStagger)
        return behind + Double(id.raw % 3) * 130
    }

    private func pilotForcedGoAround(_ ac: Aircraft, penalty: Int, selfPreservation: Bool) {
        scoreboard.penalize(penalty)
        if let m = scoreboard.resetStreak() { eventQueue.append(.streakChanged(multiplier: m)) }
        scoreboard.pilotForcedGoArounds += 1
        ac.goAroundCount += 1
        ac.delaySeconds += 60
        if selfPreservation {
            scoreboard.selfPreservations += 1
            eventQueue.append(.selfPreservation(aircraft: ac.id, penalty: penalty))
            pilotSay(ac, radio.pilotEmergencyGoAround(ac.callsign))
        } else {
            pilotSay(ac, radio.pilotSelfGoAround(ac.callsign))
        }
        beginGoAround(ac)
    }

    /// Speed cap for a go-around so it never overruns another rejoining aircraft
    /// its climb-out crosses (a lower-tier climber can pass through a higher-tier
    /// aircraft's altitude, so a horizontal hold-off is needed alongside the
    /// vertical tiers). Floors above approach speed — a climbing jet keeps flying.
    private func goAroundInTrailCap(_ ac: Aircraft) -> Double {
        var cap = Double.infinity
        for other in aircraft where other.id != ac.id {
            guard other.phase == .goingAround || other.phase == .orbiting else { continue }
            let dist = simd_length(other.pos2 - ac.pos2)
            let mergeR = 460.0 + (ac.kind.wingspanMeters + other.kind.wingspanMeters)
            guard dist < mergeR else { continue }
            // The aircraft further along toward the rejoin (higher station) is the
            // leader; the trailing one yields. Ties break by id for determinism.
            let sMe = station(of: ac.pos2), sOther = station(of: other.pos2)
            let iTrail = sMe < sOther || (sMe == sOther && ac.id.raw > other.id.raw)
            if iTrail {
                let closeness = max(0, min(1, (mergeR - dist) / mergeR))
                cap = min(cap, other.speed * (1 - 0.75 * closeness))
            }
        }
        return cap
    }

    private func updateGoAround(_ ac: Aircraft, dt: Double) {
        let gaCap = max(ac.kind.approachSpeed * 0.75, goAroundInTrailCap(ac))
        ac.driveSpeed(toward: min(ac.kind.patternSpeed, gaCap), accel: 1.6, decel: 1.4, dt: dt)
        // A go-around climbs ABOVE the pattern and transits its rejoin at that
        // higher level, only descending to pattern altitude once re-established
        // on the downwind (in updateDownwind). The vertical tier keeps a rejoin
        // safely over any downwind traffic its ground track crosses — no mid-air
        // merge even on a long straight-in go-around's sweep back to the pattern.
        let transitAlt = patternAbsAlt + Tune.goAroundTransitClimb
            + Double(ac.gaTransitTier) * Tune.goAroundTierSpacing
        let climbing = ac.altitude < transitAlt - 5
        let desiredVS = climbing ? ac.kind.climbRate : 0
        ac.verticalSpeed += (desiredVS - ac.verticalSpeed) * min(1, dt * 1.8)
        // Climb attitude via the one pitch law; go-arounds are firewalled power.
        drivePitch(ac, aoa: angleOfAttack(ac), dt: dt)
        easeCrab(ac, toward: crabAngle(forGroundHeading: ac.heading, airspeed: ac.speed), dt: dt)
        ac.throttle += ((climbing ? 0.95 : 0.6) - ac.throttle) * min(1, dt * 2.5)

        let entryStation = ac.rejoinEntryStation.isNaN
            ? airport.downwindEntryStation : ac.rejoinEntryStation
        let entry = downwindPoint(station: entryStation)
        let s = station(of: ac.pos2)
        if ac.gaFromPattern {
            // Straight to the (staggered) downwind entry — a tidy rejoin.
            ac.steer(toPoint: entry, maxRate: turnRate(ac), dt: dt, maxBank: maxBank(ac))
            if simd_length(entry - ac.pos2) < 300 {
                ac.phase = .downwind
                ac.rejoinEntryStation = .nan
                pilotSay(ac, radio.pilotBackOnDownwind(ac.callsign))
            }
        } else if s < 650 || ac.altitude < patternAbsAlt * 0.55 {
            ac.steer(toward: rw.heading22, maxRate: turnRate(ac), dt: dt, maxBank: maxBank(ac))  // straight ahead
        } else {
            ac.steer(toPoint: entry, maxRate: turnRate(ac), dt: dt, maxBank: maxBank(ac))        // crosswind → downwind
            if simd_length(entry - ac.pos2) < 300 {
                ac.phase = .downwind
                ac.rejoinEntryStation = .nan
                pilotSay(ac, radio.pilotBackOnDownwind(ac.callsign))
            }
        }
        ac.integrate(dt: dt)
    }

    private func updateFlare(_ ac: Aircraft, dt: Double, now: Double) {
        let s = station(of: ac.pos2)
        let remaining = ac.touchdownStation - s
        let groundH = groundY(rw.point(atStationFrom22: max(s, ac.touchdownStation)))
        ac.driveSpeed(toward: ac.kind.approachSpeed * 0.95, accel: 0.5, decel: 1.0, dt: dt)
        let ttd = max(0.4, remaining / max(ac.speed, 10))
        let desiredVS = max(-4.0, min(0, -(ac.altitude - groundH) / ttd))
        ac.verticalSpeed += (desiredVS - ac.verticalSpeed) * min(1, dt * 3)
        // Nose rotates nose-up INTO the flare (main gear first). Ramp the flare
        // AoA from cruise up to a per-type touchdown target as height bleeds off,
        // so contact happens ~0.12–0.16 rad nose-up. Cosmetic — VS is unchanged.
        let agl = max(0, ac.altitude - groundH)
        let flareProgress = 1 - min(1, agl / Tune.flareAGL)          // 0 high → 1 at deck
        let tdTarget = ac.kind.engineIsJet ? 0.12 : 0.16
        let flareAoA = angleOfAttack(ac) + (tdTarget - angleOfAttack(ac)) * flareProgress
        drivePitch(ac, aoa: flareAoA, dt: dt, rate: 0.4, vFloor: 15)
        // De-crab through the flare so it touches down runway-aligned.
        easeCrab(ac, toward: 0, dt: dt, rate: 0.6)
        ac.throttle += (0.2 - ac.throttle) * min(1, dt * 2.5)
        ac.steer(toPoint: rw.point(atStationFrom22: s + 120), maxRate: 0.2, dt: dt,
                 maxBank: maxBank(ac))
        ac.integrate(dt: dt)
        ac.altitude = max(ac.altitude, groundY(ac.pos2))
        if ac.altitude <= groundY(ac.pos2) + 0.15 || s >= ac.touchdownStation {
            ac.altitude = groundY(ac.pos2)
            ac.verticalSpeed = 0
            ac.phase = .rollout
            // B24 — the landing counts at touchdown, not at the turnoff.
            completeMovement(ac, isLanding: true)
            chooseExit(ac)
            consumeExpedite(now: now, by: ac.id)
        }
    }

    private func chooseExit(_ ac: Aircraft) {
        let decel = ac.expedited ? ac.kind.expediteDecel : ac.kind.rolloutDecel
        let v = max(ac.speed, Tune.exitSpeed)
        let needed = (v * v - Tune.exitSpeed * Tune.exitSpeed) / (2 * decel)
        let reach = station(of: ac.pos2) + needed
        let exits = airport.exits.sorted { $0.stationFrom22 < $1.stationFrom22 }
        // Earliest exit this type could physically make (the honest SLICK EXIT).
        let earliest = exits.first(where: { $0.stationFrom22 >= reach - 8 }) ?? exits.last!
        ac.exitStation = earliest.stationFrom22
        ac.exitIsPreferred = earliest.isPreferred
        ac.exitIsEarliestReachable = (earliest.stationFrom22 == exits.first(where: {
            $0.stationFrom22 >= reach - 8 })?.stationFrom22)
        ac.exitTaxiwayName = taxiwayName(for: earliest)
    }

    private func taxiwayName(for exit: RunwayExit) -> String {
        airport.taxiways.first(where: { $0.id == exit.taxiwayID })?.name ?? exit.taxiwayID
    }

    private func updateRollout(_ ac: Aircraft, dt: Double, now: Double) {
        let s = station(of: ac.pos2)
        let remaining = ac.exitStation - s
        let base = ac.expedited ? ac.kind.expediteDecel : ac.kind.rolloutDecel
        if ac.speed > Tune.exitSpeed {
            let required = (ac.speed * ac.speed - Tune.exitSpeed * Tune.exitSpeed)
                / (2 * max(remaining, 2))
            let a = min(required * 1.06, ac.kind.expediteDecel * 1.3)
            ac.speed = max(Tune.exitSpeed, ac.speed - a * dt)
        } else if remaining > 6 {
            ac.driveSpeed(toward: Tune.exitSpeed * 1.3, accel: base * 0.5, decel: base, dt: dt)
        }
        // De-rotation: main gear is down; ease the nose-up pitch → 0 over ~1.5 s
        // (nosewheel settles), and ease any residual bank → wings level over
        // ~0.5 s rather than snapping. Crab stays 0 (de-crabbed in the flare).
        let deRotStep = (0.16 / 1.5) * dt                     // ~0.107 rad/s cap
        ac.pitch += max(-deRotStep, min(deRotStep, 0 - ac.pitch))
        ac.rollBank(toward: 0, dt: dt, rollRate: 0.9)         // wings level ≤ ~0.5 s
        ac.throttle += (0.15 - ac.throttle) * min(1, dt * 2.5)
        ac.steer(toPoint: rw.point(atStationFrom22: s + 90), maxRate: 0.25, dt: dt,
                 maxBank: maxBank(ac))
        ac.integrate(dt: dt)
        ac.altitude = groundY(ac.pos2)

        if s >= ac.exitStation - 3 && ac.speed <= Tune.exitSpeed * 1.35 {
            beginTaxiIn(ac, now: now)
        }
    }

    private func beginTaxiIn(_ ac: Aircraft, now: Double) {
        // B15 — SLICK EXIT only when the expedite actually bought the earliest
        // reachable turnoff for THIS type (the Comet can't make Alpha Two).
        if ac.expedited && ac.exitIsEarliestReachable && ac.exitIsPreferred {
            ac.expeditedHonored = true
            awardBadge(.slickExit, to: ac,
                       note: "SLICK EXIT — \(ac.callsign.display) off at \(ac.exitTaxiwayName ?? "the high-speed")")
            lastExpedite = (now, ac.id)
        }
        var route = ac.exitIsPreferred ? airport.routeExitMidfield : airport.routeExitEnd
        if let spot = freeApronSpot() {
            ac.apronSpot = spot
            route.append(airport.apronSpots[spot].position)
        } else {
            // B21 — overflow arrivals fan out instead of stacking on one point.
            ac.apronSpot = -1
            ac.overflowIndex = overflowCount
            overflowCount += 1
            route.append(route.last! + perpTower * 12 + rw.dir22 * (14 * Double(ac.overflowIndex)))
        }
        ac.route = route
        ac.routeIndex = 0
        ac.phase = .exitingRunway
        pilotSay(ac, radio.pilotClearOfRunway(ac.callsign))
    }

    private func updateTaxiIn(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        // Idle taxi power; crab and any residual attitude relax on the ground.
        ac.throttle += (0.15 - ac.throttle) * min(1, dt * 2)
        easeCrab(ac, toward: 0, dt: dt)
        if ac.holdingPosition || groundBlocked(ac, arrivalsOnly: true) {   // B4
            ac.driveSpeed(toward: 0, accel: 0, decel: 2.2, dt: dt)
            ac.integrate(dt: dt)
            if ac.holdingPosition { accrueWait(ac, dt: dt, now: now) }
            ac.altitude = groundY(ac.pos2)
            return
        }
        if ac.phase == .exitingRunway && ac.routeIndex >= 1 { ac.phase = .taxiToApron }
        let spd = ac.kind.taxiSpeed * (ac.expedited && ac.phase == .exitingRunway ? 1.25 : 1.0)
        if ac.followRoute(speed: spd, accel: 1.0, turnRate: Tune.taxiTurnRate,
                            laneOffset: taxiLane(for: ac), dt: dt) {
            ac.phase = .parkedArrival
            ac.landingLightsOn = false
            ac.urgency = nil
            if ac.apronSpot >= 0 { ac.heading = airport.apronSpots[ac.apronSpot].heading }
        }
        ac.altitude = groundY(ac.pos2)
    }

    // MARK: Departures

    private func updateTaxiOut(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        ac.throttle += (0.15 - ac.throttle) * min(1, dt * 2)
        // B4 — departures yield to everyone ahead (arrivals clearing have
        // priority; a queue forms naturally at the hold-short line).
        if ac.holdingPosition || groundBlocked(ac, arrivalsOnly: false) {
            ac.driveSpeed(toward: 0, accel: 0, decel: 2.2, dt: dt)
            ac.integrate(dt: dt)
            if ac.holdingPosition { accrueWait(ac, dt: dt, now: now) }
            ac.altitude = groundY(ac.pos2)
            return
        }
        if ac.followRoute(speed: ac.kind.taxiSpeed, accel: 0.9, turnRate: Tune.taxiTurnRate,
                            laneOffset: taxiLane(for: ac), dt: dt) {
            ac.phase = .holdingShort
            resetWait(ac)
            pilotSay(ac, radio.pilotHoldingShort(ac.callsign))
        }
        ac.altitude = groundY(ac.pos2)
    }

    private func updateWaiting(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        ac.throttle += (0.15 - ac.throttle) * min(1, dt * 2)
        accrueWait(ac, dt: dt, now: now)
    }

    private func updateLineUpWait(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        ac.throttle += (0.15 - ac.throttle) * min(1, dt * 2)
        if !ac.lineupComplete {
            if ac.followRoute(speed: ac.kind.taxiSpeed * 0.85, accel: 0.9,
                              turnRate: Tune.taxiTurnRate, dt: dt) {
                ac.lineupComplete = true
                ac.heading = rw.heading22
                resetWait(ac)
            }
            ac.altitude = groundY(ac.pos2)
            return
        }
        ac.urgency = min(1, ac.waitSeconds / 30)
        accrueWait(ac, dt: dt, now: now)
    }

    private func updateTakeoffRoll(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        if !ac.lineupComplete {
            ac.throttle += (0.3 - ac.throttle) * min(1, dt * 2)   // taxiing into position
            if ac.followRoute(speed: ac.kind.taxiSpeed, accel: 1.0,
                              turnRate: Tune.taxiTurnRate, dt: dt) {
                ac.lineupComplete = true
                ac.heading = rw.heading22
            }
            ac.altitude = groundY(ac.pos2)
            return
        }
        if ac.preRollPause > 0 {
            ac.throttle += (0.5 - ac.throttle) * min(1, dt * 3)   // spooling up on the numbers
            ac.preRollPause = max(0, ac.preRollPause - dt)
            if ac.preRollPause > 0 { return }
        }
        // B3 — abort if a landing rolls out ahead before we can rotate.
        if ac.speed < ac.kind.rotateSpeed * 0.85 && landingAhead(of: ac) {
            pilotSay(ac, radio.pilotAbortTakeoff(ac.callsign))
            ac.clearedForTakeoff = false
            ac.immediateTakeoff = false
            ac.speed = min(ac.speed, Tune.exitSpeed)
            ac.phase = .lineUpWait
            ac.lineupComplete = true
            return
        }
        ac.urgency = nil
        ac.speed += ac.kind.takeoffAccel * dt
        ac.steer(toward: rw.heading22, maxRate: 0.15, dt: dt, maxBank: maxBank(ac))
        ac.bank = 0
        // Firewalled power on the roll.
        ac.throttle += (1.0 - ac.throttle) * min(1, dt * 3)
        // Rotation as an ARC: as speed climbs rotateSpeed*0.9 → rotateSpeed, ease
        // the nose 0 → ~0.14 rad over ~1 s. Purely presentation — the liftoff
        // moment (speed ≥ rotateSpeed) is unchanged, so the harness is identical.
        let vr = ac.kind.rotateSpeed
        let rotFrac = max(0, min(1, (ac.speed - vr * 0.9) / (vr * 0.1)))
        drivePitch2(ac, target: 0.14 * rotFrac, dt: dt, rate: 0.3)
        ac.integrate(dt: dt)
        ac.altitude = groundY(ac.pos2)
        if ac.speed >= ac.kind.rotateSpeed {
            liftoff(ac, now: now)
        }
    }

    /// Ease pitch toward an explicit target at a rate cap (rad/s). Used where the
    /// target is a rotation schedule, not a flight-path readout. Presentation-only.
    private func drivePitch2(_ ac: Aircraft, target: Double, dt: Double, rate: Double = 0.35) {
        let maxStep = rate * dt
        ac.pitch += max(-maxStep, min(maxStep, target - ac.pitch))
    }

    private func liftoff(_ ac: Aircraft, now: Double) {
        ac.phase = .climbingOut
        // No pitch snap — the rotation arc from updateTakeoffRoll has the nose
        // near ~0.14 rad already, and the climbout pitch law carries it from here.
        ac.verticalSpeed = ac.kind.climbRate * 0.4
        ac.landingLightsOn = true
        completeMovement(ac, isLanding: false)
        pilotSay(ac, radio.pilotAirborne(ac.callsign))
        adjudicateTightGap(ac, now: now)
        consumeExpedite(now: now, by: ac.id)
        if ac.immediateTakeoff { lastExpedite = (now, ac.id) }
    }

    private func updateClimbout(_ ac: Aircraft, dt: Double) {
        ac.driveSpeed(toward: ac.kind.climbSpeed, accel: 2.0, decel: 1.0, dt: dt)
        ac.verticalSpeed += (ac.kind.climbRate - ac.verticalSpeed) * min(1, dt * 1.5)
        ac.steer(toward: rw.heading22, maxRate: 0.1, dt: dt, maxBank: maxBank(ac))
        // True climb gradient + AoA via the one pitch law — the Comet's steep
        // 15 m/s climb reads clearly nose-high, the Lark's shallow climb gentle.
        drivePitch(ac, aoa: angleOfAttack(ac), dt: dt)
        easeCrab(ac, toward: crabAngle(forGroundHeading: ac.heading, airspeed: ac.speed), dt: dt)
        ac.throttle += (0.9 - ac.throttle) * min(1, dt * 2.5)
        ac.integrate(dt: dt)
        if ac.kind.hasRetractableGear && ac.gearDown && (ac.altitude - thrGroundY) >= 30 {
            ac.gearDown = false
        }
        if ac.phase == .climbingOut {
            let dist = simd_length(ac.pos2 - rw.thresholdB)
            if dist >= Tune.departHandoffDistance || (ac.altitude - thrGroundY) >= Tune.departHandoffAltitude {
                ac.phase = .departedHandoff
                ac.urgency = nil
            }
        }
    }

    // MARK: Waiting, nags, delay ledger

    private func accrueWait(_ ac: Aircraft, dt: Double, now: Double) {
        ac.waitSeconds += dt
        ac.delaySeconds += dt
        guard ac.waitSeconds >= Tune.nagAfter else { return }
        if ac.lastNagAt < 0 || now - ac.lastNagAt >= Tune.nagRepeat {
            ac.lastNagAt = now
            ac.nagCount += 1
            scoreboard.nags += 1
            pilotSay(ac, radio.pilotNag(ac.callsign))
        }
    }

    private func resetWait(_ ac: Aircraft) {
        ac.waitSeconds = 0
        ac.lastNagAt = -1
        ac.urgency = nil
    }

    // MARK: - Ground separation (B4)

    /// True when `o` has right of way over `ac`: arrivals clearing the runway
    /// outrank departures; within the same class a lower id wins. A strict
    /// total order, so mutual yielding can never deadlock.
    private func outranks(_ o: Aircraft, _ ac: Aircraft) -> Bool {
        if o.isArrival != ac.isArrival { return o.isArrival }
        return o.id.raw < ac.id.raw
    }

    /// Keep-right taxi lane, widened to a veer-around arc when another ground
    /// aircraft sits close ahead — so a moving aircraft steers around a stopped
    /// one at the shared apron throat instead of tracking straight through it.
    private func taxiLane(for ac: Aircraft) -> Double {
        let fwd = headingDirection(ac.heading)
        for o in aircraft where o.id != ac.id {
            switch o.phase {
            case .taxiToRunway, .taxiToApron, .exitingRunway, .holdingShort,
                 .lineUpWait, .startingUp:
                let rel = o.pos2 - ac.pos2
                let dist = simd_length(rel)
                if dist > 0.1, dist < 16, simd_dot(simd_normalize(rel), fwd) > 0.2 {
                    return 9.0   // arc right, around it
                }
            default: continue
            }
        }
        return Tune.taxiLaneOffset
    }

    /// Should this taxiing aircraft hold for another ground aircraft? Two
    /// guards: a forward-cone queue (follow at a gap) and a short-range
    /// side guard that yields to a higher-priority neighbour merging in — the
    /// two together stop both rear-end stacking and side-merge overlap (B4).
    private func groundBlocked(_ ac: Aircraft, arrivalsOnly: Bool) -> Bool {
        let fwd = headingDirection(ac.heading)
        for o in aircraft where o.id != ac.id {
            switch o.phase {
            case .taxiToRunway, .taxiToApron, .exitingRunway, .holdingShort,
                 .lineUpWait, .startingUp:
                let rel = o.pos2 - ac.pos2
                let dist = simd_length(rel)
                guard dist > 0.1 else { continue }
                let ahead = simd_dot(simd_normalize(rel), fwd) > 0.5
                if ahead, dist < Tune.groundQueueGap {
                    if !arrivalsOnly || o.isArrival { return true }   // forward queue
                }
                // Side/merge guard: never let a lower-priority aircraft overlap
                // a higher-priority neighbour, from any direction.
                if dist < 14, outranks(o, ac) { return true }
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Conflict projection (B2 / B3 / B5)

    /// Every committed arrival (cleared to land, or inside short final),
    /// sorted nearest-threshold first. Ta uses a two-segment speed-bleed
    /// estimate (B23) so a fast straight-in doesn't read artificially close.
    private func committedArrivals() -> [(ac: Aircraft, ta: Double)] {
        var out: [(Aircraft, Double)] = []
        for ac in aircraft {
            switch ac.phase {
            case .inboundFinal, .finalApproach, .shortFinal, .flare:
                guard ac.clearedToLand || ac.phase == .shortFinal || ac.phase == .flare else { continue }
                let d = -station(of: ac.pos2)
                guard d > -50 else { continue }
                out.append((ac, timeToThreshold(ac, distance: d)))
            default:
                continue
            }
        }
        return out.sorted { $0.1 < $1.1 }
    }

    /// B23 — integrate the pattern→Vref bleed instead of using instantaneous
    /// speed, so ambers that will self-heal don't train players to ignore them.
    private func timeToThreshold(_ ac: Aircraft, distance d: Double) -> Double {
        guard d > 0 else { return 0 }
        let vRef = ac.kind.approachSpeed
        if d <= 300 { return d / max((ac.speed + vRef) / 2, 10) }
        // Segment beyond 300 m bleeds from current speed toward Vref.
        let far = d - 300
        let vFar = (ac.speed + vRef) / 2
        return far / max(vFar, 10) + 300 / max(vRef, 10)
    }

    /// Honest runway-clear time (B5) — from distance to the chosen/likely exit,
    /// not a decel-to-zero fiction that overstated Vela occupancy by ~10 s.
    private func runwayClearTime(_ ac: Aircraft) -> Double? {
        switch ac.phase {
        case .flare:
            let ttd = max(0, ac.touchdownStation - station(of: ac.pos2)) / max(ac.speed, 10)
            return ttd + rolloutOccupancy(ac, fromStation: ac.touchdownStation)
        case .rollout:
            return rolloutOccupancy(ac, fromStation: station(of: ac.pos2))
        case .lineUpWait:
            return timeUntilAirborne(ac) + ConflictConstants.lineUpReaction   // B9
        case .takeoffRoll:
            return timeUntilAirborne(ac) + ConflictConstants.liftoffBuffer
        default:
            return nil
        }
    }

    /// Time from a runway station to clearing at the aircraft's exit.
    private func rolloutOccupancy(_ ac: Aircraft, fromStation s: Double) -> Double {
        let exitSt = ac.exitStation > 0 ? ac.exitStation : estimatedExitStation(ac)
        let remaining = max(0, exitSt - s)
        let avg = max((ac.speed + Tune.exitSpeed) / 2, Tune.exitSpeed)
        return remaining / avg + ConflictConstants.rolloutBuffer
    }

    private func estimatedExitStation(_ ac: Aircraft) -> Double {
        let decel = ac.kind.rolloutDecel
        let v = ac.kind.approachSpeed * 0.95
        let needed = (v * v - Tune.exitSpeed * Tune.exitSpeed) / (2 * decel)
        let reach = ac.touchdownStation + needed
        let exits = airport.exits.sorted { $0.stationFrom22 < $1.stationFrom22 }
        return (exits.first(where: { $0.stationFrom22 >= reach - 8 }) ?? exits.last!).stationFrom22
    }

    /// Estimated seconds a landing arrival occupies the runway (threshold→exit),
    /// used to project an arrival against the arrival ahead of it (B2).
    private func landingOccupancy(_ arr: Aircraft) -> Double {
        let toTouchdown = max(0, arr.touchdownStation) / max(arr.kind.approachSpeed * 0.9, 20)
        return toTouchdown + rolloutOccupancy(arr, fromStation: arr.touchdownStation)
    }

    private func timeUntilAirborne(_ ac: Aircraft) -> Double {
        var t = 0.0
        if !ac.lineupComplete {
            var remaining = 0.0
            if ac.routeIndex < ac.route.count {
                remaining = simd_length(ac.route[ac.routeIndex] - ac.pos2)
                for i in ac.routeIndex..<(ac.route.count - 1) {
                    remaining += simd_length(ac.route[i + 1] - ac.route[i])
                }
            }
            t += remaining / max(ac.kind.taxiSpeed * 0.85, 2)
        }
        t += max(0, ac.preRollPause)
        t += max(0, ac.kind.rotateSpeed - ac.speed) / ac.kind.takeoffAccel
        return t
    }

    /// B3 — a landing is on (or about to be on) the runway ahead of a departure.
    private func runwayHasLandingOccupant() -> Bool {
        for ac in aircraft {
            if ac.phase == .flare || ac.phase == .rollout {
                if let tc = runwayClearTime(ac), tc > 2 { return true }
            }
        }
        return false
    }

    /// B3 — a landing rolling out physically ahead of a rolling departure.
    private func landingAhead(of dep: Aircraft) -> Bool {
        let s = station(of: dep.pos2)
        for ac in aircraft where ac.phase == .flare || ac.phase == .rollout {
            if station(of: ac.pos2) > s + 20 { return true }
        }
        return false
    }

    /// B8 — a departure the player cleared onto the runway AFTER an arrival was
    /// already committed is the player's own manufactured gap; it pays nothing.
    private func isManufactured(arrival arr: Aircraft, occupant occ: Aircraft) -> Bool {
        guard !occ.isArrival else { return false }
        return occ.lastCommitAt >= 0 && occ.lastCommitAt > arr.committedAt
    }

    private func addProjection(_ proj: inout [ConflictProjection],
                               arr: Aircraft, occ: Aircraft,
                               margin: Double, ta: Double, manufactured: Bool) {
        let band = ConflictTracker.band(forMargin: margin)
        proj.append(ConflictProjection(arrival: arr.id, occupant: occ.id, margin: margin,
                                       timeToThreshold: ta, band: band, manufactured: manufactured))
        if band > .green {
            for ac in [arr, occ] {
                if band > ac.band { ac.band = band }
                ac.gapSeconds = min(ac.gapSeconds ?? .infinity, margin)
            }
        }
    }

    private func updateConflicts(_ now: Double) {
        var previousBands: [Int: ConflictBand] = [:]
        for ac in aircraft {
            previousBands[ac.id.raw] = ac.band
            ac.band = .green
            ac.gapSeconds = nil
        }

        var projections: [ConflictProjection] = []
        let arrivals = committedArrivals()
        let occupants = aircraft.filter { runwayClearTime($0) != nil }
                                .sorted { $0.id.raw < $1.id.raw }

        // B2 — each arrival vs every runway occupant AND every arrival ahead.
        for (i, entry) in arrivals.enumerated() {
            let arr = entry.ac, ta = entry.ta
            for occ in occupants where occ.id != arr.id {
                guard let tc = runwayClearTime(occ) else { continue }
                addProjection(&projections, arr: arr, occ: occ, margin: ta - tc, ta: ta,
                              manufactured: isManufactured(arrival: arr, occupant: occ))
            }
            for j in 0..<i {
                let ahead = arrivals[j].ac
                let tcAhead = arrivals[j].ta + landingOccupancy(ahead)
                addProjection(&projections, arr: arr, occ: ahead, margin: ta - tcAhead,
                              ta: ta, manufactured: false)
            }
        }

        let result = conflicts.integrate(projections: projections, now: now)
        scoreboard.saveOpportunities += result.newOpportunities
        for key in result.sustainedNow {
            scoreboard.sustainedReds += 1
            if let m = scoreboard.resetStreak() { eventQueue.append(.streakChanged(multiplier: m)) }
            for ac in aircraft where ac.id.raw == key.a || ac.id.raw == key.b {
                ac.dirty = true
            }
        }

        // B6 — pilot self-preservation: unresolved red, arrival about to cross.
        // Softened to −600, once per aircraft; if the pair had no meaningful
        // warning it resolves as an ordinary go-around (no −600, no event), so
        // the penalty only ever lands on demonstrated neglect.
        if let worst = projections.filter({ $0.band == .red }).min(by: { $0.margin < $1.margin }),
           worst.timeToThreshold < ConflictConstants.selfPreservationTa,
           let arr = aircraft.first(where: { $0.id == worst.arrival }),
           arr.phase.isAirborne, !arr.selfPresFired {
            arr.selfPresFired = true
            let ep = conflicts.state(worst.arrival, worst.occupant)
            let warned = ep?.amberSince.map { now - $0 >= ConflictConstants.selfPresWarning } ?? false
            if warned {
                pilotForcedGoAround(arr, penalty: Tune.selfPreservationPenalty, selfPreservation: true)
            } else {
                pilotForcedGoAround(arr, penalty: Tune.goAroundPenalty, selfPreservation: false)
            }
        }

        for ac in aircraft where previousBands[ac.id.raw] != ac.band {
            eventQueue.append(.bandChanged(aircraft: ac.id, band: ac.band))
        }
    }

    // MARK: - Scoring hooks

    private func completeMovement(_ ac: Aircraft, isLanding: Bool) {
        guard !ac.movementScored else { return }
        ac.movementScored = true
        let base = Int((isLanding ? 250.0 : 200.0) * ac.kind.movementWeight)
        let pts = scoreboard.award(base: base)
        if isLanding { scoreboard.landings += 1 } else { scoreboard.departures += 1 }
        if let m = scoreboard.registerMovement(clean: !ac.dirty) {
            eventQueue.append(.streakChanged(multiplier: m))
        }
        eventQueue.append(.movementCompleted(aircraft: ac.id, points: pts, isLanding: isLanding))
        scoreboard.noteMoment(points: pts, text: isLanding
            ? "\(ac.callsign.display) down and rolling, +\(pts)"
            : "\(ac.callsign.display) off the cliffs, +\(pts)")
    }

    private func awardBadge(_ badge: Badge, to ac: Aircraft, note: String) {
        let award = scoreboard.awardBadge(badge, aircraft: ac.id)
        eventQueue.append(.badge(award))
        scoreboard.noteMoment(points: award.points, text: note)
    }

    /// SAVE table (PRD law). Called for player goAround / cancel-takeoff hold.
    private func adjudicateResolution(_ ac: Aircraft, isGoAround: Bool) {
        if let ep = conflicts.worstEpisode(involving: ac.id) {
            // B8 — resolving your own manufactured gap earns respect, not points.
            if ep.playerManufactured {
                conflicts.clear(involving: ac.id)
                return
            }
            if ep.sustained {
                scoreboard.savesEarned += 1
                awardBadge(.lateSave, to: ac, note: "LATE SAVE on \(ac.callsign.display)")
            } else if !ac.saveAwarded {
                ac.saveAwarded = true
                scoreboard.savesEarned += 1
                let gap = Int(max(0, ep.lastMargin).rounded())
                awardBadge(.save, to: ac, note: "SAVE on \(ac.callsign.display), \(gap) s gap")
                if let m = scoreboard.stepDownStreak() {
                    eventQueue.append(.streakChanged(multiplier: m))
                }
            }
            conflicts.clear(involving: ac.id)
        } else if isGoAround {
            scoreboard.awardRaw(50)    // precautionary; streak untouched
        }
    }

    private func armTightGap(_ ac: Aircraft, now: Double) {
        guard let first = committedArrivals().first, first.ta <= Tune.tightGapWindow else { return }
        let m = first.ta - (timeUntilAirborne(ac) + ConflictConstants.liftoffBuffer)
        if m >= 0 && m < ConflictConstants.amberThreshold {
            ac.tightGapArmed = true
            ac.tightGapArmedArrival = first.ac.id       // B16 — pin the arrival
        }
    }

    private func adjudicateTightGap(_ ac: Aircraft, now: Double) {
        guard ac.tightGapArmed, let armed = ac.tightGapArmedArrival else { return }
        ac.tightGapArmed = false
        ac.tightGapArmedArrival = nil
        // B16 — pay only if the SAME arrival is still inbound and made it.
        guard let match = committedArrivals().first(where: { $0.ac.id == armed }) else { return }
        if match.ta - ConflictConstants.liftoffBuffer >= 0 {
            awardBadge(.tightGap, to: ac,
                       note: "TIGHT GAP — \(ac.callsign.display) off inside the arrival gap")
        }
    }

    private func consumeExpedite(now: Double, by id: AircraftID) {
        guard let e = lastExpedite, e.id != id, now - e.time <= Tune.noDelayWindow else { return }
        lastExpedite = nil
        let award = scoreboard.awardBadge(.noDelay, aircraft: e.id)
        eventQueue.append(.badge(award))
        scoreboard.noteMoment(points: award.points, text: "NO DELAY — the gap got used")
    }

    // MARK: - Shift end

    private func checkShiftEnd(_ now: Double) {
        guard !shiftEndedFired, now >= script.duration else { return }
        let unresolved = aircraft.contains { !$0.isResolved }
        if unresolved && now < script.duration + Tune.forceEndGrace { return }

        // B10 — never report with aircraft still flying: bank any pending
        // movement at base points and resolve every strip, THEN publish.
        if unresolved {
            for ac in aircraft where !ac.isResolved {
                if !ac.movementScored {
                    if ac.isArrival && (ac.phase.isAirborne || ac.phase == .rollout || ac.phase == .exitingRunway) {
                        completeMovement(ac, isLanding: true)
                    } else if !ac.isArrival && ac.phase.isAirborne {
                        completeMovement(ac, isLanding: false)
                    }
                }
                ac.phase = .removed
                eventQueue.append(.aircraftRemoved(ac.id))
            }
        }

        shiftEndedFired = true
        shiftPhase = .ended
        eventQueue.append(.shiftPhaseChanged(.ended))

        if let award = scoreboard.grantCleanShift() {
            eventQueue.append(.badge(award))
        }
        var delaySum = retiredDelaySum
        var count = retiredCount
        for ac in aircraft { delaySum += ac.delaySeconds; count += 1 }
        // B11 — grade against traffic that actually spawned.
        let report = scoreboard.makeReport(
            parScore: max(1, spawnedParScore),
            parMovements: max(1, spawnedParMovements),
            averageDelay: count == 0 ? 0 : delaySum / Double(count))
        eventQueue.append(.shiftEnded(report))
    }

    // MARK: - Legal commands (radial bloom, ≤6)

    func legalCommands(for ac: Aircraft) -> [Command] {
        switch ac.phase {
        case .inboundFinal, .finalApproach:
            var c: [Command] = []
            if !ac.clearedToLand { c.append(.clearedToLand) }
            c.append(.goAround)
            c.append(.make360(left: true))
            c.append(.make360(left: false))
            return c
        case .downwind:
            var c: [Command] = []
            if !ac.clearedToLand { c.append(.clearedToLand) }
            if !ac.extendUsed { c.append(.extendDownwind) }
            c.append(.goAround)
            c.append(.make360(left: true))
            c.append(.make360(left: false))
            return c
        case .base:
            var c: [Command] = []
            if !ac.clearedToLand { c.append(.clearedToLand) }
            c.append(.goAround)
            c.append(.make360(left: true))
            c.append(.make360(left: false))
            return c
        case .shortFinal:
            var c: [Command] = []
            if !ac.clearedToLand { c.append(.clearedToLand) }
            c.append(.goAround)
            // B15 — only offer expedite to a type that can actually make an
            // early turnoff (jets cannot, so the verb isn't a scam).
            if !ac.expedited && !ac.kind.engineIsJet { c.append(.expediteExit) }
            return c
        case .flare, .rollout:
            // B15 — no phantom expedite for jets.
            return (ac.expedited || ac.kind.engineIsJet) ? [] : [.expediteExit]
        case .exitingRunway, .taxiToApron, .taxiToRunway:
            return ac.holdingPosition ? [.continueTaxi] : [.holdPosition]
        case .holdingShort:
            return [.lineUpAndWait,
                    .clearedForTakeoff(immediate: false),
                    .clearedForTakeoff(immediate: true)]
        case .lineUpWait:
            return [.clearedForTakeoff(immediate: false),
                    .clearedForTakeoff(immediate: true)]
        case .takeoffRoll:
            return ac.speed < ac.kind.rotateSpeed * 0.7 ? [.holdPosition] : []
        case .parkedArrival, .departedHandoff:
            return [.handoff]
        case .orbiting, .goingAround, .climbingOut, .startingUp, .removed:
            return []
        }
    }
}
