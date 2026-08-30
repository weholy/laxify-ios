import ActivityKit
import SwiftUI
import WidgetKit

/// "Now playing" in the Dynamic Island and on the Lock Screen — the Laxify
/// presence there while something is playing, the way Telegram sits in the
/// island during a call. Display only: tapping it opens the app, and the
/// system's own media controls handle play/pause/next.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    mark.padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    stateIcon(context.state.isPlaying)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(.white)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
            } compactLeading: {
                mark
            } compactTrailing: {
                stateIcon(context.state.isPlaying)
            } minimal: {
                mark
            }
            .widgetURL(URL(string: "laxify://open"))
            .keylineTint(Color(red: 0.48, green: 0.36, blue: 1.0))
        }
    }

    private var mark: some View {
        Image("WidgetLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func stateIcon(_ isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
    }
}

private struct LockScreenView: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image("WidgetLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                ProgressView(value: state.progress)
                    .tint(.white)
                    .scaleEffect(x: 1, y: 0.55, anchor: .center)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(14)
    }
}
