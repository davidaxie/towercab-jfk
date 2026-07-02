import Foundation
import simd

// =============================================================================
// KAVX — Catalina "Airport in the Sky" (PRD §4.1, airport #1)
//
// A 3,000 ft runway on a mesa 1,602 ft above the Pacific, cliffs off both
// thresholds, a midfield hump that hides the far end from the cab. Real-world
// Catalina is non-towered; per the PRD we install a fictional cab and say so.
//
// Stylized single source of truth for BOTH sim and 3D scene, so art and sim
// can never disagree about geometry (PRD §9). World convention: see SimTypes.
// Runway 4/22. Active in the slice: RUNWAY 22 (land/depart toward the SW).
// Approach comes in over the channel from the NE; departures climb out over
// the SW cliffs. Tower + apron sit on the SE side, midfield.
// =============================================================================

public struct Taxiway {
    public let id: String
    public let name: String            // spoken name, e.g. "Alpha"
    public let points: [V2]            // centerline polyline
    public let width: Double
    public init(id: String, name: String, points: [V2], width: Double) {
        self.id = id; self.name = name; self.points = points; self.width = width
    }
}

public struct RunwayExit {
    /// Rollout distance from the runway 22 threshold (NE end) to the turnoff.
    public let stationFrom22: Double
    public let taxiwayID: String
    /// The exit an expedite call targets.
    public let isPreferred: Bool
    public init(stationFrom22: Double, taxiwayID: String, isPreferred: Bool) {
        self.stationFrom22 = stationFrom22; self.taxiwayID = taxiwayID; self.isPreferred = isPreferred
    }
}

public struct ApronSpot {
    public let position: V2
    public let heading: Double         // parked heading, radians
    public init(position: V2, heading: Double) {
        self.position = position; self.heading = heading
    }
}

public struct Runway {
    public let nameA = "04"
    public let nameB = "22"
    /// SW end — runway 4 threshold / runway 22 rollout end.
    public let thresholdA: V2
    /// NE end — runway 22 threshold. Arrivals cross this.
    public let thresholdB: V2
    public let width: Double
    public var length: Double { simd_length(thresholdA - thresholdB) }
    /// Heading flown when using runway 22 (B → A, toward the SW).
    public var heading22: Double { directionHeading(simd_normalize(thresholdA - thresholdB)) }
    public var heading04: Double { directionHeading(simd_normalize(thresholdB - thresholdA)) }
    /// Unit vector along the 22 landing direction.
    public var dir22: V2 { simd_normalize(thresholdA - thresholdB) }
    /// Point at a rollout station measured from the 22 threshold.
    public func point(atStationFrom22 s: Double) -> V2 { thresholdB + dir22 * s }

    public init(thresholdA: V2, thresholdB: V2, width: Double) {
        self.thresholdA = thresholdA; self.thresholdB = thresholdB; self.width = width
    }
}

public struct AirportLayout {
    public let icao: String
    public let displayName: String
    public let runway: Runway
    public let taxiways: [Taxiway]
    public let exits: [RunwayExit]
    public let apronSpots: [ApronSpot]

    // --- Ground routes (polylines the sim follows verbatim; no pathfinding in slice) ---
    /// Apron → parallel taxiway → hold-short of runway 22 (NE end).
    public let routeTaxiOut: [V2]
    /// Midfield exit turnoff → apron.
    public let routeExitMidfield: [V2]
    /// SW-end exit turnoff → apron (long taxi back).
    public let routeExitEnd: [V2]
    /// Hold-short point → runway 22 centerline, aligned for departure.
    public let routeLineUp: [V2]
    /// Where departures wait (on routeTaxiOut, short of the runway edge).
    public let holdShortPoint: V2

    // --- Pattern & approach geometry (runway 22, right traffic over the water NW) ---
    public let patternAltitude: Double        // AGL meters
    public let downwindOffset: Double         // lateral offset NW of centerline
    public let finalSpawnDistance: Double     // straight-in spawn along extended centerline
    public let finalGlideSlopeDeg: Double
    /// Downwind entry point (start of the leg, abeam the departure end) and exit
    /// (base turn) stations, measured along the runway axis from threshold 22,
    /// negative = beyond the threshold upwind.
    public let downwindEntryStation: Double
    public let baseTurnStation: Double

    // --- The place itself ---
    /// The Pacific sits this far below the runway (1,602 ft mesa).
    public let mesaDropMeters: Double
    /// Rough mesa-top footprint (closed polygon) for terrain building.
    public let mesaOutline: [V2]
    /// Midfield hump amplitude — the PRD's "blind far end" mechanic, presentation-real.
    public let humpAmplitude: Double
    /// Tower cab camera eye, world coords (fictional cab, SE midfield).
    public let towerCabEye: V3
    public let windsockPosition: V2

    /// Mesa-top ground height (the midfield hump). Both the sim's ground
    /// vehicles/aircraft and the world mesh sample this — never disagree.
    public func groundHeight(at p: V2) -> Double {
        let toPoint = p - runway.thresholdB
        let s = simd_dot(toPoint, runway.dir22)
        let t = max(0, min(1, s / runway.length))
        return humpAmplitude * sin(.pi * t)
    }

    // MARK: - KAVX

    public static let kavx: AirportLayout = {
        // Runway 4/22 — 990 m (3,250 ft) × 18 m, midpoint at origin, true heading 222°.
        let h22 = degToRad(222)
        let dir = headingDirection(h22)                    // toward the SW
        let half = 495.0
        let thresholdB = V2(0, 0) - dir * half             // NE end (RWY 22 threshold)
        let thresholdA = V2(0, 0) + dir * half             // SW end
        let runway = Runway(thresholdA: thresholdA, thresholdB: thresholdB, width: 18)

        // Perpendicular unit vectors.
        let perpSE = V2(-dir.y, dir.x)                     // right of the 22 roll — tower side
        let perpNW = -perpSE                               // over-the-water side (pattern)

        // Parallel taxiway Alpha, 55 m SE of centerline, full length + stubs.
        let alphaOffset = 55.0
        let alphaB = thresholdB + perpSE * alphaOffset     // NE end of Alpha
        let alphaA = thresholdA + perpSE * alphaOffset     // SW end of Alpha
        let taxiwayAlpha = Taxiway(id: "A", name: "Alpha", points: [alphaB, alphaA], width: 10)

        // Stubs: A1 at NE end (departure entry), A2 midfield exit, A3 SW-end exit.
        let a2Station = 560.0                              // comfortable Lark rollout
        let a3Station = 940.0
        let a1 = Taxiway(id: "A1", name: "Alpha One",
                         points: [thresholdB + dir * 10, alphaB + dir * 10], width: 10)
        let a2 = Taxiway(id: "A2", name: "Alpha Two",
                         points: [runway.point(atStationFrom22: a2Station),
                                  runway.point(atStationFrom22: a2Station) + perpSE * alphaOffset],
                         width: 10)
        let a3 = Taxiway(id: "A3", name: "Alpha Three",
                         points: [runway.point(atStationFrom22: a3Station),
                                  runway.point(atStationFrom22: a3Station) + perpSE * alphaOffset],
                         width: 10)

        let exits = [
            RunwayExit(stationFrom22: a2Station, taxiwayID: "A2", isPreferred: true),
            RunwayExit(stationFrom22: a3Station, taxiwayID: "A3", isPreferred: false),
        ]

        // Apron SE of Alpha, midfield: two tiedown rows + a VIP pad.
        let apronCenter = V2(0, 0) + perpSE * 110
        var spots: [ApronSpot] = []
        for i in 0..<5 {
            let along = Double(i - 2) * 22.0
            spots.append(ApronSpot(position: apronCenter + dir * along + perpSE * 14,
                                   heading: h22 + .pi / 2))
        }
        for i in 0..<3 {
            let along = Double(i - 1) * 26.0
            spots.append(ApronSpot(position: apronCenter + dir * along + perpSE * 44,
                                   heading: h22 - .pi / 2))
        }

        // Ground routes.
        let apronExitPoint = apronCenter + perpNW * 30     // where apron meets Alpha side
        let holdShort = alphaB + dir * 10 - (alphaB - thresholdB) * (28.0 / alphaOffset)
        // (28 m from the runway edge along stub A1)
        let routeTaxiOut: [V2] = [apronExitPoint,
                                  apronExitPoint + perpNW * 25,   // join Alpha
                                  alphaB + dir * 10,               // NE along Alpha
                                  holdShort]
        let a2Runway = runway.point(atStationFrom22: a2Station)
        let a2Alpha = a2Runway + perpSE * alphaOffset
        let routeExitMidfield: [V2] = [a2Runway, a2Alpha, apronExitPoint + perpNW * 25, apronExitPoint]
        let a3Runway = runway.point(atStationFrom22: a3Station)
        let a3Alpha = a3Runway + perpSE * alphaOffset
        let routeExitEnd: [V2] = [a3Runway, a3Alpha, apronExitPoint + perpNW * 25, apronExitPoint]
        let routeLineUp: [V2] = [holdShort, thresholdB + dir * 30]

        // Mesa footprint — asymmetric rounded blob hugging runway + apron,
        // cliffs everywhere beyond it. (World agent may refine artistically;
        // the sim only uses groundHeight.)
        var outline: [V2] = []
        let n = 24
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            let alongR = 780.0 + 90 * sin(a * 3 + 0.7)
            let crossR = 300.0 + 60 * cos(a * 2 + 1.9)
            let p = dir * (cos(a) * alongR) + perpSE * (sin(a) * crossR + 60)
            outline.append(p)
        }

        // Fictional cab: SE midfield at the apron's edge, eye ~15 m over the ramp.
        let cabGround = V2(0, 0) + perpSE * 78 - dir * 55
        let cabEye = V3(cabGround.x, 15.5, cabGround.y)

        return AirportLayout(
            icao: "KAVX",
            displayName: "Catalina — Airport in the Sky",
            runway: runway,
            taxiways: [taxiwayAlpha, a1, a2, a3],
            exits: exits,
            apronSpots: spots,
            routeTaxiOut: routeTaxiOut,
            routeExitMidfield: routeExitMidfield,
            routeExitEnd: routeExitEnd,
            routeLineUp: routeLineUp,
            holdShortPoint: holdShort,
            patternAltitude: 320,
            downwindOffset: 1250,
            finalSpawnDistance: 5200,
            finalGlideSlopeDeg: 3.3,
            downwindEntryStation: 1400,
            baseTurnStation: -900,
            mesaDropMeters: 488,
            mesaOutline: outline,
            humpAmplitude: 3.0,
            towerCabEye: cabEye,
            windsockPosition: V2(0, 0) + perpSE * 40 - dir * 180
        )
    }()

    public init(icao: String, displayName: String, runway: Runway, taxiways: [Taxiway],
                exits: [RunwayExit], apronSpots: [ApronSpot],
                routeTaxiOut: [V2], routeExitMidfield: [V2], routeExitEnd: [V2],
                routeLineUp: [V2], holdShortPoint: V2,
                patternAltitude: Double, downwindOffset: Double, finalSpawnDistance: Double,
                finalGlideSlopeDeg: Double, downwindEntryStation: Double, baseTurnStation: Double,
                mesaDropMeters: Double, mesaOutline: [V2], humpAmplitude: Double,
                towerCabEye: V3, windsockPosition: V2) {
        self.icao = icao; self.displayName = displayName; self.runway = runway
        self.taxiways = taxiways; self.exits = exits; self.apronSpots = apronSpots
        self.routeTaxiOut = routeTaxiOut; self.routeExitMidfield = routeExitMidfield
        self.routeExitEnd = routeExitEnd; self.routeLineUp = routeLineUp
        self.holdShortPoint = holdShortPoint
        self.patternAltitude = patternAltitude; self.downwindOffset = downwindOffset
        self.finalSpawnDistance = finalSpawnDistance; self.finalGlideSlopeDeg = finalGlideSlopeDeg
        self.downwindEntryStation = downwindEntryStation; self.baseTurnStation = baseTurnStation
        self.mesaDropMeters = mesaDropMeters; self.mesaOutline = mesaOutline
        self.humpAmplitude = humpAmplitude
        self.towerCabEye = towerCabEye; self.windsockPosition = windsockPosition
    }
}
