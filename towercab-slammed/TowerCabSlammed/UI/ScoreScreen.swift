import SwiftUI

// =============================================================================
// ScoreScreen — the run's payoff. Grade stamp, counting score, staggered axis
// bars, badge tally, and one tap back into the next shift (pillar 1).
// =============================================================================

struct ScoreScreenView: View {
    let report: ShiftReport
    let actions: GameActions?

    @State private var displayScore = 0
    @State private var gradeLanded = false
    @State private var barsRevealed = false
    @State private var detailsRevealed = false

    var body: some View {
        ZStack {
            // Warm dark scrim — post-play, allowed to own the touch plane.
            Color(red: 0.09, green: 0.055, blue: 0.04).opacity(0.74)
                .ignoresSafeArea()

            // C3/D33 — compact card: bounded height, no stretched dead space.
            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 32) {
                    gradeColumn
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 232)   // C3 — divider never drives height
                    detailColumn
                }
                buttonRow
                    .opacity(detailsRevealed ? 1 : 0)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            .etchedGlass(cornerRadius: 22, tintOpacity: 0.55)
        }
        .onAppear(perform: runEntrance)
        .task { await countUp() }
    }

    // MARK: Entrance choreography

    private func runEntrance() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.68).delay(0.1)) {
            gradeLanded = true
        }
        withAnimation(Theme.spring.delay(0.45)) { barsRevealed = true }
        withAnimation(Theme.spring.delay(0.8)) { detailsRevealed = true }
    }

    private func countUp() async {
        let target = report.totalScore
        guard target != 0 else { return }
        let steps = 45
        for i in 1...steps {
            try? await Task.sleep(nanoseconds: 26_000_000)
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)   // ease-out cubic
            displayScore = Int(Double(target) * eased)
        }
        displayScore = target
    }

    // MARK: Grade + score

    private var gradeColumn: some View {
        VStack(spacing: 8) {
            Text(report.grade.rawValue)
                .font(.system(size: 132, weight: .black, design: .rounded))
                .foregroundStyle(gradeStyle)
                .shadow(color: Theme.amber.opacity(gradeGlowOpacity), radius: 18)
                .scaleEffect(gradeLanded ? 1.0 : 1.55)
                .opacity(gradeLanded ? 1.0 : 0.0)

            Text("\(displayScore)")
                .font(Theme.mono(34, .bold))
                .foregroundStyle(Theme.amber)
                .contentTransition(.numericText(value: Double(displayScore)))
                .animation(.linear(duration: 0.05), value: displayScore)

            Text("TOTAL SCORE")
                .font(Theme.display(15, .semibold))
                .tracking(2.5)
                .foregroundStyle(Theme.warmWhite.opacity(0.55))
        }
        .frame(minWidth: 190)
    }

    // C4/D33 — every grade gets the amber/gold stamp treatment; lower grades
    // deepen toward bronze but never fall out of the palette into grey.
    private var gradeStyle: LinearGradient {
        let colors: [Color]
        switch report.grade {
        case .s:
            // Gold foil — highlight sweep through the amber.
            colors = [Color(red: 1.0, green: 0.92, blue: 0.62), Theme.amber, Theme.amberDeep]
        case .a:
            colors = [Theme.amber, Theme.amberDeep]
        case .b:
            colors = [Theme.amber.opacity(0.95), Theme.amberDeep]
        case .c:
            colors = [Theme.amberDeep, Color(red: 0.62, green: 0.37, blue: 0.09)]
        case .d:
            colors = [Color(red: 0.68, green: 0.40, blue: 0.11), Color(red: 0.48, green: 0.28, blue: 0.08)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var gradeGlowOpacity: Double {
        switch report.grade {
        case .s: return 0.5
        case .a: return 0.42
        case .b: return 0.32
        case .c: return 0.24
        case .d: return 0.18
        }
    }

    // MARK: Right column — axes, badges, stats, quote

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            axisBars
            if !report.badges.isEmpty {
                badgeChips.opacity(detailsRevealed ? 1 : 0)
            }
            statsRow.opacity(detailsRevealed ? 1 : 0)
            if !report.bestMoment.isEmpty {
                Text("“\(report.bestMoment)”")
                    .font(Theme.display(15, .medium))
                    .italic()
                    .foregroundStyle(Theme.warmWhite.opacity(0.66))
                    .lineLimit(2)
                    .opacity(detailsRevealed ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var axes: [(String, Int)] {
        [("FLOW", report.flow), ("PRECISION", report.precision),
         ("COOL", report.cool), ("FREQUENCY", report.frequency)]
    }

    private var axisBars: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(axes.enumerated()), id: \.offset) { index, axis in
                HStack(spacing: 12) {
                    Text(axis.0)
                        .font(Theme.mono(15, .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.warmWhite.opacity(0.75))
                        .frame(width: 118, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule()
                                .fill(Theme.amber)
                                .frame(width: barsRevealed
                                       ? geo.size.width * CGFloat(min(max(axis.1, 0), 100)) / 100
                                       : 0)
                                .animation(Theme.spring.delay(0.45 + Double(index) * 0.12),
                                           value: barsRevealed)
                        }
                    }
                    .frame(height: 8)
                    Text("\(axis.1)")
                        .font(Theme.mono(15, .bold))
                        .foregroundStyle(Theme.amber.opacity(0.9))
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private struct BadgeTally: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
        var chipText: String { count > 1 ? "\(label) ×\(count)" : label }
        var isSave: Bool { label.contains("SAVE") }
    }

    private var badgeTally: [BadgeTally] {
        let groups = Dictionary(grouping: report.badges) { $0.badge.label }
        let entries = groups.map { BadgeTally(label: $0.key, count: $0.value.count) }
        return entries.sorted { a, b in
            a.count == b.count ? a.label < b.label : a.count > b.count
        }
    }

    // C14 — chips wrap in an adaptive grid, capped at 8 with a "+N" tail chip.
    private var badgeChips: some View {
        let shown = Array(badgeTally.prefix(8))
        let extra = badgeTally.count - shown.count
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 128), spacing: 8, alignment: .leading)],
            alignment: .leading, spacing: 8
        ) {
            ForEach(shown) { entry in
                chip(entry.chipText, tint: entry.isSave ? Theme.teal : Theme.amber)
            }
            if extra > 0 {
                chip("+\(extra)", tint: Theme.warmWhite.opacity(0.7))
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        HStack {
            Text(text)
                .font(Theme.display(15, .bold))
                .tracking(1.0)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(0.07))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                )
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {   // C4 — labels never wrap mid-word
            stat("\(report.landings)", "LANDED")
            stat("\(report.departures)", "DEPARTED")
            stat("×\(report.bestStreak)", "BEST STREAK")
            stat(String(format: "%.0fs", report.averageDelaySeconds), "AVG DELAY")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.mono(20, .bold))
                .foregroundStyle(Theme.warmWhite)
            Text(label)
                .font(Theme.display(15, .semibold))
                .tracking(0.8)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Theme.warmWhite.opacity(0.48))
        }
    }

    // MARK: Buttons

    private var buttonRow: some View {
        HStack(spacing: 22) {
            Button {
                actions?.startShift()
            } label: {
                Text("NEXT SHIFT")
                    .font(Theme.display(18, .heavy))
                    .tracking(2.6)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 12)
                    .background {
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.amber, Theme.amberDeep],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                            .shadow(color: Theme.amber.opacity(0.45), radius: 12, y: 3)
                    }
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityIdentifier("nextShift")

            Button {
                actions?.restartShift()
            } label: {
                Text("RESTART SAME SEED")
                    .font(Theme.display(15, .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Theme.warmWhite.opacity(0.6))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(PressScaleButtonStyle())
        }
    }
}
