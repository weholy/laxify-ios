import SwiftUI

/// Search, in the shape iOS gives you for free.
///
/// A native `.searchable` field with scopes, and one plain `List` per scope,
/// rather than a hand-built field over a stack of every section at once. The
/// old layout drew tracks, artists, albums and playlists together on one long
/// scroll, which meant every result competed for the same screen and nothing
/// was where you expected it. Picking a scope is both faster to read and
/// faster to draw.
struct SearchView: View {
    var onClose: () -> Void
    /// The tab presentation has no chrome to dismiss, so it hides the ✕.
    var showsCloseButton: Bool = true

    @State private var query = ""
    @State private var scope: SearchScope = .tracks
    @State private var viewModel = SearchViewModel()
    @State private var selectedArtistId: String?
    @State private var selectedAlbum: MusicAlbum?
    @State private var selectedCategory: MusicCategory?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    discovery
                } else {
                    results
                }
            }
            .background(LaxifyPalette.background)
            .navigationTitle(L("search.title", "Поиск"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("common.close", "Закрыть"), action: onClose)
                    }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L("search.field", "Треки, артисты")
            )
            .searchScopes($scope, activation: .onSearchPresentation) {
                ForEach(SearchScope.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .overlay { emptyState }
        }
        .task { await viewModel.loadBrowseIfNeeded() }
        .task(id: trimmedQuery) {
            guard !trimmedQuery.isEmpty else {
                viewModel.clearResults()
                return
            }
            // Long enough that typing does not fire a request per keystroke,
            // short enough that a pause feels like a result rather than a wait.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await viewModel.search(query: trimmedQuery)
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedArtistId != nil },
            set: { if !$0 { selectedArtistId = nil } }
        )) {
            if let artistId = selectedArtistId {
                ArtistView(artistId: artistId) { selectedArtistId = nil }
            }
        }
        .fullScreenCover(item: $selectedAlbum) { album in
            AlbumDetailView(album: album) { selectedAlbum = nil }
        }
        .fullScreenCover(item: $selectedCategory) { category in
            CategoryTracksView(categoryId: category.id, categoryTitle: category.title) {
                selectedCategory = nil
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        List {
            if viewModel.isSearching && viewModel.results == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let found = viewModel.results {
                switch scope {
                case .tracks:
                    ForEach(found.tracks) { song in
                        Button {
                            AudioPlayerController.shared.play(song, queue: found.tracks)
                        } label: {
                            SongRowView(song: song)
                        }
                        .buttonStyle(.plain)
                    }

                case .artists:
                    ForEach(found.artists) { artist in
                        Button { selectedArtistId = artist.id } label: {
                            ArtistRowView(artist: artist)
                        }
                        .buttonStyle(.plain)
                    }

                case .albums:
                    ForEach(found.albums) { album in
                        Button { selectedAlbum = album } label: {
                            CollectionRow(album: album, subtitle: album.artistName)
                        }
                        .buttonStyle(.plain)
                    }

                case .playlists:
                    ForEach(found.playlists) { playlist in
                        Button { selectedAlbum = playlist } label: {
                            CollectionRow(album: playlist, subtitle: playlist.artistName)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !trimmedQuery.isEmpty, viewModel.hasError {
            ContentUnavailableView {
                Label(L("search.failed", "Не удалось выполнить поиск"), systemImage: "exclamationmark.magnifyingglass")
            } actions: {
                Button(L("common.retry", "Повторить")) {
                    Task { await viewModel.search(query: trimmedQuery) }
                }
            }
        } else if !trimmedQuery.isEmpty,
                  !viewModel.isSearching,
                  let found = viewModel.results,
                  isEmpty(found) {
            ContentUnavailableView.search(text: trimmedQuery)
        }
    }

    private func isEmpty(_ results: SearchResults) -> Bool {
        switch scope {
        case .tracks: results.tracks.isEmpty
        case .artists: results.artists.isEmpty
        case .albums: results.albums.isEmpty
        case .playlists: results.playlists.isEmpty
        }
    }

    // MARK: - Discovery (no query yet)

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var discovery: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !viewModel.popular.isEmpty {
                    section(L("search.popular", "Популярные рекомендации")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: LaxifyMetrics.itemSpacing) {
                                ForEach(viewModel.popular) { song in
                                    Button {
                                        AudioPlayerController.shared.play(song, queue: viewModel.popular)
                                    } label: {
                                        SongCardView(song: song)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, LaxifyMetrics.screenPadding)
                        }
                        .scrollClipDisabled()
                    }
                }

                if !viewModel.categories.isEmpty {
                    section(L("search.categories", "Категории")) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(viewModel.categories) { category in
                                Button { selectedCategory = category } label: {
                                    CategoryCard(
                                        category: category,
                                        coverURL: viewModel.categoryCovers[category.id]
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                    }
                } else if viewModel.isLoadingBrowse {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            content()
        }
    }
}

/// Which kind of result the list is showing. Albums and playlists are both
/// collections, so they share a row.
enum SearchScope: String, CaseIterable, Identifiable {
    case tracks, artists, albums, playlists

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .tracks: L("search.tracks", "Треки")
        case .artists: L("search.artists", "Артисты")
        case .albums: L("search.albums", "Альбомы")
        case .playlists: L("search.playlists", "Плейлисты")
        }
    }
}

/// An album or playlist as a list row — square artwork, name, who made it.
private struct CollectionRow: View {
    let album: MusicAlbum
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverImage(
                url: album.coverURL,
                cornerRadius: LaxifyMetrics.smallCornerRadius,
                displaySize: 100
            )
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
private struct CategoryCard: View {
    let category: MusicCategory
    var coverURL: URL?

    var body: some View {
        let seed = category.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(seed % 360) / 360
        let gradient = LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.6, brightness: 0.82),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                      saturation: 0.72, brightness: 0.5)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        ZStack(alignment: .bottomLeading) {
            if let coverURL {
                CachedImage(url: coverURL, displaySize: 240, contentMode: .fill)
                    .overlay(gradient.opacity(0.35))
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.55)],
                            startPoint: .center, endPoint: .bottom
                        )
                    )
            } else {
                gradient
                Image(systemName: Self.symbol(for: category.id))
                    .font(.system(size: 62, weight: .bold))
                    .foregroundStyle(.white.opacity(0.16))
                    .offset(x: 44, y: 22)
            }

            Text(category.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .padding(14)
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
        .contentShape(Rectangle())
    }

    static func symbol(for id: String) -> String {
        switch id {
        case "hiphoprap", "trap": "mic.fill"
        case "pop": "star.fill"
        case "electronic", "house", "techno", "dubstep", "drumbass": "waveform"
        case "rnb": "heart.fill"
        case "rock", "metal": "guitars.fill"
        case "dance": "figure.dance"
        case "indie": "sparkles"
        case "ambient": "moon.stars.fill"
        case "classical": "pianokeys"
        case "jazzblues": "music.quarternote.3"
        case "reggae": "sun.max.fill"
        case "soundtrack": "film.fill"
        case "country": "hat.cap.fill"
        case "latin": "flame.fill"
        default: "music.note"
        }
    }
}
