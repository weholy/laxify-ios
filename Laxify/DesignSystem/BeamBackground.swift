import SwiftUI

/// A slow field of light beams rendered by the `beam` Metal shader — the
/// Laxify take on the reference WebGL effect. Drop it behind a header or a
/// hero area; it draws over a dark base and animates on its own.
struct BeamBackground: View {
    var tint: Color = Color(hex: 0x8A7CFF)
    var opacity: Double = 0.9

    var body: some View {
        TimelineView(.animation) { timeline in
            // Wrapped so the value stays small enough for the shader's Float
            // precision; the beams loop on fract() anyway.
            let t = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))

            GeometryReader { proxy in
                let size = proxy.size
                // A near-invisible fill gives the effect real pixels to run
                // on; if the shader is ever unavailable this stays unseen
                // rather than showing a black box.
                Rectangle()
                    .fill(Color(white: 0, opacity: 0.02))
                    .colorEffect(
                        ShaderLibrary.beam(
                            .float2(size),
                            .float(t),
                            .color(tint)
                        )
                    )
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}
