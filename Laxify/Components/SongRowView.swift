import SwiftUI

struct SongRowView: View {
    let song: Song
    var isFavorite: Bool = false

    var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: LaxifyMetrics.smallCornerRadius, displaySize: 56)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)

                Text(song.artistName)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            downloadMark

            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LaxifyPalette.accent)
                    .transition(.scale.combined(with: .opacity))
            }

            // Hidden rather than shown as "0:00" when the length is not known
            // yet — the library backfills it in the background.
            if song.duration > 0 {
                Text(formattedDuration)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Small and grey on purpose: this says the track will play with the
    /// network off, which is worth knowing and not worth announcing.
    @ViewBuilder
    private var downloadMark: some View {
        if let fraction = downloads.progress[song.id] {
            Circle()
                .trim(from: 0, to: max(0.05, fraction))
                .stroke(LaxifyPalette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 13, height: 13)
                .animation(.linear(duration: 0.3), value: fraction)
        } else if downloads.isDownloaded(song.id) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(LaxifyPalette.textTertiary)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var formattedDuration: String {
        let minutes = Int(song.duration) / 60
        let seconds = Int(song.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
