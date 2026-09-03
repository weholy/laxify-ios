import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allFavorites: [FavoriteTrack]
    @State private var sortOption: SortOption = .recent
    @State private var showsClearDownloads = false

    var downloads = DownloadManager.shared

    enum SortOption: String, CaseIterable {
        case recent
        case artist
        case alphabetical

        var titleKey: String {
            switch self {
            case .recent: "sort.recent"
            case .artist: "sort.artist"
            case .alphabetical: "sort.alpha"
            }
        }
        var fallback: String {
            switch self {
            case .recent: "Недавние"
            case .artist: "Исполнитель"
            case .alphabetical: "Алфавит"
            }
        }
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
            .padding(.bottom, 28)
        }
        .background(LaxifyPalette.background)
        .task {
            await SyncService.shared.pullLibrary(into: modelContext)
            await backfillDurations()
        }
        .confirmationDialog(
            L("download.clearConfirm", "Удалить загруженные треки?"),
            isPresented: $showsClearDownloads,
            titleVisibility: .visible
        ) {
            Button(L("common.delete", "Удалить"), role: .destructive) {
                for favorite in allFavorites {
                    downloads.remove(favorite.id)
                }
            }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("download.clearNote", "Треки останутся в избранном, но перестанут играть без интернета"))
        }
    }

    /// Older favourites were saved before track length was carried through and
    /// sit at zero. Fetch the real length once and patch the local record, so
    /// the row and the total stop reading "0".
    private func backfillDurations() async {
        let broken = allFavorites.filter { $0.duration <= 0 }
        guard !broken.isEmpty else { return }

        for favorite in broken.prefix(30) {
            if let song = try? await CatalogService.shared.song(id: favorite.id), song.duration > 0 {
                favorite.duration = song.duration
            }
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            coverCollage
                .frame(width: 210, height: 210)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text(L("favorites.title", "Избранное"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Text("\(allFavorites.count) \(tracksWord) · \(formattedTotalDuration)")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            // Three glyphs, play in the middle and larger: with the words
            // gone the row reads as one control with a centre, which is what
            // it is.
            HStack(spacing: 22) {
                CircleGlassButton(
                    systemImage: "shuffle",
                    diameter: 52,
                    accessibilityLabel: L("favorites.shuffle", "Перемешать")
                ) { playAll(shuffled: true) }

                CircleGlassButton(
                    systemImage: "play.fill",
                    diameter: 66,
                    glyphSize: 24,
                    tint: LaxifyPalette.accent,
                    accessibilityLabel: L("favorites.listen", "Слушать")
                ) { playAll(shuffled: false) }

                DownloadRingButton(
                    progress: downloads.batchProgress,
                    isDone: allDownloaded,
                    action: downloadOrClear
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var tracksWord: String {
        // Russian keeps its case forms; every other language uses one word.
        guard LocalizationManager.shared.language == .ru else {
            return L("unit.tracks", "треков")
        }
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
                    Image(systemName: "heart.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
    }

    private var sortRow: some View {
        HStack {
            Text(L("favorites.sort", "Сортировка"))
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)

            Spacer()

            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button(L(option.titleKey, option.fallback)) {
                        sortOption = option
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(L(sortOption.titleKey, sortOption.fallback))
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
                SongRowView(song: favorite.song, isFavorite: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        AudioPlayerController.shared.play(
                            favorite.song, queue: sortedFavorites.map(\.song)
                        )
                    }
                    .trackContextMenu(
                        song: favorite.song,
                        removeTitle: L("favorites.remove", "Удалить из избранного")
                    ) {
                        removeFavorite(favorite)
                    }
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart")
                .font(.system(size: 40))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text(L("favorites.empty", "Пока нет избранных треков"))
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

    /// Every favourite is on the device — the state the tick stands for.
    private var allDownloaded: Bool {
        !allFavorites.isEmpty && allFavorites.allSatisfy { downloads.isDownloaded($0.id) }
    }

    /// One button, two meanings, decided by what is already here: save the
    /// list, or ask before throwing the saved copies away.
    private func downloadOrClear() {
        if allDownloaded {
            showsClearDownloads = true
        } else {
            downloads.download(sortedFavorites.map(\.song))
        }
    }

    private func removeFavorite(_ favorite: FavoriteTrack) {
        let id = favorite.id
        withAnimation(.easeOut(duration: 0.2)) {
            modelContext.delete(favorite)
        }
        try? modelContext.save()
        SyncService.shared.favoriteRemoved(trackId: id)
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
