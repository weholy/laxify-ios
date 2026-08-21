import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var isSearchPresented = false
    @State private var isPlayerPresented = false
    var router = DeepLinkRouter.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            LaxifyPalette.background.ignoresSafeArea()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                MiniPlayerBar {
                    isPlayerPresented = true
                }

                LaxifyTabBar(selectedTab: $selectedTab) {
                    isSearchPresented = true
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, LaxifyMetrics.tabBarBottomInset)
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchView()
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            FullPlayerView()
        }
        .fullScreenCover(isPresented: Binding(
            get: { router.pendingArtistId != nil },
            set: { if !$0 { router.pendingArtistId = nil } }
        )) {
            if let artistId = router.pendingArtistId {
                ArtistView(artistId: artistId)
            }
        }
        .fullScreenCover(item: Binding(
            get: { router.pendingAlbum },
            set: { router.pendingAlbum = $0 }
        )) { album in
            AlbumDetailView(album: album)
        }
        .fullScreenCover(item: Binding(
            get: { router.pendingCollection },
            set: { router.pendingCollection = $0 }
        )) { collection in
            PlaylistDetailView(collection: collection)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            HomeView()
        case .favorites:
            FavoritesView()
        case .profile:
            ProfileView()
        }
    }
}

#Preview {
    RootView()
}
