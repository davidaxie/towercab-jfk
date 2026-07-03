import Foundation
import SwiftUI

// =============================================================================
// UI bridge — the ONLY interface between the game loop and the SwiftUI HUD.
// GameViewController writes; HUD views read + call GameActions. The HUD never
// touches SimEngine or SceneKit directly.
// =============================================================================

@MainActor
public protocol GameActions: AnyObject {
    func startShift()
    func restartShift()
    func togglePause()
    func stripTapped(_ id: AircraftID)
    func stripDoubleTapped(_ id: AircraftID)
    func verbSelected(_ id: AircraftID, command: Command)
    func bloomDismissed()
}

public enum StripTone: Equatable {
    case normal          // green band
    case attention       // amber band — the bonus band
    case alarm           // red band
    case complete        // ready for handoff — flick it off
}

public struct StripModel: Identifiable, Equatable {
    public var id: AircraftID
    public var callsign: String        // "ISL 212"
    public var typeLabel: String       // "LK72"
    public var phaseLabel: String      // "SHORT FINAL"
    public var tone: StripTone
    public var isArrival: Bool
    public var isSelected: Bool
    /// Projected interaction margin, whole seconds (Gap Arc, PRD §2.5).
    public var gapSeconds: Int?
    /// 0–1 countdown for time-sensitive states (holding in position, short final).
    public var urgency: Double?
    /// 0 (fresh) … 1 (max nag) delay tint (PRD delay ledger).
    public var delayLevel: Double

    public init(id: AircraftID, callsign: String, typeLabel: String, phaseLabel: String,
                tone: StripTone, isArrival: Bool, isSelected: Bool,
                gapSeconds: Int?, urgency: Double?, delayLevel: Double) {
        self.id = id; self.callsign = callsign; self.typeLabel = typeLabel
        self.phaseLabel = phaseLabel; self.tone = tone; self.isArrival = isArrival
        self.isSelected = isSelected; self.gapSeconds = gapSeconds
        self.urgency = urgency; self.delayLevel = delayLevel
    }
}

public struct VerbOption: Identifiable, Equatable {
    public enum Style { case standard, caution, save }
    public var id: String { command.label }
    public var command: Command
    public var style: Style
    /// Verb sets are FROZEN when the bloom opens (capsules never move or swap
    /// under a finger); commands that become illegal mid-open render disabled.
    public var enabled: Bool
    public init(command: Command, style: Style = .standard, enabled: Bool = true) {
        self.command = command; self.style = style; self.enabled = enabled
    }
}

public struct BloomModel: Equatable {
    public var aircraftID: AircraftID
    public var callsign: String
    /// Screen-space anchor (projected aircraft position), updated every frame.
    public var anchor: CGPoint
    public var verbs: [VerbOption]
    public init(aircraftID: AircraftID, callsign: String, anchor: CGPoint, verbs: [VerbOption]) {
        self.aircraftID = aircraftID; self.callsign = callsign
        self.anchor = anchor; self.verbs = verbs
    }
}

public struct BadgeToast: Identifiable, Equatable {
    public let id: UUID
    public var text: String            // "TIGHT GAP +500"
    public var isSave: Bool
    public var createdAt: Date
    public init(text: String, isSave: Bool) {
        self.id = UUID(); self.text = text; self.isSave = isSave; self.createdAt = Date()
    }
}

public struct RadioLine: Identifiable, Equatable {
    public let id: UUID
    public var speaker: String         // "TWR" or callsign
    public var text: String
    public var isTower: Bool
    public init(speaker: String, text: String, isTower: Bool) {
        self.id = UUID(); self.speaker = speaker; self.text = text; self.isTower = isTower
    }
}

public enum ScreenState: Equatable {
    case start
    case playing
    case score(ShiftReportBox)
}

/// Equatable box so ScreenState stays Equatable without ShiftReport conforming.
public struct ShiftReportBox: Equatable {
    public let report: ShiftReport
    private let stamp = UUID()
    public static func == (l: ShiftReportBox, r: ShiftReportBox) -> Bool { l.stamp == r.stamp }
    public init(_ report: ShiftReport) { self.report = report }
}

@MainActor
public final class UIState: ObservableObject {
    @Published public var screen: ScreenState = .start
    @Published public var strips: [StripModel] = []
    @Published public var bloom: BloomModel?
    @Published public var toasts: [BadgeToast] = []
    @Published public var radioLog: [RadioLine] = []
    @Published public var score: Int = 0
    @Published public var streakMultiplier: Int = 1
    @Published public var paused: Bool = false
    @Published public var shiftClock: String = "6:00"
    @Published public var shiftPhase: ShiftPhase = .ramp
    @Published public var windText: String = "240° 8G14"
    @Published public var localTimeText: String = "17:38"

    public weak var actions: GameActions?
    public init() {}
}
