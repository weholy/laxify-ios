import SwiftUI
import SwiftData

struct FullPlayerView: View {
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    var player = AudioPlayerController.shared
    var downloads = DownloadManager.shared

    @State private var isLyricsPresented = false
    @Namespace private var lyricsZoom
    @State private var isAddToPlaylistPresented = false
    @State private var selectedArtistId: String?
    @State private var palette: ArtworkPalette = .neutral

    // MARK: - Export
    @State private var isExporting = false
    @State private var isSharePresented = false
    @State private var exportedFileURL: URL?
    @State private var exportErrorMessage: String?


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

            if isExporting {
                exportProgressOverlay
            }
        }
        .task(id: player.currentSong?.id) {
            palette = await PaletteExtractor.shared.palette(for: player.currentSong?.coverURL)
        }
        // Grows out of the glyph that opened it and shrinks back into it,
        // the same way the full player does from the mini player. A sheet
        // that slides up from nowhere loses the thread of where you were.
        .sheet(isPresented: $isLyricsPresented) {
            LyricsView()
                .navigationTransition(.zoom(sourceID: "lyrics", in: lyricsZoom))
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
        .sheet(isPresented: $isSharePresented) {
            if let exportedFileURL {
                ShareSheet(items: [exportedFileURL])
            }
        }
        .alert(
            L("player.exportFailedTitle", "Не получилось"),
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button(L("common.ok", "Ок"), role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    /// A small centred card, not a full-screen block: the player underneath
    /// keeps playing and stays visible while a track downloads for export,
    /// which on a slow connection can take a few seconds worth watching
    /// rather than staring at a blank screen for.
    private var exportProgressOverlay: some View {
        let fraction = player.currentSong.flatMap { downloads.progress[$0.id] }

        return VStack(spacing: 14) {
            if let fraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .frame(width: 140)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
            Text(L("player.exporting", "Готовим файл…"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(24)
        .frame(minWidth: 180)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExporting)
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
                    .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
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
                .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
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
                .matchedTransitionSource(id: "lyrics", in: lyricsZoom)
                .frame(maxWidth: .infinity)

            AirPlayRouteButton()
                .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
                .frame(maxWidth: .infinity)

            RepeatButton()
                .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
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
                .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(player.currentSong == nil)
    }

    private var titleBlock: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(
                    text: player.currentSong?.title ?? "",
                    font: LaxifyTypography.playerTitle,
                    color: .white
                )
                .contentShape(Rectangle())
                .onLongPressGesture {
                    exportAudioFile()
                }

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


    /// Long-press on the title: hands the actual audio file to the system
    /// share sheet, which is how "save this to Files" works on iOS. Reuses
    /// the same download this track's ring button would start — no second
    /// fetch path to keep in sync with the first.
    private func exportAudioFile() {
        guard let song = player.currentSong else { return }
        exportErrorMessage = nil

        if let local = DownloadManager.localURL(for: song.id) {
            presentExport(of: local, song: song)
            return
        }

        isExporting = true
        downloads.download(song)

        Task {
            while downloads.isDownloading(song.id) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let local = DownloadManager.localURL(for: song.id) else {
                isExporting = false
                exportErrorMessage = L("player.exportFailed", "Не удалось скачать трек для экспорта")
                return
            }
            isExporting = false
            presentExport(of: local, song: song)
        }
    }

    /// Copies the saved file to a name a person would recognise — the raw
    /// title as the source has it, untouched, per the user's own request —
    /// leaving the download cache's own `<id>.mp3` alone.
    private func presentExport(of local: URL, song: Song) {
        let rawName = song.rawTitle ?? song.title
        let safeName = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safeName.isEmpty ? song.id : safeName

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(Self.audioExtension(for: local))

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: local, to: destination)
            exportedFileURL = destination
            isSharePresented = true
        } catch {
            exportErrorMessage = L("player.exportFailed", "Не удалось подготовить файл")
        }
    }

    /// The download cache names every file `.mp3` regardless of what is
    /// actually inside it — fine for AVPlayer, which reads content rather
    /// than trusting extensions, but a rescued track (served from the
    /// YouTube fallback as `audio/mp4`) is really an M4A container, and
    /// handing it to another app mislabelled is how it arrives unplayable
    /// there. Sniffed from the file's own header rather than trusted.
    private static func audioExtension(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "mp3" }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count >= 8 else { return "mp3" }

        if header.starts(with: [0x49, 0x44, 0x33]) { return "mp3" } // "ID3"
        if header[0] == 0xFF, (header[1] & 0xE0) == 0xE0 { return "mp3" } // raw MPEG frame sync
        if header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 { return "m4a" } // "ftyp"
        return "mp3"
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

