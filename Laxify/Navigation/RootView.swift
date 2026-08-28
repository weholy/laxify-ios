import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var isSearchPresented = false
    @State private var isPlayerPresented = false
    @Namespace private var playerZoom
    var router = DeepLinkRouter.shared
    var announcements = AnnouncementService.shared
    var appearance = AppearanceSettings.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            LaxifyPalette.background.ignoresSafeArea()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                if appearance.needsRestart {
                    RestartBanner()
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                }

                MiniPlayerBar(zoomNamespace: playerZoom) {
                    isPlayerPresented = true
                }

                LaxifyTabBar(selectedTab: $selectedTab) {
                    isSearchPresented = true
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, LaxifyMetrics.tabBarBottomInset)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appearance.needsRestart)
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchView { isSearchPresented = false }
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            FullPlayerView { isPlayerPresented = false }
                .navigationTransition(.zoom(sourceID: MiniPlayerBar.zoomID, in: playerZoom))
        }
        .fullScreenCover(isPresented: Binding(
            get: { router.pendingArtistId != nil },
            set: { if !$0 { router.pendingArtistId = nil } }
        )) {
            if let artistId = router.pendingArtistId {
                ArtistView(artistId: artistId) { router.pendingArtistId = nil }
            }
        }
        .fullScreenCover(item: Binding(
            get: { router.pendingAlbum },
            set: { router.pendingAlbum = $0 }
        )) { album in
            AlbumDetailView(album: album) { router.pendingAlbum = nil }
        }
        .fullScreenCover(item: Binding(
            get: { router.pendingCollection },
            set: { router.pendingCollection = $0 }
        )) { collection in
            PlaylistDetailView(collection: collection) { router.pendingCollection = nil }
        }
        .sheet(item: Binding(
            get: { announcements.current },
            set: { if $0 == nil { announcements.markSeen() } }
        )) { item in
            LaunchAnnouncementView(announcement: item) { announcements.markSeen() }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            HomeView()
        case .myWave:
            MyWaveView()
        case .favorites:
            LibraryView()
        case .profile:
            ProfileView()
        }
    }
}

#Preview {
    RootView()
}
