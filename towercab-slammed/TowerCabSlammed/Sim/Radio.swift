import Foundation

// =============================================================================
// RadioVoice — flavor phraseology for tower and pilots. Owns a private RNG
// stream (seeded off the shift seed) so wording variety never perturbs the
// behavioral RNG: same seed, same radio, same sim.
// =============================================================================

struct RadioVoice {
    private var rng: SeededRNG
    let windText: String

    init(seed: UInt64, wind: Wind) {
        self.rng = SeededRNG(seed: seed ^ 0x11AD_10_11AD_10)
        let dir = ShiftScript.spokenDigits(String(format: "%03d", Int(wind.directionDeg)))
        let spd = ShiftScript.spokenDigits(String(Int(wind.speedKts)))
        self.windText = "wind \(dir.lowercased()) at \(spd.lowercased())"
    }

    private mutating func pick(_ options: [String]) -> String { rng.pick(options) }

    // MARK: Tower → pilot (returns tower call; readbacks built separately)

    mutating func towerClearedToLand(_ c: Callsign) -> String {
        "\(c.spoken), runway two-two, \(windText), cleared to land."
    }
    mutating func towerGoAround(_ c: Callsign) -> String {
        pick(["\(c.spoken), go around, fly runway heading, climb to pattern altitude.",
              "\(c.spoken), go around. Runway heading, back to pattern altitude."])
    }
    mutating func towerExtend(_ c: Callsign) -> String {
        pick(["\(c.spoken), extend downwind, I'll call your base.",
              "\(c.spoken), extend downwind, expect a late base."])
    }
    mutating func towerOrbit(_ c: Callsign, left: Bool) -> String {
        "\(c.spoken), make one three-sixty to the \(left ? "left" : "right"), report back inbound."
    }
    mutating func towerLineUp(_ c: Callsign) -> String {
        "\(c.spoken), runway two-two, line up and wait."
    }
    mutating func towerTakeoff(_ c: Callsign, immediate: Bool) -> String {
        immediate
            ? "\(c.spoken), runway two-two, no delay, cleared for immediate takeoff."
            : "\(c.spoken), runway two-two, \(windText), cleared for takeoff."
    }
    mutating func towerHold(_ c: Callsign) -> String {
        pick(["\(c.spoken), hold position.", "\(c.spoken), hold your position."])
    }
    mutating func towerContinue(_ c: Callsign) -> String {
        pick(["\(c.spoken), continue taxi.", "\(c.spoken), continue."])
    }
    mutating func towerExpedite(_ c: Callsign, exitName: String?) -> String {
        // B15 — name the exit this type can actually make, or stay generic.
        if let e = exitName {
            return pick(["\(c.spoken), expedite, right at \(e), no delay.",
                         "\(c.spoken), keep your speed up, exit right at \(e)."])
        }
        return pick(["\(c.spoken), expedite, first available right, no delay.",
                     "\(c.spoken), keep your speed up, first available right."])
    }
    /// B25 — the tower answers a ready-to-taxi call with an actual clearance.
    mutating func towerTaxiClearance(_ c: Callsign, via: String) -> String {
        pick(["\(c.spoken), runway two-two, taxi via \(via), hold short.",
              "\(c.spoken), taxi to runway two-two via \(via), hold short."])
    }
    mutating func towerHandoffDeparture(_ c: Callsign) -> String {
        pick(["\(c.spoken), contact SoCal departure. Good day.",
              "\(c.spoken), frequency change approved, so long."])
    }
    mutating func towerHandoffArrival(_ c: Callsign) -> String {
        pick(["\(c.spoken), taxi to parking is approved, welcome to the island.",
              "\(c.spoken), parking's ahead on your left. Nice job on the hill."])
    }

    // MARK: Pilot readbacks (queued ~0.7 s after the tower call)

    mutating func readback(_ c: Callsign, for command: Command) -> String {
        switch command {
        case .clearedToLand:
            return "Cleared to land two-two, \(c.spoken)."
        case .goAround:
            return pick(["Going around, \(c.spoken).",
                         "Runway heading, going around, \(c.spoken)."])
        case .extendDownwind:
            return "Extending downwind, \(c.spoken)."
        case .make360(let left):
            return "One three-sixty to the \(left ? "left" : "right"), \(c.spoken)."
        case .lineUpAndWait:
            return "Line up and wait two-two, \(c.spoken)."
        case .clearedForTakeoff(let immediate):
            return immediate ? "Rolling now, \(c.spoken)."
                             : "Cleared for takeoff two-two, \(c.spoken)."
        case .holdPosition:
            return "Holding, \(c.spoken)."
        case .continueTaxi:
            return "Continuing, \(c.spoken)."
        case .expediteExit:
            return pick(["Wilco, no delay, \(c.spoken).", "Keeping it rolling, \(c.spoken)."])
        case .handoff:
            return pick(["Good day.", "So long, \(c.spoken)."])
        }
    }

    // MARK: Pilot-initiated

    mutating func pilotReadyToTaxi(_ c: Callsign) -> String {
        pick(["Catalina Tower, \(c.spoken), at the ramp, ready to taxi.",
              "Tower, \(c.spoken), ready to taxi with the numbers."])
    }
    mutating func pilotHoldingShort(_ c: Callsign) -> String {
        "\(c.spoken), holding short runway two-two, ready for departure."
    }
    mutating func pilotNag(_ c: Callsign) -> String {
        pick(["Tower, \(c.spoken), still holding short, ready.",
              "\(c.spoken) is still waiting, ready when you are.",
              "Tower, \(c.spoken), any word on our clearance?"])
    }
    mutating func pilotSelfGoAround(_ c: Callsign) -> String {
        pick(["\(c.spoken) is going around, no clearance received.",
              "Tower, \(c.spoken), going around."])
    }
    mutating func pilotEmergencyGoAround(_ c: Callsign) -> String {
        pick(["\(c.spoken), going around! Traffic on the runway!",
              "\(c.spoken) breaking off the approach — runway's occupied!"])
    }
    mutating func pilotBackOnFinal(_ c: Callsign) -> String {
        "\(c.spoken), back with you on final."
    }
    /// B19 — phase-aware orbit exit for pattern legs.
    mutating func pilotBackOnDownwind(_ c: Callsign) -> String {
        pick(["\(c.spoken), back on the downwind.",
              "\(c.spoken), three-sixty complete, downwind."])
    }
    /// B18 — go-around issued on the downwind reads back as a rejoin.
    mutating func readbackPatternGoAround(_ c: Callsign) -> String {
        pick(["Coming around for the downwind, \(c.spoken).",
              "Breaking off, we'll rejoin the downwind, \(c.spoken)."])
    }
    /// B3 — departure refuses a takeoff clearance onto an occupied runway.
    mutating func pilotUnableTakeoff(_ c: Callsign) -> String {
        pick(["\(c.spoken), unable, traffic on the runway.",
              "Negative, \(c.spoken), there's traffic on the runway."])
    }
    /// B3 — departure aborts the roll when the runway fills in front of it.
    mutating func pilotAbortTakeoff(_ c: Callsign) -> String {
        "\(c.spoken), aborting, traffic on the runway!"
    }
    /// Cleared traffic squeezed by the runway — firm but not an emergency.
    mutating func pilotTrafficGoAround(_ c: Callsign) -> String {
        pick(["\(c.spoken), going around, that gap's not there.",
              "\(c.spoken) is going around, runway's still occupied."])
    }
    mutating func pilotClearOfRunway(_ c: Callsign) -> String {
        pick(["\(c.spoken), clear of two-two.", "\(c.spoken) is clear, taxiing in."])
    }
    mutating func pilotAirborne(_ c: Callsign) -> String {
        // B30 — departure phraseology (no "rolling out" on a climb-out).
        pick(["\(c.spoken), on the go.",
              "\(c.spoken), airborne, climbing on runway heading."])
    }
}
