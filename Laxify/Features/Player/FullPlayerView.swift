import SwiftUI
import SwiftData

struct FullPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var favorites: [FavoriteTrack]

    var player = AudioPlayerController.shared

    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return favorites.contains { $0.id == song.id }
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 24) {
                topBar

                Spacer()

                artwork

                titleBlock

                scrubber

                controls

                volumeSlider

                Spacer()
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 24)
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
            glassIconButton(systemName: "ellipsis") {}
        }
    }

    private var artwork: some View {
        AsyncCoverImage(url: player.currentSong?.coverURL, cornerRadius: 24)
            .frame(width: 280, height: 280)
            .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
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

    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN, time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
