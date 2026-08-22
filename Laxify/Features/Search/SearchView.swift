import SwiftUI
import SwiftData

struct SearchView: View {
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SearchHistoryEntry.searchedAt, order: .reverse) private var history: [SearchHistoryEntry]

    @State private var query = ""
    @State private var viewModel = SearchViewModel()
    @State private var selectedArtistId: String?
    @State private var selectedAlbum: MusicAlbum?
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
                    historySection
                } else {
                    resultsSection
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task(id: trimmedQuery) {
            guard !trimmedQuery.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await viewModel.search(query: trimmedQuery)
        }
        .onAppear {
            isFocused = true
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
        .withMiniPlayer()
    }

    private var header: some View {
        HStack {
            Text("Поиск")
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            LaxifyCloseButton(action: onClose)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LaxifyPalette.textTertiary)
            TextField("Треки, артисты", text: $query)
                .focused($isFocused)
                .foregroundStyle(LaxifyPalette.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
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

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Недавние")
                        .font(LaxifyTypography.title)
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Spacer()

                    Button("Очистить") {
                        for entry in history {
                            modelContext.delete(entry)
                        }
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

    @ViewBuilder
    private var resultsSection: some View {
        if viewModel.isSearching && viewModel.results == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if viewModel.hasError {
            VStack(spacing: 14) {
                Text("Не удалось выполнить поиск")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                Button("Повторить") {
                    Task { await viewModel.search(query: trimmedQuery) }
                }
                .buttonStyle(.laxifySecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if let results = viewModel.results {
            if results.isEmpty {
                Text("Ничего не найдено")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .padding(.top, 40)
            } else {
                if let corrected = results.correctedQuery {
                    HStack(spacing: 4) {
                        Text("Показано по запросу")
                            .foregroundStyle(LaxifyPalette.textSecondary)
                        Text("«\(corrected)»")
                            .foregroundStyle(LaxifyPalette.textPrimary)
                    }
                    .font(LaxifyTypography.footnote)
                }

                // Lead with whatever the query actually matched: searching a
                // song title should not bury tracks under artist results.
                if results.bestMatch == .artist {
                    artistsBlock(results)
                    tracksBlock(results)
                } else {
                    tracksBlock(results)
                    artistsBlock(results)
                }

                albumsBlock(results)
            }
        }
    }

    @ViewBuilder
    private func tracksBlock(_ results: SearchResults) -> some View {
        if !results.tracks.isEmpty {
            Text("Треки")
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            VStack(spacing: 12) {
                ForEach(results.tracks) { song in
                    Button {
                        recordHistory(id: song.id, title: song.title, subtitle: song.artistName, coverURL: song.coverURL, kind: .track)
                        AudioPlayerController.shared.play(song, queue: results.tracks)
                    } label: {
                        SongRowView(song: song)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func artistsBlock(_ results: SearchResults) -> some View {
        if !results.artists.isEmpty {
            Text("Артисты")
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)

            VStack(spacing: 12) {
                ForEach(results.artists) { artist in
                    Button {
                        recordHistory(id: artist.id, title: artist.name, subtitle: "Исполнитель", coverURL: artist.imageURL, kind: .artist)
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

#Preview {
    SearchView(onClose: {})
}
