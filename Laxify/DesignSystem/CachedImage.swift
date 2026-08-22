import SwiftUI
import UIKit

/// A plain cached image, for the places that are not artwork tiles.
///
/// Shares the artwork cache, so a cover already fetched for a list costs
/// nothing when the player opens on the same track.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var displaySize: CGFloat = 200
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        // The image is drawn as an overlay on a shape that takes whatever
        // space it is given, and is clipped to it.
        //
        // Drawn directly, a resizable image reports the pixel size of what it
        // loaded — a 500-point square for artwork — and a ZStack sized to fit
        // that grows past the screen. That is what made screens look
        // stretched, and it is fixed here rather than at each call site so it
        // cannot come back somewhere else.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    placeholder()
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }

        let sized = CoverImageLoader.variant(of: url, forDisplayWidth: displaySize)

        if let cached = CoverImageLoader.shared.cached(sized) {
            image = cached
            return
        }

        image = nil
        guard let loaded = await CoverImageLoader.shared.image(for: sized) else { return }
        withAnimation(.easeOut(duration: 0.25)) { image = loaded }
    }
}

extension CachedImage where Placeholder == Color {
    init(url: URL?, displaySize: CGFloat = 200, contentMode: ContentMode = .fill) {
        self.init(url: url, displaySize: displaySize, contentMode: contentMode) {
            Color.clear
        }
    }
}

/// The blurred wash behind a header or the player.
///
/// Deliberately loads a small variant: the image is blurred past the point
/// where any detail survives, so a large one costs bandwidth for a result
/// nobody can tell apart.
struct BlurredBackdrop: View {
    let url: URL?
    var blur: CGFloat = 60
    var opacity: Double = 1

    var body: some View {
        CachedImage(url: url, displaySize: 120)
            .blur(radius: blur)
            .opacity(opacity)
            // Blur draws outside the bounds it was given; without clipping
            // that spill is what a parent measures.
            .clipped()
    }
}
