import Foundation
import Testing
@testable import NexGenVideo

@Suite("Preview navigation bounds")
@MainActor
struct PreviewCanvasNavigationTests {
    @Test func zoomingOverLetterboxingKeepsTheImageReachable() {
        let viewport = CGSize(width: 1000, height: 1000)
        let content = CGSize(width: 500, height: 1000)
        let offset = PreviewCanvasNavigation.zoomOffset(from: 1, to: 8, offset: .zero,
            point: CGPoint(x: 1000, y: 500), contentSize: content, viewport: viewport)
        #expect(offset == CGSize(width: -1500, height: 0))
        #expect(PreviewCanvasNavigation.boundedOffset(offset, zoom: 8,
            contentSize: content, viewport: viewport) == offset)
        #expect(PreviewCanvasNavigation.zoomOffset(from: 1, to: 1.5, offset: .zero,
            point: CGPoint(x: 1000, y: 500), contentSize: content, viewport: viewport) == .zero)
    }

    @Test func interiorZoomRetainsThePointAndFitCentersIt() {
        let viewport = CGSize(width: 1000, height: 1000)
        let offset = PreviewCanvasNavigation.zoomOffset(from: 1, to: 2, offset: .zero,
            point: CGPoint(x: 400, y: 600), contentSize: viewport, viewport: viewport)
        #expect(offset == CGSize(width: 100, height: -100))
        #expect(PreviewCanvasNavigation.zoomOffset(from: 2, to: 1, offset: offset,
            point: CGPoint(x: 1000, y: 1000), contentSize: viewport, viewport: viewport) == .zero)
        #expect(PreviewCanvasNavigation.boundedOffset(offset, zoom: 2,
            contentSize: CGSize(width: 250, height: 250), viewport: viewport) == .zero)
    }
}
