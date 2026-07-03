import SwiftUI

// =============================================================================
// Theme — "etched glass in a warm cab at dusk".
// Single source of truth for the HUD palette, type ramp, glass treatment and
// the two sanctioned looping pulses (SLAMMED chip, red-band alarm).
// =============================================================================

enum Theme {
    // MARK: Palette
    static let amber     = Color(red: 1.00, green: 0.69, blue: 0.24)   // #FFB13D — score, streak, badges
    static let amberDeep = Color(red: 0.82, green: 0.50, blue: 0.10)
    static let teal      = Color(red: 0.36, green: 0.86, blue: 0.73)   // SAVE energy
    static let sage      = Color(red: 0.64, green: 0.79, blue: 0.55)   // normal band
    static let alarm     = Color(red: 1.00, green: 0.30, blue: 0.26)   // red band ONLY
    static let penalty   = Color(red: 0.84, green: 0.44, blue: 0.42)   // desaturated red, toasts
    static let warmWhite = Color(red: 0.99, green: 0.96, blue: 0.90)
    static let coolSteel = Color(red: 0.70, green: 0.78, blue: 0.83)   // cooldown / silver
    static let smoke     = Color(red: 0.10, green: 0.075, blue: 0.055) // warm smoked tint

    // MARK: Type ramp (PRD law: nothing below 15 pt)
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: max(15, size), weight: weight, design: .rounded)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: max(15, size), weight: weight, design: .monospaced)
    }

    // MARK: Motion
    static let spring = Animation.spring(response: 0.30, dampingFraction: 0.84)
    static let springFast = Animation.spring(response: 0.25, dampingFraction: 0.86)

    // D31: green is reserved for cleared/complete states only — a normal strip
    // reads warm paper, so the rail sits in the amber family until it earns green.
    static func toneColor(_ tone: StripTone) -> Color {
        switch tone {
        case .normal: return warmWhite
        case .attention: return amber
        case .alarm: return alarm
        case .complete: return sage
        }
    }

    /// C11 — colorblind redundancy: every non-normal tone pairs its hue with a glyph.
    static func toneGlyph(_ tone: StripTone) -> String? {
        switch tone {
        case .normal: return nil
        case .attention: return "exclamationmark"
        case .alarm: return "triangle.fill"
        case .complete: return "checkmark"
        }
    }
}

// MARK: - Etched glass surface

struct EtchedGlass: ViewModifier {
    var cornerRadius: CGFloat = 12
    var tintOpacity: Double = 0.42
    var strokeTint: Color = .white

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Theme.smoke.opacity(tintOpacity)))
                    .overlay {
                        // Top-lit 1 px hairline — the "etched" edge.
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [strokeTint.opacity(0.38), strokeTint.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            }
    }
}

extension View {
    func etchedGlass(cornerRadius: CGFloat = 12, tintOpacity: Double = 0.42,
                     strokeTint: Color = .white) -> some View {
        modifier(EtchedGlass(cornerRadius: cornerRadius, tintOpacity: tintOpacity,
                             strokeTint: strokeTint))
    }
}

// MARK: - Sanctioned looping pulse (SLAMMED chip + red-band alarm only)

struct PulseEffect: ViewModifier {
    var active: Bool
    var dimTo: Double = 0.5
    var period: Double = 0.7
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dimmed ? dimTo : 1.0)
            .onAppear { restart() }
            .onChange(of: active) { restart() }
    }

    private func restart() {
        guard active else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dimmed = false }
            return
        }
        dimmed = false
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

extension View {
    func pulsing(_ active: Bool, dimTo: Double = 0.5, period: Double = 0.7) -> some View {
        modifier(PulseEffect(active: active, dimTo: dimTo, period: period))
    }
}
