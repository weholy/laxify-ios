import SwiftUI

/// Google's four-colour mark, drawn with arcs rather than shipped as an asset.
///
/// The SDK's own button doesn't match this app's shape language, and a single
/// glyph isn't worth bundling a raster for — so the ring is four trimmed arcs
/// plus the bar that closes the G.
struct GoogleLogoView: View {
    var size: CGFloat = 20

    private let blue = Color(hex: 0x4285F4)
    private let green = Color(hex: 0x34A853)
    private let yellow = Color(hex: 0xFBBC05)
    private let red = Color(hex: 0xEA4335)

    private var lineWidth: CGFloat { size * 0.23 }

    var body: some View {
        ZStack {
            arc(from: 0.02, to: 0.26, color: blue)
            arc(from: 0.26, to: 0.51, color: green)
            arc(from: 0.51, to: 0.74, color: yellow)
            arc(from: 0.74, to: 0.98, color: red)

            // The crossbar the arcs open onto, sitting on the mark's midline.
            Rectangle()
                .fill(blue)
                .frame(width: size * 0.34, height: lineWidth)
                .offset(x: size * 0.22, y: 0)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-8))
    }

    private func arc(from: CGFloat, to: CGFloat, color: Color) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            .padding(lineWidth / 2)
            .rotationEffect(.degrees(-90))
    }
}

#Preview {
    HStack(spacing: 20) {
        GoogleLogoView(size: 20)
        GoogleLogoView(size: 44)
        GoogleLogoView(size: 88)
    }
    .padding()
}
