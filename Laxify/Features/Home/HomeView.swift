import SwiftUI
import SwiftData

struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @State private var query = ""
    @State private var searchResults: SearchResults?
    @State private var isSearching = false
    @State private var selectedArtistId: String?
    @Query(sort: \FavoriteTrack.addedAt, order: .reverse) private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    private var favoriteArtistIds: Set<String> {
        Set(favorites.compactMap(\.artistId))
    }

    private var recommendedTracks: [Song] {
        guard let content = viewModel.content else { return [] }
        let dislikedIds = Set(dislikedTracks.map(\.id))
        let filtered = content.recommendedTracks.filter { !dislikedIds.contains($0.id) }
        return WaveRanking.reorder(filtered, favoriteArtistIds: favoriteArtistIds)
    }

    private var waveTracks: [Song] {
        let dislikedIds = Set(dislikedTracks.map(\.id))
        return viewModel.waveTracks.filter { !dislikedIds.contains($0.id) }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                searchField

                if trimmedQuery.isEmpty {
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
        .task(id: favoriteArtistIds) {
            await viewModel.refreshWave(seedArtistIds: Array(favoriteArtistIds))
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
        if let errorMessage = viewModel.errorMessage {
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
        } else if viewModel.content != nil {
            if !waveTracks.isEmpty {
                trackListSection(title: "Ваша волна", songs: waveTracks)
            } else if viewModel.isLoadingWave {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Ваша волна")
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
            }

            trackListSection(title: "Для вас", songs: recommendedTracks)
        }
    }

    private func trackListSection(title: String, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title)

            LazyVStack(spacing: 12) {
                ForEach(songs) { song in
                    Button {
                        AudioPlayerController.shared.play(song, queue: songs)
                    } label: {
                        SongRowView(song: song)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
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

}

#Preview {
    HomeView()
}
