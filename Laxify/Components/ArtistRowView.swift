import SwiftUI

struct ArtistRowView: View {
    let artist: MusicArtist

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverImage(url: artist.imageURL, cornerRadius: 24)
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            Text(artist.name)
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            Spacer()
        }
    }
}
