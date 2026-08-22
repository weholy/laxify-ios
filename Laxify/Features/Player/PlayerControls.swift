import SwiftUI

/// What happens when a track ends, in one button.
///
/// Three states, cycled by tapping: play through and stop, start the queue
/// again, or repeat this track. The badge appears only for the last of those,
/// because "1" next to a loop is the one people already read as meaning a
/// single track.
struct RepeatButton: View {
    var player = AudioPlayerController.shared

    private var isActive: Bool { player.repeatMode != .off }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                player.cycleRepeatMode()
            }
        } label: {
            ZStack {
                Image(systemName: "repeat")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isActive ? LaxifyPalette.accent : .white.opacity(0.55))

                if player.repeatMode == .one {
                    Text("1")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.accent)
                        .padding(2)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .offset(x: 9, y: 7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
    }
}

/// The favourite star.
///
/// Filling in is the whole feedback for the tap, so it is worth doing
/// properly: the outline fades as the fill grows out of the middle, rather
/// than one glyph being swapped for another mid-gesture.
struct FavouriteStar: View {
    let isOn: Bool
    var action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                Image(systemName: "star")
                    .foregroundStyle(.white)
                    .opacity(isOn ? 0 : 1)
                    .scaleEffect(isOn ? 0.8 : 1)

                Image(systemName: "star.fill")
                    .foregroundStyle(LaxifyPalette.accent)
                    .opacity(isOn ? 1 : 0)
                    .scaleEffect(isOn ? 1 : 0.4)
            }
            .font(.system(size: 20, weight: .semibold))
            .scaleEffect(pulse ? 1.22 : 1)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: isOn)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .onChange(of: isOn) { _, added in
            // A single overshoot on the way in, and nothing on the way out:
            // removing something should not celebrate.
            guard added else { return }

            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { pulse = true }
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pulse = false }
            }
        }
    }
}
