import Foundation
import simd

// =============================================================================
// SimEngine+Tick — the deterministic heart. One fixed 10 Hz tick:
//   shift phase → spawns → commands → per-aircraft flight/ground update →
//   conflict projection → deferred radio → shift end.
// All iteration over aircraft is in AircraftID order; all randomness comes
// from SeededRNG streams. Same seed ⇒ identical run.
// =============================================================================

extension SimEngine {

    // MARK: Tuning

    private enum Tune {
        static let maxActiveStrips = 9
        static let minSpawnSeparation = 8.0
        static let patternTurnRate = 0.14        // rad/s ≈ a 45 s orbit
        static let cometTurnRate = 0.105
        static let taxiTurnRate = 0.9
        static let approachLookahead = 260.0     // final-track aim distance, m
        static let speedBleedStart = 2000.0      // begin decel to Vref here
        static let exitSpeed = 7.0               // runway turnoff speed, m/s
        static let thresholdCrossAGL = 15.0
        static let commitDistance = 500.0        // uncleared inside this → pilot GA
        static let nagAfter = 45.0
        static let nagRepeat = 40.0
        static let preRollPauseSeconds = 3.0
        static let departHandoffDistance = 3500.0
        static let departHandoffAltitude = 350.0
        static let goAroundPenalty = 250
        static let selfPreservationPenalty = 2000
        static let tightGapWindow = 90.0
        static let noDelayWindow = 25.0
        static let forceEndGrace = 150.0
    }

    // MARK: Geometry sugar

    private var rw: Runway { airport.runway }
    private var perpSE: V2 { V2(-rw.dir22.y, rw.dir22.x) }
    private var perpNW: V2 { -perpSE }
    private var gsRad: Double { degToRad(airport.finalGlideSlopeDeg) }

    /// Signed distance along the runway axis from threshold 22 (+ = toward SW).
    private func station(of p: V2) -> Double { simd_dot(p - rw.thresholdB, rw.dir22) }
    /// Lateral offset from centerline (+ = SE/tower side).
    private func cross(of p: V2) -> Double { simd_dot(p - rw.thresholdB, perpSE) }
    /// Glideslope altitude at a given distance-to-threshold.
    private func glideAlt(_ dist: Double) -> Double {
        Tune.thresholdCrossAGL + max(0, dist) * tan(gsRad)
    }
    private func downwindPoint(station s: Double) -> V2 {
        rw.point(atStationFrom22: s) + perpNW * airport.downwindOffset
    }
    private func turnRate(_ ac: Aircraft) -> Double {
        ac.kind == .comet60 ? Tune.cometTurnRate : Tune.patternTurnRate
    }
    private func groundY(_ p: V2) -> Double { airport.groundHeight(at: p) }

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
                    shiftTimeRemaining: max(0, script.duration - simTime), wind: wind)
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
        // The traffic curve stops authoring movements 60 s before shift end;
        // strip-cap deferrals past that point are abandoned, not backlogged.
        if now > ShiftScript.lastSpawnTime + 10 {
            spawnCursor = script.orders.count
            return
        }
        while spawnCursor < script.orders.count, script.orders[spawnCursor].time <= now {
            guard aircraft.count < Tune.maxActiveStrips,
                  now - lastSpawnAt >= Tune.minSpawnSeparation                // no deferral bursts
            else { return }                                                   // retry next tick
            let order = script.orders[spawnCursor]
            if order.isArrival {
                spawnArrival(order)
            } else {
                guard let spot = freeApronSpot() else { return }          // defer until a spot opens
                spawnDeparture(order, spot: spot)
            }
            lastSpawnAt = now
            spawnCursor += 1
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
            ac.pos2 = downwindPoint(station: airport.downwindEntryStation)
            ac.altitude = airport.patternAltitude
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
        pilotSay(ac, ac.straightIn
            ? "Catalina Tower, \(ac.callsign.spoken), long final runway two-two."
            : "Catalina Tower, \(ac.callsign.spoken), right downwind two-two, full stop.")
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
            ac.phase = .lineUpWait
            ac.route = lineUpRoute()
            ac.routeIndex = 0
            ac.lineupComplete = false
            resetWait(ac)
            towerSay(radio.towerLineUp(ac.callsign), readback: command, ac: ac, now: now)

        case .clearedForTakeoff(let immediate):
            ac.clearedForTakeoff = true
            ac.immediateTakeoff = immediate
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
            towerSay(radio.towerExpedite(ac.callsign), readback: command, ac: ac, now: now)

        case .handoff:
            scoreboard.award(base: 50)
            towerSay(ac.isArrival ? radio.towerHandoffArrival(ac.callsign)
                                  : radio.towerHandoffDeparture(ac.callsign),
                     readback: command, ac: ac, now: now)
            remove(ac)
        }
    }

    private func lineUpRoute() -> [V2] {
        // Extend the authored line-up route with an along-runway point so the
        // aircraft finishes naturally aligned with the 22 heading.
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
        eventQueue.append(.radio(RadioCall(speaker: .tower, text: text)))
        let reply = radio.readback(ac.callsign, for: readback)
        delayedRadio.append((now + 0.7, RadioCall(speaker: .pilot(ac.id), text: reply)))
    }

    private func pilotSay(_ ac: Aircraft, _ text: String) {
        eventQueue.append(.radio(RadioCall(speaker: .pilot(ac.id), text: text)))
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
            if ac.phaseTime >= 4 {
                pilotSay(ac, radio.pilotReadyToTaxi(ac.callsign))
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

        // Phase ladder by distance.
        if ac.phase == .inboundFinal && d <= 3500 { ac.phase = .finalApproach }
        if (ac.phase == .finalApproach || ac.phase == .inboundFinal) && d <= 1200 {
            ac.phase = .shortFinal
        }
        ac.urgency = ac.phase == .shortFinal ? (1 - max(0, d) / 1200) : nil

        // Frequency neglect: no clearance inside the commit distance.
        if d <= Tune.commitDistance && !ac.clearedToLand {
            pilotForcedGoAround(ac, penalty: Tune.goAroundPenalty, selfPreservation: false)
            return
        }
        if d <= 0 {
            ac.phase = .flare
            ac.urgency = nil
            return
        }

        // Speed: pattern speed bleeding to Vref inside 2 km.
        let vRef = ac.kind.approachSpeed
        let blend = max(0, min(1, (d - 300) / (Tune.speedBleedStart - 300)))
        ac.driveSpeed(toward: vRef + (ac.kind.patternSpeed - vRef) * blend,
                      accel: 1.2, decel: 1.1, dt: dt)

        // Lateral: pursue a point on the centerline just ahead.
        let aim = rw.point(atStationFrom22: -(d - Tune.approachLookahead))
        ac.steer(toPoint: aim, maxRate: turnRate(ac), dt: dt)

        driveGlide(ac, targetAlt: glideAlt(d), dt: dt)
        ac.integrate(dt: dt)
    }

    /// Smooth vertical guidance toward a target altitude with a glide feedforward.
    private func driveGlide(_ ac: Aircraft, targetAlt: Double, dt: Double, gentle: Bool = false) {
        let ff = -ac.speed * tan(gsRad)
        var desired = ff + (targetAlt - ac.altitude) * 0.30
        if targetAlt > ac.altitude { desired = min(desired + 2.5, ac.kind.climbRate) }
        desired = max(gentle ? -6 : -9, min(desired, 4))
        ac.verticalSpeed += (desired - ac.verticalSpeed) * min(1, dt * 2.2)
        ac.pitch += (atan2(ac.verticalSpeed, max(ac.speed, 20)) * 0.9 - ac.pitch) * min(1, dt * 3)
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
        ac.driveSpeed(toward: ac.kind.patternSpeed, accel: 1.2, decel: 1.0, dt: dt)
        ac.steer(toPoint: downwindPoint(station: s - 320), maxRate: turnRate(ac), dt: dt)
        let pathDist = (s - airport.baseTurnStation) + airport.downwindOffset - airport.baseTurnStation
        driveGlide(ac, targetAlt: min(airport.patternAltitude, glideAlt(pathDist)), dt: dt, gentle: true)
        ac.integrate(dt: dt)
    }

    private func updateBase(_ ac: Aircraft, dt: Double) {
        let intercept = rw.point(atStationFrom22: airport.baseTurnStation)
        ac.driveSpeed(toward: ac.kind.patternSpeed * 0.9, accel: 1.0, decel: 1.0, dt: dt)
        ac.steer(toPoint: intercept, maxRate: turnRate(ac), dt: dt)
        let lateral = abs(cross(of: ac.pos2))
        let pathDist = lateral - airport.baseTurnStation
        driveGlide(ac, targetAlt: min(airport.patternAltitude, glideAlt(pathDist)), dt: dt, gentle: true)
        ac.integrate(dt: dt)
        if lateral < 150 { ac.phase = .finalApproach }
    }

    private func updateOrbit(_ ac: Aircraft, dt: Double) {
        let rate = (2 * .pi / 45.0) * (ac.orbitLeft ? -1.0 : 1.0)
        ac.heading += rate * dt
        ac.orbitRemaining -= abs(rate * dt)
        let targetBank = atan((abs(rate) * max(ac.speed, 20)) / 9.81) * (ac.orbitLeft ? -1 : 1)
        ac.bank += (max(-0.45, min(0.45, targetBank)) - ac.bank) * min(1, dt * 4)
        ac.driveSpeed(toward: ac.kind.patternSpeed, accel: 1.0, decel: 0.8, dt: dt)
        ac.verticalSpeed += (0 - ac.verticalSpeed) * min(1, dt * 2)
        ac.integrate(dt: dt)
        if ac.orbitRemaining <= 0 {
            ac.phase = ac.resumePhase == .orbiting ? .finalApproach : ac.resumePhase
            if !ac.straightIn && ac.phase == .downwind { /* rejoin handled by downwind */ }
            else { pilotSay(ac, radio.pilotBackOnFinal(ac.callsign)) }
        }
    }

    private func beginGoAround(_ ac: Aircraft) {
        ac.phase = .goingAround
        ac.clearedToLand = false
        ac.urgency = nil
        conflicts.clear(involving: ac.id)
    }

    private func pilotForcedGoAround(_ ac: Aircraft, penalty: Int, selfPreservation: Bool) {
        scoreboard.penalize(penalty)
        if let m = scoreboard.resetStreak() { eventQueue.append(.streakChanged(multiplier: m)) }
        scoreboard.pilotForcedGoArounds += 1
        ac.goAroundCount += 1
        ac.delaySeconds += 60
        if selfPreservation {
            eventQueue.append(.selfPreservation(aircraft: ac.id, penalty: penalty))
            pilotSay(ac, radio.pilotEmergencyGoAround(ac.callsign))
        } else {
            pilotSay(ac, radio.pilotSelfGoAround(ac.callsign))
        }
        beginGoAround(ac)
    }

    private func updateGoAround(_ ac: Aircraft, dt: Double) {
        ac.driveSpeed(toward: ac.kind.patternSpeed, accel: 1.6, decel: 0.8, dt: dt)
        let s = station(of: ac.pos2)
        let climbing = ac.altitude < airport.patternAltitude - 5
        let desiredVS = climbing ? ac.kind.climbRate : 0
        ac.verticalSpeed += (desiredVS - ac.verticalSpeed) * min(1, dt * 1.8)
        ac.pitch += (atan2(ac.verticalSpeed, max(ac.speed, 20)) - ac.pitch) * min(1, dt * 3)

        let entry = downwindPoint(station: airport.downwindEntryStation)
        if s < 650 || ac.altitude < airport.patternAltitude * 0.55 {
            ac.steer(toward: rw.heading22, maxRate: turnRate(ac), dt: dt)      // straight ahead
        } else {
            ac.steer(toPoint: entry, maxRate: turnRate(ac), dt: dt)            // crosswind → downwind
            if simd_length(entry - ac.pos2) < 260 {
                ac.phase = .downwind
                pilotSay(ac, "\(ac.callsign.spoken), back on the downwind.")
            }
        }
        ac.integrate(dt: dt)
    }

    private func updateFlare(_ ac: Aircraft, dt: Double, now: Double) {
        let s = station(of: ac.pos2)
        let remaining = ac.touchdownStation - s
        let groundH = groundY(rw.point(atStationFrom22: ac.touchdownStation))
        ac.driveSpeed(toward: ac.kind.approachSpeed * 0.95, accel: 0.5, decel: 1.0, dt: dt)
        let ttd = max(0.4, remaining / max(ac.speed, 10))
        let desiredVS = max(-4.0, min(0, -(ac.altitude - groundH) / ttd))
        ac.verticalSpeed += (desiredVS - ac.verticalSpeed) * min(1, dt * 3)
        ac.pitch += (0.07 - ac.pitch) * min(1, dt * 2.5)   // nose-up in the flare
        ac.steer(toPoint: rw.point(atStationFrom22: s + 120), maxRate: 0.2, dt: dt)
        ac.integrate(dt: dt)
        if ac.altitude <= groundH + 0.15 || s >= ac.touchdownStation {
            ac.altitude = groundY(ac.pos2)
            ac.verticalSpeed = 0
            ac.phase = .rollout
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
        var chosen = exits.last!
        if ac.expedited, let preferred = exits.first(where: { $0.isPreferred }),
           preferred.stationFrom22 >= reach - 8 {
            chosen = preferred
        } else if let first = exits.first(where: { $0.stationFrom22 >= reach - 5 }) {
            chosen = first
        }
        ac.exitStation = chosen.stationFrom22
        ac.exitIsPreferred = chosen.isPreferred
    }

    private func updateRollout(_ ac: Aircraft, dt: Double, now: Double) {
        let s = station(of: ac.pos2)
        let remaining = ac.exitStation - s
        let base = ac.expedited ? ac.kind.expediteDecel : ac.kind.rolloutDecel
        if ac.speed > Tune.exitSpeed {
            // Follow the profile that reaches exit speed exactly at the turnoff:
            // roll fast, minimum runway occupancy. Cap at hard braking.
            let required = (ac.speed * ac.speed - Tune.exitSpeed * Tune.exitSpeed)
                / (2 * max(remaining, 2))
            let a = min(required * 1.06, ac.kind.expediteDecel * 1.3)
            ac.speed = max(Tune.exitSpeed, ac.speed - a * dt)
        } else if remaining > 6 {
            // Braked early (recomputed exit): keep it moving to the turnoff.
            ac.driveSpeed(toward: Tune.exitSpeed * 1.3, accel: base * 0.5, decel: base, dt: dt)
        }
        ac.pitch += (0 - ac.pitch) * min(1, dt * 2)
        ac.bank = 0
        ac.steer(toPoint: rw.point(atStationFrom22: s + 90), maxRate: 0.25, dt: dt)
        ac.integrate(dt: dt)
        ac.altitude = groundY(ac.pos2)

        if s >= ac.exitStation - 3 && ac.speed <= Tune.exitSpeed * 1.35 {
            beginTaxiIn(ac, now: now)
        }
    }

    private func beginTaxiIn(_ ac: Aircraft, now: Double) {
        // The landing movement banks at turnoff (PRD: touchdown-complete).
        completeMovement(ac, isLanding: true)
        if ac.expedited && ac.exitIsPreferred {
            ac.expeditedHonored = true
            awardBadge(.slickExit, to: ac,
                       note: "SLICK EXIT — \(ac.callsign.display) off at Alpha Two")
            lastExpedite = (now, ac.id)
        }
        var route = ac.exitIsPreferred ? airport.routeExitMidfield : airport.routeExitEnd
        if let spot = freeApronSpot() {
            ac.apronSpot = spot
            route.append(airport.apronSpots[spot].position)
        } else {
            ac.apronSpot = -1
            route.append(route.last! + perpSE * 12)
        }
        ac.route = route
        ac.routeIndex = 0
        ac.phase = .exitingRunway
        pilotSay(ac, radio.pilotClearOfRunway(ac.callsign))
    }

    private func updateTaxiIn(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        if ac.holdingPosition {
            ac.driveSpeed(toward: 0, accel: 0, decel: 2.2, dt: dt)
            ac.integrate(dt: dt)
            accrueWait(ac, dt: dt, now: now)
            return
        }
        if ac.phase == .exitingRunway && ac.routeIndex >= 1 { ac.phase = .taxiToApron }
        let spd = ac.kind.taxiSpeed * (ac.expedited && ac.phase == .exitingRunway ? 1.25 : 1.0)
        if ac.followRoute(speed: spd, accel: 1.0, turnRate: Tune.taxiTurnRate, dt: dt) {
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
        if ac.holdingPosition {
            ac.driveSpeed(toward: 0, accel: 0, decel: 2.2, dt: dt)
            ac.integrate(dt: dt)
            accrueWait(ac, dt: dt, now: now)
            return
        }
        if ac.followRoute(speed: ac.kind.taxiSpeed, accel: 0.9, turnRate: Tune.taxiTurnRate, dt: dt) {
            ac.phase = .holdingShort
            resetWait(ac)
            pilotSay(ac, radio.pilotHoldingShort(ac.callsign))
        }
        ac.altitude = groundY(ac.pos2)
    }

    private func updateWaiting(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        accrueWait(ac, dt: dt, now: now)
    }

    private func updateLineUpWait(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
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
        // Sitting on the runway: urgency climbs, pilot gets antsy.
        ac.urgency = min(1, ac.waitSeconds / 30)
        accrueWait(ac, dt: dt, now: now)
    }

    private func updateTakeoffRoll(_ ac: Aircraft, dt: Double, now: Double) {
        ac.altitude = groundY(ac.pos2)
        if !ac.lineupComplete {
            if ac.followRoute(speed: ac.kind.taxiSpeed, accel: 1.0,
                              turnRate: Tune.taxiTurnRate, dt: dt) {
                ac.lineupComplete = true
                ac.heading = rw.heading22
            }
            ac.altitude = groundY(ac.pos2)
            return
        }
        if ac.preRollPause > 0 {
            ac.preRollPause = max(0, ac.preRollPause - dt)
            if ac.preRollPause > 0 { return }
        }
        ac.urgency = nil
        ac.speed += ac.kind.takeoffAccel * dt
        ac.steer(toward: rw.heading22, maxRate: 0.15, dt: dt)
        ac.bank = 0
        ac.integrate(dt: dt)
        ac.altitude = groundY(ac.pos2)
        if ac.speed >= ac.kind.rotateSpeed {
            liftoff(ac, now: now)
        }
    }

    private func liftoff(_ ac: Aircraft, now: Double) {
        ac.phase = .climbingOut
        ac.pitch = 0.14        // ~8° rotation
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
        ac.steer(toward: rw.heading22, maxRate: 0.1, dt: dt)
        ac.pitch += (0.14 - ac.pitch) * min(1, dt * 2)
        ac.integrate(dt: dt)
        if ac.kind.hasRetractableGear && ac.gearDown && ac.altitude >= 30 {
            ac.gearDown = false
        }
        if ac.phase == .climbingOut {
            let dist = simd_length(ac.pos2 - rw.thresholdB)
            if dist >= Tune.departHandoffDistance || ac.altitude >= Tune.departHandoffAltitude {
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

    // MARK: - Conflict projection

    /// Nearest committed arrival: cleared to land, or inside short final.
    private func committedArrival() -> (ac: Aircraft, timeToThreshold: Double)? {
        var best: (Aircraft, Double)? = nil
        for ac in aircraft {
            switch ac.phase {
            case .inboundFinal, .finalApproach, .shortFinal:
                guard ac.clearedToLand || ac.phase == .shortFinal else { continue }
                let d = -station(of: ac.pos2)
                guard d > 0 else { continue }
                let ta = d / max(ac.speed, 10)
                if best == nil || ta < best!.1 { best = (ac, ta) }
            default:
                continue
            }
        }
        return best.map { (ac: $0.0, timeToThreshold: $0.1) }
    }

    private func runwayClearTime(_ ac: Aircraft) -> Double? {
        switch ac.phase {
        case .flare:
            let ttd = max(0, ac.touchdownStation - station(of: ac.pos2)) / max(ac.speed, 10)
            let decel = ac.expedited ? ac.kind.expediteDecel : ac.kind.rolloutDecel
            let roll = max(0, ac.speed * 0.95 - Tune.exitSpeed) / decel
            return ttd + roll + ConflictConstants.rolloutBuffer
        case .rollout:
            let decel = ac.expedited ? ac.kind.expediteDecel : ac.kind.rolloutDecel
            return max(0, ac.speed - Tune.exitSpeed) / decel + ConflictConstants.rolloutBuffer
        case .lineUpWait:
            return ConflictConstants.lineUpWaitNeed
        case .takeoffRoll:
            return timeUntilAirborne(ac) + ConflictConstants.liftoffBuffer
        default:
            return nil
        }
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

    private func updateConflicts(_ now: Double) {
        var previousBands: [Int: ConflictBand] = [:]
        for ac in aircraft {
            previousBands[ac.id.raw] = ac.band
            ac.band = .green
            ac.gapSeconds = nil
        }

        var projections: [ConflictProjection] = []
        if let (arr, ta) = committedArrival() {
            for occ in aircraft where occ.id != arr.id {
                guard let tc = runwayClearTime(occ) else { continue }
                let m = ta - tc
                let band = ConflictTracker.band(forMargin: m)
                projections.append(ConflictProjection(arrival: arr.id, occupant: occ.id,
                                                      margin: m, timeToThreshold: ta, band: band))
                if band > .green {
                    for ac in [arr, occ] {
                        if band > ac.band { ac.band = band }
                        ac.gapSeconds = min(ac.gapSeconds ?? .infinity, m)
                    }
                }
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

        // Pilot self-preservation: unresolved red, arrival about to cross.
        if let worst = projections.filter({ $0.band == .red }).min(by: { $0.margin < $1.margin }),
           worst.timeToThreshold < ConflictConstants.selfPreservationTa,
           let arr = aircraft.first(where: { $0.id == worst.arrival }),
           arr.phase.isAirborne {
            pilotForcedGoAround(arr, penalty: Tune.selfPreservationPenalty, selfPreservation: true)
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
        guard let (_, ta) = committedArrival(), ta <= Tune.tightGapWindow else { return }
        let m = ta - (timeUntilAirborne(ac) + ConflictConstants.liftoffBuffer)
        if m >= 0 && m < ConflictConstants.amberThreshold { ac.tightGapArmed = true }
    }

    private func adjudicateTightGap(_ ac: Aircraft, now: Double) {
        guard ac.tightGapArmed else { return }
        ac.tightGapArmed = false
        guard let (_, ta) = committedArrival() else { return }
        if ta - ConflictConstants.liftoffBuffer >= 0 {
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
        guard !unresolved || now >= script.duration + Tune.forceEndGrace else { return }
        shiftEndedFired = true
        shiftPhase = .ended
        eventQueue.append(.shiftPhaseChanged(.ended))

        if let award = scoreboard.grantCleanShift() {
            eventQueue.append(.badge(award))
        }
        var delaySum = retiredDelaySum
        var count = retiredCount
        for ac in aircraft { delaySum += ac.delaySeconds; count += 1 }
        let report = scoreboard.makeReport(script: script,
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
            if !ac.expedited { c.append(.expediteExit) }
            return c
        case .flare:
            return ac.expedited ? [] : [.expediteExit]
        case .rollout:
            return ac.expedited ? [] : [.expediteExit]
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
            // Abort window: still slow on the roll.
            return ac.speed < ac.kind.rotateSpeed * 0.7 ? [.holdPosition] : []
        case .parkedArrival, .departedHandoff:
            return [.handoff]
        case .orbiting, .goingAround, .climbingOut, .startingUp, .removed:
            return []
        }
    }
}
