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
            let batch = try await YandexMusicService.shared.artistTracks(artistId: artistId, page: page)
            let existing = Set(songs.map(\.id))
            let fresh = batch.filter { !existing.contains($0.id) }
            songs.append(contentsOf: fresh)
            hasMore = !batch.isEmpty && !fresh.isEmpty
            page += 1
        } catch {
            hasError = true
            hasMore = false
        }
        isLoading = false
    }
}
