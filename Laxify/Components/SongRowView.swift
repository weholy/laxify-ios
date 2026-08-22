import SwiftUI

struct SongRowView: View {
    let song: Song
    var isFavorite: Bool = false

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

            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LaxifyPalette.accent)
                    .transition(.scale.combined(with: .opacity))
            }

            Text(formattedDuration)
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textTertiary)
        }
        .contentShape(Rectangle())
    }

    private var formattedDuration: String {
        let minutes = Int(song.duration) / 60
        let seconds = Int(song.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
