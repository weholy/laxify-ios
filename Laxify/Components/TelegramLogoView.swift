import SwiftUI

/// Telegram's paper-plane mark.
///
/// Font Awesome's `telegram-plane` outline (viewBox `0 0 448 512`), converted
/// from its path data to absolute points and filled flat — the same approach
/// as `GoogleLogoView`, so the glyph stays crisp at any size.
struct TelegramLogoView: View {
    var size: CGFloat = 20
    var color: Color = .white

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 512
            context.scaleBy(x: scale, y: scale)
            // The art is 448 wide inside a 512 box — nudge it to the centre.
            context.translateBy(x: 32, y: 0)
            context.fill(Self.plane, with: .color(color))
        }
        .frame(width: size, height: size)
    }

    private static var plane: Path {
        var p = Path()
        p.move(to: CGPoint(x: 446.7, y: 98.6))
        p.addLine(to: CGPoint(x: 379.1, y: 417.4))
        p.addCurve(
            to: CGPoint(x: 341.8, y: 434.9),
            control1: CGPoint(x: 374.0, y: 439.9),
            control2: CGPoint(x: 360.7, y: 445.5)
        )
        p.addLine(to: CGPoint(x: 238.8, y: 359.0))
        p.addLine(to: CGPoint(x: 189.1, y: 406.8))
        p.addCurve(
            to: CGPoint(x: 168.4, y: 416.9),
            control1: CGPoint(x: 183.6, y: 412.3),
            control2: CGPoint(x: 179.0, y: 416.9)
        )
        p.addLine(to: CGPoint(x: 175.8, y: 312.0))
        p.addLine(to: CGPoint(x: 366.7, y: 139.5))
        p.addCurve(
            to: CGPoint(x: 353.8, y: 135.4),
            control1: CGPoint(x: 375.0, y: 132.1),
            control2: CGPoint(x: 364.9, y: 128.0)
        )
        p.addLine(to: CGPoint(x: 117.8, y: 284.0))
        p.addLine(to: CGPoint(x: 16.2, y: 252.2))
        p.addCurve(
            to: CGPoint(x: 20.8, y: 219.5),
            control1: CGPoint(x: -5.9, y: 245.3),
            control2: CGPoint(x: -6.3, y: 230.1)
        )
        p.addLine(to: CGPoint(x: 418.2, y: 66.4))
        p.addCurve(
            to: CGPoint(x: 446.7, y: 98.6),
            control1: CGPoint(x: 436.6, y: 59.5),
            control2: CGPoint(x: 452.7, y: 70.5)
        )
        p.closeSubpath()
        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        TelegramLogoView(size: 20).background(.blue)
        TelegramLogoView(size: 44).background(.blue)
        TelegramLogoView(size: 96).background(.blue)
    }
    .padding()
}
