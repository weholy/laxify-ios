import SwiftUI

struct AlbumCardView: View {
    let album: MusicAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCoverImage(url: album.coverURL)
                .frame(width: 140, height: 140)

            Text(album.title)
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            if let year = album.year {
                Text(String(year))
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
        }
        .frame(width: 140, alignment: .leading)
    }
}
