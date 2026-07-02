import SwiftUI

// =============================================================================
// StripRail — flight-progress strips down the right edge (rail law: ≤9 shown,
// overflow collapses to a "+N MORE" chip). Strips must LEAVE satisfyingly:
// completed strips slide off to the right on a ≥60 pt swipe (handoff).
// =============================================================================

private enum Rail {
    static let stripWidth: CGFloat = 178
    static let stripHeight: CGFloat = 68
    static let maxVisible = 9
    static let handoffThreshold: CGFloat = 60
}

struct StripRailView: View {
    let strips: [StripModel]
    let actions: GameActions?

    var body: some View {
        let visible = Array(strips.prefix(Rail.maxVisible))
        let overflow = strips.count - visible.count
        VStack(spacing: 8) {
            ForEach(visible) { strip in
                StripCard(strip: strip, actions: actions)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            }
            if overflow > 0 {
                Text("+\(overflow) MORE")
                    .font(Theme.mono(15, .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.warmWhite.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .etchedGlass(cornerRadius: 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: strips)
    }
}

// MARK: - One strip

private struct StripCard: View {
    let strip: StripModel
    let actions: GameActions?
    @State private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: 9) {
            // Tone band — the strip's traffic-light edge.
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.toneColor(strip.tone))
                .frame(width: 4)
                .pulsing(strip.tone == .alarm, dimTo: 0.35, period: 0.55)
                .shadow(color: Theme.toneColor(strip.tone).opacity(strip.tone == .alarm ? 0.7 : 0.0),
                        radius: 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(strip.callsign)
                        .font(Theme.mono(16, .bold))
                        .foregroundStyle(Theme.warmWhite)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(strip.typeLabel)
                        .font(Theme.mono(15, .regular))
                        .foregroundStyle(Theme.warmWhite.opacity(0.55))
                }
                Text(strip.phaseLabel)
                    .font(Theme.display(15, .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.toneColor(strip.tone).opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let urgency = strip.urgency {
                    urgencyBar(urgency)
                }
            }

            if let gap = strip.gapSeconds {
                GapArc(seconds: gap, color: Theme.toneColor(strip.tone))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Rail.stripWidth, height: Rail.stripHeight)
        .etchedGlass(cornerRadius: 12,
                     strokeTint: strip.isSelected ? Theme.warmWhite : .white)
        .overlay {
            // Delay ledger — the card slowly warms toward amber as it waits.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.amber.opacity(0.13 * strip.delayLevel))
                .allowsHitTesting(false)
        }
        .overlay {
            if strip.isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.warmWhite.opacity(0.85), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(strip.isSelected ? 1.04 : 1.0)
        .offset(x: dragX)
        .opacity(1.0 - Double(dragX) / 420.0)
        .animation(Theme.springFast, value: strip.isSelected)
        .gesture(handoffSwipe)
        .gesture(taps)
    }

    private func urgencyBar(_ urgency: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Theme.toneColor(strip.tone).opacity(0.9))
                    .frame(width: geo.size.width * min(max(urgency, 0), 1))
                    .animation(.linear(duration: 0.25), value: urgency)
            }
        }
        .frame(height: 3)
    }

    private var taps: some Gesture {
        TapGesture(count: 2)
            .onEnded { actions?.stripDoubleTapped(strip.id) }
            .exclusively(before: TapGesture()
                .onEnded { actions?.stripTapped(strip.id) })
    }

    /// Rail hygiene: completed strips flick off to the right for handoff.
    /// Attached to every card but inert unless the strip is .complete.
    private var handoffSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard strip.tone == .complete else { return }
                dragX = max(0, value.translation.width)
            }
            .onEnded { value in
                guard strip.tone == .complete else { return }
                if value.translation.width >= Rail.handoffThreshold {
                    actions?.verbSelected(strip.id, command: .handoff)
                } else {
                    withAnimation(Theme.springFast) { dragX = 0 }
                }
            }
    }
}

// MARK: - Gap Arc (PRD §2.5 — the margin you can see)

private struct GapArc: View {
    let seconds: Int
    let color: Color
    /// Full ring at this margin or better; drains toward zero below it.
    private let fullScaleSeconds = 20.0

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: seconds)
            Text("\(seconds)")
                .font(Theme.mono(15, .bold))
                .foregroundStyle(color)
        }
        .frame(width: 36, height: 36)
    }

    private var fraction: Double { min(1, max(0.02, Double(seconds) / fullScaleSeconds)) }
}
