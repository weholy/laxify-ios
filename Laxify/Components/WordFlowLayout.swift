import SwiftUI

/// Lays words out like wrapped text, but as separate subviews so each word can
/// be styled and animated on its own — a single `Text` can only be masked as
/// one block, which fills every wrapped line at once instead of word by word.
struct WordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)

        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.height
        } + lineSpacing * CGFloat(max(rows.count - 1, 0))

        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width

            if projected > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
                current.items = [Item(index: index, size: size)]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(Item(index: index, size: size))
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
