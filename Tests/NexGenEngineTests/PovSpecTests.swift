import Foundation
import simd
import Testing
@testable import NexGenEngine

/// #166: the deterministic spatial contract of the 4-wall POV set — the guarantee a 2D generator can't
/// give: opposite walls are the same wall (back = −front) and a reverse shot mirrors left/right
/// (left = −right). Pure geometry, no image needed.
@Suite("PovSpec geometry")
struct PovSpecTests {
    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, eps: Double = 1e-9) -> Bool {
        simd_length(a - b) < eps
    }

    @Test("the four wall POVs face the cardinal directions")
    func cardinalDirections() {
        let byName = Dictionary(uniqueKeysWithValues: defaultFourWallPovs.map { ($0.name, $0) })
        #expect(close(byName["wide_front"]!.forwardDirection, SIMD3(0, 0, 1)))
        #expect(close(byName["wide_right"]!.forwardDirection, SIMD3(1, 0, 0)))
        #expect(close(byName["wide_back"]!.forwardDirection, SIMD3(0, 0, -1)))
        #expect(close(byName["wide_left"]!.forwardDirection, SIMD3(-1, 0, 0)))
    }

    @Test("reverse shot is the opposite wall; left/right are mirrored")
    func reverseAndMirror() {
        let byName = Dictionary(uniqueKeysWithValues: defaultFourWallPovs.map { ($0.name, $0) })
        // back = −front (the camera turned around sees the opposite wall)
        #expect(close(byName["wide_back"]!.forwardDirection, -byName["wide_front"]!.forwardDirection))
        // left = −right (what was on the left is on the right in the reverse shot)
        #expect(close(byName["wide_left"]!.forwardDirection, -byName["wide_right"]!.forwardDirection))
    }

    @Test("pitch tilts the forward vector vertically without breaking the yaw plane")
    func pitch() {
        let up = PovSpec(name: "t", yawDegrees: 0, pitchDegrees: 90)
        #expect(close(up.forwardDirection, SIMD3(0, 1, 0)))
    }

    @Test("all four share one horizontal FOV by default (90°)")
    func defaultFov() {
        #expect(defaultFourWallPovs.allSatisfy { $0.fovHorizontalDegrees == 90 })
    }
}
