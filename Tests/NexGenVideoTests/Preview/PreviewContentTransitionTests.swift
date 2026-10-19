import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Reference to timeline preview bounds")
struct PreviewContentTransitionTests {
    @Test func narrowerTimelineReboundsTheExistingReferencePan() {
        let viewport = CGSize(width: 1000, height: 1000)
        let referenceOffset = PreviewCanvasNavigation.boundedOffset(CGSize(width: 4000, height: -4000),
            zoom: 8, contentSize: viewport, viewport: viewport)
        #expect(referenceOffset == CGSize(width: 3500, height: -3500))
        let timelineOffset = PreviewCanvasNavigation.boundedOffset(referenceOffset, zoom: 8,
            contentSize: CGSize(width: 500, height: 1000), viewport: viewport)
        #expect(timelineOffset == CGSize(width: 1500, height: -3500))
        #expect(PreviewCanvasNavigation.boundedOffset(timelineOffset, zoom: 2,
            contentSize: CGSize(width: 500, height: 1000), viewport: viewport) == CGSize(width: 0, height: -500))
    }
}
