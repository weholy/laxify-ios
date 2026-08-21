import SwiftUI

struct MiniPlayerOverlay: ViewModifier {
    @State private var isPlayerPresented = false

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            MiniPlayerBar {
                isPlayerPresented = true
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 12)
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            FullPlayerView()
        }
    }
}

extension View {
    func withMiniPlayer() -> some View {
        modifier(MiniPlayerOverlay())
    }
}
