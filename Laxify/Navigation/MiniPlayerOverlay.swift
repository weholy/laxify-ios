import SwiftUI

struct MiniPlayerOverlay: ViewModifier {
    @State private var isPlayerPresented = false
    @Namespace private var playerZoom

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            MiniPlayerBar(zoomNamespace: playerZoom) {
                isPlayerPresented = true
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 12)
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            FullPlayerView { isPlayerPresented = false }
                .navigationTransition(.zoom(sourceID: MiniPlayerBar.zoomID, in: playerZoom))
        }
    }
}

extension View {
    func withMiniPlayer() -> some View {
        modifier(MiniPlayerOverlay())
    }
}
