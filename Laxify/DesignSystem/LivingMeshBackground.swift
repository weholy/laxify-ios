import SwiftUI

/// A slow, breathing mesh of the artwork's two colours — the Apple Music
/// "the room takes on the record's colour" effect. Low contrast on purpose:
/// it sits behind content and must not compete with it.
struct LivingMeshBackground: View {
    var palette: ArtworkPalette
    /// 0 = still, 1 = full drift.
    var motion: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: motion == 0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * motion
            let dx = Float(0.16 * sin(t * 0.23))
            let dy = Float(0.14 * cos(t * 0.19))
            let ex = Float(0.12 * cos(t * 0.17))
            let ey = Float(0.13 * sin(t * 0.27))

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0), SIMD2<Float>(1, 0),
                    SIMD2<Float>(0, 0.5 + dy), SIMD2<Float>(0.5 + dx, 0.5 + dy), SIMD2<Float>(1, 0.5 - dy),
                    SIMD2<Float>(0, 1), SIMD2<Float>(0.5 + ex, 1), SIMD2<Float>(1, 1 - ey)
                ],
                colors: [
                    a, d, a,
                    d, a, d,
                    .black, .black, .black
                ]
            )
        }
        .ignoresSafeArea()
    }

    private var d: Color { palette.dominant }
    private var a: Color { palette.accent }
}
