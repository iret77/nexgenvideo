import Foundation
import Testing
@testable import NexGenEngine

/// Verbatim port of `engine/tests/test_frames_geometry.py`'s crop cases —
/// exact integer box equality, no tolerance.
@Suite("CropPlanner")
struct CropPlannerTests {
    @Test("center crop from a wide master: height stays, width shrinks, centered")
    func planCropCenterFromWideMaster() throws {
        // 21:9 master, 16:9 target → height stays, width shrinks, centered.
        let plan = try planCrop(masterSize: (2100, 900), targetAspect: "16:9", anchor: .center)
        #expect(plan.targetSize == (1600, 900))
        let left = plan.box.left
        #expect(left == (2100 - 1600) / 2)
        #expect(plan.box == (left, 0, left + 1600, 900))
    }

    @Test("full take when master already has the target aspect")
    func planCropFullTakeOnMatchingAspect() throws {
        let plan = try planCrop(masterSize: (1600, 900), targetAspect: "16:9")
        #expect(plan.box == (0, 0, 1600, 900))
        #expect(plan.targetSize == (1600, 900))
    }
}
