import SwiftUI
import SwiftData

struct FullPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]
    @Query private var dislikedTracks: [DislikedTrack]

    var player = AudioPlayerController.shared

    @State private var isLyricsPresented = false
    @State private var isQueuePresented = false
    @State private var artworkDragOffset: CGFloat = 0

    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return favorites.contains { $0.id == song.id }
    }

    private var shareText: String {
        guard let song = player.currentSong else { return "" }
        return "\(song.title) — \(song.artistName)"
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 20) {
                topBar

                Spacer()

                artwork

                titleBlock

                scrubber

                controls

                volumeSlider

                bottomIconRow

                Spacer()
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $isLyricsPresented) {
            LyricsView()
        }
        .sheet(isPresented: $isQueuePresented) {
            QueueView()
        }
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            LaxifyPalette.background

            if let url = player.currentSong?.coverURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
                .blur(radius: 60)

                Color.black.opacity(0.55)
            }
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            glassIconButton(systemName: "chevron.down") { dismiss() }
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
                Label("Скорость", systemImage: "speedometer")
            }

            Menu {
                ForEach(SleepTimerOption.allCases) { option in
                    Button(option.label) {
                        player.setSleepTimer(minutes: option.minutes)
                    }
                }
                if player.sleepTimerDeadline != nil {
                    Button("Отключить таймер", role: .destructive) {
                        player.cancelSleepTimer()
                    }
                }
            } label: {
                Label("Таймер сна", systemImage: "moon.zzz")
            }

            Button {
                markNotInterested()
            } label: {
                Label("Не интересно", systemImage: "hand.thumbsdown")
            }

            ShareLink(item: shareText) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
        }
        .laxGlassCircle(interactive: true)
        .disabled(player.currentSong == nil)
    }

    private var artwork: some View {
        AsyncCoverImage(url: player.currentSong?.coverURL, cornerRadius: 24)
            .frame(width: 280, height: 280)
            .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
            .offset(y: artworkDragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard value.translation.height < 0 else { return }
                        artworkDragOffset = value.translation.height
                    }
                    .onEnded { value in
                        if value.translation.height < -60 {
                            isLyricsPresented = true
                        }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            artworkDragOffset = 0
                        }
                    }
            )
    }

    private var bottomIconRow: some View {
        HStack {
            Button {
                isLyricsPresented = true
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)

            Spacer()

            AirPlayRouteButton()
                .frame(width: 36, height: 36)

            Spacer()

            Button {
                isQueuePresented = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    private var titleBlock: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentSong?.title ?? "")
                    .font(LaxifyTypography.playerTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(player.currentSong?.artistName ?? "")
                    .font(LaxifyTypography.playerArtist)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFavorite ? LaxifyPalette.accent : .white)
            }
            .buttonStyle(.plain)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            .tint(.white)

            HStack {
                Text(formattedTime(player.currentTime))
                Spacer()
                Text("-" + formattedTime(max(player.duration - player.currentTime, 0)))
            }
            .font(LaxifyTypography.caption)
            .foregroundStyle(.white.opacity(0.7))
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

    private var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider()
                .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.7))
    }

    private func glassIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
        }
        .laxGlassCircle(interactive: true)
    }

    private func toggleFavorite() {
        guard let song = player.currentSong else { return }
        if let existing = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(existing)
        } else {
            modelContext.insert(FavoriteTrack(song: song))
        }
    }

    private func markNotInterested() {
        guard let song = player.currentSong else { return }
        if !dislikedTracks.contains(where: { $0.id == song.id }) {
            modelContext.insert(DislikedTrack(id: song.id))
        }
        if let existingFavorite = favorites.first(where: { $0.id == song.id }) {
            modelContext.delete(existingFavorite)
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

private enum PlaybackSpeedOption: Double, CaseIterable, Identifiable {
    case slow = 0.75
    case normal = 1.0
    case fast = 1.25
    case faster = 1.5

    var id: Double { rawValue }
    var rate: Double { rawValue }

    var label: String {
        switch self {
        case .slow: return "0.75×"
        case .normal: return "Обычная"
        case .fast: return "1.25×"
        case .faster: return "1.5×"
        }
    }
}

private enum SleepTimerOption: Int, CaseIterable, Identifiable {
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var label: String { "\(rawValue) мин" }
}
