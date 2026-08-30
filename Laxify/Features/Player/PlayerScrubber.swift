import SwiftUI

/// Progress bar and time labels, isolated from the rest of the player.
///
/// Built on the system `Slider` with its thumb hidden — the same thing Apple
/// Music does. That buys the whole interaction for free: the bar swells under
/// a finger, the touch target is generous, dragging is rubber-banded at the
/// ends, and the haptics are the system's. Ours was hand-rolled from a
/// `DragGesture` and had none of that.
///
/// The playback clock ticks ten times a second and hops to the main actor on
/// the way, so a bar bound to it visibly steps. This reads the player's own
/// clock through a display-linked timeline instead, so the fill glides at
/// screen rate — and because the view is small, a frame redraws a slider and
/// two labels rather than the whole player.
struct PlayerScrubber: View {
    var player = AudioPlayerController.shared

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var duration: TimeInterval { max(player.duration, 0.1) }

    var body: some View {
        // Paused only while a finger is down: playback progress needs the
        // timeline, a held scrub does not.
        TimelineView(.animation(paused: isScrubbing)) { _ in
            let elapsed = isScrubbing
                ? scrubTime
                : min(max(player.preciseTime, 0), duration)

            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { min(max(elapsed, 0), duration) },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if editing {
                            scrubTime = elapsed
                            isScrubbing = true
                        } else {
                            isScrubbing = false
                            player.seek(to: scrubTime)
                        }
                    }
                )
                .sliderThumbVisibility(.hidden)
                .tint(.white)

                HStack {
                    Text(Self.format(elapsed))
                    Spacer()
                    Text("-" + Self.format(max(duration - elapsed, 0)))
                }
                .font(LaxifyTypography.caption)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
            }
            // A fresh bar per track, so the fill never animates back from the
            // end of one song to the start of the next.
            .id(player.currentSong?.id)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isScrubbing)
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

            // Writes through on every change, not only when the finger lifts —
            // the old slider staged the value and applied it on release, so
            // dragging did nothing until you let go.
            Slider(
                value: Binding(
                    get: { volume.volume },
                    set: { volume.setVolume($0) }
                ),
                in: 0...1
            )
            .sliderThumbVisibility(.hidden)
            .tint(.white)

            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.7))
        .background(volume.hostView)
    }
}
