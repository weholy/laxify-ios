import SwiftUI

struct SongCardView: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCoverImage(url: song.coverURL)
                .frame(width: 150, height: 150)

            Text(song.title)
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            Text(song.artistName)
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
    }
}
