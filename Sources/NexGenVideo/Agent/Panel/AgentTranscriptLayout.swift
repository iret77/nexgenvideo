import SwiftUI

struct AgentTranscriptLayout: SwiftUI.Layout {
    var spacing: CGFloat = AppTheme.Spacing.md

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = Self.width(proposal.width)
        let heights = subviews.map { Self.height($0.sizeThatFits(.init(width: width, height: nil)).height) }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = Self.width(bounds.width)
        var y = bounds.minY
        for subview in subviews {
            let height = Self.height(subview.sizeThatFits(.init(width: width, height: nil)).height)
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: .init(width: width, height: height))
            y += height + spacing
        }
    }

    // Transcript rows do not export descendant alignment guides to the lazy scroll layout.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    static func width(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return AppTheme.Layout.chatColumnMax }
        return min(max(0, proposed), AppTheme.Layout.chatColumnMax)
    }

    static func height(_ measured: CGFloat) -> CGFloat {
        measured.isFinite ? max(0, measured) : 0
    }
}
