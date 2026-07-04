import SwiftUI

// =============================================================================
// StartScreen — cinematic title treatment over the live golden-hour diorama.
// Pre-play, so this screen is allowed to own the touch plane.
// =============================================================================

struct StartScreenView: View {
    @ObservedObject var state: UIState
    @State private var revealed = false

    var body: some View {
        ZStack {
            vignette

            VStack(spacing: 26) {
                Spacer()

                titleBlock
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 18)

                locationCard
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 14)

                Text("GOLDEN HOUR · RWY 22 · WIND \(state.windText)")
                    .font(Theme.mono(15, .medium))
                    .tracking(2.0)
                    .foregroundStyle(Theme.warmWhite.opacity(0.7))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .opacity(revealed ? 1 : 0)

                Spacer()

                startButton
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 12)

                Spacer().frame(height: 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9).delay(0.15)) {
                revealed = true
            }
        }
    }

    // Soft edge scrim — keeps the diorama the hero while seating the type.
    private var vignette: some View {
        ZStack {
            RadialGradient(
                colors: [Color.black.opacity(0.0), Color(red: 0.07, green: 0.04, blue: 0.03).opacity(0.62)],
                center: .center, startRadius: 220, endRadius: 950)
            LinearGradient(
                colors: [Color.black.opacity(0.35), .clear, Color.black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Text("TOWERCAB")
                .font(.system(size: 62, weight: .heavy, design: .rounded))
                .tracking(20)
                .foregroundStyle(Theme.warmWhite)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 3)
                // .tracking pads the trailing edge too; nudge back to optical center.
                .offset(x: 10)

            Text("SLAMMED")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .tracking(9)
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.amber.opacity(0.9), lineWidth: 3)
                }
                .rotationEffect(.degrees(-2.5))
                .shadow(color: Theme.amber.opacity(0.35), radius: 12)
                .offset(x: 4)
        }
    }

    private var locationCard: some View {
        VStack(spacing: 6) {
            Text("KJFK — JOHN F. KENNEDY INTL")
                .font(Theme.display(17, .bold))
                .tracking(2.4)
                .foregroundStyle(Theme.warmWhite.opacity(0.92))
            Text("“The world lands here.”")
                .font(Theme.display(15, .medium))
                .italic()
                .foregroundStyle(Theme.warmWhite.opacity(0.62))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .etchedGlass(cornerRadius: 14)
    }

    private var startButton: some View {
        Button {
            state.actions?.startShift()
        } label: {
            Text("START SHIFT")
                .font(Theme.display(21, .heavy))
                .tracking(3.2)
                .foregroundStyle(.black)
                .padding(.horizontal, 44)
                .padding(.vertical, 15)
                .background {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.amber, Theme.amberDeep],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                        .shadow(color: Theme.amber.opacity(0.5), radius: 16, y: 4)
                }
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("startShift")
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
