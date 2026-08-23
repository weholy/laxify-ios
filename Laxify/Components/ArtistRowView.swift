import SwiftUI

struct ArtistRowView: View {
    let artist: MusicArtist

    var body: some View {
        HStack(spacing: 12) {
            AsyncCoverImage(url: artist.imageURL, cornerRadius: 38, displaySize: 56)
                .frame(width: 48, height: 48)
                .clipShape(Circle())

            ArtistName(name: artist.name, isVerified: artist.isVerified, badgeSize: 13)
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            Spacer()
        }
    }
}
