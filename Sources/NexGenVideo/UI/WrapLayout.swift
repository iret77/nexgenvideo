import SwiftUI

/// Minimal wrapping row: subviews flow left-to-right and break onto new lines at the
/// proposed width (badge rows, action rows in narrow panels). Conformance is
/// SwiftUI-qualified — the app's own `Layout` constants enum shadows the protocol name.
struct WrapLayout: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        arrangement(
            maxWidth: Self.finiteWidth(proposal.width),
            subviews: subviews
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let result = arrangement(
            maxWidth: Self.finiteWidth(proposal.width) ?? Self.finiteWidth(bounds.width),
            subviews: subviews
        )
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(result.subviewSizes[index])
            )
        }
    }

    // The default merges guides through badge overlays, creating a secondary-layer layout cycle.
    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    private func arrangement(
        maxWidth: CGFloat?,
        subviews: LayoutSubviews
    ) -> (origins: [CGPoint], subviewSizes: [CGSize], size: CGSize) {
        let result = WrapLayoutGeometry.arrange(
            sizes: subviews.map { $0.sizeThatFits(.unspecified) },
            maxWidth: maxWidth,
            spacing: spacing
        )
        return (result.origins, result.subviewSizes, result.size)
    }

    private static func finiteWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite else { return nil }
        return min(
            max(width, AppTheme.Spacing.none),
            AppTheme.Layout.safeDimensionCeiling
        )
    }
}

enum WrapLayoutGeometry {
    struct Arrangement: Equatable {
        let origins: [CGPoint]
        let subviewSizes: [CGSize]
        let size: CGSize
    }

    static func arrange(
        sizes: [CGSize],
        maxWidth: CGFloat?,
        spacing: CGFloat
    ) -> Arrangement {
        let availableWidth = maxWidth.flatMap {
            $0.isFinite
                ? min(max($0, AppTheme.Spacing.none), AppTheme.Layout.safeDimensionCeiling)
                : nil
        }
        let safeSpacing = spacing.isFinite
            ? min(max(spacing, AppTheme.Spacing.none), AppTheme.Layout.safeDimensionCeiling)
            : AppTheme.Spacing.none
        let rowLimit = availableWidth ?? AppTheme.Layout.safeDimensionCeiling
        var origins: [CGPoint] = []
        var subviewSizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for rawSize in sizes {
            let size = CGSize(
                width: safeDimension(rawSize.width, positiveInfinityFallback: rowLimit),
                height: safeDimension(
                    rawSize.height,
                    positiveInfinityFallback: AppTheme.Layout.safeDimensionCeiling
                )
            )
            if x > 0, size.width > max(rowLimit - x, AppTheme.Spacing.none) {
                x = 0
                y = finiteSum(y, finiteSum(rowHeight, safeSpacing))
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            subviewSizes.append(size)
            rowHeight = max(rowHeight, size.height)
            width = max(width, finiteSum(x, size.width))
            x = finiteSum(x, finiteSum(size.width, safeSpacing))
        }
        return Arrangement(
            origins: origins,
            subviewSizes: subviewSizes,
            size: CGSize(width: width, height: finiteSum(y, rowHeight))
        )
    }

    private static func safeDimension(
        _ value: CGFloat,
        positiveInfinityFallback: CGFloat
    ) -> CGFloat {
        if value == .infinity { return positiveInfinityFallback }
        guard value.isFinite else { return AppTheme.Spacing.none }
        return min(
            max(value, AppTheme.Spacing.none),
            AppTheme.Layout.safeDimensionCeiling
        )
    }

    private static func finiteSum(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let result = lhs + rhs
        guard result.isFinite else { return AppTheme.Layout.safeDimensionCeiling }
        return min(result, AppTheme.Layout.safeDimensionCeiling)
    }
}
