import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var lastMainTab: AppTab = .home
    @State private var isPlayerPresented = false
    @Namespace private var playerZoom
    var player = AudioPlayerController.shared
    var router = DeepLinkRouter.shared
    var announcements = AnnouncementService.shared
    var appearance = AppearanceSettings.shared

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue != .search { lastMainTab = newValue }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        playerAwareTabView
            .overlay(alignment: .bottom) {
                if appearance.needsRestart {
                    RestartBanner()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appearance.needsRestart)
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

    /// The mini player rides as the tab bar's bottom accessory — so on
    /// scroll-down the bar minimises and the mini player slides into the
    /// same row (iOS 26 / Apple Music).
    ///
    /// The accessory modifier is attached unconditionally and only its
    /// *content* depends on whether something is playing. Toggling the
    /// modifier itself gave the `TabView` a new identity the first time a
    /// track started, which tore down every tab — closing an open playlist,
    /// the favourites screen or search mid-use.
    private var playerAwareTabView: some View {
        tabs.tabViewBottomAccessory {
            if player.currentSong != nil {
                MiniPlayerBar(zoomNamespace: playerZoom) { isPlayerPresented = true }
            }
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(L("tab.home", "Главная"), systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab(L("tab.wave", "Моя волна"), systemImage: "dot.radiowaves.left.and.right", value: AppTab.myWave) {
                MyWaveView()
            }
            Tab(L("tab.favorites", "Избранное"), systemImage: "heart.fill", value: AppTab.favorites) {
                LibraryView()
            }
            Tab(L("tab.profile", "Профиль"), systemImage: "person.fill", value: AppTab.profile) {
                ProfileView()
            }
            Tab(L("search.title", "Поиск"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView(onClose: { selectedTab = lastMainTab }, showsCloseButton: false)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    RootView()
}
