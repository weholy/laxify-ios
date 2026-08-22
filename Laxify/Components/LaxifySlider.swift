import SwiftUI

/// Thin track slider used in the player.
///
/// SwiftUI's stock `Slider` picks up the system's thick, glassy treatment,
/// which reads as heavy next to the rest of the player. This draws a plain
/// capsule track with a small knob, and reports drags continuously while
/// suppressing external updates mid-gesture — otherwise the playback clock
/// fights the finger and the knob jumps.
struct LaxifySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var trackHeight: CGFloat = 4
    var knobSize: CGFloat = 10
    var tint: Color = .white
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private var displayed: Double {
        isDragging ? dragValue : value
    }

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((displayed - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knobX = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.25))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(tint)
                    .frame(width: max(knobX, 0), height: trackHeight)

                // Small and fixed-size: a knob that swells on touch draws
                // the eye away from the track, which the reference avoids.
                Circle()
                    .fill(tint)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobX - knobSize / 2)
            }
            .frame(height: max(knobSize, trackHeight))
            .frame(maxHeight: .infinity, alignment: .center)
            // A slim track is hard to hit, so the gesture area is the full row.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        dragValue = valueAt(x: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        let final = valueAt(x: gesture.location.x, width: width)
                        dragValue = final
                        value = final
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: max(knobSize, trackHeight) + 16)
    }

    private func valueAt(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return range.lowerBound }
        let ratio = min(max(x / width, 0), 1)
        return range.lowerBound + Double(ratio) * (range.upperBound - range.lowerBound)
    }
}
