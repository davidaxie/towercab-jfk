import SwiftUI

// =============================================================================
// StripRail — flight-progress strips down the right edge (rail law: ≤7 shown,
// overflow collapses to a "+N MORE" chip; alarms are always promoted into
// view). Strips must LEAVE satisfyingly: completed strips slide off to the
// right on a ≥60 pt swipe (handoff).
// =============================================================================

enum Rail {
    static let stripWidth: CGFloat = 224          // C13
    static let stripHeight: CGFloat = 68
    static let maxVisible = 7                     // C7
    static let handoffThreshold: CGFloat = 60
    /// Horizontal footprint the rail claims from the right screen edge
    /// (strip + trailing padding) — the bloom clamps against this (C19).
    static let screenFootprint: CGFloat = stripWidth + 24
}

struct StripRailView: View {
    let strips: [StripModel]
    let actions: GameActions?

    var body: some View {
        // C7 — severity promotion within the cap: alarm → attention → normal
        // → complete, stable order inside each class, so every alarm/attention
        // strip is guaranteed a slot before stale completes hog one.
        let ranked = [StripTone.alarm, .attention, .normal, .complete]
            .flatMap { tone in strips.filter { $0.tone == tone } }
        let visible = Array(ranked.prefix(Rail.maxVisible))
        let overflow = ranked.count - visible.count
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
            toneBand

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
                Text(shortPhase(strip.phaseLabel))
                    .font(Theme.display(15, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.toneColor(strip.tone).opacity(0.95))
                    .shadow(color: .black.opacity(0.55), radius: 1, y: 1)   // C25
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let urgency = strip.urgency {
                    urgencyBar(urgency)
                }
            }

            // C23 — the arc only appears once the margin is actually tight.
            if let gap = strip.gapSeconds, gap <= 30 {
                GapArc(seconds: min(gap, 99), color: Theme.toneColor(strip.tone))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Rail.stripWidth, height: Rail.stripHeight)
        .etchedGlass(cornerRadius: 12,
                     tintOpacity: 0.55,   // C25/D31 — darker plate for tone-text contrast
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
        // C22 — the drag recognizer only exists on complete strips; everywhere
        // else the rail is a pure tap zone (no dead pan capture).
        .gesture(handoffSwipe, including: strip.tone == .complete ? .all : .none)
        .gesture(tap)
        .accessibilityIdentifier("strip-\(strip.callsign)")
    }

    /// Tone band + C11 colorblind glyph under the bar.
    private var toneBand: some View {
        let tone = Theme.toneColor(strip.tone)
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tone)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .pulsing(strip.tone == .alarm, dimTo: 0.35, period: 0.55)
                .shadow(color: tone.opacity(strip.tone == .alarm ? 0.7 : 0.0), radius: 4)
            if let glyph = Theme.toneGlyph(strip.tone) {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tone)
            }
        }
        .frame(width: 14)
    }

    /// C13 — strip-scale phraseology: long phases get their rail short form.
    private func shortPhase(_ label: String) -> String {
        switch label {
        case "LINE UP & WAIT", "LINE UP AND WAIT": return "LINE UP"
        case "HOLDING SHORT": return "HOLD SHORT"
        default: return label
        }
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

    // C1 — single tap fires immediately (no double-tap disambiguation delay);
    // re-tapping the selected strip frames the camera in the VC.
    private var tap: some Gesture {
        TapGesture().onEnded { actions?.stripTapped(strip.id) }
    }

    /// Rail hygiene: completed strips flick off to the right for handoff.
    private var handoffSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                dragX = max(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width >= Rail.handoffThreshold {
                    actions?.verbSelected(strip.id, command: .handoff)
                }
                // C21 — always spring home; the removal transition covers success.
                withAnimation(Theme.springFast) { dragX = 0 }
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
