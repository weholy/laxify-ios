import SwiftUI

struct RootView: View {
    @State private var selectedTab: AppTab = .home
    @State private var lastMainTab: AppTab = .home
    @State private var isPlayerPresented = false
    @Namespace private var playerZoom
    var player = AudioPlayerController.shared
    var router = DeepLinkRouter.shared
    var interface = InterfaceSettings.shared

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

    /// A `Tab` built from a title always draws that title, and no modifier
    /// suppresses it — so every tab is built from the `label:` initialiser
    /// and the label itself decides whether a word appears. Keeping the same
    /// initialiser either way matters: swapping between two shapes of `Tab`
    /// would give the `TabView` a new identity and tear down every screen
    /// inside it the moment the switch is flipped.
    ///
    /// Search keeps its own initialiser — in its search role the system draws
    /// it as a lone magnifier regardless.
    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(value: AppTab.home) {
                HomeView()
            } label: {
                tabLabel(L("tab.home", "Главная"), systemImage: "house.fill")
            }
            Tab(value: AppTab.myWave) {
                MyWaveView()
            } label: {
                tabLabel(L("tab.wave", "Моя волна"), systemImage: "dot.radiowaves.left.and.right")
            }
            Tab(value: AppTab.favorites) {
                LibraryView()
            } label: {
                tabLabel(L("tab.favorites", "Избранное"), systemImage: "heart.fill")
            }
            Tab(value: AppTab.profile) {
                ProfileView()
            } label: {
                tabLabel(L("tab.profile", "Профиль"), systemImage: "person.fill")
            }
            Tab(L("search.title", "Поиск"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView(onClose: { selectedTab = lastMainTab }, showsCloseButton: false)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    @ViewBuilder
    private func tabLabel(_ title: String, systemImage: String) -> some View {
        if interface.hideTabLabels {
            // The word still exists for VoiceOver — it is only the drawing
            // of it that the switch turns off.
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

#Preview {
    RootView()
}
