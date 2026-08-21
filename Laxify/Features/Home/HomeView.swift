import SwiftUI
import SwiftData

struct HomeView: View {
    var onSearchTap: () -> Void

    @State private var viewModel = HomeViewModel()
    @State private var selectedChip = "Все"
    @Query(sort: \FavoriteTrack.addedAt, order: .reverse) private var favorites: [FavoriteTrack]

    private let chips = ["Все", "Музыка", "Подкасты", "Аудиокниги"]

    private var favoriteArtistIds: Set<String> {
        Set(favorites.compactMap(\.artistId))
    }

    private var recommendedTracks: [Song] {
        guard let content = viewModel.content else { return [] }
        return WaveRanking.reorder(content.recommendedTracks, favoriteArtistIds: favoriteArtistIds)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                searchField
                chipRow

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.body)
                        .foregroundStyle(LaxifyPalette.textSecondary)
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
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var searchField: some View {
        Button(action: onSearchTap) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LaxifyPalette.textTertiary)
                Text("Поиск")
                    .foregroundStyle(LaxifyPalette.textTertiary)
                Spacer()
            }
            .font(LaxifyTypography.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .laxGlassCapsule()
        }
        .buttonStyle(.plain)
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
                CollectionCardView(collection: collection)
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func songSection(title: String, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(LaxifyTypography.title)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .padding(.horizontal, LaxifyMetrics.screenPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(songs) { song in
                        SongCardView(song: song)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
        }
    }
}

#Preview {
    HomeView(onSearchTap: {})
}
