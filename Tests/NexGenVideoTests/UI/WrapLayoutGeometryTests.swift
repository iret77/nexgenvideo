import CoreGraphics
import Testing
@testable import NexGenVideo

@Suite("Wrap layout geometry")
struct WrapLayoutGeometryTests {
    @Test func emptyInputHasZeroGeometry() {
        let result = WrapLayoutGeometry.arrange(
            sizes: [],
            maxWidth: 100,
            spacing: 6
        )

        #expect(result.origins.isEmpty)
        #expect(result.size == .zero)
    }

    @Test func wrapsAtFiniteWidthDeterministically() {
        let result = WrapLayoutGeometry.arrange(
            sizes: [
                CGSize(width: 40, height: 10),
                CGSize(width: 50, height: 12),
                CGSize(width: 30, height: 8),
            ],
            maxWidth: 100,
            spacing: 6
        )

        #expect(result.origins == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 46, y: 0),
            CGPoint(x: 0, y: 18),
        ])
        #expect(result.size == CGSize(width: 96, height: 26))
    }

    @Test func unspecifiedWidthKeepsOneNaturalRow() {
        let result = WrapLayoutGeometry.arrange(
            sizes: [
                CGSize(width: 40, height: 10),
                CGSize(width: 50, height: 12),
            ],
            maxWidth: nil,
            spacing: 6
        )

        #expect(result.origins == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 46, y: 0),
        ])
        #expect(result.size == CGSize(width: 96, height: 12))
    }

    @Test func reportedWidthPreservesTheMeasuredWrapping() {
        let sizes = [
            CGSize(width: 40, height: 10),
            CGSize(width: 50, height: 12),
            CGSize(width: 30, height: 8),
        ]
        let measured = WrapLayoutGeometry.arrange(
            sizes: sizes,
            maxWidth: 100,
            spacing: 6
        )
        let placed = WrapLayoutGeometry.arrange(
            sizes: sizes,
            maxWidth: measured.size.width,
            spacing: 6
        )

        #expect(placed.origins == measured.origins)
        #expect(placed.size == measured.size)
    }

    @Test func rejectsNonFiniteGeometry() {
        let result = WrapLayoutGeometry.arrange(
            sizes: [
                CGSize(width: .infinity, height: 10),
                CGSize(width: 20, height: .nan),
            ],
            maxWidth: .infinity,
            spacing: .nan
        )

        #expect(result.origins == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: 10),
        ])
        #expect(result.subviewSizes == [
            CGSize(width: AppTheme.Layout.safeDimensionCeiling, height: 10),
            CGSize(width: 20, height: 0),
        ])
        #expect(result.size == CGSize(
            width: AppTheme.Layout.safeDimensionCeiling,
            height: 10
        ))
    }

    @Test func negativeSpacingIsClampedToZero() {
        let result = WrapLayoutGeometry.arrange(
            sizes: [
                CGSize(width: 40, height: 10),
                CGSize(width: 50, height: 12),
            ],
            maxWidth: 100,
            spacing: -6
        )

        #expect(result.origins == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 40, y: 0),
        ])
        #expect(result.size == CGSize(width: 90, height: 12))
    }

    @Test func finiteInputsCannotOverflowReportedGeometry() {
        let result = WrapLayoutGeometry.arrange(
            sizes: [
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: 10),
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: 10),
            ],
            maxWidth: nil,
            spacing: CGFloat.greatestFiniteMagnitude
        )

        #expect(result.origins.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(result.size.width <= AppTheme.Layout.safeDimensionCeiling)
        #expect(result.size.height <= AppTheme.Layout.safeDimensionCeiling)
    }
}
