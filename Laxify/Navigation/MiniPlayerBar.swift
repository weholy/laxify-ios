import SwiftUI

struct MiniPlayerBar: View {
    var player = AudioPlayerController.shared
    var onTap: () -> Void

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 10) {
                AsyncCoverImage(url: song.coverURL, cornerRadius: 16)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(LaxifyTypography.subheadline)
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(1)
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
}
