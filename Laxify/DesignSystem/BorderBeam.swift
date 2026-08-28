import SwiftUI

enum BorderBeamSize {
    case sm, md, lg

    var lineWidth: CGFloat {
        switch self {
        case .sm: 1.5
        case .md: 2
        case .lg: 3
        }
    }

    /// Seconds for one lap of the border.
    var duration: Double {
        switch self {
        case .sm: 3.2
        case .md: 4
        case .lg: 5
        }
    }
}

enum BorderBeamVariant {
    case ocean, sunset, violet, mono

    var tint: Color {
        switch self {
        case .ocean: Color(hex: 0x35D0FF)
        case .sunset: Color(hex: 0xFF7A59)
        case .violet: Color(hex: 0xA855F7)
        case .mono: .white
        }
    }
}

/// A comet of light that runs around a rounded border and fades behind
/// itself — the Laxify take on BorderBeamKit's `borderBeam`.
struct BorderBeamModifier: ViewModifier {
    var cornerRadius: CGFloat
    var size: BorderBeamSize
    var variant: BorderBeamVariant

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation) { timeline in
                let lap = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: size.duration) / size.duration
                let angle = Angle.degrees(lap * 360)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .clear, location: 0.62),
                                .init(color: variant.tint.opacity(0.7), location: 0.80),
                                .init(color: .white, location: 0.90),
                                .init(color: variant.tint.opacity(0.7), location: 0.97),
                                .init(color: .clear, location: 1.0)
                            ]),
                            center: .center,
                            angle: angle
                        ),
                        lineWidth: size.lineWidth
                    )
                    .blur(radius: 1.4)
                    .shadow(color: variant.tint.opacity(0.6), radius: 4)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func borderBeam(
        _ size: BorderBeamSize = .md,
        cornerRadius: CGFloat = 22,
        colorVariant: BorderBeamVariant = .violet
    ) -> some View {
        modifier(BorderBeamModifier(cornerRadius: cornerRadius, size: size, variant: colorVariant))
    }
}
