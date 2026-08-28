import SwiftUI

/// Progress bar and time labels, isolated from the rest of the player.
///
/// The playback clock ticks ten times a second and hops to the main actor on
/// the way, so a bar bound to it visibly steps and trails the audio. This
/// reads the player's own clock through a display-linked timeline instead, so
/// the fill glides at screen rate — and because the view is small, a frame
/// redraws a capsule and two labels rather than the whole player.
struct PlayerScrubber: View {
    var player = AudioPlayerController.shared

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    private var duration: TimeInterval { max(player.duration, 0.1) }

    var body: some View {
        // Paused only while a finger is down: playback progress needs the
        // timeline, a held scrub does not.
        TimelineView(.animation(paused: isScrubbing)) { _ in
            let fraction = isScrubbing
                ? scrubFraction
                : min(max(player.preciseTime / duration, 0), 1)

            VStack(spacing: 8) {
                PlayerProgressBar(
                    fraction: fraction,
                    isScrubbing: isScrubbing,
                    onScrubChanged: { value in
                        isScrubbing = true
                        scrubFraction = value
                    },
                    onScrubEnded: { value in
                        scrubFraction = value
                        isScrubbing = false
                        player.seek(to: value * duration)
                    }
                )

                HStack {
                    Text(Self.format(fraction * duration))
                    Spacer()
                    Text("-" + Self.format(max(duration - fraction * duration, 0)))
                }
                .font(LaxifyTypography.caption)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
            }
        }
        .sensoryFeedback(.impact(weight: .soft), trigger: isScrubbing)
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN, time >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}

/// The bar itself, in the Apple Music mould: a thin capsule that swells under
/// a touch, no knob until then, a generous invisible hit area so a slim bar
/// is still easy to catch.
private struct PlayerProgressBar: View {
    let fraction: Double
    let isScrubbing: Bool
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    private var trackHeight: CGFloat { isScrubbing ? 10 : 5 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.24))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: max(width * clamped, trackHeight), height: trackHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isScrubbing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onScrubChanged(progress(at: gesture.location.x, width: width))
                    }
                    .onEnded { gesture in
                        onScrubEnded(progress(at: gesture.location.x, width: width))
                    }
            )
        }
        .frame(height: 32)
    }

    private func progress(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
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
                trackHeight: 5,
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
