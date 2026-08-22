import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Environment(\.modelContext) private var modelContext
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
        .task {
            await SyncService.shared.pullLibrary(into: modelContext)
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            coverCollage
                .frame(width: 210, height: 210)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text("Избранное")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Text("\(allFavorites.count) \(tracksWord) · \(formattedTotalDuration)")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            HStack(spacing: 12) {
                Button {
                    playAll(shuffled: false)
                } label: {
                    Label("Слушать", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.laxifyPrimary)

                Button {
                    playAll(shuffled: true)
                } label: {
                    Label("Перемешать", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.laxifySecondary)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var tracksWord: String {
        let remainder10 = allFavorites.count % 10
        let remainder100 = allFavorites.count % 100
        if remainder10 == 1, remainder100 != 11 {
            return "трек"
        } else if (2...4).contains(remainder10), !(12...14).contains(remainder100) {
            return "трека"
        } else {
            return "треков"
        }
    }

    private var coverCollage: some View {
        let urls = recentCovers
        return Group {
            if urls.count >= 4 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        AsyncCoverImage(url: urls[index], cornerRadius: 0, displaySize: 90)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                    }
                }
            } else if let first = urls.first {
                AsyncCoverImage(url: first, cornerRadius: 0, displaySize: 180)
            } else {
                LinearGradient(
                    colors: [LaxifyPalette.accent.opacity(0.7), LaxifyPalette.accent.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "star.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
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
                // A tap gesture rather than a button around the row: the
                // download control inside it is its own button, and nesting
                // one button in another means only the outer one is ever hit.
                SongRowView(song: favorite.song, isFavorite: true, showsDownload: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        AudioPlayerController.shared.play(
                            favorite.song, queue: sortedFavorites.map(\.song)
                        )
                    }
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
