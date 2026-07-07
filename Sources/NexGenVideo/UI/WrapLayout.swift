import SwiftUI

/// Minimal wrapping row: subviews flow left-to-right and break onto new lines at the
/// proposed width (badge rows, action rows in narrow panels). Conformance is
/// SwiftUI-qualified — the app's own `Layout` constants enum shadows the protocol name.
struct WrapLayout: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        for (index, origin) in layout(proposal: proposal, subviews: subviews).origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: LayoutSubviews) -> (origins: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            width = max(width, x + size.width)
            x += size.width + spacing
        }
        return (origins, CGSize(width: width, height: y + rowHeight))
    }
}
