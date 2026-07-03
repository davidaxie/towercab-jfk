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
    static let capsuleHalfHeight: CGFloat = 27
    static let chipLift: CGFloat = 48     // callsign chip sits this far above the ring
    /// C27 — drag-off distance that arms a caution verb.
    static let cautionConfirmDistance: CGFloat = 24
}

struct RadialBloomView: View {
    let bloom: BloomModel
    let screenSize: CGSize
    /// Width the strip rail occupies at the right edge (0 when rail empty) — C19.
    var railInset: CGFloat = 0
    let actions: GameActions?
    @State private var appeared = false

    var body: some View {
        let anchor = clampedAnchor
        // C5 — capsule positions derive from the FROZEN verb array order the VC
        // captured at bloom-open; never re-sorted, so nothing swaps under a finger.
        let verbs = Array(bloom.verbs.prefix(6))
        ZStack {
            ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
                let angle = angleFor(index: index, count: verbs.count)
                let r = Bloom.radius * (appeared ? 1.0 : 0.72)
                VerbButton(verb: verb) {
                    actions?.verbSelected(bloom.aircraftID, command: verb.command)
                }
                // C5 — commands that became illegal mid-open dim and go inert.
                .opacity(verb.enabled ? 1.0 : 0.4)
                .allowsHitTesting(verb.enabled)
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

    /// Keep the entire bloom (ring + chip + capsule extents) on screen, and
    /// clear of the strip rail on the right (C19).
    private var clampedAnchor: CGPoint {
        let mx = Bloom.radius + Bloom.capsuleHalfWidth + 8
        let myTop = Bloom.radius + Bloom.chipLift + Bloom.capsuleHalfHeight + 12
        let myBottom = Bloom.radius + Bloom.capsuleHalfHeight + 12
        guard screenSize.width > mx * 2 + railInset, screenSize.height > myTop + myBottom else {
            return CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        }
        return CGPoint(
            x: min(max(bloom.anchor.x, mx), screenSize.width - railInset - mx),
            y: min(max(bloom.anchor.y, myTop), screenSize.height - myBottom))
    }
}

// MARK: - Verb capsule

private struct VerbButton: View {
    let verb: VerbOption
    let action: () -> Void
    @State private var stretch: CGSize = .zero

    /// C27 — IMMEDIATE TAKEOFF is the only flick-confirm verb; GO AROUND,
    /// HOLD and every other command stays an instant tap.
    private var requiresDragConfirm: Bool {
        verb.style == .caution && verb.command == .clearedForTakeoff(immediate: true)
    }

    var body: some View {
        Group {
            if requiresDragConfirm {
                label
                    .offset(x: stretch.width, y: stretch.height)
                    .gesture(dragConfirm)
            } else {
                Button(action: action) { label }
                    .buttonStyle(BloomButtonStyle())
            }
        }
        .accessibilityIdentifier("verb-\(verb.command.label)")
    }

    private var label: some View {
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
        .padding(.vertical, 14)                              // C10 — 44 pt+ capsule
        .etchedGlass(cornerRadius: 24, strokeTint: strokeTint)
        .contentShape(Rectangle().inset(by: -6))             // C10 — ≥48 pt hit target
    }

    /// C27 — caution verbs arm by dragging the capsule off its seat ≥24 pt;
    /// releasing short springs it home un-fired.
    private var dragConfirm: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let d = hypot(value.translation.width, value.translation.height)
                let clamp = min(d, 44) / max(d, 0.001)       // visual stretch, capped
                stretch = CGSize(width: value.translation.width * clamp * 0.8,
                                 height: value.translation.height * clamp * 0.8)
            }
            .onEnded { value in
                let d = hypot(value.translation.width, value.translation.height)
                if d >= Bloom.cautionConfirmDistance { action() }
                withAnimation(Theme.springFast) { stretch = .zero }
            }
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
