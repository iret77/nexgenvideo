import Foundation
import Testing
@testable import NexGenEngine

/// Verbatim port of `engine/tests/test_frames_geometry.py`'s pan-pair cases —
/// exact integer box equality, no tolerance.
@Suite("PanPairPlanner")
struct PanPairPlannerTests {
    @Test("horizontal pan: target box is half the master width, both boxes full height")
    func planPanPairHorizontal() throws {
        // 32:9 master, 16:9 target → target box is half the master width, both boxes full height.
        let plan = try planPanPair(
            masterSize: (3200, 900), targetAspect: "16:9", direction: .right, travelPct: 100.0
        )
        #expect(plan.targetSize == (1600, 900))
        #expect(plan.startBox.top == 0 && plan.startBox.bottom == 900)
        #expect(plan.travelPx == 1600)
        // 'right' starts at the left edge and ends at the right edge for full travel.
        #expect(plan.startBox.left == 0)
        #expect(plan.endBox.left == 1600)
    }

    @Test("rejects a master too narrow for the requested pan aspect")
    func planPanPairRejectsTooNarrowMaster() {
        #expect(throws: PanPairPlannerError.self) {
            try planPanPair(masterSize: (1600, 900), targetAspect: "21:9", direction: .right)
        }
    }
}
