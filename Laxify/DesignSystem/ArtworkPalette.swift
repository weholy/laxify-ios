import SwiftUI
import UIKit

/// Colours taken from a piece of artwork.
///
/// Each month of listening gets its look from whatever was played most, so
/// no two look alike and none of it had to be designed per month. Reading
/// the colours from the image is also the only way to guarantee text placed
/// over it stays legible.
struct ArtworkPalette: Sendable, Equatable {
    /// The colour the image is mostly made of.
    let dominant: Color
    /// A second, more saturated one, for gradients that need somewhere to go.
    let accent: Color
    /// Whether the dominant colour is light enough that text over it should
    /// be dark.
    let prefersDarkText: Bool

    static let neutral = ArtworkPalette(
        dominant: Color(hex: 0x1C1C1E),
        accent: Color(hex: 0x3A3A3C),
        prefersDarkText: false
    )

    /// A background that reads as one colour but is never flat.
    var gradient: LinearGradient {
        LinearGradient(
            colors: [
                accent.opacity(0.95),
                dominant.opacity(0.85),
                Color.black.opacity(0.92)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var textColor: Color { prefersDarkText ? Color(hex: 0x111114) : .white }
    var secondaryText: Color { textColor.opacity(0.65) }
}

/// Works out a palette for an image, and remembers it.
actor PaletteExtractor {
    static let shared = PaletteExtractor()

    private var cache: [URL: ArtworkPalette] = [:]

    func palette(for url: URL?) async -> ArtworkPalette {
        guard let url else { return .neutral }

        if let known = cache[url] { return known }

        let sized = CoverImageLoader.variant(of: url, forDisplayWidth: 120)
        guard let image = await CoverImageLoader.shared.image(for: sized) else {
            return .neutral
        }

        let palette = Self.extract(from: image)
        cache[url] = palette

        if cache.count > 200 {
            cache.removeAll()
        }

        return palette
    }

    /// Averages the image down to a handful of pixels and picks from those.
    ///
    /// Drawing into a tiny context is the cheap way to do this: the hardware
    /// does the averaging, and what comes back is already the colours the
    /// image reads as from a distance — which is exactly what a background
    /// needs to be.
    private nonisolated static func extract(from image: UIImage) -> ArtworkPalette {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = image.cgImage else {
            return .neutral
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var candidates: [(colour: (r: Double, g: Double, b: Double), score: Double)] = []
        var totalR = 0.0, totalG = 0.0, totalB = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255

            totalR += r; totalG += g; totalB += b

            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum

            // Prefer colours that are actually colours: a photograph's
            // average is usually a muddy grey, which makes every month look
            // the same.
            candidates.append(((r, g, b), saturation * (0.35 + maximum * 0.65)))
        }

        let count = Double(side * side)
        let average = (r: totalR / count, g: totalG / count, b: totalB / count)

        let best = candidates.max { $0.score < $1.score }?.colour ?? average

        // Luminance as eyes weight it, not as arithmetic does.
        let luminance = 0.2126 * average.r + 0.7152 * average.g + 0.0722 * average.b

        return ArtworkPalette(
            dominant: Color(red: average.r, green: average.g, blue: average.b),
            accent: Color(red: best.r, green: best.g, blue: best.b),
            prefersDarkText: luminance > 0.62
        )
    }
}
