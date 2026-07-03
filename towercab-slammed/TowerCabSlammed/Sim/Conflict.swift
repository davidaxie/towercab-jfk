import Foundation
import simd

// =============================================================================
// Conflict projection — runway occupancy bands (PRD §2.5, tuned generous).
//
// One protected resource in the slice: runway 22. For the nearest committed
// arrival we project time-to-threshold Ta; every occupant projects a
// runway-clear time Tc. Margin M = Ta − Tc maps to green/amber/red. Red must
// hold 1.0 s continuously before it "sustains" (streak reset).
// =============================================================================

struct ConflictConstants {
    static let amberThreshold = 8.0      // M ≥ 8 → green
    static let redSustainSeconds = 1.0
    static let selfPreservationTa = 5.0  // unresolved red inside this → pilot bails
    static let lineUpWaitNeed = 22.0     // legacy constant (B9: superseded by timeUntilAirborne)
    /// B9 — player reaction allowance folded into a LUAW occupant's clear time.
    static let lineUpReaction = 5.0
    static let rolloutBuffer = 3.0
    static let liftoffBuffer = 2.0
    /// B6/B8 — the −600 only lands after this much continuous non-green warning
    /// on the pair; anything faster resolves as an ordinary pilot go-around.
    static let selfPresWarning = 15.0
    /// B8 — a commit command this close to amber onset marks the episode
    /// player-manufactured (pays nothing, counts as no opportunity).
    static let manufactureWindow = 3.0
}

struct PairKey: Hashable {
    let a: Int, b: Int
    init(_ x: AircraftID, _ y: AircraftID) {
        a = min(x.raw, y.raw); b = max(x.raw, y.raw)
    }
}

/// Per-pair episode memory. An episode spans one continuous amber/red contact.
struct PairState {
    var band: ConflictBand = .green
    var redSince: Double? = nil
    /// Start of the current continuous amber/red contact (nil while green).
    var amberSince: Double? = nil
    var sustained = false
    var opportunityCounted = false
    /// B8 — episode was created by a player commit command; pays nothing.
    var playerManufactured = false
    var lastMargin: Double = 0
}

struct ConflictProjection {
    let arrival: AircraftID
    let occupant: AircraftID
    let margin: Double        // seconds; the Gap Arc value
    let timeToThreshold: Double
    let band: ConflictBand
    /// B8 — set when this pair would be non-green within seconds of a player
    /// commit command (the episode is player-made, not authored pressure).
    var manufactured: Bool = false
}

struct ConflictTracker {
    var pairs: [PairKey: PairState] = [:]

    static func band(forMargin m: Double) -> ConflictBand {
        if m < 0 { return .red }
        if m < ConflictConstants.amberThreshold { return .amber }
        return .green
    }

    /// Update episode memory for the projections found this tick.
    /// Returns pairs that just crossed into "sustained red" this tick, and
    /// whether each projection is a fresh save opportunity.
    mutating func integrate(projections: [ConflictProjection], now: Double)
        -> (sustainedNow: [PairKey], newOpportunities: Int) {
        var seen = Set<PairKey>()
        var sustainedNow: [PairKey] = []
        var newOpportunities = 0

        for p in projections {
            let key = PairKey(p.arrival, p.occupant)
            seen.insert(key)
            var st = pairs[key] ?? PairState()
            st.band = p.band
            st.lastMargin = p.margin
            if p.band < .amber {
                st.redSince = nil
                st.amberSince = nil
            } else {
                if st.amberSince == nil {
                    st.amberSince = now
                    st.playerManufactured = p.manufactured   // B8: decided at onset
                }
                if !st.opportunityCounted {
                    st.opportunityCounted = true
                    if !st.playerManufactured { newOpportunities += 1 }
                }
            }
            if p.band == .red {
                if st.redSince == nil { st.redSince = now }
                if let since = st.redSince, !st.sustained,
                   now - since >= ConflictConstants.redSustainSeconds {
                    st.sustained = true
                    sustainedNow.append(key)
                }
            } else {
                st.redSince = nil
            }
            pairs[key] = st
        }
        // Contact broken → episode over; forget so a later re-approach is fresh.
        for key in pairs.keys where !seen.contains(key) {
            pairs.removeValue(forKey: key)
        }
        return (sustainedNow, newOpportunities)
    }

    func state(_ x: AircraftID, _ y: AircraftID) -> PairState? {
        pairs[PairKey(x, y)]
    }

    /// Worst live episode involving this aircraft (for SAVE adjudication).
    func worstEpisode(involving id: AircraftID) -> PairState? {
        var worst: PairState? = nil
        for (key, st) in pairs.sorted(by: { $0.key.a == $1.key.a ? $0.key.b < $1.key.b
                                                                 : $0.key.a < $1.key.a }) {
            guard key.a == id.raw || key.b == id.raw, st.band >= .amber else { continue }
            if worst == nil || st.band > worst!.band
                || (st.sustained && !(worst!.sustained)) {
                worst = st
            }
        }
        return worst
    }

    /// Drop all episodes involving an aircraft (after a resolving action).
    mutating func clear(involving id: AircraftID) {
        for key in pairs.keys where key.a == id.raw || key.b == id.raw {
            pairs.removeValue(forKey: key)
        }
    }
}
