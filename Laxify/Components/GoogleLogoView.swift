import SwiftUI

/// Google's four-colour "G".
///
/// Drawn from the official path data rather than assembled from stroked arcs:
/// the arc approach could not reproduce the flat cut where the bar meets the
/// ring, or the blue segment's straight edges, so it never quite looked right.
/// The coordinates below come from the published 48×48 mark and are scaled to
/// whatever size is requested.
struct GoogleLogoView: View {
    var size: CGFloat = 20

    private let blue = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
    private let green = Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255)
    private let yellow = Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255)
    private let red = Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255)

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 48
            context.scaleBy(x: scale, y: scale)

            context.fill(Self.bluePath, with: .color(blue))
            context.fill(Self.greenPath, with: .color(green))
            context.fill(Self.yellowPath, with: .color(yellow))
            context.fill(Self.redPath, with: .color(red))
        }
        .frame(width: size, height: size)
    }

    /// Right side and the horizontal bar.
    private static var bluePath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 46.98, y: 24.55))
        path.addCurve(
            to: CGPoint(x: 46.6, y: 20),
            control1: CGPoint(x: 46.98, y: 22.98),
            control2: CGPoint(x: 46.85, y: 21.46)
        )
        path.addLine(to: CGPoint(x: 24, y: 20))
        path.addLine(to: CGPoint(x: 24, y: 29.02))
        path.addLine(to: CGPoint(x: 36.94, y: 29.02))
        path.addCurve(
            to: CGPoint(x: 31.77, y: 37.11),
            control1: CGPoint(x: 36.36, y: 32.21),
            control2: CGPoint(x: 34.68, y: 34.91)
        )
        path.addLine(to: CGPoint(x: 31.77, y: 43.01))
        path.addLine(to: CGPoint(x: 39.89, y: 43.01))
        path.addCurve(
            to: CGPoint(x: 46.98, y: 24.55),
            control1: CGPoint(x: 44.6, y: 38.68),
            control2: CGPoint(x: 46.98, y: 32.3)
        )
        path.closeSubpath()
        return path
    }

    /// Bottom arc.
    private static var greenPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 24, y: 48))
        path.addCurve(
            to: CGPoint(x: 39.89, y: 43.01),
            control1: CGPoint(x: 30.48, y: 48),
            control2: CGPoint(x: 35.93, y: 45.87)
        )
        path.addLine(to: CGPoint(x: 31.77, y: 37.11))
        path.addCurve(
            to: CGPoint(x: 24, y: 39.2),
            control1: CGPoint(x: 29.71, y: 38.48),
            control2: CGPoint(x: 27.09, y: 39.2)
        )
        path.addCurve(
            to: CGPoint(x: 12.19, y: 30.51),
            control1: CGPoint(x: 18.05, y: 39.2),
            control2: CGPoint(x: 13.99, y: 35.19)
        )
        path.addLine(to: CGPoint(x: 3.8, y: 30.51))
        path.addLine(to: CGPoint(x: 3.8, y: 36.6))
        path.addCurve(
            to: CGPoint(x: 24, y: 48),
            control1: CGPoint(x: 7.96, y: 44.85),
            control2: CGPoint(x: 15.32, y: 48)
        )
        path.closeSubpath()
        return path
    }

    /// Left arc.
    private static var yellowPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 12.19, y: 30.51))
        path.addCurve(
            to: CGPoint(x: 11.67, y: 24),
            control1: CGPoint(x: 11.86, y: 28.44),
            control2: CGPoint(x: 11.67, y: 26.26)
        )
        path.addCurve(
            to: CGPoint(x: 12.19, y: 17.49),
            control1: CGPoint(x: 11.67, y: 21.74),
            control2: CGPoint(x: 11.86, y: 19.56)
        )
        path.addLine(to: CGPoint(x: 12.19, y: 11.4))
        path.addLine(to: CGPoint(x: 3.8, y: 11.4))
        path.addCurve(
            to: CGPoint(x: 3.8, y: 36.6),
            control1: CGPoint(x: 1.38, y: 15.19),
            control2: CGPoint(x: 0, y: 19.45)
        )
        path.closeSubpath()
        return path
    }

    /// Top arc.
    private static var redPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 24, y: 8.8))
        path.addCurve(
            to: CGPoint(x: 33.21, y: 12.4),
            control1: CGPoint(x: 27.62, y: 8.8),
            control2: CGPoint(x: 30.86, y: 10.04)
        )
        path.addLine(to: CGPoint(x: 40.06, y: 5.54))
        path.addCurve(
            to: CGPoint(x: 24, y: 0),
            control1: CGPoint(x: 35.9, y: 1.67),
            control2: CGPoint(x: 30.48, y: 0)
        )
        path.addCurve(
            to: CGPoint(x: 3.8, y: 11.4),
            control1: CGPoint(x: 15.32, y: 0),
            control2: CGPoint(x: 7.96, y: 3.15)
        )
        path.addLine(to: CGPoint(x: 12.19, y: 17.49))
        path.addCurve(
            to: CGPoint(x: 24, y: 8.8),
            control1: CGPoint(x: 13.99, y: 12.81),
            control2: CGPoint(x: 18.05, y: 8.8)
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(spacing: 24) {
        GoogleLogoView(size: 20)
        GoogleLogoView(size: 44)
        GoogleLogoView(size: 96)
    }
    .padding()
}
