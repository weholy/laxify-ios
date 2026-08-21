import SwiftUI

struct ArtistView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ArtistViewModel

    init(artistId: String) {
        _viewModel = State(initialValue: ArtistViewModel(artistId: artistId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.body)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                        .padding(.top, 120)
                } else if viewModel.isLoading && viewModel.detail == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else if let detail = viewModel.detail {
                    header(detail)
                    actionButtons(detail)

                    if !detail.topTracks.isEmpty {
                        topTracksSection(detail.topTracks)
                    }

                    if !detail.releases.isEmpty {
                        releasesSection(detail.releases)
                    }

                    if let bio = detail.artist.bio, !bio.isEmpty {
                        bioSection(bio)
                    }

                    if !detail.similarArtists.isEmpty {
                        similarArtistsSection(detail.similarArtists)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            dismissButton
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 12)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var dismissButton: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .laxGlassCircle(interactive: true)

            Spacer()
        }
    }

    private func header(_ detail: ArtistDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncCoverImage(url: detail.artist.imageURL, cornerRadius: 0)
                .frame(height: 320)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)

            VStack(alignment: .leading, spacing: 4) {
                Text(detail.artist.name)
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let trackCount = detail.artist.trackCount {
                    Text("\(trackCount) треков")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 20)
        }
    }

    private func actionButtons(_ detail: ArtistDetail) -> some View {
        HStack(spacing: 12) {
            Button {
                playAll(detail.topTracks, shuffled: false)
            } label: {
                Label("Слушать", systemImage: "play.fill")
            }
            .buttonStyle(.laxifyPrimary)

            Button {
                playAll(detail.topTracks, shuffled: true)
            } label: {
                Label("Перемешать", systemImage: "shuffle")
            }
            .buttonStyle(.laxifySecondary)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func topTracksSection(_ tracks: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Популярное")

            VStack(spacing: 12) {
                ForEach(tracks) { song in
                    Button {
                        AudioPlayerController.shared.play(song, queue: tracks)
                    } label: {
                        SongRowView(song: song)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func releasesSection(_ releases: [MusicAlbum]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Релизы")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(releases) { album in
                        AlbumCardView(album: album)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
        }
    }

    private func bioSection(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("О артисте")

            Text(bio)
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
        }
    }

    private func similarArtistsSection(_ artists: [MusicArtist]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Похожие артисты")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LaxifyMetrics.itemSpacing) {
                    ForEach(artists) { artist in
                        VStack(spacing: 8) {
                            AsyncCoverImage(url: artist.imageURL, cornerRadius: 44)
                                .frame(width: 88, height: 88)
                                .clipShape(Circle())

                            Text(artist.name)
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(LaxifyPalette.textPrimary)
                                .lineLimit(1)
                        }
                        .frame(width: 96)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(LaxifyTypography.title)
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func playAll(_ tracks: [Song], shuffled: Bool) {
        var songs = tracks
        if shuffled { songs.shuffle() }
        guard let first = songs.first else { return }
        AudioPlayerController.shared.play(first, queue: songs)
    }
}
