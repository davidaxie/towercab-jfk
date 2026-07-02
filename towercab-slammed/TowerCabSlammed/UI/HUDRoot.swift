import SwiftUI

// =============================================================================
// HUDRootView — composition of the whole HUD over the live SceneKit world.
// The postcard rule: the airfield is the star; chrome hugs the edges and only
// actual controls capture touches (camera gestures live underneath).
// =============================================================================

struct HUDRootView: View {
    @ObservedObject var state: UIState

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch state.screen {
                case .start:
                    StartScreenView(state: state)
                        .transition(.opacity)
                case .playing:
                    playingHUD(size: geo.size)
                        .transition(.opacity)
                case .score(let box):
                    ScoreScreenView(report: box.report, actions: state.actions)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.4), value: state.screen)
        }
    }

    // MARK: Playing layout — edges only, center stays clean.

    private func playingHUD(size: CGSize) -> some View {
        ZStack {
            TopBarView(state: state)
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            StripRailView(strips: state.strips, actions: state.actions)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            RadioLogView(lines: state.radioLog)
                .padding(.leading, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            ToastStackView(toasts: state.toasts)
                .padding(.top, 86)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let bloom = state.bloom {
                RadialBloomView(bloom: bloom, screenSize: size, actions: state.actions)
                    .id(bloom.aircraftID)   // re-run entrance per aircraft
            }
        }
    }
}
