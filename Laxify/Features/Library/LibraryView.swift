import SwiftUI
import SwiftData

/// The Медиатека tab — a Spotify-style hub. A pinned "Любимые треки" tile
/// on top, the playlists as rows beneath it. Picking the tile drops the
/// liked-tracks screen in place; picking a playlist opens it full-screen.
struct LibraryView: View {
    @Query private var favorites: [FavoriteTrack]
    var store = PlaylistStore.shared

    @State private var showsFavorites = false
    @State private var selected: PlaylistDTO?
    @State private var isCreatePresented = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if showsFavorites {
                FavoritesView()
                    .transition(.opacity)
            } else {
                hub
                    .transition(.opacity)
            }
        }
        .background(LaxifyPalette.background)
        .task { await store.loadIfNeeded() }
        .fullScreenCover(item: $selected) { playlist in
            UserPlaylistView(playlist: playlist) { selected = nil }
        }
        .sheet(isPresented: $isCreatePresented) {
            CreatePlaylistSheet { isCreatePresented = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if showsFavorites {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        showsFavorites = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Text(showsFavorites
                 ? L("favorites.title", "Избранное")
                 : L("library.title", "Медиатека"))
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            if !showsFavorites {
                Button {
                    isCreatePresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Hub

    private var hub: some View {
        ScrollView {
            VStack(spacing: 10) {
                likedTile

                if !store.playlists.isEmpty {
                    HStack {
                        Text(L("library.playlists", "Плейлисты"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 14)
                }

                ForEach(store.playlists) { playlist in
                    Button { selected = playlist } label: {
                        PlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }

                if store.playlists.isEmpty && !store.isLoading {
                    emptyPlaylists
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .scrollIndicators(.hidden)
        .tracksBottomBarHiding()
        .refreshable { await store.reload() }
    }

    private var recentFavoriteCovers: [URL] {
        Array(
            favorites
                .sorted { $0.addedAt > $1.addedAt }
                .compactMap(\.coverURL)
                .prefix(4)
        )
    }

    private var likedTile: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                showsFavorites = true
            }
        } label: {
            HStack(spacing: 12) {
                CoverCollage(urls: recentFavoriteCovers, displaySize: 120) {
                    LinearGradient(
                        colors: [Color(hex: 0x7B5CFF), Color(hex: 0x3B7BFF)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("favorites.title", "Избранное"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text("\(favorites.count) \(Self.tracksWord(favorites.count))")
                        .font(LaxifyTypography.caption)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(10)
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyPlaylists: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text(L("library.empty", "Создайте плейлист и складывайте в него треки —\nиз плеера или долгим нажатием на трек"))
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @MainActor
    static func tracksWord(_ n: Int) -> String {
        guard LocalizationManager.shared.language == .ru else {
            return L("unit.tracks", "треков")
        }
        let r10 = n % 10, r100 = n % 100
        if r10 == 1, r100 != 11 { return "трек" }
        if (2...4).contains(r10), !(12...14).contains(r100) { return "трека" }
        return "треков"
    }
}

/// One playlist as a Spotify-style row: square cover, title, "Плейлист · N".
struct PlaylistRow: View {
    let playlist: PlaylistDTO
    var previews = PlaylistPreviewStore.shared

    var body: some View {
        HStack(spacing: 12) {
            cover
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)

                Text("\(L("library.playlist", "Плейлист")) · \(playlist.trackCount) \(PlaylistCard.tracksWord(playlist.trackCount))")
                    .font(LaxifyTypography.caption)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textTertiary)
        }
        .padding(10)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let local = PlaylistCoverStore.shared.image(for: playlist.id) {
            Image(uiImage: local).resizable().scaledToFill()
        } else if let url = playlist.coverURL {
            AsyncCoverImage(url: url, cornerRadius: 12, displaySize: 120)
        } else {
            CoverCollage(urls: previews.previews(for: playlist), displaySize: 120) {
                gradientFallback
            }
        }
    }

    private var gradientFallback: some View {
        LaxifyPalette.surfaceElevated
    }
}

/// The grid card kept for anywhere that still wants a grid; the hub uses
/// `PlaylistRow` now.
struct PlaylistCard: View {
    let playlist: PlaylistDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))

            Text(playlist.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            Text("\(playlist.trackCount) \(Self.tracksWord(playlist.trackCount))")
                .font(LaxifyTypography.caption)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let local = PlaylistCoverStore.shared.image(for: playlist.id) {
            Image(uiImage: local).resizable().scaledToFill()
        } else if let url = playlist.coverURL {
            AsyncCoverImage(url: url, cornerRadius: 24, displaySize: 240)
        } else {
            let seed = playlist.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            let hue = Double(seed % 360) / 360
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.8),
                    Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    @MainActor
    static func tracksWord(_ n: Int) -> String {
        guard LocalizationManager.shared.language == .ru else {
            return L("unit.tracks", "треков")
        }
        let r10 = n % 10, r100 = n % 100
        if r10 == 1, r100 != 11 { return "трек" }
        if (2...4).contains(r10), !(12...14).contains(r100) { return "трека" }
        return "треков"
    }
}

#Preview {
    LibraryView()
}
