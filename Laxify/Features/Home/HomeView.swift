import SwiftUI
import SwiftData

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var selectedChip = "Все"
    @State private var query = ""
    @State private var searchResults: SearchResults?
    @State private var isSearching = false
    @State private var selectedCollection: MusicCollection?
    @State private var selectedArtistId: String?
    @Query(sort: \FavoriteTrack.addedAt, order: .reverse) private var favorites: [FavoriteTrack]

    private let chips = ["Все", "Музыка", "Подкасты", "Аудиокниги"]

    private var favoriteArtistIds: Set<String> {
        Set(favorites.compactMap(\.artistId))
    }

    private var recommendedTracks: [Song] {
        guard let content = viewModel.content else { return [] }
        return WaveRanking.reorder(content.recommendedTracks, favoriteArtistIds: favoriteArtistIds)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                searchField

                if trimmedQuery.isEmpty {
                    chipRow
                    homeContent
                } else {
                    inlineSearchResults
                }
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
        .task {
            await viewModel.loadIfNeeded()
        }
        .task(id: trimmedQuery) {
            guard !trimmedQuery.isEmpty else {
                searchResults = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            searchResults = try? await YandexMusicService.shared.search(query: trimmedQuery)
            isSearching = false
        }
        .fullScreenCover(item: $selectedCollection) { collection in
            PlaylistDetailView(collection: collection)
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedArtistId != nil },
            set: { if !$0 { selectedArtistId = nil } }
        )) {
            if let artistId = selectedArtistId {
                ArtistView(artistId: artistId)
            }
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        if selectedChip == "Подкасты" || selectedChip == "Аудиокниги" {
            Text("Раздел «\(selectedChip)» скоро появится")
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 40)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 14) {
                Text(errorMessage)
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                Button("Повторить") {
                    Task { await viewModel.reload() }
                }
                .buttonStyle(.laxifySecondary)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        } else if viewModel.isLoading && viewModel.content == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let content = viewModel.content {
            collectionsGrid(content.collections)

            if !favoriteArtistIds.isEmpty {
                songSection(title: "Ваша волна", songs: recommendedTracks)
            }

            songSection(title: "Рекомендованные треки", songs: recommendedTracks)
        }
    }

    @ViewBuilder
    private var inlineSearchResults: some View {
        if isSearching && searchResults == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let results = searchResults {
            if results.artists.isEmpty && results.tracks.isEmpty {
                Text("Ничего не найдено")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 40)
            } else {
                if !results.artists.isEmpty {
                    sectionTitle("Артисты")
                    VStack(spacing: 12) {
                        ForEach(results.artists) { artist in
                            Button {
                                selectedArtistId = artist.id
                            } label: {
                                ArtistRowView(artist: artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                }

                if !results.tracks.isEmpty {
                    sectionTitle("Треки")
                    VStack(spacing: 12) {
                        ForEach(results.tracks) { song in
                            Button {
                                AudioPlayerController.shared.play(song, queue: results.tracks)
                            } label: {
                                SongRowView(song: song)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(LaxifyTypography.title)
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LaxifyPalette.textTertiary)
            TextField("Поиск", text: $query)
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
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    let isSelected = chip == selectedChip
                    Button {
                        selectedChip = chip
                    } label: {
                        Text(chip)
                            .font(LaxifyTypography.subheadline)
                            .foregroundStyle(isSelected ? Color.white : LaxifyPalette.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(isSelected ? LaxifyPalette.accent : LaxifyPalette.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func collectionsGrid(_ collections: [MusicCollection]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: LaxifyMetrics.itemSpacing), GridItem(.flexible())], spacing: LaxifyMetrics.itemSpacing) {
            ForEach(collections) { collection in
                Button {
                    selectedCollection = collection
                } label: {
                    CollectionCardView(collection: collection)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func songSection(title: String, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(songs) { song in
                        Button {
                            AudioPlayerController.shared.play(song, queue: songs)
                        } label: {
                            SongCardView(song: song)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
        }
    }
}

#Preview {
    HomeView()
}
