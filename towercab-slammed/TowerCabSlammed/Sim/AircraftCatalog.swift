import Foundation

// =============================================================================
// AircraftCatalog — the data-driven spec table backing all 16 real aircraft
// types. AircraftKind (SimTypes.swift) is a thin enum; every per-type property
// (speeds, geometry, rarity, capability class) reads out of `spec` here so the
// fleet lives in ONE source of truth.
//
// Branding rule: REAL type names, FICTIONAL airlines only. No real liveries.
// Determinism rule: the weighted spawn picker consumes the seeded RNG only —
// no wall clock, no SystemRandomNumberGenerator — so a seed replays identically.
// =============================================================================

public enum EngineType {
    case piston, turboprop, jet
}

/// Coarse size/capability tier. Airports gate spawns by an accepted set of
/// these classes (KAVX accepts everything up to heritage — no jets). Ordered
/// light → widebody; `<` compares by rawValue so ranges/sorting read naturally.
public enum SizeClass: Int, Comparable {
    case light        = 0
    case cabinTwin    = 1
    case turboprop    = 2
    case heritage     = 3
    case bizjet       = 4
    case regional     = 5
    case narrowbody   = 6
    case widebody     = 7

    public static func < (l: SizeClass, r: SizeClass) -> Bool { l.rawValue < r.rawValue }
}

/// The full per-type record. Speeds are authored in KNOTS / m/s / m as noted;
/// AircraftKind's computed properties convert knots → m/s where the sim expects
/// SI, keeping the existing property names so movement/sim code compiles as-is.
public struct AircraftSpec {
    public let display: String        // strip type code, e.g. "C172"
    public let fullName: String       // spoken/UI full name, e.g. "Cessna 172 Skyhawk"
    public let sizeClass: SizeClass
    public let engine: EngineType
    public let wingspanM: Double
    public let lengthM: Double
    public let approachKt: Double
    public let patternKt: Double
    public let climbKt: Double
    public let rotateKt: Double
    public let climbRateMps: Double   // vertical m/s
    public let rolloutDecel: Double   // m/s²
    public let takeoffAccel: Double   // m/s²
    public let taxiMps: Double        // m/s
    public let spawnWeight: Double    // rarity: higher = commoner
    public let movementWeight: Double // score multiplier flavor
    public let mtowLb: Double
    public let retractableGear: Bool

    public var engineIsJet: Bool { engine == .jet }

    public init(display: String, fullName: String, sizeClass: SizeClass, engine: EngineType,
                wingspanM: Double, lengthM: Double, approachKt: Double, patternKt: Double,
                climbKt: Double, rotateKt: Double, climbRateMps: Double, rolloutDecel: Double,
                takeoffAccel: Double, taxiMps: Double, spawnWeight: Double, movementWeight: Double,
                mtowLb: Double, retractableGear: Bool) {
        self.display = display; self.fullName = fullName
        self.sizeClass = sizeClass; self.engine = engine
        self.wingspanM = wingspanM; self.lengthM = lengthM
        self.approachKt = approachKt; self.patternKt = patternKt
        self.climbKt = climbKt; self.rotateKt = rotateKt
        self.climbRateMps = climbRateMps; self.rolloutDecel = rolloutDecel
        self.takeoffAccel = takeoffAccel; self.taxiMps = taxiMps
        self.spawnWeight = spawnWeight; self.movementWeight = movementWeight
        self.mtowLb = mtowLb; self.retractableGear = retractableGear
    }
}

public extension AircraftKind {
    /// The single source of truth for every per-type number. Transcribed from
    /// the roster; do not hand-edit derived properties on AircraftKind — edit
    /// the row here.
    var spec: AircraftSpec {
        switch self {
        case .c172:
            return AircraftSpec(display: "C172", fullName: "Cessna 172 Skyhawk",
                sizeClass: .light, engine: .piston,
                wingspanM: 11.0, lengthM: 8.3, approachKt: 65, patternKt: 90, climbKt: 75,
                rotateKt: 55, climbRateMps: 3.6, rolloutDecel: 1.8, takeoffAccel: 1.9,
                taxiMps: 7.0, spawnWeight: 22, movementWeight: 1.0, mtowLb: 2450, retractableGear: false)
        case .pa28:
            return AircraftSpec(display: "PA28", fullName: "Piper PA-28 Archer",
                sizeClass: .light, engine: .piston,
                wingspanM: 10.7, lengthM: 7.3, approachKt: 66, patternKt: 90, climbKt: 76,
                rotateKt: 55, climbRateMps: 3.5, rolloutDecel: 1.8, takeoffAccel: 1.9,
                taxiMps: 7.0, spawnWeight: 12, movementWeight: 1.0, mtowLb: 2550, retractableGear: false)
        case .c182:
            return AircraftSpec(display: "C182", fullName: "Cessna 182 Skylane",
                sizeClass: .light, engine: .piston,
                wingspanM: 11.0, lengthM: 8.8, approachKt: 70, patternKt: 95, climbKt: 80,
                rotateKt: 58, climbRateMps: 4.6, rolloutDecel: 1.9, takeoffAccel: 2.0,
                taxiMps: 7.0, spawnWeight: 9, movementWeight: 1.0, mtowLb: 3100, retractableGear: false)
        case .sr22:
            return AircraftSpec(display: "SR22", fullName: "Cirrus SR22",
                sizeClass: .light, engine: .piston,
                wingspanM: 11.7, lengthM: 7.9, approachKt: 80, patternKt: 110, climbKt: 100,
                rotateKt: 70, climbRateMps: 4.6, rolloutDecel: 2.0, takeoffAccel: 2.3,
                taxiMps: 7.5, spawnWeight: 8, movementWeight: 1.1, mtowLb: 3600, retractableGear: false)
        case .baron58:
            return AircraftSpec(display: "BE58", fullName: "Beechcraft Baron 58",
                sizeClass: .cabinTwin, engine: .piston,
                wingspanM: 11.5, lengthM: 8.5, approachKt: 96, patternKt: 130, climbKt: 105,
                rotateKt: 84, climbRateMps: 5.5, rolloutDecel: 2.1, takeoffAccel: 2.6,
                taxiMps: 8.0, spawnWeight: 4, movementWeight: 1.2, mtowLb: 5500, retractableGear: true)
        case .caravan:
            return AircraftSpec(display: "C208", fullName: "Cessna 208 Caravan",
                sizeClass: .turboprop, engine: .turboprop,
                wingspanM: 15.9, lengthM: 12.7, approachKt: 85, patternKt: 120, climbKt: 105,
                rotateKt: 75, climbRateMps: 5.0, rolloutDecel: 2.2, takeoffAccel: 2.4,
                taxiMps: 8.0, spawnWeight: 8, movementWeight: 1.3, mtowLb: 8750, retractableGear: false)
        case .kingair350:
            return AircraftSpec(display: "BE30", fullName: "Beechcraft King Air 350",
                sizeClass: .turboprop, engine: .turboprop,
                wingspanM: 17.7, lengthM: 14.2, approachKt: 110, patternKt: 160, climbKt: 140,
                rotateKt: 95, climbRateMps: 12.0, rolloutDecel: 2.4, takeoffAccel: 3.0,
                taxiMps: 9.0, spawnWeight: 5, movementWeight: 1.4, mtowLb: 15000, retractableGear: true)
        case .twinotter:
            return AircraftSpec(display: "DHC6", fullName: "DHC-6 Twin Otter",
                sizeClass: .turboprop, engine: .turboprop,
                wingspanM: 19.8, lengthM: 15.8, approachKt: 75, patternKt: 110, climbKt: 95,
                rotateKt: 65, climbRateMps: 5.0, rolloutDecel: 2.0, takeoffAccel: 2.3,
                taxiMps: 8.0, spawnWeight: 4, movementWeight: 1.4, mtowLb: 12500, retractableGear: false)
        case .dc3:
            return AircraftSpec(display: "DC3", fullName: "Douglas DC-3",
                sizeClass: .heritage, engine: .piston,
                wingspanM: 29.0, lengthM: 19.7, approachKt: 85, patternKt: 120, climbKt: 100,
                rotateKt: 75, climbRateMps: 5.0, rolloutDecel: 2.0, takeoffAccel: 2.2,
                taxiMps: 8.0, spawnWeight: 1.5, movementWeight: 1.6, mtowLb: 25000, retractableGear: true)
        case .phenom300:
            return AircraftSpec(display: "E55P", fullName: "Embraer Phenom 300",
                sizeClass: .bizjet, engine: .jet,
                wingspanM: 15.9, lengthM: 15.6, approachKt: 108, patternKt: 160, climbKt: 150,
                rotateKt: 100, climbRateMps: 15.0, rolloutDecel: 2.6, takeoffAccel: 3.4,
                taxiMps: 9.0, spawnWeight: 5, movementWeight: 1.4, mtowLb: 18500, retractableGear: true)
        case .challenger350:
            return AircraftSpec(display: "CL35", fullName: "Bombardier Challenger 350",
                sizeClass: .bizjet, engine: .jet,
                wingspanM: 21.0, lengthM: 20.9, approachKt: 115, patternKt: 160, climbKt: 150,
                rotateKt: 120, climbRateMps: 15.0, rolloutDecel: 2.6, takeoffAccel: 3.4,
                taxiMps: 9.0, spawnWeight: 3, movementWeight: 1.5, mtowLb: 40600, retractableGear: true)
        case .e175:
            return AircraftSpec(display: "E175", fullName: "Embraer E175",
                sizeClass: .regional, engine: .jet,
                wingspanM: 26.0, lengthM: 31.7, approachKt: 130, patternKt: 180, climbKt: 170,
                rotateKt: 130, climbRateMps: 12.0, rolloutDecel: 2.6, takeoffAccel: 3.2,
                taxiMps: 9.0, spawnWeight: 3, movementWeight: 2.0, mtowLb: 89000, retractableGear: true)
        case .boeing737:
            return AircraftSpec(display: "B738", fullName: "Boeing 737-800",
                sizeClass: .narrowbody, engine: .jet,
                wingspanM: 35.8, lengthM: 39.5, approachKt: 145, patternKt: 210, climbKt: 250,
                rotateKt: 145, climbRateMps: 12.0, rolloutDecel: 2.4, takeoffAccel: 2.4,
                taxiMps: 9.0, spawnWeight: 2.5, movementWeight: 3.0, mtowLb: 174000, retractableGear: true)
        case .airbus320:
            return AircraftSpec(display: "A320", fullName: "Airbus A320",
                sizeClass: .narrowbody, engine: .jet,
                wingspanM: 35.8, lengthM: 37.6, approachKt: 140, patternKt: 210, climbKt: 250,
                rotateKt: 140, climbRateMps: 12.0, rolloutDecel: 2.4, takeoffAccel: 2.4,
                taxiMps: 9.0, spawnWeight: 2.5, movementWeight: 3.0, mtowLb: 169000, retractableGear: true)
        case .boeing777:
            return AircraftSpec(display: "B77W", fullName: "Boeing 777-300ER",
                sizeClass: .widebody, engine: .jet,
                wingspanM: 64.8, lengthM: 73.9, approachKt: 149, patternKt: 220, climbKt: 270,
                rotateKt: 150, climbRateMps: 12.0, rolloutDecel: 2.2, takeoffAccel: 2.2,
                taxiMps: 9.0, spawnWeight: 0.8, movementWeight: 4.5, mtowLb: 775000, retractableGear: true)
        case .airbus380:
            return AircraftSpec(display: "A388", fullName: "Airbus A380-800",
                sizeClass: .widebody, engine: .jet,
                wingspanM: 79.8, lengthM: 72.7, approachKt: 145, patternKt: 220, climbKt: 270,
                rotateKt: 150, climbRateMps: 11.0, rolloutDecel: 2.0, takeoffAccel: 2.0,
                taxiMps: 9.0, spawnWeight: 0.3, movementWeight: 6.0, mtowLb: 1268000, retractableGear: true)
        }
    }

    /// Convenience: is this a jet? (turn rate / bank / expedite gating read this).
    var engineIsJet: Bool { spec.engineIsJet }
}

// MARK: - Rarity-weighted, capability-gated spawn picker

public extension AircraftKind {
    /// Deterministic rarity-weighted pick over the types this airport accepts.
    /// Filters AircraftKind.allCases to specs whose sizeClass ∈ acceptedClasses,
    /// then rolls a single RNG double against the cumulative spawnWeight. Pure
    /// function of (airport, rng state) — no wall clock — so seeds replay.
    static func weightedKind(spawnableAt airport: AirportLayout,
                             rng: inout SeededRNG) -> AircraftKind {
        // `allCases` order is the enum declaration order — deterministic.
        let eligible = AircraftKind.allCases.filter {
            airport.acceptedClasses.contains($0.spec.sizeClass)
        }
        // Defensive: an airport that accepts nothing falls back to the lightest
        // type so the sim never traps. (KAVX always has eligible GA types.)
        guard !eligible.isEmpty else { return .c172 }
        let total = eligible.reduce(0.0) { $0 + $1.spec.spawnWeight }
        guard total > 0 else { return eligible[0] }
        var roll = rng.double(in: 0...total)
        for kind in eligible {
            roll -= kind.spec.spawnWeight
            if roll <= 0 { return kind }
        }
        return eligible[eligible.count - 1]   // fp guard
    }
}
