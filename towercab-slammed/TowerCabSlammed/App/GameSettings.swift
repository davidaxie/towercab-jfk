import Foundation
import SwiftUI

// =============================================================================
// GameSettings — persisted player preferences.
//
// Deliberately tiny and boring: one observable object, backed by UserDefaults,
// read by the HUD and the audio layer. Add a stored property + a key and it
// persists; nothing else needs to know.
//
// Audio note: the slice's soundscape is programmer-synthesized (see Audio/,
// PRD §5 budgets a contract audio designer + neural-TTS pilot voices to replace
// it), so sound ships **off by default** until real audio lands. `soundEnabled`
// is the single switch: when it is off the AVAudioEngine is never started at
// all, rather than started and muted — no audio session, no render thread, no
// battery cost. Silent play is full parity by design (PRD: the game must be
// completely playable with no sound).
// =============================================================================

@MainActor
public final class GameSettings: ObservableObject {

    public static let shared = GameSettings()

    private enum Key {
        static let soundEnabled = "settings.soundEnabled"
    }

    /// Master sound switch. Defaults to OFF while the soundscape is programmer
    /// audio. Writing it persists immediately and notifies observers.
    @Published public var soundEnabled: Bool {
        didSet {
            guard oldValue != soundEnabled else { return }
            defaults.set(soundEnabled, forKey: Key.soundEnabled)
            onSoundEnabledChanged?(soundEnabled)
        }
    }

    /// Set by the game controller so a toggle takes effect immediately —
    /// starting or tearing down the audio engine without a restart.
    public var onSoundEnabledChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` distinguishes "never set" from "set to false", so
        // the default only applies on a fresh install.
        if let stored = defaults.object(forKey: Key.soundEnabled) as? Bool {
            soundEnabled = stored
        } else {
            soundEnabled = false
        }
    }
}
