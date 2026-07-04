import Foundation
import simd

// =============================================================================
// KAVX — Catalina "Airport in the Sky" (PRD §4.1, airport #1)
//
// Researched layout (AUDIT.md §A, FAA/Conservancy-sourced):
//   A1  Runway 4/22 true heading 055/235.
//   A2  914.4 × 22.9 m (3,000 × 75 ft), concrete.
//   A4  The signature gradient: crest 213 m from the 4 (SW) threshold; the SW
//       threshold sits ~1.5 m below the crest, the NE (22) threshold ~14.7 m
//       below — a ~2.1% upslope landing 22. y = 0 is the CREST datum; the
//       Pacific stays at y = -mesaDropMeters.
//   A7  Ramp/tower on the TRUE southeast side; pattern is flown NW over the
//       water. GAME CALL (noted creative liberty, like the tower itself): the
//       real parallel taxiway is partial (midfield ramp → SW end only), which
//       would force back-taxi departures; we keep it full-length to the NE
//       hold-short so departures flow. The midfield ramp stub is real.
//   A8  SE midfield ramp fronting the terminal, with a dirt tiedown infield
//       between the ramp pavement and the taxiway (the authentic Catalina
//       look). No fuel island — just disused DC-3 fuel pits in the pavement.
//   A11 Mesa built by leveling two hilltops and filling the canyon between:
//       groundHeight carries two gentle knolls near the runway ends, offset
//       from the centerline; cliffs drop off both runway ends.
//
// Real-world Catalina is non-towered; per the PRD we install a fictional
// standalone cab (SE, behind the parallel near the terminal cluster) and say so.
//
// Stylized single source of truth for BOTH sim and 3D scene, so art and sim
// can never disagree about geometry (PRD §9). World convention: see SimTypes.
// Runway 4/22. Active in the slice: RUNWAY 22 (land/depart toward the SW).
// Approach comes in over the channel from the NE; departures climb out over
// the SW cliffs.
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
    /// Painted number at the A end (rollout end of the active direction). KAVX
    /// "04"; KJFK "13R". Display-only — the geometric API below stays neutral.
    public let nameA: String
    /// Painted number at the B end (the arrival/landing threshold). KAVX "22";
    /// KJFK "31L".
    public let nameB: String
    /// SW end — runway 4 threshold / runway 22 rollout end.
    public let thresholdA: V2
    /// NE end — runway 22 threshold. Arrivals cross this.
    public let thresholdB: V2
    public let width: Double
    public var length: Double { simd_length(thresholdA - thresholdB) }
    /// Heading flown when landing (B → A). Named `heading22` for API stability
    /// (the KAVX active); at KJFK this is the 31L landing heading (~301° true).
    public var heading22: Double { directionHeading(simd_normalize(thresholdA - thresholdB)) }
    /// Reciprocal (A → B) heading. KAVX runway 04; KJFK runway 13R.
    public var heading04: Double { directionHeading(simd_normalize(thresholdB - thresholdA)) }
    /// Unit vector along the landing (B → A) direction.
    public var dir22: V2 { simd_normalize(thresholdA - thresholdB) }
    /// Point at a rollout station measured from the arrival (B) threshold.
    public func point(atStationFrom22 s: Double) -> V2 { thresholdB + dir22 * s }

    public init(thresholdA: V2, thresholdB: V2, width: Double,
                nameA: String = "04", nameB: String = "22") {
        self.thresholdA = thresholdA; self.thresholdB = thresholdB; self.width = width
        self.nameA = nameA; self.nameB = nameB
    }
}

public struct AirportLayout {
    public let icao: String
    public let displayName: String
    public let runway: Runway
    public let taxiways: [Taxiway]
    public let exits: [RunwayExit]
    public let apronSpots: [ApronSpot]

    /// Capability gate: which SizeClasses may spawn here. The rarity-weighted
    /// spawn picker filters the fleet to these. KAVX (short mesa runway, no
    /// jet ops) accepts light / cabinTwin / turboprop / heritage — NO jets.
    public let acceptedClasses: Set<SizeClass>

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
    /// When true the field is dead flat: groundHeight returns 0 everywhere and
    /// the KAVX mesa profile/knolls are bypassed (KJFK, ~13 ft, dead flat).
    public let flat: Bool
    /// The sea/water sits this far below the field. KAVX: the Pacific 488.3 m
    /// below the 1,602 ft mesa crest. KJFK: Jamaica Bay ~4 m below the field.
    public let mesaDropMeters: Double
    /// Rough mesa-top footprint (closed polygon) for terrain building.
    public let mesaOutline: [V2]
    /// Max crest-to-threshold relief of the real gradient (A4). Kept for API
    /// stability; the actual profile lives in groundHeight.
    public let humpAmplitude: Double
    /// Tower cab camera eye, world coords (fictional cab, SE midfield).
    public let towerCabEye: V3
    public let windsockPosition: V2

    // A4 — the real KAVX longitudinal profile, crest = y 0 (datum).
    // Asymmetric piecewise grade with parabolic crest blends (C1-smooth):
    //   NE (22) side: ~2.2% grade, threshold B at -14.7 m
    //   SW (4) side:  ~0.87% grade, threshold A at -1.5 m
    static let crestStationFrom22 = 914.4 - 213.0          // 701.4 m from B
    static let crestBlendHalf = 80.0                       // rounded crest span
    static let gradeNE = 14.7 / (crestStationFrom22 - crestBlendHalf / 2)
    static let gradeSW = 1.5 / (213.0 - crestBlendHalf / 2)

    static func runwayProfile(atStation s: Double) -> Double {
        let x = crestStationFrom22 - s          // >0 on the NE side of the crest
        let b = crestBlendHalf
        if x >= 0 {
            if x <= b { return -(gradeNE / (2 * b)) * x * x }
            return -(gradeNE * b / 2 + gradeNE * (x - b))
        } else {
            let xa = -x
            if xa <= b { return -(gradeSW / (2 * b)) * xa * xa }
            return -(gradeSW * b / 2 + gradeSW * (xa - b))
        }
    }

    // A11 — the two filled knolls (station-from-22, lateral-SE, height, radius).
    // Offset from the centerline, clear of all pavement and taxi routes.
    static let knolls: [(s: Double, p: Double, h: Double, r: Double)] = [
        (130.0, -160.0, 10.0, 110.0),      // NE-end knoll, pattern (NW) side
        (800.0, 195.0, 9.0, 110.0),        // SW-end knoll, tower (SE) side
    ]

    /// Tower callout name for radio phraseology (e.g. "Catalina", "Kennedy").
    public var towerName: String {
        switch icao {
        case "KAVX": return "Catalina"
        case "KJFK": return "Kennedy"
        default:     return displayName.split(separator: " ").last.map(String.init) ?? icao
        }
    }

    /// Fraction of arrivals authored as straight-in ILS finals (vs pattern/
    /// downwind entries). Big-jet airliner fields fly almost entirely straight-in
    /// ILS (KJFK); the GA mesa flies a lively mix (KAVX). Keyed off the fleet the
    /// field accepts so it needs no extra stored field.
    public var straightInFraction: Double {
        acceptedClasses.contains(.light) ? 0.5 : 0.85
    }

    /// Mesa-top ground height. Both the sim's ground vehicles/aircraft and the
    /// world mesh sample this — never disagree. The runway profile extends
    /// laterally across the graded airfield; the knolls rise off to the sides.
    public func groundHeight(at p: V2) -> Double {
        // Flat fields (KJFK) sit at datum y = 0 everywhere — no mesa profile.
        if flat { return 0.0 }
        let toPoint = p - runway.thresholdB
        let d = runway.dir22
        let s = simd_dot(toPoint, d)
        let lat = simd_dot(toPoint, V2(d.y, -d.x))         // + toward the SE
        let sClamped = max(0, min(runway.length, s))
        var y = AirportLayout.runwayProfile(atStation: sClamped)
        for k in AirportLayout.knolls {
            let ds = s - k.s, dp = lat - k.p
            let dist = (ds * ds + dp * dp).squareRoot()
            if dist < k.r {
                y += k.h * (0.5 + 0.5 * cos(.pi * dist / k.r))
            }
        }
        return y
    }

    // MARK: - KAVX

    public static let kavx: AirportLayout = {
        // A1/A2 — Runway 4/22: 914.4 m × 22.9 m, midpoint at origin,
        // TRUE heading 235 flying runway 22 (mag 221, var 12E).
        let h22 = degToRad(235)
        let dir = headingDirection(h22)                    // toward the SW
        let half = 914.4 / 2
        let thresholdB = V2(0, 0) - dir * half             // NE end (RWY 22 threshold)
        let thresholdA = V2(0, 0) + dir * half             // SW end
        let runway = Runway(thresholdA: thresholdA, thresholdB: thresholdB, width: 22.9)

        // Perpendicular unit vectors. A7: TRUE southeast (audit fix — the old
        // build's perp pointed compass-NW, mirroring the field).
        let perpSE = V2(dir.y, -dir.x)                     // right of the 22 roll — tower side
        // (pattern/downwind side = -perpSE, the NW over-the-water side)
        /// Runway-frame helper: s along the 22 roll from threshold B, p toward SE.
        func at(_ s: Double, _ p: Double) -> V2 { thresholdB + dir * s + perpSE * p }

        // Parallel taxiway Alpha, 55 m SE of centerline (see GAME CALL above:
        // full-length vs the real partial parallel), + stubs.
        let alphaOffset = 55.0
        let taxiwayAlpha = Taxiway(id: "A", name: "Alpha",
                                   points: [at(6, alphaOffset), at(886, alphaOffset)], width: 10)

        // Stubs: A1 at the NE end (departure entry), A2 midfield ramp stub
        // (extends SE past Alpha into the ramp — the real perpendicular stub),
        // A3 SW-end exit.
        let a2Station = 550.0                              // comfortable Lark rollout
        let a3Station = 880.0                              // beyond the crest — the long roll
        let a1 = Taxiway(id: "A1", name: "Alpha One",
                         points: [at(10, 0), at(10, alphaOffset)], width: 10)
        let a2 = Taxiway(id: "A2", name: "Alpha Two",
                         points: [at(a2Station, 0), at(a2Station, 98)], width: 10)
        let a3 = Taxiway(id: "A3", name: "Alpha Three",
                         points: [at(a3Station, 0), at(a3Station, alphaOffset)], width: 10)

        let exits = [
            RunwayExit(stationFrom22: a2Station, taxiwayID: "A2", isPreferred: true),
            RunwayExit(stationFrom22: a3Station, taxiwayID: "A3", isPreferred: false),
        ]

        // A8 — parking: two tiedown rows on the dirt infield (p 62…94, between
        // Alpha and the ramp pavement) + three paved transient spots on the
        // ramp. Dirt spots park nose into the prevailing 240 wind; paved spots
        // face the field.
        var spots: [ApronSpot] = []
        for s in [450.0, 470.0, 490.0, 510.0] {            // dirt row 1
            spots.append(ApronSpot(position: at(s, 73), heading: h22))
        }
        for s in [460.0, 480.0, 500.0] {                   // dirt row 2
            spots.append(ApronSpot(position: at(s, 87), heading: h22))
        }
        for s in [455.0, 480.0, 505.0] {                   // paved transient row
            spots.append(ApronSpot(position: at(s, 112), heading: h22 + .pi / 2))
        }

        // Ground routes. Hold-short bar 28.6 m off the centerline on stub A1.
        let apronExitPoint = at(a2Station, 98)             // ramp mouth of the A2 stub
        let holdShort = at(10, 40)
        let routeTaxiOut: [V2] = [apronExitPoint,
                                  at(a2Station, alphaOffset),   // join Alpha
                                  at(10, alphaOffset),           // NE along Alpha
                                  holdShort]
        let routeExitMidfield: [V2] = [at(a2Station, 0), at(a2Station, alphaOffset), apronExitPoint]
        let routeExitEnd: [V2] = [at(a3Station, 0), at(a3Station, alphaOffset),
                                  at(a2Station, alphaOffset), apronExitPoint]
        let routeLineUp: [V2] = [holdShort, thresholdB + dir * 30]

        // A11/D4 — mesa footprint: fBm-jittered outline (96 points, ±10%
        // radial noise), two coves, one promontory near the 22 threshold.
        // Cliffs everywhere beyond it, off both runway ends.
        var outline: [V2] = []
        let n = 96
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            var radial = 1.0 + 0.10 * (0.5 * sin(3 * a + 1.7)
                                       + 0.3 * sin(7 * a + 0.4)
                                       + 0.2 * sin(13 * a + 3.1))
            radial -= 0.22 * exp(-pow(angleDelta(from: a, to: 2.2) / 0.18, 2))   // cove SE
            radial -= 0.18 * exp(-pow(angleDelta(from: a, to: 5.2) / 0.22, 2))   // cove NW
            radial += 0.30 * exp(-pow(angleDelta(from: a, to: 3.49) / 0.16, 2))  // promontory nr 22 thr
            let along = 640.0 * radial
            let cross = 362.0 * radial
            outline.append(dir * (cos(a) * along) + perpSE * (sin(a) * cross + 55))
        }

        // Fictional cab: SE, behind the parallel near the terminal cluster,
        // eye 15.5 m above local ground (knolls are far; profile is exact here).
        //
        // A4 payoff note (verified by the geometry harness): with the TRUE
        // profile (crest +0, thr B −14.7, thr A −1.5) no tower-height eye can
        // be crest-blind to a runway threshold — blocking the 2 m point over
        // thr B needs an eye below ~+0.5 m absolute, and blocking thr A is
        // impossible since +0.5 m over A sits ABOVE the crest. The real KAVX
        // blind-end is pilot-to-pilot: a 2 m eye at A cannot see a 2 m eye at
        // B (min clearance −2.95 m at station 649 — reproduced exactly by
        // groundHeight). The drama the cab DOES get is the true 14.7 m
        // amphitheater upslope: arrivals touch down far below and climb the
        // concrete toward the crest.
        let cabGround = at(645, 168)
        let cabEyeY = AirportLayout.runwayProfile(atStation: 645) + 15.5

        return AirportLayout(
            icao: "KAVX",
            displayName: "Catalina — Airport in the Sky",
            runway: runway,
            taxiways: [taxiwayAlpha, a1, a2, a3],
            exits: exits,
            apronSpots: spots,
            // KAVX capability gate: GA + turboprop + the DC-3, NO jets. The
            // short mesa runway and single ramp can't take airliner metal.
            acceptedClasses: [.light, .cabinTwin, .turboprop, .heritage],
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
            flat: false,
            mesaDropMeters: 488.3,
            mesaOutline: outline,
            humpAmplitude: 14.7,
            towerCabEye: V3(cabGround.x, cabEyeY, cabGround.y),
            windsockPosition: at(400, 84)                  // D23: SE, near the ramp
        )
    }()

    // MARK: - KJFK

    // New York — John F. Kennedy Intl. A dead-flat coastal field (~13 ft) built
    // out onto Jamaica Bay. The active in the slice is the Bay Runway 13R/31L —
    // North America's longest commercial runway (14,511 ft) — landing 31L toward
    // the NW (301° true), arrivals sweeping in over the bay from the SE. Airliners
    // only: regional/narrowbody/widebody. Functional (not survey-accurate) taxi
    // layout on the terminal side; the World layer re-skins terrain/Terminal City.
    public static let kjfk: AirportLayout = {
        // Bay Runway 13R/31L. Active = 31L: land toward the NW, true heading 301°.
        let hLand = degToRad(301)
        let dir = headingDirection(hLand)                  // points NW (landing dir)
        let half = 4423.0 / 2                              // 14,511 ft ≈ 4423 m
        let thresholdB = V2(0, 0) - dir * half             // SE end — 31L threshold (arrival)
        let thresholdA = V2(0, 0) + dir * half             // NW end — 13R (rollout end)
        let runway = Runway(thresholdA: thresholdA, thresholdB: thresholdB, width: 60,
                            nameA: "13R", nameB: "31L")

        // Runway-frame helper: s along the roll from threshold B (31L), p toward
        // the terminal (NE) side. perpSE is "right of the 31L landing roll".
        let perpSE = V2(dir.y, -dir.x)                     // right of the roll = terminal (NE) side
        func at(_ s: Double, _ p: Double) -> V2 { thresholdB + dir * s + perpSE * p }

        // Full-length parallel taxiway 120 m onto the terminal side, big-jet scale.
        let parOffset = 120.0
        let parallel = Taxiway(id: "P", name: "Papa",
                               points: [at(120, parOffset), at(4300, parOffset)], width: 30)

        // The gate ramp sits near threshold B so departures reach the runway in
        // a short taxi (keeps a full-length runway but a workable ground flow, as
        // the real Terminal-4 ramp feeds 31L via nearby taxiways). Runway exits
        // are out at stations 1800/3200 per spec; arrivals roll out, turn off,
        // and taxi back down the parallel to the near-threshold ramp.
        let rampStation = 500.0
        let exit1Station = 1800.0
        let exit2Station = 3200.0
        let c1 = Taxiway(id: "C1", name: "Charlie One",
                         points: [at(120, 0), at(120, parOffset)], width: 25)   // near thr B, line-up
        let c2 = Taxiway(id: "C2", name: "Charlie Two",
                         points: [at(exit1Station, 0), at(exit1Station, parOffset)], width: 25)
        let c3 = Taxiway(id: "C3", name: "Charlie Three",
                         points: [at(exit2Station, 0), at(exit2Station, parOffset)], width: 25)

        let exits = [
            RunwayExit(stationFrom22: exit1Station, taxiwayID: "C2", isPreferred: true),
            RunwayExit(stationFrom22: exit2Station, taxiwayID: "C3", isPreferred: false),
        ]

        // Apron/gate spots on the terminal side, a compact row near the ramp
        // (p ≈ 300 m off centerline), all facing the field.
        var spots: [ApronSpot] = []
        let apronP = 300.0
        for s in stride(from: 300.0, through: 1000.0, by: 100.0) {   // 8 gates near thr B
            spots.append(ApronSpot(position: at(s, apronP), heading: hLand + .pi / 2))
        }

        // Ground routes. Hold-short near thr B; line-up joins the runway there.
        let apronExitPoint = at(rampStation, apronP)       // ramp mouth feeding the parallel
        let holdShort = at(120, 60)                        // short of the runway edge on C1
        let routeTaxiOut: [V2] = [apronExitPoint,
                                  at(rampStation, parOffset),  // join the parallel
                                  at(120, parOffset),           // short taxi to thr B
                                  holdShort]
        let routeExitMidfield: [V2] = [at(exit1Station, 0), at(exit1Station, parOffset),
                                       at(rampStation, parOffset), apronExitPoint]
        let routeExitEnd: [V2] = [at(exit2Station, 0), at(exit2Station, parOffset),
                                  at(exit1Station, parOffset),
                                  at(rampStation, parOffset), apronExitPoint]
        let routeLineUp: [V2] = [holdShort, thresholdB + dir * 40]

        // A big flat land footprint centered on the field: a rounded rectangle
        // ~5000 m along × ~3500 m across via a superellipse (n≈4 → rounded-rect
        // corners). The World layer re-skins this terrain later.
        var outline: [V2] = []
        let nOut = 72
        let halfAlong = 2500.0, halfAcross = 1750.0
        for i in 0..<nOut {
            let a = Double(i) / Double(nOut) * 2 * .pi
            let ca = cos(a), sa = sin(a)
            // Superellipse |x|^4 + |y|^4 = 1 → boxy rounded rectangle.
            let along = halfAlong * copysign(pow(abs(ca), 0.5), ca)
            let cross = halfAcross * copysign(pow(abs(sa), 0.5), sa)
            outline.append(dir * along + perpSE * (cross + parOffset))
        }

        // Tower cab: real Terminal-4 tower is 98 m. Commanding eye offset to the
        // NE/terminal side near midfield, looking out over the runway and the SE
        // bay approach. flat field ⇒ ground datum y = 0.
        let cabGround = at(2200, 900)
        let cabEyeY = 90.0

        return AirportLayout(
            icao: "KJFK",
            displayName: "New York — John F. Kennedy Intl",
            runway: runway,
            taxiways: [parallel, c1, c2, c3],
            exits: exits,
            apronSpots: spots,
            // Airliners only — no light/cabinTwin/turboprop/heritage/bizjet.
            acceptedClasses: [.regional, .narrowbody, .widebody],
            routeTaxiOut: routeTaxiOut,
            routeExitMidfield: routeExitMidfield,
            routeExitEnd: routeExitEnd,
            routeLineUp: routeLineUp,
            holdShortPoint: holdShort,
            patternAltitude: 460,
            downwindOffset: 3000,
            finalSpawnDistance: 13000,
            finalGlideSlopeDeg: 3.0,
            downwindEntryStation: 3600,
            baseTurnStation: -2400,
            flat: true,
            mesaDropMeters: 4.0,                            // Jamaica Bay just below the field
            mesaOutline: outline,
            humpAmplitude: 0,
            towerCabEye: V3(cabGround.x, cabEyeY, cabGround.y),
            windsockPosition: at(1500, apronP - 40)         // terminal side, near the apron
        )
    }()

    public init(icao: String, displayName: String, runway: Runway, taxiways: [Taxiway],
                exits: [RunwayExit], apronSpots: [ApronSpot],
                acceptedClasses: Set<SizeClass>,
                routeTaxiOut: [V2], routeExitMidfield: [V2], routeExitEnd: [V2],
                routeLineUp: [V2], holdShortPoint: V2,
                patternAltitude: Double, downwindOffset: Double, finalSpawnDistance: Double,
                finalGlideSlopeDeg: Double, downwindEntryStation: Double, baseTurnStation: Double,
                flat: Bool = false,
                mesaDropMeters: Double, mesaOutline: [V2], humpAmplitude: Double,
                towerCabEye: V3, windsockPosition: V2) {
        self.icao = icao; self.displayName = displayName; self.runway = runway
        self.taxiways = taxiways; self.exits = exits; self.apronSpots = apronSpots
        self.acceptedClasses = acceptedClasses
        self.routeTaxiOut = routeTaxiOut; self.routeExitMidfield = routeExitMidfield
        self.routeExitEnd = routeExitEnd; self.routeLineUp = routeLineUp
        self.holdShortPoint = holdShortPoint
        self.patternAltitude = patternAltitude; self.downwindOffset = downwindOffset
        self.finalSpawnDistance = finalSpawnDistance; self.finalGlideSlopeDeg = finalGlideSlopeDeg
        self.downwindEntryStation = downwindEntryStation; self.baseTurnStation = baseTurnStation
        self.flat = flat
        self.mesaDropMeters = mesaDropMeters; self.mesaOutline = mesaOutline
        self.humpAmplitude = humpAmplitude
        self.towerCabEye = towerCabEye; self.windsockPosition = windsockPosition
    }
}
