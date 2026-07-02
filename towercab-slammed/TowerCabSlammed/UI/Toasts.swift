import SwiftUI

// =============================================================================
// Toasts — badge stamps blooming upper-center: gold for points, teal for
// SAVEs, desaturated red for penalties. UIState prunes after 2.6 s; we just
// make the arrival and departure feel minted.
// =============================================================================

struct ToastStackView: View {
    let toasts: [BadgeToast]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(toasts) { toast in
                ToastStamp(toast: toast)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .toastLift))
            }
        }
        .animation(Theme.spring, value: toasts)
        .allowsHitTesting(false)
    }
}

private struct ToastStamp: View {
    let toast: BadgeToast

    var body: some View {
        HStack(spacing: 8) {
            if toast.isSave {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            Text(toast.text)
                .font(Theme.display(21, .heavy))
                .tracking(2.6)
        }
        .foregroundStyle(color)
        .shadow(color: color.opacity(0.55), radius: 9)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    private var color: Color {
        if toast.isSave { return Theme.teal }
        if isPenalty { return Theme.penalty }
        return Theme.amber
    }

    /// Badge texts carry "+"; penalties carry a minus ("PILOT'S CALL −2000").
    private var isPenalty: Bool {
        toast.text.contains("−") || toast.text.range(of: #"-\d"#, options: .regularExpression) != nil
    }
}

// MARK: - Fade-up-and-out removal

private struct ToastLiftModifier: ViewModifier {
    let lifted: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: lifted ? -26 : 0)
            .opacity(lifted ? 0 : 1)
    }
}

private extension AnyTransition {
    static var toastLift: AnyTransition {
        .modifier(active: ToastLiftModifier(lifted: true),
                  identity: ToastLiftModifier(lifted: false))
    }
}
