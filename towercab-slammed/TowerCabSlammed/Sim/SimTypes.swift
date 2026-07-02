import Foundation
import simd

// =============================================================================
// TowerCab: Slammed — shared simulation contracts
//
// World space convention (used by BOTH the sim and SceneKit presentation):
//   - Units: meters. Right-handed, Y up.
//   - North = -Z, East = +X. Heading 0 rad = north, positive clockwise (viewed
//     from above). Direction of heading h = (sin h, 0, -cos h).
//   - Y origin (0) = KAVX runway surface (mesa top). The Pacific sits at
//     y = -AirportLayout.mesaDropMeters.
//   - The sim runs a fixed 10 Hz tick (PRD §9.3). Presentation interpolates.
// =============================================================================

public typealias V2 = SIMD2<Double>
public typealias V3 = SIMD3<Double>

@inline(__always) public func headingDirection(_ h: Double) -> V2 { V2(sin(h), -cos(h)) }
@inline(__always) public func directionHeading(_ d: V2) -> Double { atan2(d.x, -d.y) }
/// Shortest signed angular difference a→b in radians (-π, π].
@inline(__always) public func angleDelta(from a: Double, to b: Double) -> Double {
    var d = (b - a).truncatingRemainder(dividingBy: .pi * 2)
    if d > .pi { d -= .pi * 2 }
    if d <= -.pi { d += .pi * 2 }
    return d
}
@inline(__always) public func degToRad(_ d: Double) -> Double { d * .pi / 180 }
@inline(__always) public func ktsToMps(_ k: Double) -> Double { k * 0.514444 }

// MARK: - Identity & fleet

public struct AircraftID: Hashable, Codable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "AC\(raw)" }
}

/// PRD §4.4 near-types present at Catalina in the slice.
public enum AircraftKind: String, CaseIterable, Codable {
    case lark72   // C172 analog — high-wing GA piston, fixed gear
    case vela22   // SR22 analog — low-wing GA piston, fixed gear, faster
    case comet60  // Challenger-class bizjet — the VIP that breaks the rhythm

    public var displayType: String {
        switch self {
        case .lark72: return "LK72"
        case .vela22: return "VL22"
        case .comet60: return "CM60"
        }
    }
    /// Approach speed over the fence, m/s.
    public var approachSpeed: Double {
        switch self {
        case .lark72: return ktsToMps(65)
        case .vela22: return ktsToMps(80)
        case .comet60: return ktsToMps(115)
        }
    }
    public var patternSpeed: Double {
        switch self {
        case .lark72: return ktsToMps(90)
        case .vela22: return ktsToMps(110)
        case .comet60: return ktsToMps(160)
        }
    }
    public var climbSpeed: Double {
        switch self {
        case .lark72: return ktsToMps(75)
        case .vela22: return ktsToMps(100)
        case .comet60: return ktsToMps(150)
        }
    }
    public var climbRate: Double {   // m/s vertical
        switch self {
        case .lark72: return 3.6
        case .vela22: return 4.6
        case .comet60: return 15.0
        }
    }
    /// Peak deceleration on rollout, m/s² (comfortable braking).
    public var rolloutDecel: Double {
        switch self {
        case .lark72: return 1.8
        case .vela22: return 2.0
        case .comet60: return 2.6
        }
    }
    /// Harder braking when told to expedite.
    public var expediteDecel: Double { rolloutDecel * 1.5 }
    public var takeoffAccel: Double { // m/s²
        switch self {
        case .lark72: return 1.9
        case .vela22: return 2.3
        case .comet60: return 3.4
        }
    }
    public var rotateSpeed: Double {
        switch self {
        case .lark72: return ktsToMps(55)
        case .vela22: return ktsToMps(70)
        case .comet60: return ktsToMps(120)
        }
    }
    public var taxiSpeed: Double {
        switch self {
        case .lark72: return 7.0
        case .vela22: return 7.5
        case .comet60: return 9.0
        }
    }
    public var hasRetractableGear: Bool { self == .comet60 }
    public var wingspanMeters: Double {
        switch self {
        case .lark72: return 11.0
        case .vela22: return 11.7
        case .comet60: return 19.6
        }
    }
    /// Base points weight — bigger metal pays slightly more (flavor only).
    public var movementWeight: Double { self == .comet60 ? 1.4 : 1.0 }
}

/// PRD §4.5 fictional carriers relevant to KAVX, plus private GA.
public enum Livery: String, CaseIterable, Codable {
    case islaTurquoise    // Isla Air — turquoise island commuter
    case islaClassic      // Isla Air retro cream variant
    case privateWhite     // private GA — white with maroon stripe
    case privateSunburst  // private GA — sunburst yellow/orange
    case meridianVIP      // navy-and-gold — the Comet 60 VIP
}

public struct Callsign: Hashable, Codable {
    /// Strip label, e.g. "ISL 212" or "N734RT".
    public let display: String
    /// Radio short name, e.g. "Isla Two-Twelve" or "Lark Four-Romeo-Tango".
    public let spoken: String
    public init(display: String, spoken: String) {
        self.display = display
        self.spoken = spoken
    }
}

// MARK: - Flight phases

public enum FlightPhase: Equatable, Codable {
    // Air — arrivals
    case inboundFinal        // straight-in, outside the pattern
    case downwind
    case base
    case finalApproach
    case shortFinal          // inside commit distance
    case flare
    case goingAround
    case orbiting            // flying a commanded 360
    // Ground — arrival flow
    case rollout
    case exitingRunway
    case taxiToApron
    case parkedArrival       // done: awaiting strip handoff
    // Ground — departure flow
    case startingUp          // spawned at apron; will call ready to taxi
    case taxiToRunway
    case holdingShort
    case lineUpWait
    case takeoffRoll
    case climbingOut
    case departedHandoff     // done: awaiting strip handoff
    case removed             // despawned

    public var isAirborne: Bool {
        switch self {
        case .inboundFinal, .downwind, .base, .finalApproach, .shortFinal,
             .flare, .goingAround, .orbiting, .climbingOut:
            return true
        default: return false
        }
    }
    public var isArrivalFlow: Bool {
        switch self {
        case .inboundFinal, .downwind, .base, .finalApproach, .shortFinal, .flare,
             .goingAround, .orbiting, .rollout, .exitingRunway, .taxiToApron, .parkedArrival:
            return true
        default: return false
        }
    }
    /// Short label for the strip.
    public var stripLabel: String {
        switch self {
        case .inboundFinal: return "INBOUND"
        case .downwind: return "DOWNWIND"
        case .base: return "BASE"
        case .finalApproach: return "FINAL"
        case .shortFinal: return "SHORT FINAL"
        case .flare: return "LANDING"
        case .goingAround: return "GO-AROUND"
        case .orbiting: return "IN THE TURN"
        case .rollout: return "ROLLOUT"
        case .exitingRunway: return "EXITING"
        case .taxiToApron: return "TAXI IN"
        case .parkedArrival: return "AT PARKING"
        case .startingUp: return "STARTING UP"
        case .taxiToRunway: return "TAXI OUT"
        case .holdingShort: return "HOLDING SHORT"
        case .lineUpWait: return "LINE UP & WAIT"
        case .takeoffRoll: return "ROLLING"
        case .climbingOut: return "CLIMBING OUT"
        case .departedHandoff: return "DEPARTED"
        case .removed: return "—"
        }
    }
}

// MARK: - Commands (PRD §2.2 P0 verbs in slice scope)

public enum Command: Equatable, Codable {
    case clearedToLand
    case goAround
    case extendDownwind
    case make360(left: Bool)
    case lineUpAndWait
    case clearedForTakeoff(immediate: Bool)
    case holdPosition
    case continueTaxi
    case expediteExit        // "exit right at the next taxiway, no delay"
    case handoff             // flick the completed strip off the rail

    public var label: String {
        switch self {
        case .clearedToLand: return "CLEARED TO LAND"
        case .goAround: return "GO AROUND"
        case .extendDownwind: return "EXTEND DOWNWIND"
        case .make360(let left): return left ? "360 LEFT" : "360 RIGHT"
        case .lineUpAndWait: return "LINE UP & WAIT"
        case .clearedForTakeoff(let immediate):
            return immediate ? "IMMEDIATE TAKEOFF" : "CLEARED FOR TAKEOFF"
        case .holdPosition: return "HOLD POSITION"
        case .continueTaxi: return "CONTINUE"
        case .expediteExit: return "EXPEDITE EXIT"
        case .handoff: return "HANDOFF"
        }
    }
}

public struct CommandEnvelope {
    public let aircraft: AircraftID
    public let command: Command
    /// Wall-clock sim time (seconds) at input, millisecond resolution (PRD §9.3).
    public let timestamp: Double
    public init(aircraft: AircraftID, command: Command, timestamp: Double) {
        self.aircraft = aircraft
        self.command = command
        self.timestamp = timestamp
    }
}

public enum CommandResult {
    case accepted
    case invalid(reason: String)
}

// MARK: - Conflict bands (PRD §2.5)

public enum ConflictBand: Int, Comparable, Codable {
    case green = 0, amber = 1, red = 2
    public static func < (l: ConflictBand, r: ConflictBand) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Scoring (PRD §2.6 — the SAVE table is law)

public enum Badge: Equatable, Codable {
    case tightGap        // +500 amber-band departure inside an arrival gap
    case slickExit       // +200 expedited high-speed exit on request
    case noDelay         // +150 expedited compliance chained into the freed gap
    case save            // +750 projected conflict resolved (amber / early red)
    case lateSave        // +250 sustained red resolved by player action
    case cleanShift      // ×1.1 end-of-shift

    public var points: Int {
        switch self {
        case .tightGap: return 500
        case .slickExit: return 200
        case .noDelay: return 150
        case .save: return 750
        case .lateSave: return 250
        case .cleanShift: return 0
        }
    }
    public var label: String {
        switch self {
        case .tightGap: return "TIGHT GAP"
        case .slickExit: return "SLICK EXIT"
        case .noDelay: return "NO DELAY"
        case .save: return "SAVE"
        case .lateSave: return "LATE SAVE"
        case .cleanShift: return "CLEAN SHIFT"
        }
    }
}

public struct BadgeAward: Equatable, Codable {
    public let badge: Badge
    public let aircraft: AircraftID
    public let points: Int
    public init(badge: Badge, aircraft: AircraftID, points: Int) {
        self.badge = badge
        self.aircraft = aircraft
        self.points = points
    }
}

public enum ShiftGrade: String, Codable { case s = "S", a = "A", b = "B", c = "C", d = "D" }

public struct ShiftReport: Codable {
    public var totalScore: Int
    public var grade: ShiftGrade
    /// 0–100 each: Flow, Precision, Cool, Frequency (PRD §2.6 end-of-shift axes).
    public var flow: Int
    public var precision: Int
    public var cool: Int
    public var frequency: Int
    public var landings: Int
    public var departures: Int
    public var badges: [BadgeAward]
    public var bestStreak: Int
    public var averageDelaySeconds: Double
    public var bestMoment: String
    public init(totalScore: Int, grade: ShiftGrade, flow: Int, precision: Int, cool: Int,
                frequency: Int, landings: Int, departures: Int, badges: [BadgeAward],
                bestStreak: Int, averageDelaySeconds: Double, bestMoment: String) {
        self.totalScore = totalScore; self.grade = grade
        self.flow = flow; self.precision = precision; self.cool = cool; self.frequency = frequency
        self.landings = landings; self.departures = departures
        self.badges = badges; self.bestStreak = bestStreak
        self.averageDelaySeconds = averageDelaySeconds; self.bestMoment = bestMoment
    }
}

// MARK: - Radio

public enum RadioSpeaker: Equatable, Codable {
    case tower
    case pilot(AircraftID)
}

public struct RadioCall: Equatable, Codable {
    public let speaker: RadioSpeaker
    public let text: String
    public init(speaker: RadioSpeaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - Shift structure (PRD §2.7 traffic curve)

public enum ShiftPhase: String, Codable {
    case ramp        // spacing opens generous, builds
    case crescendo   // the slammed minute
    case cooldown    // last strips resolve
    case ended
}

public struct Wind: Equatable, Codable {
    /// Direction the wind is FROM, degrees true.
    public var directionDeg: Double
    public var speedKts: Double
    public var gustKts: Double
    public init(directionDeg: Double, speedKts: Double, gustKts: Double) {
        self.directionDeg = directionDeg
        self.speedKts = speedKts
        self.gustKts = gustKts
    }
}

// MARK: - Aircraft state (per tick)

public struct AircraftState {
    public var id: AircraftID
    public var kind: AircraftKind
    public var livery: Livery
    public var callsign: Callsign
    public var phase: FlightPhase

    public var position: V3          // world meters
    public var heading: Double       // radians
    public var speed: Double         // m/s ground speed
    public var verticalSpeed: Double // m/s
    public var bank: Double          // radians, presentation hint
    public var pitch: Double         // radians, presentation hint

    public var gearDown: Bool
    public var landingLightsOn: Bool

    /// True once the tower has issued the matching clearance.
    public var clearedToLand: Bool
    public var clearedForTakeoff: Bool
    public var holdingPosition: Bool

    /// Cumulative delay attributable to tower handling (PRD delay ledger).
    public var delaySeconds: Double
    /// Worst band this aircraft currently participates in.
    public var band: ConflictBand
    /// Projected interaction margin in seconds if in amber/red (Gap Arc, §2.5).
    public var gapSeconds: Double?
    /// 0–1 progress for time-sensitive states (short final, holding in position).
    public var urgency: Double?

    public init(id: AircraftID, kind: AircraftKind, livery: Livery, callsign: Callsign,
                phase: FlightPhase, position: V3, heading: Double, speed: Double,
                verticalSpeed: Double = 0, bank: Double = 0, pitch: Double = 0,
                gearDown: Bool = true, landingLightsOn: Bool = false,
                clearedToLand: Bool = false, clearedForTakeoff: Bool = false,
                holdingPosition: Bool = false, delaySeconds: Double = 0,
                band: ConflictBand = .green, gapSeconds: Double? = nil, urgency: Double? = nil) {
        self.id = id; self.kind = kind; self.livery = livery; self.callsign = callsign
        self.phase = phase; self.position = position; self.heading = heading
        self.speed = speed; self.verticalSpeed = verticalSpeed
        self.bank = bank; self.pitch = pitch
        self.gearDown = gearDown; self.landingLightsOn = landingLightsOn
        self.clearedToLand = clearedToLand; self.clearedForTakeoff = clearedForTakeoff
        self.holdingPosition = holdingPosition
        self.delaySeconds = delaySeconds; self.band = band
        self.gapSeconds = gapSeconds; self.urgency = urgency
    }
}

/// Interpolated state handed to the renderer each frame.
public struct AircraftRenderState {
    public var id: AircraftID
    public var kind: AircraftKind
    public var livery: Livery
    public var phase: FlightPhase
    public var position: V3
    public var heading: Double
    public var bank: Double
    public var pitch: Double
    public var speed: Double
    public var gearDown: Bool
    public var landingLightsOn: Bool
    public var band: ConflictBand
    public init(id: AircraftID, kind: AircraftKind, livery: Livery, phase: FlightPhase,
                position: V3, heading: Double, bank: Double, pitch: Double, speed: Double,
                gearDown: Bool, landingLightsOn: Bool, band: ConflictBand) {
        self.id = id; self.kind = kind; self.livery = livery; self.phase = phase
        self.position = position; self.heading = heading; self.bank = bank; self.pitch = pitch
        self.speed = speed; self.gearDown = gearDown; self.landingLightsOn = landingLightsOn
        self.band = band
    }
}

// MARK: - Events

public enum SimEvent {
    case radio(RadioCall)
    case badge(BadgeAward)
    case streakChanged(multiplier: Int)
    case movementCompleted(aircraft: AircraftID, points: Int, isLanding: Bool)
    case bandChanged(aircraft: AircraftID, band: ConflictBand)
    case selfPreservation(aircraft: AircraftID, penalty: Int)  // pilot saved themselves: −2000
    case aircraftSpawned(AircraftID)
    case aircraftRemoved(AircraftID)
    case shiftPhaseChanged(ShiftPhase)
    case shiftEnded(ShiftReport)
}

// MARK: - Snapshot

public struct SimSnapshot {
    public var simTime: Double
    public var tickIndex: Int
    public var aircraft: [AircraftState]
    public var score: Int
    public var streakMultiplier: Int
    public var shiftPhase: ShiftPhase
    public var shiftTimeRemaining: Double
    public var wind: Wind
    public init(simTime: Double, tickIndex: Int, aircraft: [AircraftState], score: Int,
                streakMultiplier: Int, shiftPhase: ShiftPhase, shiftTimeRemaining: Double, wind: Wind) {
        self.simTime = simTime; self.tickIndex = tickIndex; self.aircraft = aircraft
        self.score = score; self.streakMultiplier = streakMultiplier
        self.shiftPhase = shiftPhase; self.shiftTimeRemaining = shiftTimeRemaining
        self.wind = wind
    }
}
