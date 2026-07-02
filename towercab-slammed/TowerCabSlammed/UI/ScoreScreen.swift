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

            VStack(spacing: 22) {
                HStack(alignment: .top, spacing: 36) {
                    gradeColumn
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1)
                        .padding(.vertical, 8)
                    detailColumn
                }
                buttonRow
                    .opacity(detailsRevealed ? 1 : 0)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: 760)
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
                .shadow(color: gradeGlow.opacity(0.5), radius: 18)
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

    private var gradeStyle: LinearGradient {
        let colors: [Color]
        switch report.grade {
        case .s:
            // Gold foil — highlight sweep through the amber.
            colors = [Color(red: 1.0, green: 0.92, blue: 0.62), Theme.amber, Theme.amberDeep]
        case .a:
            colors = [Theme.amber, Theme.amberDeep]
        case .b:
            colors = [Color.white.opacity(0.95), Theme.coolSteel]
        case .c, .d:
            colors = [Color.white.opacity(0.6), Color.white.opacity(0.35)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var gradeGlow: Color {
        switch report.grade {
        case .s, .a: return Theme.amber
        case .b: return Theme.coolSteel
        case .c, .d: return .clear
        }
    }

    // MARK: Right column — axes, badges, stats, quote

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
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

    private var badgeChips: some View {
        HStack(spacing: 8) {
            ForEach(badgeTally) { entry in
                Text(entry.chipText)
                    .font(Theme.display(15, .bold))
                    .tracking(1.0)
                    .foregroundStyle(entry.isSave ? Theme.teal : Theme.amber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.white.opacity(0.07))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    )
                    .lineLimit(1)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 26) {
            stat("\(report.landings)", "LANDINGS")
            stat("\(report.departures)", "DEPARTURES")
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
                .tracking(1.4)
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
