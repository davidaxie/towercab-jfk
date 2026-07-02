import SwiftUI

// =============================================================================
// RadialBloom — verb capsules blooming around a tapped aircraft's projected
// screen position. No backdrop, no tap-catcher: the world stays live beneath;
// tapping empty world dismisses via the 3D layer.
// =============================================================================

private enum Bloom {
    static let radius: CGFloat = 118
    /// Half-extent of the widest verb capsule — used to clamp on-screen.
    static let capsuleHalfWidth: CGFloat = 88
    static let capsuleHalfHeight: CGFloat = 24
    static let chipLift: CGFloat = 48     // callsign chip sits this far above the ring
}

struct RadialBloomView: View {
    let bloom: BloomModel
    let screenSize: CGSize
    let actions: GameActions?
    @State private var appeared = false

    var body: some View {
        let anchor = clampedAnchor
        let verbs = Array(bloom.verbs.prefix(6))
        ZStack {
            ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
                let angle = angleFor(index: index, count: verbs.count)
                let r = Bloom.radius * (appeared ? 1.0 : 0.72)
                VerbButton(verb: verb) {
                    actions?.verbSelected(bloom.aircraftID, command: verb.command)
                }
                .scaleEffect(appeared ? 1.0 : 0.85)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(Theme.springFast.delay(Double(index) * 0.03), value: appeared)
                .position(x: anchor.x + r * cos(angle),
                          y: anchor.y + r * sin(angle))
            }

            // Callsign chip crowning the ring.
            Text(bloom.callsign)
                .font(Theme.mono(16, .bold))
                .tracking(1.0)
                .foregroundStyle(Theme.warmWhite)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .etchedGlass(cornerRadius: 10)
                .scaleEffect(appeared ? 1.0 : 0.85)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(Theme.springFast, value: appeared)
                .position(x: anchor.x, y: anchor.y - Bloom.radius - Bloom.chipLift)
                .allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appeared = true }
        }
    }

    /// Verbs start at 12 o'clock and distribute evenly; screen +y is down,
    /// so 12 o'clock is -π/2.
    private func angleFor(index: Int, count: Int) -> CGFloat {
        let step = 2 * CGFloat.pi / CGFloat(max(count, 1))
        return -CGFloat.pi / 2 + step * CGFloat(index)
    }

    /// Keep the entire bloom (ring + chip + capsule extents) on screen.
    private var clampedAnchor: CGPoint {
        let mx = Bloom.radius + Bloom.capsuleHalfWidth + 8
        let myTop = Bloom.radius + Bloom.chipLift + Bloom.capsuleHalfHeight + 12
        let myBottom = Bloom.radius + Bloom.capsuleHalfHeight + 12
        guard screenSize.width > mx * 2, screenSize.height > myTop + myBottom else {
            return CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        }
        return CGPoint(
            x: min(max(bloom.anchor.x, mx), screenSize.width - mx),
            y: min(max(bloom.anchor.y, myTop), screenSize.height - myBottom))
    }
}

// MARK: - Verb capsule

private struct VerbButton: View {
    let verb: VerbOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                Text(shortLabel)
                    .font(Theme.display(15, .bold))
                    .tracking(1.1)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .etchedGlass(cornerRadius: 22, strokeTint: strokeTint)
        }
        .buttonStyle(BloomButtonStyle())
    }

    private var tint: Color {
        switch verb.style {
        case .standard: return Theme.warmWhite
        case .caution: return Theme.amber
        case .save: return Theme.teal
        }
    }

    private var strokeTint: Color {
        switch verb.style {
        case .standard: return .white
        case .caution: return Theme.amber
        case .save: return Theme.teal
        }
    }

    private var iconName: String {
        switch verb.command {
        case .clearedToLand: return "airplane.arrival"
        case .goAround: return "arrow.uturn.up"
        case .extendDownwind: return "arrow.up.right"
        case .make360(let left): return left ? "rotate.left" : "rotate.right"
        case .lineUpAndWait: return "rectangle.and.arrow.up.right"
        case .clearedForTakeoff(let immediate): return immediate ? "hare" : "airplane.departure"
        case .holdPosition: return "hand.raised"
        case .continueTaxi: return "play"
        case .expediteExit: return "hare"
        case .handoff: return "checkmark.seal"
        }
    }

    /// Tight bloom labels; the radio log speaks the full phraseology.
    private var shortLabel: String {
        switch verb.command {
        case .clearedToLand: return "LAND"
        case .goAround: return "GO AROUND"
        case .extendDownwind: return "EXTEND"
        case .make360(let left): return left ? "360 LEFT" : "360 RIGHT"
        case .lineUpAndWait: return "LUAW"
        case .clearedForTakeoff(let immediate): return immediate ? "IMMEDIATE" : "TAKEOFF"
        case .holdPosition: return "HOLD"
        case .continueTaxi: return "CONTINUE"
        case .expediteExit: return "EXPEDITE"
        case .handoff: return "HANDOFF"
        }
    }
}

private struct BloomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
