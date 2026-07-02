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

    static func standardShift(seed: UInt64) -> ShiftScript {
        var rng = SeededRNG(seed: seed ^ 0x5C21F7_5C21F7)
        var script = ShiftScript()
        var t = rng.double(in: 4...8)
        var usedIsla = Set<Int>()
        var usedTail = Set<String>()
        var arrivalsMinusDepartures = 0

        while t < lastSpawnTime {
            // Mix ≈ 55/45, nudged so a run never goes all-one-direction.
            var pArrival = 0.55
            if arrivalsMinusDepartures >= 3 { pArrival = 0.30 }
            if arrivalsMinusDepartures <= -3 { pArrival = 0.75 }
            let isArrival = rng.chance(pArrival)
            arrivalsMinusDepartures += isArrival ? 1 : -1

            let roll = rng.double(in: 0...1)
            let kind: AircraftKind = roll < 0.45 ? .lark72 : (roll < 0.80 ? .vela22 : .comet60)

            let (callsign, livery) = Self.makeIdentity(kind: kind, rng: &rng,
                                                       usedIsla: &usedIsla, usedTail: &usedTail)
            script.orders.append(SpawnOrder(
                time: t,
                isArrival: isArrival,
                straightIn: rng.chance(0.5),
                kind: kind,
                livery: livery,
                callsign: callsign,
                touchdownStation: rng.double(in: 252...318)))

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

    private static func makeIdentity(kind: AircraftKind, rng: inout SeededRNG,
                                     usedIsla: inout Set<Int>,
                                     usedTail: inout Set<String>) -> (Callsign, Livery) {
        if kind == .comet60 {
            // VIP bizjet: N6xCM, "Comet Six-One-Charlie-Mike".
            var tail = ""
            repeat {
                tail = "N6\(Int(rng.double(in: 0...9.99)))CM"
            } while usedTail.contains(tail)
            usedTail.insert(tail)
            let digits = String(tail.dropFirst().dropLast(2))
            return (Callsign(display: tail,
                             spoken: "Comet \(spokenDigits(digits))-Charlie-Mike"),
                    .meridianVIP)
        }
        // lark72 / vela22: Isla Air commuter or private GA.
        if rng.chance(0.45) {
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
        // GA N-number: N7d4dLL — "Lark Seven-Three-Four-Romeo-Tango".
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        var tail = ""
        repeat {
            let d1 = Int(rng.double(in: 0...9.99))
            let d2 = Int(rng.double(in: 0...9.99))
            let l1 = letters[letters.index(letters.startIndex, offsetBy: Int(rng.double(in: 0...23.99)))]
            let l2 = letters[letters.index(letters.startIndex, offsetBy: Int(rng.double(in: 0...23.99)))]
            tail = "N7\(d1)\(d2)\(l1)\(l2)"
        } while usedTail.contains(tail)
        usedTail.insert(tail)
        let body = String(tail.dropFirst())
        let name = kind == .lark72 ? "Lark" : "Vela"
        let livery: Livery = rng.chance(0.55) ? .privateWhite : .privateSunburst
        return (Callsign(display: tail, spoken: "\(name) \(spokenDigits(body))"), livery)
    }
}
