import SwiftUI

/// The mark that says an account is who it claims to be.
///
/// Drawn rather than shipped as an image: an image would carry a background
/// to strip, soften at large sizes, and stay one colour whatever it sits on.
/// A shape scales cleanly from a name row to a profile header and takes the
/// tint it is given.
///
/// The scalloped edge is the shape people already read as verification, on
/// every service that has one — which is the whole point of a badge.
struct VerifiedBadge: View {
    var size: CGFloat = 15
    var tint: Color = LaxifyPalette.accent

    var body: some View {
        ZStack {
            ScallopedDisc(points: 12, depth: 0.09)
                .fill(tint)

            Tick()
                .stroke(
                    Color.white,
                    style: StrokeStyle(
                        lineWidth: size * 0.13,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size * 0.44, height: size * 0.32)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Официальный исполнитель")
    }
}

/// A circle with a wavy edge.
///
/// Built from a sine wave rather than from arcs: the radius varies smoothly
/// all the way round, so the scallops stay even at any size and there are no
/// joins to go wrong.
private struct ScallopedDisc: Shape {
    let points: Int
    /// How far the edge swings, as a fraction of the radius.
    let depth: Double

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        var path = Path()
        let steps = points * 24

        for step in 0...steps {
            let angle = (Double(step) / Double(steps)) * 2 * .pi
            let wobble = 1 + depth * cos(Double(points) * angle)
            let distance = radius * wobble

            let point = CGPoint(
                x: centre.x + CGFloat(cos(angle) * distance),
                y: centre.y + CGFloat(sin(angle) * distance)
            )

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

private struct Tick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A name with its badge, when there is one.
struct ArtistName: View {
    let name: String
    var isVerified: Bool
    var font: Font = LaxifyTypography.body
    var badgeSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(font)
                .lineLimit(1)

            if isVerified {
                VerifiedBadge(size: badgeSize)
            }
        }
    }
}

/// The line on an artist's page saying whether this is really them.
///
/// Said plainly in both directions. The source is open to anyone, so an
/// unverified page is not an accusation — most genuine artists here have no
/// badge — but someone deciding whether they have found the right account
/// deserves to know which kind they are looking at.
struct VerificationNotice: View {
    let isVerified: Bool
    var followers: Int?

    var body: some View {
        HStack(spacing: 8) {
            if isVerified {
                VerifiedBadge(size: 16)
            } else {
                Image(systemName: "person.fill.questionmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .frame(width: 16, height: 16)
            }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isVerified ? LaxifyPalette.textSecondary : LaxifyPalette.textTertiary
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    private var title: String {
        if isVerified {
            return "Официальный исполнитель"
        }

        // A page with a real audience is probably the artist even without a
        // badge; one with almost none probably is not. Saying which is more
        // useful than a flat "unverified" on both.
        if let followers, followers >= 50_000 {
            return "Не подтверждён, но популярен"
        }
        return "Не официальный исполнитель"
    }
}
