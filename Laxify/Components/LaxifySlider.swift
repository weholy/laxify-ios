import SwiftUI

/// Thin track slider used in the player.
///
/// SwiftUI's stock `Slider` picks up the system's thick, glassy treatment,
/// which reads as heavy next to the rest of the player. This draws a plain
/// capsule track — no knob by default, so the fill alone marks the position —
/// and reports drags continuously while suppressing external updates
/// mid-gesture, otherwise the playback clock fights the finger.
struct LaxifySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var trackHeight: CGFloat = 4
    var knobSize: CGFloat = 0
    var tint: Color = .white
    /// Draws the track as glass rather than as a flat capsule. Used in the
    /// player, where the bar sits over artwork and a solid track reads as a
    /// sticker laid on top of it.
    var isGlass: Bool = false
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    /// How far outside the bar a touch still counts. A slim bar is hard to
    /// hit exactly; more than this and it starts catching taps aimed
    /// elsewhere.
    private static let touchPadding: CGFloat = 8

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
                Group {
                    if isGlass {
                        // Glass rather than a flat capsule: the bar sits over
                        // artwork, and a solid track reads as a sticker laid
                        // on top of it. The hairline is what keeps a bar this
                        // slim visible over a light cover.
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5)
                            }
                            .frame(height: trackHeight)
                    } else {
                        Capsule()
                            .fill(tint.opacity(0.25))
                            .frame(height: trackHeight)
                    }
                }

                Capsule()
                    .fill(tint)
                    .frame(width: max(knobX, 0), height: trackHeight)
                    .shadow(
                        color: isGlass ? tint.opacity(0.5) : .clear,
                        radius: 4
                    )
                    // Follows the finger exactly while dragging, and eases
                    // between clock ticks the rest of the time so playback
                    // progress glides instead of stepping.
                    .animation(
                        isDragging ? .interactiveSpring(response: 0.15) : .linear(duration: 0.25),
                        value: knobX
                    )

                if knobSize > 0 {
                    Circle()
                        .fill(tint)
                        .frame(width: knobSize, height: knobSize)
                        .offset(x: knobX - knobSize / 2)
                }
            }
            .frame(height: max(knobSize, trackHeight))
            .frame(maxHeight: .infinity, alignment: .center)
            // Only the bar itself takes the gesture. It was the whole row,
            // which meant a tap in the space beside the bar moved playback —
            // and that space is where a thumb naturally lands.
            .contentShape(
                Rectangle().inset(by: -Self.touchPadding)
            )
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
        // Just enough height to be reachable without swallowing taps meant
        // for whatever is above or below.
        .frame(height: max(knobSize, trackHeight) + Self.touchPadding * 2)
    }

    private func valueAt(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return range.lowerBound }
        let ratio = min(max(x / width, 0), 1)
        return range.lowerBound + Double(ratio) * (range.upperBound - range.lowerBound)
    }
}
