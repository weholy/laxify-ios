import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var lastMainTab: AppTab = .home
    @State private var isPlayerPresented = false
    @Namespace private var playerZoom
    var player = AudioPlayerController.shared
    var router = DeepLinkRouter.shared

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
    }

    /// The mini player rides as the tab bar's bottom accessory — so on
    /// scroll-down the bar minimises and the mini player slides into the
    /// same row (iOS 26 / Apple Music).
    ///
    /// Toggling the modifier's *presence* gives the `TabView` a new identity
    /// and tears down every tab — closing an open playlist, the favourites
    /// screen or search mid-use — so on 26.1+ it stays attached and only
    /// `isEnabled` flips, which also hides the empty accessory bar that
    /// otherwise shows when nothing is playing. 26.0 has no `isEnabled`, so
    /// there the modifier is attached only while a track plays.
    @ViewBuilder
    private var playerAwareTabView: some View {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: player.currentSong != nil) {
                MiniPlayerBar(zoomNamespace: playerZoom) { isPlayerPresented = true }
            }
        } else if player.currentSong != nil {
            tabs.tabViewBottomAccessory {
                MiniPlayerBar(zoomNamespace: playerZoom) { isPlayerPresented = true }
            }
        } else {
            tabs
        }
    }

    /// Glyphs only. A `Tab` built from a title shows that title under the
    /// icon and there is no modifier to suppress it, so each tab is built
    /// from the `label:` initialiser with a bare image instead. The words
    /// survive as accessibility labels, which is the one job they still had.
    /// Search keeps its own initialiser: in its search role the system draws
    /// it as a lone magnifier anyway.
    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(value: AppTab.home) {
                HomeView()
            } label: {
                Image(systemName: "house.fill")
                    .accessibilityLabel(L("tab.home", "Главная"))
            }
            Tab(value: AppTab.myWave) {
                MyWaveView()
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .accessibilityLabel(L("tab.wave", "Моя волна"))
            }
            Tab(value: AppTab.favorites) {
                LibraryView()
            } label: {
                Image(systemName: "heart.fill")
                    .accessibilityLabel(L("tab.favorites", "Избранное"))
            }
            Tab(value: AppTab.profile) {
                ProfileView()
            } label: {
                Image(systemName: "person.fill")
                    .accessibilityLabel(L("tab.profile", "Профиль"))
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
