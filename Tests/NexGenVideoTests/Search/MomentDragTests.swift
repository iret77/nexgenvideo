import Foundation
import Testing
@testable import NexGenVideo

@Suite("Moment drag payload")
@MainActor
struct MomentDragTests {
    @Test func segmentRoundTrips() {
        let s = MediaTab.assetDragString(forAssetId: "abc-123", segment: 12.5...20.25)
        #expect(MediaTab.assetId(fromDragString: s) == "abc-123")
        #expect(MediaTab.assetSegment(fromDragString: s) == 12.5...20.25)
    }

    @Test func plainAssetStringHasNoSegment() {
        let s = MediaTab.assetDragString(forAssetId: "abc-123")
        #expect(MediaTab.assetId(fromDragString: s) == "abc-123")
        #expect(MediaTab.assetSegment(fromDragString: s) == nil)
    }

    @Test func malformedSegmentsRejected() {
        #expect(MediaTab.assetSegment(fromDragString: "nexgen-asset://x#5-2") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "nexgen-asset://x#-1-2") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "nexgen-asset://x#junk") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "nexgen-asset://x#0-inf") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "nexgen-asset://x#nan-2") == nil)
        #expect(MediaTab.assetSegment(fromDragString: "nexgen-folder://x#1-2") == nil)
        #expect(MediaTab.assetId(fromDragString: "nexgen-asset://x#junk") == "x")
    }

    @Test func zeroPrefixedFractionsParse() {
        let s = MediaTab.assetDragString(forAssetId: "x", segment: 0.0...0.5)
        #expect(MediaTab.assetSegment(fromDragString: s) == 0.0...0.5)
    }
    @Test func invalidOrOutOfSourceSegmentsNeverFallBackToTheWholeAsset() {
        let editor = EditorViewModel()
        editor.mediaAssets = [MediaAsset(id: "x", url: URL(fileURLWithPath: "/source.mov"), type: .video, name: "Source", duration: 2)]
        for suffix in ["0-inf", "junk", "1-5", "3-4", "1-1e300"] {
            let payload = "nexgen-asset://x#" + suffix
            #expect(editor.assetsFromDragPayload(payload).isEmpty)
            #expect(editor.segmentsFromDragPayload(payload).isEmpty)
        }
        #expect(editor.assetsFromDragPayload("nexgen-asset://x#0.5-1.5").map(\.id) == ["x"])
    }

}
