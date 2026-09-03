import SwiftUI

struct MiniPlayerBar: View {
    var player = AudioPlayerController.shared
    /// When set, the bar is the source the full player zooms out of, so
    /// tapping it grows into the sheet the way Apple Music's does.
    var zoomNamespace: Namespace.ID?
    var onTap: () -> Void

    static let zoomID = "laxify.player.zoom"

    var body: some View {
        if let song = player.currentSong {
            bar(for: song)
                .zoomSource(id: Self.zoomID, in: zoomNamespace)
        }
    }

    private func bar(for song: Song) -> some View {
        HStack(spacing: 10) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: 26, displaySize: 44)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(
                    text: song.title,
                    font: LaxifyTypography.subheadline,
                    color: LaxifyPalette.textPrimary
                )
                Text(player.errorMessage ?? song.artistName)
                    .font(LaxifyTypography.caption)
                    .foregroundStyle(player.errorMessage == nil ? LaxifyPalette.textSecondary : LaxifyPalette.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                player.togglePlayPause()
            } label: {
                if player.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .opacity(player.hasNext ? 1 : 0.35)
            .disabled(!player.hasNext)
        }
        .padding(.horizontal, 10)
        .frame(height: LaxifyMetrics.miniPlayerHeight)
        .laxGlassCard(cornerRadius: LaxifyMetrics.miniPlayerCornerRadius)
        .contentShape(RoundedRectangle(cornerRadius: LaxifyMetrics.miniPlayerCornerRadius, style: .continuous))
        .onTapGesture(perform: onTap)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: song.id)
    }
}

extension View {
    /// `matchedTransitionSource` that no-ops when there is no namespace, so a
    /// caller that does not care about the zoom can leave it off.
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
