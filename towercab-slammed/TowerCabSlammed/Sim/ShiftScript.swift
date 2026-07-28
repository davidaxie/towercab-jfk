import Foundation

// =============================================================================
// ShiftScript — the authored traffic curve for one shift (PRD §2.7).
// Fully precomputed from the seed at init so a shift replays identically.
// =============================================================================

struct SpawnOrder {
    let time: Double
    let isArrival: Bool
    let straightIn: Bool         // arrivals only: straight-in vs pattern entry
    let kind: AircraftKind
    let livery: Livery
    let callsign: Callsign
    /// Touchdown point past the 22 threshold, pre-rolled for determinism.
    let touchdownStation: Double
}

struct ShiftScript {
    var duration: Double = 360
    var orders: [SpawnOrder] = []
    /// Authored movement count — the Flow axis par.
    var parMovements: Int = 0
    /// Score par used for grading (base points × a modest expected multiplier).
    var parScore: Int = 0

    // Spawn spacing curve: generous at open, ~12 s at peak,
    // crescendo holds t≈200–280, taper to the last spawn at duration−60.
    static let crescendoStart = 200.0
    static let crescendoEnd = 280.0
    static let lastSpawnTime = 300.0

    static func baseInterval(at t: Double) -> Double {
        if t < crescendoStart {
            let f = t / crescendoStart
            return 45 - (45 - 12) * f
        } else if t < crescendoEnd {
            return 12
        } else {
            let f = min(1, (t - crescendoEnd) / (lastSpawnTime - crescendoEnd))
            return 12 + (28 - 12) * f
        }
    }

    /// Where this arrival puts its wheels down, in metres past the landing
    /// threshold. An ABSOLUTE band per size class — never a fraction of runway
    /// length.
    ///
    /// This was `runway.length × 0.275…0.348`, which read as a correct ~250 m
    /// on KAVX's 914 m runway and became **1,216–1,539 m** on KJFK's 4,423 m
    /// Bay Runway. The flare still began on schedule at the threshold, so
    /// `updateFlare` stretched the descent across the remainder and airliners
    /// floated 1,490 m / 21.4 s a metre off the concrete — in the game's
    /// most-watched moment (AUDIT-KJFK.md §C1). It also pushed the rollout
    /// past the near turnoff, which is what made the preferred exit and the
    /// SLICK EXIT badge unreachable (§C3).
    ///
    /// Real airliners aim the touchdown zone ~300 m (1,000 ft) in, bigger metal
    /// a little deeper. Clamped so a genuinely short runway can never be
    /// authored an off-the-far-end touchdown.
    static func touchdownStation(kind: AircraftKind, airport: AirportLayout,
                                 rng: inout SeededRNG) -> Double {
        let band: ClosedRange<Double>
        switch kind.spec.sizeClass {
        case .light, .cabinTwin:            band = 120...200
        case .turboprop, .heritage:         band = 150...240
        case .bizjet:                       band = 200...300
        case .regional:                     band = 250...350
        case .narrowbody:                   band = 300...400
        case .widebody:                     band = 350...450
        }
        let aim = rng.double(in: band)
        // Never author a touchdown deeper than a third of the runway.
        return min(aim, airport.runway.length / 3)
    }

    /// Coarse spawn-to-threshold estimate used by the authoring guard (B1).
    /// Mirrors the sim's speed-bleed shape without simulating it.
    static func estArrivalDuration(kind: AircraftKind, straightIn: Bool,
                                   airport: AirportLayout) -> Double {
        let vPat = kind.patternSpeed
        let vRef = kind.approachSpeed
        let vBleed = (vPat + vRef) / 2
        if straightIn {
            let d = airport.finalSpawnDistance
            let bleed = min(d, 2000.0)
            return (d - bleed) / vPat + bleed / vBleed
        }
        let downwind = airport.downwindEntryStation - airport.baseTurnStation
        let baseLeg = airport.downwindOffset
        let final = max(0, -airport.baseTurnStation)
        return (downwind + baseLeg) / vPat + final / vBleed
    }

    static func standardShift(seed: UInt64, airport: AirportLayout = .kjfk) -> ShiftScript {
        var rng = SeededRNG(seed: seed ^ 0x5C21F7_5C21F7)
        var script = ShiftScript()
        // A big single-runway airliner field (KJFK: 4.4 km runway, 13 km finals,
        // long taxi) clears its traffic more slowly than the tiny KAVX mesa, so
        // the shift runs a little longer to let the departure queue drain. Keyed
        // off the accepted fleet so it needs no extra stored field.
        script.duration = airport.acceptedClasses.contains(.light) ? 360 : 420
        var t = rng.double(in: 4...8)
        var usedIsla = Set<Int>()
        var usedTail = Set<String>()
        var arrivalsMinusDepartures = 0
        var lastArrivalSpawn = -1000.0
        var lastArrivalLanding = -1000.0
        var lastArrivalKind: AircraftKind? = nil

        while t < lastSpawnTime {
            // Mix ≈ 55/45, nudged so a run never goes all-one-direction.
            var pArrival = 0.55
            if arrivalsMinusDepartures >= 3 { pArrival = 0.30 }
            if arrivalsMinusDepartures <= -3 { pArrival = 0.75 }
            var isArrival = rng.chance(pArrival)
            arrivalsMinusDepartures += isArrival ? 1 : -1

            // Rarity-weighted pick over the types this airport accepts (KAVX =
            // GA + turboprops + the DC-3, no jets). Deterministic on the RNG.
            let kind = AircraftKind.weightedKind(spawnableAt: airport, rng: &rng)
            // Airliner fields fly mostly straight-in ILS; the GA mesa a livelier mix.
            let straightIn = rng.chance(airport.straightInFraction)

            // B1/B13 — authoring guard. Consecutive arrivals keep ≥26 s spawn
            // spacing (≥45 s when the follower type is faster — a Vela may
            // never be authored to run down a Lark), and projected threshold
            // crossings stay a landable ≥30 s apart. Violators flip to
            // departures so the 12 s crescendo cadence survives as mixed flow.
            if isArrival {
                let fasterBehindSlower = lastArrivalKind.map {
                    kind.approachSpeed > $0.approachSpeed + 0.1
                } ?? false
                // Big-jet airliner fields need wider arrival spacing than the GA
                // mesa: a long runway occupies longer per landing and the long
                // final leaves little room to recover a squeeze, so keep landings
                // comfortably apart to avoid manufactured back-to-back reds.
                let airliner = !airport.acceptedClasses.contains(.light)
                let minGap = fasterBehindSlower ? 45.0 : (airliner ? 34.0 : 26.0)
                let minLandingGap = airliner ? 55.0 : 30.0
                let landing = t + Self.estArrivalDuration(kind: kind, straightIn: straightIn,
                                                          airport: airport)
                if t - lastArrivalSpawn < minGap || landing - lastArrivalLanding < minLandingGap {
                    isArrival = false
                    arrivalsMinusDepartures -= 2      // undo +1, apply −1
                } else {
                    lastArrivalSpawn = t
                    lastArrivalLanding = landing
                    lastArrivalKind = kind
                }
            }

            let (callsign, livery) = Self.makeIdentity(kind: kind, rng: &rng,
                                                       usedIsla: &usedIsla, usedTail: &usedTail)
            script.orders.append(SpawnOrder(
                time: t,
                isArrival: isArrival,
                straightIn: straightIn,
                kind: kind,
                livery: livery,
                callsign: callsign,
                touchdownStation: Self.touchdownStation(kind: kind, airport: airport,
                                                        rng: &rng)))

            t += Self.baseInterval(at: t) * rng.double(in: 0.85...1.18)
        }

        script.parMovements = script.orders.count
        var par = 0.0
        for o in script.orders {
            par += (o.isArrival ? 250.0 : 200.0) * o.kind.movementWeight
        }
        // Par ≈ a solid shift at a modest average multiplier. Grade thresholds
        // (S ≥ 1.35×par … D) key off this; a methodical-but-slow controller
        // grades C, streak-and-badge play reaches A/S.
        script.parScore = Int(par * 1.6)
        return script
    }

    // MARK: Identity

    private static let phonetic: [Character: String] = [
        "A": "Alpha", "B": "Bravo", "C": "Charlie", "D": "Delta", "E": "Echo",
        "F": "Foxtrot", "G": "Golf", "H": "Hotel", "J": "Juliett", "K": "Kilo",
        "L": "Lima", "M": "Mike", "N": "November", "P": "Papa", "Q": "Quebec",
        "R": "Romeo", "S": "Sierra", "T": "Tango", "U": "Uniform", "V": "Victor",
        "W": "Whiskey", "X": "X-ray", "Y": "Yankee", "Z": "Zulu",
    ]
    private static let digitWords = ["Zero", "One", "Two", "Three", "Four",
                                     "Five", "Six", "Seven", "Eight", "Niner"]

    static func spokenDigits(_ s: String) -> String {
        s.compactMap { c -> String? in
            if let d = c.wholeNumberValue { return digitWords[d] }
            return phonetic[c]
        }.joined(separator: "-")
    }

    /// Short spoken type prefix for GA / bizjet N-number callsigns, e.g. a C172
    /// checks in as "Skyhawk 734RT". Real type names, no airline.
    private static func spokenTypePrefix(_ kind: AircraftKind) -> String {
        switch kind {
        case .c172:          return "Skyhawk"
        case .pa28:          return "Archer"
        case .c182:          return "Skylane"
        case .sr22:          return "Cirrus"
        case .baron58:       return "Baron"
        case .caravan:       return "Caravan"
        case .kingair350:    return "King Air"
        case .twinotter:     return "Twin Otter"
        case .dc3:           return "Douglas"
        case .phenom300:     return "Phenom"
        case .challenger350: return "Challenger"
        // Airliners never use the type prefix (they get airline callsigns), but
        // provide a sane fallback for completeness.
        case .e175, .e190:   return "Embraer"
        case .atr72:         return "ATR"
        case .dash8:         return "Dash Eight"
        case .crj900:        return "Regional Jet"
        case .a319, .a321, .a330, .a350:
                             return "Airbus"
        case .b757, .b767, .b787, .b747:
                             return "Boeing"
        case .md80:          return "Mad Dog"
        case .dc10:          return "Douglas"
        case .boeing737, .airbus320, .boeing777, .airbus380: return "Heavy"
        }
    }

    /// Fictional carrier: display prefix (strip), spoken airline word, callsign
    /// telephony, and the livery to paint. FICTIONAL only — no real airlines.
    private struct Carrier {
        let displayPrefix: String   // e.g. "PCA"
        let spoken: String          // e.g. "Pacifica"
        let livery: Livery
    }
    private static let mainlineCarriers: [Carrier] = [
        Carrier(displayPrefix: "PCA", spoken: "Pacifica", livery: .pacifica),
        Carrier(displayPrefix: "MER", spoken: "Meridian", livery: .meridianAir),
    ]
    private static let regionalCarriers: [Carrier] = [
        Carrier(displayPrefix: "ALT", spoken: "Altair", livery: .altairExpress),
    ]

    private static func makeIdentity(kind: AircraftKind, rng: inout SeededRNG,
                                     usedIsla: inout Set<Int>,
                                     usedTail: inout Set<String>) -> (Callsign, Livery) {
        let sizeClass = kind.spec.sizeClass

        // --- Airliners (regional / narrowbody / widebody): airline flight-number
        //     callsigns using fictional carriers + their liveries. ------------
        if sizeClass >= .regional {
            let pool = sizeClass == .regional ? regionalCarriers : mainlineCarriers
            // Deterministic carrier pick off the RNG.
            let carrier = pool[Int(rng.double(in: 0...Double(pool.count) - 0.01))]
            // Bounded unique flight number (100…999). Tail set doubles as the
            // uniqueness ledger keyed on "<PREFIX><flight>".
            var flight = 0
            var key = ""
            var attempts = 0
            repeat {
                flight = 100 + Int(rng.double(in: 0...899.99))
                key = "\(carrier.displayPrefix)\(flight)"
                attempts += 1
            } while usedTail.contains(key) && attempts < 40
            if usedTail.contains(key) {
                var serial = 100
                repeat { flight = serial; key = "\(carrier.displayPrefix)\(flight)"; serial += 1 }
                    while usedTail.contains(key)
            }
            usedTail.insert(key)
            return (Callsign(display: "\(carrier.displayPrefix) \(flight)",
                             spoken: "\(carrier.spoken) \(spokenDigits(String(flight)))"),
                    carrier.livery)
        }

        // --- Bizjets (light/super-mid): N-number tail, spoken with the type
        //     prefix, in the navy-and-gold VIP scheme. --------------------------
        if sizeClass == .bizjet {
            // NxxLL biz tail; "Challenger 6JC", etc. Bounded search + serial fb.
            let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
            var tail = ""
            var attempts = 0
            repeat {
                let d1 = Int(rng.double(in: 0...9.99))
                let d2 = Int(rng.double(in: 0...9.99))
                let l1 = letters[letters.index(letters.startIndex, offsetBy: Int(rng.double(in: 0...23.99)))]
                let l2 = letters[letters.index(letters.startIndex, offsetBy: Int(rng.double(in: 0...23.99)))]
                tail = "N\(d1)\(d2)\(l1)\(l2)"
                attempts += 1
            } while usedTail.contains(tail) && attempts < 40
            if usedTail.contains(tail) {
                var serial = 10
                repeat { tail = "N\(serial)JX"; serial += 1 } while usedTail.contains(tail)
            }
            usedTail.insert(tail)
            let body = String(tail.dropFirst())
            return (Callsign(display: tail,
                             spoken: "\(spokenTypePrefix(kind)) \(spokenDigits(body))"),
                    .meridianVIP)
        }

        // --- GA / turboprop / heritage: optional Isla Air commuter flavor for
        //     the smaller types, otherwise a private N-number in the type's own
        //     spoken prefix. -----------------------------------------------------
        // Keep the Isla commuter feel for the light singles/twins only.
        let islaEligible = sizeClass == .light || sizeClass == .cabinTwin
        if islaEligible && rng.chance(0.40) {
            var flight = 0
            repeat { flight = 201 + Int(rng.double(in: 0...48.99)) } while usedIsla.contains(flight)
            usedIsla.insert(flight)
            let tens = flight % 100
            let spokenTail = tens < 10 ? "Oh-\(digitWords[tens])"
                : "\(digitWords[tens / 10])\(tens % 10 == 0 ? "-Zero" : "-" + digitWords[tens % 10])"
            // "Isla Two-Twelve" cadence: leading digit, then the pair.
            let pairWord: String = {
                switch tens {
                case 10: return "Ten"
                case 11: return "Eleven"
                case 12: return "Twelve"
                default: return spokenTail
                }
            }()
            let livery: Livery = rng.chance(0.65) ? .islaTurquoise : .islaClassic
            return (Callsign(display: "ISL \(flight)",
                             spoken: "Isla \(digitWords[flight / 100])-\(pairWord)"),
                    livery)
        }
        // Private N-number: N7d4dLL — "Skyhawk Seven-Three-Four-Romeo-Tango".
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        var tail = ""
        var attempts = 0                                    // B28 — bounded
        repeat {
            let d1 = Int(rng.double(in: 0...9.99))
            let d2 = Int(rng.double(in: 0...9.99))
            let l1 = letters[letters.index(letters.startIndex, offsetBy: Int(rng.double(in: 0...23.99)))]
            let l2 = letters[letters.index(letters.startIndex, offsetBy: Int(rng.double(in: 0...23.99)))]
            tail = "N7\(d1)\(d2)\(l1)\(l2)"
            attempts += 1
        } while usedTail.contains(tail) && attempts < 40
        if usedTail.contains(tail) {
            var serial = 10
            repeat { tail = "N7\(serial)XX"; serial += 1 } while usedTail.contains(tail)
        }
        usedTail.insert(tail)
        let body = String(tail.dropFirst())
        // Private GA paints white or sunburst; turboprops/DC-3 lean neutral white.
        let livery: Livery = rng.chance(0.55) ? .privateWhite : .privateSunburst
        return (Callsign(display: tail,
                         spoken: "\(spokenTypePrefix(kind)) \(spokenDigits(body))"),
                livery)
    }
}
