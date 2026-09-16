import SwiftUI

struct ArtistView: View {
    @State private var viewModel: ArtistViewModel
    @State private var selectedAlbum: MusicAlbum?
    @State private var isAllTracksPresented = false

    private let artistId: String
    private let onClose: () -> Void

    init(artistId: String, onClose: @escaping () -> Void) {
        self.artistId = artistId
        self.onClose = onClose
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
            .padding(.bottom, LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(artistBackground)
        .overlay(alignment: .top) {
            dismissButton
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 12)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .fullScreenCover(item: $selectedAlbum) { album in
            AlbumDetailView(album: album) { selectedAlbum = nil }
        }
        .fullScreenCover(isPresented: $isAllTracksPresented) {
            ArtistAllTracksView(
                artistId: artistId,
                artistName: viewModel.detail?.artist.name ?? ""
            ) { isAllTracksPresented = false }
        }
        .withMiniPlayer()
    }

    private var artistBackground: some View {
        ZStack {
            LaxifyPalette.background

            if let url = viewModel.detail?.artist.imageURL {
                BlurredBackdrop(url: url, blur: 90, opacity: 0.4)
                    .frame(height: 520)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            LinearGradient(
                colors: [.clear, LaxifyPalette.background.opacity(0.9), LaxifyPalette.background],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var dismissButton: some View {
        HStack {
            LaxifyCloseButton(style: .chevronDown, tinted: false, action: onClose)

            Spacer()
        }
    }

    private func header(_ detail: ArtistDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: 340)
                .overlay {
                    if let url = detail.artist.imageURL {
                        CachedImage(url: url, displaySize: 400)
                    } else {
                        LaxifyPalette.surface
                    }
                }
                .clipped()

            LinearGradient(
                colors: [.black.opacity(0.35), .clear, .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 340)

            VStack(alignment: .leading, spacing: 4) {
                ArtistName(
                    name: detail.artist.name,
                    isVerified: detail.artist.isVerified,
                    font: LaxifyTypography.largeTitle,
                    badgeSize: 22
                )
                .foregroundStyle(.white)

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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.laxifyPrimary)

            Button {
                playAll(detail.topTracks, shuffled: true)
            } label: {
                Label("Перемешать", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.laxifySecondary)

            ShareLink(item: ShareText.artist(detail.artist)) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.laxifyIcon)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func topTracksSection(_ tracks: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Популярное")
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Spacer()

                Button {
                    isAllTracksPresented = true
                } label: {
                    HStack(spacing: 3) {
                        Text("Все треки")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(LaxifyTypography.subheadline)
                    .foregroundStyle(LaxifyPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)

            VStack(spacing: 12) {
                ForEach(tracks) { song in
                    Button {
                        AudioPlayerController.shared.play(song, queue: tracks)
                    } label: {
                        SongRowView(song: song)
                    }
                    .buttonStyle(.plain)
                    .trackContextMenu(song: song)
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
                        Button {
                            selectedAlbum = album
                        } label: {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
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
                            AsyncCoverImage(url: artist.imageURL, cornerRadius: 44, displaySize: 88)
                                .frame(width: 88, height: 88)
                                .clipShape(Circle())

                            ArtistName(
                                name: artist.name,
                                isVerified: artist.isVerified,
                                badgeSize: 12
                            )
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
