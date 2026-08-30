import SwiftUI

/// One row of the Yandex-style home feed. A "playlist" block is a single
/// feature card you press play on; a "shelf" block is a browsable carousel.
struct FeedRow: View {
    let block: WaveFeedBlockDTO

    private var songs: [Song] { block.tracks.map(\.song) }

    var body: some View {
        if songs.isEmpty {
            EmptyView()
        } else if block.type == "playlist" {
            featureCard
        } else {
            shelf
        }
    }

    // MARK: - Playlist → feature card

    private var featureCard: some View {
        Button {
            guard let first = songs.first else { return }
            AudioPlayerController.shared.play(first, queue: songs)
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let cover = songs.first?.coverURL {
                    CachedImage(url: cover, displaySize: 600, contentMode: .fill)
                        .overlay(Color.black.opacity(0.28))
                        .overlay(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.78)],
                                startPoint: .center, endPoint: .bottom
                            )
                        )
                } else {
                    LinearGradient(
                        colors: [LaxifyPalette.accent.opacity(0.8), LaxifyPalette.accent.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(block.title)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let subtitle = block.subtitle {
                        Text(subtitle)
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(16)

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    // MARK: - Shelf → carousel

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                if let subtitle = block.subtitle {
                    Text(subtitle)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(songs) { song in
                        Button {
                            let rest = Array(songs.drop(while: { $0.id != song.id }))
                            AudioPlayerController.shared.play(song, queue: rest.isEmpty ? songs : rest)
                        } label: {
                            SongCardView(song: song)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
            .scrollClipDisabled()
        }
    }
}
