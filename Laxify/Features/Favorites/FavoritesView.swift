import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query private var allFavorites: [FavoriteTrack]
    @State private var sortOption: SortOption = .recent

    enum SortOption: String, CaseIterable {
        case recent = "Недавние"
        case artist = "Исполнитель"
        case alphabetical = "Алфавит"
    }

    private var sortedFavorites: [FavoriteTrack] {
        switch sortOption {
        case .recent:
            allFavorites.sorted { $0.addedAt > $1.addedAt }
        case .artist:
            allFavorites.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        case .alphabetical:
            allFavorites.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private var recentCovers: [URL] {
        Array(
            allFavorites
                .sorted { $0.addedAt > $1.addedAt }
                .compactMap(\.coverURL)
                .prefix(4)
        )
    }

    private var totalDuration: TimeInterval {
        allFavorites.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                if allFavorites.isEmpty {
                    emptyState
                } else {
                    header
                    sortRow
                    trackList
                }
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            coverCollage
                .frame(height: 220)
                .padding(.horizontal, LaxifyMetrics.screenPadding)

            VStack(alignment: .leading, spacing: 4) {
                Text("Избранное")
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Text("\(allFavorites.count) треков · \(formattedTotalDuration)")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)

            HStack(spacing: 12) {
                Button {
                    playAll(shuffled: false)
                } label: {
                    Label("Слушать", systemImage: "play.fill")
                }
                .buttonStyle(.laxifyPrimary)

                Button {
                    playAll(shuffled: true)
                } label: {
                    Label("Перемешать", systemImage: "shuffle")
                }
                .buttonStyle(.laxifySecondary)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private var coverCollage: some View {
        let urls = recentCovers
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                AsyncCoverImage(url: index < urls.count ? urls[index] : nil, cornerRadius: 0)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
    }

    private var sortRow: some View {
        HStack {
            Text("Сортировка")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)

            Spacer()

            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button(option.rawValue) {
                        sortOption = option
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sortOption.rawValue)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textPrimary)
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var trackList: some View {
        VStack(spacing: 12) {
            ForEach(sortedFavorites) { favorite in
                Button {
                    AudioPlayerController.shared.play(favorite.song, queue: sortedFavorites.map(\.song))
                } label: {
                    SongRowView(song: favorite.song, isFavorite: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star")
                .font(.system(size: 40))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text("Пока нет избранных треков")
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private func playAll(shuffled: Bool) {
        var songs = sortedFavorites.map(\.song)
        if shuffled { songs.shuffle() }
        guard let first = songs.first else { return }
        AudioPlayerController.shared.play(first, queue: songs)
    }

    private var formattedTotalDuration: String {
        let totalMinutes = Int(totalDuration) / 60
        if totalMinutes < 60 {
            return "\(totalMinutes) мин"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours) ч \(minutes) мин"
    }
}

#Preview {
    FavoritesView()
}
