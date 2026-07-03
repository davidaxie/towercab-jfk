import SwiftUI

// =============================================================================
// RadioLog — the last few exchanges floating bottom-left over the world.
// Tower amber, pilots warm white, history fading with age. No box: just a
// whisper of gradient for legibility.
// =============================================================================

struct RadioLogView: View {
    let lines: [RadioLine]
    // C24 — keep 8 lines and dim the oldest instead of dropping at 5.
    private let maxLines = 8

    var body: some View {
        let shown = Array(lines.suffix(maxLines))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                logLine(line)
                    .opacity(ageOpacity(index: index, count: shown.count))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 500, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.32), Color.black.opacity(0.0)],
                startPoint: .bottomLeading, endPoint: .topTrailing)
            .blur(radius: 8)
            .padding(-10)
        }
        .animation(Theme.spring, value: lines)
        .allowsHitTesting(false)
    }

    private func logLine(_ line: RadioLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.speaker)
                .font(Theme.mono(15, .bold))
                .foregroundStyle(line.isTower ? Theme.amber : Theme.warmWhite.opacity(0.75))
            Text(line.text)
                .font(Theme.mono(15, .medium))
                .foregroundStyle(line.isTower ? Theme.amber.opacity(0.92) : Theme.warmWhite)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
    }

    /// C24 — the 5 newest lines read at full strength; older history dims in
    /// steps toward 35% (oldest of 8 = 35, then 45, then 55).
    private func ageOpacity(index: Int, count: Int) -> Double {
        let dimmedCount = max(0, count - 5)
        guard index < dimmedCount else { return 1.0 }
        return 0.55 - 0.10 * Double(dimmedCount - 1 - index)
    }
}
