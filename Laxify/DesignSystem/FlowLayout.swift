import SwiftUI

/// Wraps its children onto as many rows as they need.
///
/// A grid would make every cell the same width, which is wrong for anything
/// sized by its own content — genre names of very different lengths, for
/// instance, where the varying widths are part of what the row says.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if rowWidth + size.width > width, rowWidth > 0 {
                total.width = max(total.width, rowWidth - spacing)
                total.height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }

            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        total.width = max(total.width, rowWidth - spacing)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
