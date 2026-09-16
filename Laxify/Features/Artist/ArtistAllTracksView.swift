import SwiftUI

struct ArtistAllTracksView: View {
    let artistId: String
    let artistName: String
    var onClose: () -> Void

    @State private var songs: [Song] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var hasError = false
    /// Pages that came back empty in a row.
    ///
    /// The server assembles this list from a metadata catalogue and then has
    /// to find something playable behind each entry, and the ones it cannot
    /// place in time are left out — so a page can legitimately arrive empty
    /// with plenty still to come after it. Stopping on the first empty page
    /// is why an artist with two hundred tracks showed forty and then nothing.
    @State private var emptyPages = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header

                ForEach(songs) { song in
                    Button {
                        AudioPlayerController.shared.play(song, queue: songs)
                    } label: {
                        SongRowView(song: song)
                    }
                    .buttonStyle(.plain)
                    .trackContextMenu(song: song)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                }

                if hasError {
                    Button("Повторить") {
                        Task { await loadNextPage() }
                    }
                    .buttonStyle(.laxifySecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else if hasMore {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task { await loadNextPage() }
                        }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task {
            await loadNextPage()
        }
        .withMiniPlayer()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Все треки")
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text(artistName)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.laxifyCheckmark)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 8)
    }

    private func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        hasError = false
        do {
            let batch = try await CatalogService.shared.artistTracks(
                artistId: artistId, page: page
            )
            let existing = Set(songs.map(\.id))
            let fresh = batch.filter { !existing.contains($0.id) }
            songs.append(contentsOf: fresh)

            // Covers, started now rather than when each row scrolls into
            // place. Every other list in the app does this; this one did not,
            // which is why its artwork came in one tile at a time.
            AsyncCoverImage.prefetchCovers(for: fresh, width: 56)

            emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
            // Three empty pages in a row is the end of the catalogue; one is
            // a page whose tracks could not be placed in time.
            hasMore = emptyPages < 3
            page += 1
        } catch {
            hasError = true
            hasMore = false
        }
        isLoading = false
    }
}
