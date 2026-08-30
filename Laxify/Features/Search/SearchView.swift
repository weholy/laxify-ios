import SwiftUI
import SwiftData

struct SearchView: View {
    var onClose: () -> Void
    /// The tab presentation has no chrome to dismiss, so it hides the ✕.
    var showsCloseButton: Bool = true

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SearchHistoryEntry.searchedAt, order: .reverse) private var history: [SearchHistoryEntry]

    @State private var query = ""
    @State private var viewModel = SearchViewModel()
    @State private var selectedArtistId: String?
    @State private var selectedAlbum: MusicAlbum?
    @State private var selectedCategory: MusicCategory?
    @FocusState private var isFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                header
                searchField

                if trimmedQuery.isEmpty {
                    browseSection
                } else if !viewModel.suggestions.isEmpty && viewModel.results == nil {
                    suggestionsSection
                } else {
                    resultsSection
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .task {
            await viewModel.loadBrowseIfNeeded()
        }
        .task(id: trimmedQuery) {
            guard !trimmedQuery.isEmpty else {
                viewModel.clearResults()
                return
            }
            viewModel.updateSuggestions(for: trimmedQuery)
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await viewModel.search(query: trimmedQuery)
        }
        .onAppear { isFocused = true }
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

    private var header: some View {
        HStack {
            Text(L("search.title", "Поиск"))
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            if showsCloseButton {
                LaxifyCloseButton(action: onClose)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LaxifyPalette.textTertiary)
            TextField(L("search.field", "Треки, артисты"), text: $query)
                .focused($isFocused)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .submitLabel(.search)
                .onSubmit {
                    Task { await viewModel.search(query: trimmedQuery) }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    viewModel.clearResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(LaxifyTypography.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .laxGlassCapsule()
    }

    // MARK: - Browse (no query)

    @ViewBuilder
    private var browseSection: some View {
        if !viewModel.popular.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("search.popular", "Популярные рекомендации"))
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LaxifyMetrics.itemSpacing) {
                        ForEach(viewModel.popular) { song in
                            Button {
                                AudioPlayerController.shared.play(song, queue: viewModel.popular)
                            } label: {
                                SongCardView(song: song)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }

        if !viewModel.categories.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("search.categories", "Категории"))
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(viewModel.categories) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            CategoryCard(category: category, coverURL: viewModel.categoryCovers[category.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if viewModel.isLoadingBrowse {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        }

        historySection
    }

    // MARK: - Suggestions (typing)

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.suggestions, id: \.self) { suggestion in
                Button {
                    query = suggestion
                    Task { await viewModel.search(query: suggestion) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                        Text(suggestion)
                            .font(LaxifyTypography.body)
                            .foregroundStyle(LaxifyPalette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 12))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion != viewModel.suggestions.last {
                    Divider().overlay(LaxifyPalette.separator)
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("search.recent", "Недавние"))
                        .font(LaxifyTypography.title)
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Spacer()

                    Button(L("search.clear", "Очистить")) {
                        for entry in history { modelContext.delete(entry) }
                    }
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                }

                VStack(spacing: 12) {
                    ForEach(history) { entry in
                        historyRow(entry)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: SearchHistoryEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                switch entry.kind {
                case .artist:
                    selectedArtistId = entry.id
                case .track:
                    playFromHistory(entry)
                }
            } label: {
                HStack(spacing: 12) {
                    if entry.coverURL != nil {
                        AsyncCoverImage(url: entry.coverURL, cornerRadius: LaxifyMetrics.smallCornerRadius, displaySize: 48)
                            .frame(width: 44, height: 44)
                    } else {
                        Circle()
                            .fill(LaxifyPalette.surface)
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "clock")
                                    .foregroundStyle(LaxifyPalette.textTertiary)
                            }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(LaxifyTypography.body)
                            .foregroundStyle(LaxifyPalette.textPrimary)
                            .lineLimit(1)
                        if let subtitle = entry.subtitle {
                            Text(subtitle)
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(LaxifyPalette.textSecondary)
                        }
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                modelContext.delete(entry)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if viewModel.isSearching && viewModel.results == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if viewModel.hasError {
            VStack(spacing: 14) {
                Text(L("search.failed", "Не удалось выполнить поиск"))
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                Button(L("common.retry", "Повторить")) {
                    Task { await viewModel.search(query: trimmedQuery) }
                }
                .buttonStyle(.laxifySecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if let results = viewModel.results {
            if results.isEmpty {
                Text(L("common.nothingFound", "Ничего не найдено"))
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .padding(.top, 40)
            } else {
                if let corrected = results.correctedQuery {
                    HStack(spacing: 4) {
                        Text(L("search.corrected", "Показано по запросу"))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                        Text("«\(corrected)»")
                            .foregroundStyle(LaxifyPalette.textPrimary)
                    }
                    .font(LaxifyTypography.footnote)
                }

                // Artists first. Someone searching a name is looking for the
                // person, and a page of their uploads underneath answers that;
                // the same page above it does not.
                artistsBlock(results)
                tracksBlock(results)
                albumsBlock(results)
                playlistsBlock(results)
            }
        }
    }

    @ViewBuilder
    private func tracksBlock(_ results: SearchResults) -> some View {
        if !results.tracks.isEmpty {
            Text(L("search.tracks", "Треки"))
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            VStack(spacing: 12) {
                ForEach(results.tracks) { song in
                    Button {
                        guard song.playable else { return }
                        recordHistory(id: song.id, title: song.title, subtitle: song.artistName, coverURL: song.coverURL, kind: .track)
                        AudioPlayerController.shared.play(
                            song, queue: results.tracks.filter(\.playable)
                        )
                    } label: {
                        SongRowView(song: song)
                            .opacity(song.playable ? 1 : 0.4)
                            .overlay(alignment: .trailing) {
                                if !song.playable {
                                    Text(L("search.unavailable", "нет на SoundCloud"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(LaxifyPalette.textTertiary)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!song.playable)
                }
            }
        }
    }

    @ViewBuilder
    private func playlistsBlock(_ results: SearchResults) -> some View {
        if !results.playlists.isEmpty {
            Text(L("search.playlists", "Плейлисты"))
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(results.playlists) { playlist in
                        Button {
                            selectedAlbum = playlist
                        } label: {
                            AlbumCardView(album: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func artistsBlock(_ results: SearchResults) -> some View {
        if !results.artists.isEmpty {
            Text(L("search.artists", "Артисты"))
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            VStack(spacing: 12) {
                ForEach(results.artists) { artist in
                    Button {
                        recordHistory(id: artist.id, title: artist.name, subtitle: L("search.artistRole", "Исполнитель"), coverURL: artist.imageURL, kind: .artist)
                        selectedArtistId = artist.id
                    } label: {
                        ArtistRowView(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func albumsBlock(_ results: SearchResults) -> some View {
        if !results.albums.isEmpty {
            Text("Альбомы")
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(results.albums) { album in
                        Button {
                            selectedAlbum = album
                        } label: {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func recordHistory(id: String, title: String, subtitle: String?, coverURL: URL?, kind: SearchHistoryKind) {
        if let existing = history.first(where: { $0.id == id }) {
            existing.searchedAt = .now
        } else {
            let entry = SearchHistoryEntry(id: id, title: title, subtitle: subtitle, coverURLString: coverURL?.absoluteString, kind: kind)
            modelContext.insert(entry)
        }
    }

    private func playFromHistory(_ entry: SearchHistoryEntry) {
        entry.searchedAt = .now
        Task {
            guard let song = try? await CatalogService.shared.song(id: entry.id) else { return }
            AudioPlayerController.shared.play(song, queue: [song])
        }
    }
}

/// A genre banner: a real cover from the genre behind a dark scrim when one
/// is known, the coloured gradient tile as the fallback.
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

#Preview {
    SearchView(onClose: {})
}
