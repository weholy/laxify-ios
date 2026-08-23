import SwiftUI

/// Progress bar and time labels, isolated from the rest of the player.
///
/// The playback clock ticks ten times a second. When the whole player screen
/// reads `currentTime`, every one of those ticks invalidates the blurred
/// artwork backdrop, the artwork card and the control row — which is what made
/// dragging feel heavy. Keeping the observation inside this small view means a
/// tick redraws a capsule and two labels instead.
struct PlayerScrubber: View {
    var player = AudioPlayerController.shared

    @State private var isScrubbing = false
    @State private var scrubTarget: TimeInterval = 0

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTarget : player.currentTime
    }

    var body: some View {
        VStack(spacing: 2) {
            LaxifySlider(
                value: Binding(
                    get: { displayedTime },
                    set: { newValue in
                        scrubTarget = newValue
                        if !isScrubbing {
                            player.seek(to: newValue)
                        }
                    }
                ),
                range: 0...max(player.duration, 1),
                // Slim on purpose: the bar sits under the artwork and only
                // has to be readable, not prominent.
                trackHeight: 3,
                isGlass: true,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        player.seek(to: scrubTarget)
                    }
                }
            )

            HStack {
                Text(Self.format(displayedTime))
                Spacer()
                Text("-" + Self.format(max(player.duration - displayedTime, 0)))
            }
            .font(LaxifyTypography.caption)
            .foregroundStyle(.white.opacity(0.7))
            .monospacedDigit()
        }
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN, time >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

/// Volume row, isolated for the same reason: it observes the volume
/// controller, which the rest of the player has no reason to redraw for.
struct PlayerVolumeRow: View {
    var volume = VolumeController.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")

            LaxifySlider(
                value: Binding(
                    get: { volume.volume },
                    set: { volume.setVolume($0) }
                ),
                range: 0...1,
                trackHeight: 3,
                tint: .white.opacity(0.9),
                isGlass: true
            )

            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.7))
        .background(volume.hostView)
    }
}
