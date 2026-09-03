import SwiftUI

/// A single line of text that scrolls itself when it does not fit.
///
/// Truncating a title with an ellipsis hides exactly the part that
/// distinguishes one long title from another, and on a phone most titles
/// carrying a feature credit are long. So when the text overflows it travels:
/// it rests at the start for a beat, moves right to left at a readable pace,
/// and comes round again.
///
/// Text that fits does not move at all — a line drifting for no reason reads
/// worse than a still one. The decision is made by measuring the string in its
/// real font rather than by guessing a character count.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color

    /// The still moment at the start of each pass, so the beginning can
    /// actually be read before it leaves.
    var pause: Double = 1.0
    /// Points per second. Slow enough to read, quick enough not to feel stuck.
    var speed: Double = 28
    /// Blank space between the end of one pass and the start of the next.
    var gap: CGFloat = 44

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        // An invisible line in the caller's own font sets the height and the
        // baseline, so swapping a plain `Text` for this one moves nothing
        // around it. Everything visible is drawn in the overlay.
        Text(verbatim: " ")
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { track }
            .onChange(of: text) { _, _ in restart() }
    }

    private var track: some View {
        GeometryReader { proxy in
            HStack(spacing: gap) {
                line
                // The trailing copy exists only while scrolling, so a title
                // that fits stays a single ordinary line of text.
                if overflows { line }
            }
            .offset(x: offset)
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = proxy.size.width
                restart()
            }
            .onChange(of: proxy.size.width) { _, new in
                containerWidth = new
                restart()
            }
        }
    }

    private var line: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measured(proxy.size.width) }
                        .onChange(of: proxy.size.width) { _, new in measured(new) }
                }
            }
    }

    private func measured(_ width: CGFloat) {
        guard abs(width - textWidth) > 0.5 else { return }
        textWidth = width
        restart()
    }

    private func restart() {
        // Cut any pass already running, or the new one inherits its phase and
        // the title appears to start from the middle of itself.
        withAnimation(.linear(duration: 0)) { offset = 0 }

        guard overflows, containerWidth > 0 else { return }

        let distance = textWidth + gap

        withAnimation(
            .linear(duration: Double(distance) / speed)
                .delay(pause)
                .repeatForever(autoreverses: false)
        ) {
            offset = -distance
        }
    }
}
