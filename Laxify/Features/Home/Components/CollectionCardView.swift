import SwiftUI

struct CollectionCardView: View {
    let collection: MusicCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncCoverImage(url: collection.coverURL, displaySize: 170)
                .aspectRatio(1, contentMode: .fit)

            Text(collection.title)
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            if let subtitle = collection.subtitle {
                Text(subtitle)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}
