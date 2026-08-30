import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// "Now playing" in the Dynamic Island and on the Lock Screen. The Lock Screen
/// card is art-forward — the cover fills it, blurred, with a dark wash and the
/// track details on top, the same treatment as the in-app full player. It sits
/// alongside iOS's own media player (which can't be restyled), not instead of
/// it. Display only: tapping opens the app.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    cover(context.state.artwork, side: 30).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    stateIcon(context.state.isPlaying).padding(.trailing, 6)
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
                cover(context.state.artwork, side: 20)
            } compactTrailing: {
                stateIcon(context.state.isPlaying)
            } minimal: {
                cover(context.state.artwork, side: 20)
            }
            .widgetURL(URL(string: "laxify://open"))
            .keylineTint(Color(red: 0.48, green: 0.36, blue: 1.0))
        }
    }

    private func stateIcon(_ isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
    }
}

// MARK: - shared cover view

/// The cover as a rounded square, or the Laxify mark when it hasn't loaded.
@ViewBuilder
private func cover(_ data: Data?, side: CGFloat) -> some View {
    let radius = side * 0.24
    if let data, let ui = UIImage(data: data) {
        Image(uiImage: ui)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    } else {
        Image("WidgetLogo")
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Lock Screen card

private struct LockScreenCard: View {
    let state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        ZStack {
            background
            HStack(spacing: 13) {
                cover(state.artwork, side: 54)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    ProgressView(value: state.progress)
                        .tint(.white)
                        .scaleEffect(x: 1, y: 0.5, anchor: .center)
                        .padding(.top, 3)
                }

                Spacer(minLength: 0)

                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
        }
    }

    @ViewBuilder
    private var background: some View {
        if let data = state.artwork, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.4)
                .blur(radius: 24, opaque: true)
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.32), .black.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipped()
        } else {
            LinearGradient(
                colors: [Color(red: 0.48, green: 0.36, blue: 1.0), Color(red: 0.23, green: 0.48, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
