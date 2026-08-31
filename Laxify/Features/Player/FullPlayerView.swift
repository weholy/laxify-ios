import SwiftUI
import SwiftData

struct FullPlayerView: View {
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    var player = AudioPlayerController.shared

    @State private var isLyricsPresented = false
    @State private var isAddToPlaylistPresented = false
    @State private var selectedArtistId: String?
    @State private var palette: ArtworkPalette = .neutral


    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return favorites.contains { $0.id == song.id }
    }

    private var shareText: String {
        guard let song = player.currentSong else { return "" }
        return ShareText.track(song)
    }

    var body: some View {
        ZStack(alignment: .top) {
            background

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 12)

                titleBlock
                    .padding(.bottom, 20)

                PlayerScrubber()
                    .padding(.bottom, 20)

                controls
                    .padding(.bottom, 22)

                PlayerVolumeRow()
                    .padding(.bottom, 18)

                bottomIconRow
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .task(id: player.currentSong?.id) {
            palette = await PaletteExtractor.shared.palette(for: player.currentSong?.coverURL)
        }
        .sheet(isPresented: $isLyricsPresented) {
            LyricsView()
        }
        .sheet(isPresented: $isAddToPlaylistPresented) {
            if let song = player.currentSong {
                AddToPlaylistSheet(songs: [song]) { isAddToPlaylistPresented = false }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedArtistId != nil },
            set: { if !$0 { selectedArtistId = nil } }
        )) {
            if let selectedArtistId {
                ArtistView(artistId: selectedArtistId) { self.selectedArtistId = nil }
            }
        }
    }

    /// The immersive backdrop, in the Yandex mould: the real cover fills the
    /// top of the screen edge-to-edge and fades, over its own heavy blur which
    /// carries the rest of the screen behind the controls.
    @ViewBuilder
    private var background: some View {
        Color.black
            .overlay {
                BlurredBackdrop(url: player.currentSong?.coverURL, blur: 55)
            }
            .overlay {
                // The record's colour, slowly breathing behind the controls.
                LivingMeshBackground(palette: palette)
                    .opacity(0.5)
                    .blendMode(.plusLighter)
            }
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    AsyncCoverImage(url: player.currentSong?.coverURL, cornerRadius: 0, displaySize: 720)
                        .frame(width: geo.size.width, height: geo.size.height * 0.56)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.80),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                .ignoresSafeArea()
            }
            .overlay(Color.black.opacity(0.28))
            .clipped()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: player.currentSong?.id)
    }

    /// Deliberately quiet: both of these sit over artwork, and at full white
    /// they were the loudest thing on a screen whose subject is the cover.
    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerGlyphButtonStyle())

            Spacer()

            menuButton
        }
    }

    private var menuButton: some View {
        Menu {
            Menu {
                ForEach(PlaybackSpeedOption.allCases) { option in
                    Button {
                        player.setPlaybackRate(option.rate)
                    } label: {
                        if player.playbackRate == option.rate {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Label(L("player.speed", "Скорость"), systemImage: "speedometer")
            }

            Menu {
                ForEach(AudioPlayerController.CrossfadeDuration.allCases) { option in
                    Button {
                        player.crossfadeDuration = option
                    } label: {
                        if player.crossfadeDuration == option {
                            Label(crossfadeLabel(option), systemImage: "checkmark")
                        } else {
                            Text(crossfadeLabel(option))
                        }
                    }
                }
            } label: {
                Label(L("player.crossfade", "Кроссфейд"), systemImage: "waveform.path")
            }


            Button {
                isAddToPlaylistPresented = true
            } label: {
                Label(L("player.addToPlaylist", "Добавить в плейлист"), systemImage: "text.badge.plus")
            }

            Button {
                markNotInterested()
            } label: {
                Label(L("player.notInterested", "Не интересно"), systemImage: "hand.thumbsdown")
            }

            ShareLink(item: shareText) {
                Label(L("player.share", "Поделиться"), systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .disabled(player.currentSong == nil)
    }

    /// Three glyphs, each centred in its own third of the row — with a
    /// `Spacer` between them the outer two hugged the screen edges and the
    /// gaps came out uneven the moment one of them changed width.
    private var bottomIconRow: some View {
        HStack(spacing: 0) {
            glyphButton("text.alignleft") { isLyricsPresented = true }
                .frame(maxWidth: .infinity)

            AirPlayRouteButton()
                .frame(width: 40, height: 40)
                .frame(maxWidth: .infinity)

            RepeatButton()
                .frame(width: 40, height: 40)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6)
    }

    private func crossfadeLabel(_ option: AudioPlayerController.CrossfadeDuration) -> String {
        option == .off ? L("player.crossfade.off", "Выкл") : "\(option.rawValue) \(L("unit.sec", "с"))"
    }

    private func glyphButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(player.currentSong == nil)
    }

    private var titleBlock: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentSong?.title ?? "")
                    .font(LaxifyTypography.playerTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                artistRow
            }

            Spacer()

            FavouriteHeart(isOn: isFavorite) {
                toggleFavorite()
            }
        }
    }

    /// Each credited artist is its own tap target, so a track by two people
    /// opens whichever one was tapped rather than only the first.
    @ViewBuilder
    private var artistRow: some View {
        let artists = player.currentSong?.artists ?? []

        if artists.isEmpty {
            Text(player.currentSong?.artistName ?? "")
                .font(LaxifyTypography.playerArtist)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                        Button {
                            guard !artist.id.isEmpty else { return }
                            selectedArtistId = artist.id
                        } label: {
                            // No underline: the name reads as a name, and a
                            // slightly brighter fill plus a generous tap
                            // target is enough to say it is tappable.
                            Text(artist.name)
                                .font(LaxifyTypography.playerArtist)
                                .foregroundStyle(.white.opacity(artist.id.isEmpty ? 0.6 : 0.9))
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ArtistLinkButtonStyle())
                        .disabled(artist.id.isEmpty)

                        if index < artists.count - 1 {
                            Text(", ")
                                .font(LaxifyTypography.playerArtist)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }


    private var controls: some View {
        HStack(spacing: 36) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
            }
            .opacity(player.hasPrevious ? 1 : 0.35)
            .disabled(!player.hasPrevious)

            Button {
                player.togglePlayPause()
            } label: {
                if player.isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34))
                        .frame(width: 64, height: 64)
                }
            }

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
            }
            .opacity(player.hasNext ? 1 : 0.35)
            .disabled(!player.hasNext)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }


    private func toggleFavorite() {
        guard let song = player.currentSong else { return }
        if let existing = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(existing)
            SyncService.shared.favoriteRemoved(trackId: song.id)
        } else {
            modelContext.insert(FavoriteTrack(song: song))
            SyncService.shared.favoriteAdded(song)
        }
    }

    private func markNotInterested() {
        guard let song = player.currentSong else { return }
        if !dislikedTracks.contains(where: { $0.id == song.id }) {
            modelContext.insert(DislikedTrack(id: song.id))
            SyncService.shared.dislikeAdded(trackId: song.id)
        }
        if let existingFavorite = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(existingFavorite)
            SyncService.shared.favoriteRemoved(trackId: song.id)
        }
        if player.hasNext {
            player.next()
        }
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN, time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Bare glyph, no material behind it — used for the collapse chevron and the
/// overflow menu at the top of the full player, where a glass circle competed
/// with the artwork for attention.
private struct PlayerGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// An artist name in the player. Says "tappable" by dimming and shrinking
/// under the finger, rather than by wearing an underline.
private struct ArtistLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1, anchor: .leading)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private enum PlaybackSpeedOption: Double, CaseIterable, Identifiable {
    case slow = 0.75
    case normal = 1.0
    case fast = 1.25
    case faster = 1.5

    var id: Double { rawValue }
    var rate: Double { rawValue }

    @MainActor
    var label: String {
        switch self {
        case .slow: return "0.75×"
        case .normal: return L("player.speedNormal", "Обычная")
        case .fast: return "1.25×"
        case .faster: return "1.5×"
        }
    }
}

