import SwiftUI

/// One category, opened from the search grid: an endless list of its tracks.
///
/// Pages the same way the artist "all tracks" screen does — a 1pt sentinel at
/// the tail asks for more — and de-duplicates by id, because the first page
/// (a genre listing) and the tail (paged search on the genre name) overlap at
/// the seam.
struct CategoryTracksView: View {
    let categoryId: String
    let categoryTitle: String
    var onClose: () -> Void

    @State private var songs: [Song] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var hasError = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                banner

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
                    Button(L("common.retry", "Повторить")) {
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
                        .onAppear { Task { await loadNextPage() } }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task {
            guard songs.isEmpty else { return }
            await loadNextPage()
        }
        .withMiniPlayer()
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncCoverImage(url: songs.first?.coverURL, cornerRadius: 38, displaySize: 400)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.15), .black.opacity(0.7)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }

            HStack(alignment: .bottom) {
                Text(categoryTitle)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    guard !songs.isEmpty else { return }
                    AudioPlayerController.shared.play(songs[0], queue: songs)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(LaxifyPalette.accent))
                }
                .buttonStyle(.plain)
                .opacity(songs.isEmpty ? 0 : 1)
            }
            .padding(16)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .overlay(alignment: .topTrailing) {
            LaxifyCloseButton(style: .xmark, tinted: false, action: onClose)
            .padding(.trailing, LaxifyMetrics.screenPadding + 12)
            .padding(.top, 12)
        }
    }

    private func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        hasError = false
        do {
            let batch = try await CatalogService.shared.categoryTracks(
                id: categoryId, title: categoryTitle, page: page
            )
            let existing = Set(songs.map(\.id))
            let fresh = batch.filter { !existing.contains($0.id) }
            songs.append(contentsOf: fresh)
            // Stop when a page brings nothing new — either the source is out
            // or the seam has fully overlapped.
            hasMore = !batch.isEmpty && !fresh.isEmpty
            page += 1
        } catch {
            hasError = true
            hasMore = false
        }
        isLoading = false
    }
}
