import ActivityKit
import SwiftUI
import WidgetKit

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            lockScreenView(context.state)
                .activityBackgroundTint(.black.opacity(0.7))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    cover(context.state, size: 46)
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    favoriteButton(context.state)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        progressBar(context.state)
                        transportControls(context.state, size: 26)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                cover(context.state, size: 20)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 10 / 255, green: 132 / 255, blue: 1))
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 10 / 255, green: 132 / 255, blue: 1))
            }
        }
    }

    private func lockScreenView(_ state: NowPlayingAttributes.ContentState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                cover(state, size: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                favoriteButton(state)
            }

            progressBar(state)

            transportControls(state, size: 28)
        }
        .padding(16)
    }

    private func cover(_ state: NowPlayingAttributes.ContentState, size: CGFloat) -> some View {
        // AsyncImage is unavailable to widgets, so artwork is whatever the
        // system already cached; the gradient keeps the layout stable when
        // there is nothing to draw.
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 10 / 255, green: 132 / 255, blue: 1),
                        Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }

    private func progressBar(_ state: NowPlayingAttributes.ContentState) -> some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 3)

                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * min(max(state.progress, 0), 1), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)

            HStack {
                Text(format(state.elapsed))
                Spacer()
                Text("-" + format(max(state.duration - state.elapsed, 0)))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .monospacedDigit()
        }
    }

    private func transportControls(
        _ state: NowPlayingAttributes.ContentState,
        size: CGFloat
    ) -> some View {
        HStack(spacing: 34) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private func favoriteButton(_ state: NowPlayingAttributes.ContentState) -> some View {
        Button(intent: ToggleFavoriteIntent()) {
            Image(systemName: state.isFavorite ? "star.fill" : "star")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(
                    state.isFavorite
                        ? Color(red: 10 / 255, green: 132 / 255, blue: 1)
                        : .white
                )
        }
        .buttonStyle(.plain)
    }

    private func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}
