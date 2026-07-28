import SwiftUI

// =============================================================================
// TopBar — one slim etched-glass strip across the top.
// Left: pause + station + local time + wind. Center: shift clock + phase chip.
// Right: score + streak meter. Info blocks never capture touches; the pause
// glyph is the bar's only control (C12).
// =============================================================================

struct TopBarView: View {
    @ObservedObject var state: UIState
    @ObservedObject private var settings = GameSettings.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            pauseButton
            soundButton
            stationBlock.allowsHitTesting(false)
            Spacer(minLength: 12)
            scoreBlock.allowsHitTesting(false)
        }
        .overlay(clockBlock.allowsHitTesting(false))   // keeps the clock truly centered
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .etchedGlass(cornerRadius: 14)
        .frame(maxWidth: 960)
    }

    // MARK: Pause (C12 — PRD launch gate)

    private var pauseButton: some View {
        Button {
            state.actions?.togglePause()
        } label: {
            Image(systemName: state.paused ? "play.fill" : "pause.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.warmWhite.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("pauseButton")
    }

    // MARK: Sound (persisted; off by default while audio is programmer-synth)

    private var soundButton: some View {
        Button {
            settings.soundEnabled.toggle()
        } label: {
            Image(systemName: settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.warmWhite.opacity(settings.soundEnabled ? 0.85 : 0.45))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("soundButton")
        .accessibilityLabel(settings.soundEnabled ? "Sound on" : "Sound off")
    }

    // MARK: Left — station identity

    private var stationBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("KJFK · NEW YORK")
                .font(Theme.display(15, .semibold))
                .tracking(2.2)
                .foregroundStyle(Theme.warmWhite.opacity(0.88))
            HStack(spacing: 8) {
                Text(state.localTimeText)
                Text("·").opacity(0.4)
                Text(state.windText)
            }
            .font(Theme.mono(15, .medium))
            .foregroundStyle(Theme.warmWhite.opacity(0.62))
        }
    }

    // MARK: Center — shift clock + phase

    private var clockBlock: some View {
        HStack(spacing: 12) {
            Text(state.shiftClock)
                .font(Theme.mono(28, .bold))
                .foregroundStyle(Theme.warmWhite)
                .contentTransition(.numericText(countsDown: true))
                .animation(Theme.springFast, value: state.shiftClock)
                .opacity(state.paused ? 0.35 : 1.0)   // C12 — held breath, not alarm
            if state.paused { pausedChip } else { phaseChip }
        }
        .animation(Theme.springFast, value: state.paused)
    }

    private var pausedChip: some View {
        Text("PAUSED")
            .font(Theme.display(15, .heavy))
            .tracking(1.8)
            .foregroundStyle(Theme.warmWhite.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.white.opacity(0.10))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            )
            .transition(.opacity)
    }

    @ViewBuilder private var phaseChip: some View {
        let (label, color): (String, Color) = {
            switch state.shiftPhase {
            case .ramp:      return ("RAMP", Theme.warmWhite.opacity(0.65))
            case .crescendo: return ("SLAMMED", Theme.amber)
            case .cooldown:  return ("COOLDOWN", Theme.coolSteel)
            case .ended:     return ("ENDED", Theme.warmWhite.opacity(0.45))
            }
        }()
        Text(label)
            .font(Theme.display(15, .heavy))
            .tracking(1.8)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.14))
                    .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
            )
            .pulsing(state.shiftPhase == .crescendo, dimTo: 0.55, period: 0.8)
            .animation(Theme.spring, value: state.shiftPhase)
    }

    // MARK: Right — score + streak

    private var scoreBlock: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(state.score)")
                .font(Theme.mono(26, .bold))
                .foregroundStyle(Theme.amber)
                .contentTransition(.numericText(value: Double(state.score)))
                .animation(Theme.spring, value: state.score)
                .shadow(color: Theme.amber.opacity(0.35), radius: 6)
            streakMeter
        }
    }

    private var streakMeter: some View {
        HStack(spacing: 6) {
            Text("×\(state.streakMultiplier)")
                .font(Theme.display(15, .heavy))
                .foregroundStyle(state.streakMultiplier > 1 ? Theme.amber : Theme.warmWhite.opacity(0.5))
            HStack(spacing: 2.5) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < min(state.streakMultiplier, 8)
                              ? Theme.amber
                              : Color.white.opacity(0.14))
                        .frame(width: 8, height: 4)
                }
            }
            .animation(Theme.springFast, value: state.streakMultiplier)
        }
    }
}
