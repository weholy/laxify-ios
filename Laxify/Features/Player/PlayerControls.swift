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
            .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
    }
}

/// The favourite heart.
///
/// The tap is the only feedback there is, so it gets a proper one: the fill
/// springs out of the middle as the outline fades, the whole glyph overshoots
/// once, and a ring and six sparks push outward and vanish. Nothing happens on
/// the way out — taking something out of a library should not celebrate.
struct FavouriteHeart: View {
    let isOn: Bool
    var action: () -> Void

    /// The overshoot on the glyph itself.
    @State private var pop: CGFloat = 1
    /// 0 → 1 across one burst; drives the ring and the sparks together.
    @State private var burst: CGFloat = 0
    @State private var burstOpacity: Double = 0

    var body: some View {
        Button(action: action) {
            ZStack {
                ring
                sparks
                glyph
            }
            .font(.system(size: 20, weight: .semibold))
            .scaleEffect(pop)
            .frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.34, dampingFraction: 0.55), value: isOn)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .onChange(of: isOn) { _, added in
            guard added else { return }
            celebrate()
        }
    }

    private var glyph: some View {
        ZStack {
            Image(systemName: "heart")
                .foregroundStyle(.white)
                .opacity(isOn ? 0 : 1)
                .scaleEffect(isOn ? 0.7 : 1)

            Image(systemName: "heart.fill")
                .foregroundStyle(LaxifyPalette.accent)
                .opacity(isOn ? 1 : 0)
                .scaleEffect(isOn ? 1 : 0.2)
        }
    }

    private var ring: some View {
        Circle()
            .stroke(LaxifyPalette.accent, lineWidth: 2)
            .frame(width: 26, height: 26)
            .scaleEffect(0.4 + burst * 1.5)
            .opacity(burstOpacity)
    }

    private var sparks: some View {
        ForEach(0..<6, id: \.self) { index in
            Circle()
                .fill(LaxifyPalette.accent)
                .frame(width: 3.5, height: 3.5)
                // Offset first, rotate second: `offset` leaves the layout
                // frame where it was, so the rotation swings each spark
                // around the heart rather than around itself.
                .offset(y: -(10 + burst * 11))
                .rotationEffect(.degrees(Double(index) * 60))
                .scaleEffect(1 - burst * 0.7)
                .opacity(burstOpacity)
        }
    }

    private func celebrate() {
        pop = 1
        burst = 0
        burstOpacity = 0.9

        withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { pop = 1.3 }
        withAnimation(.easeOut(duration: 0.5)) { burst = 1 }
        withAnimation(.easeOut(duration: 0.42).delay(0.06)) { burstOpacity = 0 }

        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { pop = 1 }
        }
    }
}
