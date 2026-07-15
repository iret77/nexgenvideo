import Foundation
import simd
import Testing
@testable import NexGenEngine

/// #166: the deterministic spatial contract of the 4-wall POV set — the guarantee a 2D generator can't
/// give: opposite walls are the same wall (back = −front) and left/right stay mirrored across a
/// reverse angle. Pure geometry, no image needed.
///
/// The relationships hold in the YAW PLANE: all four POVs share one downward tilt (5°, as in
/// `pov.py`), so `back.forward` is not the exact negation of `front.forward` — both point slightly
/// down. Negating a tilted vector would point it slightly UP, which is not what a reverse angle
/// does. The horizontal component is where "opposite wall" and "mirrored" live.
@Suite("PovSpec geometry")
struct PovSpecTests {
    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, eps: Double = 1e-9) -> Bool {
        simd_length(a - b) < eps
    }

    /// The forward vector flattened onto the ground plane and renormalized.
    private func horizontal(_ pov: PovSpec) -> SIMD3<Double> {
        let f = pov.forwardDirection
        return simd_normalize(SIMD3(f.x, 0, f.z))
    }

    private var byName: [String: PovSpec] {
        Dictionary(uniqueKeysWithValues: defaultFourWallPovs.map { ($0.name, $0) })
    }

    @Test("the four wall POVs face the cardinal directions")
    func cardinalDirections() {
        #expect(close(horizontal(byName["wide_front"]!), SIMD3(0, 0, 1)))
        #expect(close(horizontal(byName["wide_right"]!), SIMD3(1, 0, 0)))
        #expect(close(horizontal(byName["wide_back"]!), SIMD3(0, 0, -1)))
        #expect(close(horizontal(byName["wide_left"]!), SIMD3(-1, 0, 0)))
    }

    @Test("reverse shot is the opposite wall; left/right are mirrored")
    func reverseAndMirror() {
        // back = −front (the camera turned around sees the opposite wall)
        #expect(close(horizontal(byName["wide_back"]!), -horizontal(byName["wide_front"]!)))
        // left = −right (what was on the left is on the right in the reverse shot)
        #expect(close(horizontal(byName["wide_left"]!), -horizontal(byName["wide_right"]!)))
    }

    /// The mirroring rule a 2D model cannot honor, stated on the camera's own right axis: world +X
    /// content sits on the RIGHT of the front view and on the LEFT of the back view.
    @Test("the camera's right axis flips between opposite views")
    func rightAxisFlips() {
        let front = EquirectProjector.basis(byName["wide_front"]!)
        let back = EquirectProjector.basis(byName["wide_back"]!)
        #expect(close(front.right, SIMD3(1, 0, 0)))
        #expect(close(back.right, SIMD3(-1, 0, 0)))
        #expect(close(back.right, -front.right))
    }

    @Test("all four share one downward tilt — a reverse angle does not tilt up")
    func sharedTilt() {
        let ys = defaultFourWallPovs.map(\.forwardDirection.y)
        #expect(ys.allSatisfy { $0 < 0 })                          // tilted down
        #expect(ys.allSatisfy { abs($0 - ys[0]) < 1e-12 })          // identically so
    }

    @Test("pitch is signed: positive looks up, negative looks down")
    func pitchSign() {
        #expect(close(PovSpec(name: "t", yawDegrees: 0, pitchDegrees: 90).forwardDirection, SIMD3(0, 1, 0)))
        #expect(close(PovSpec(name: "t", yawDegrees: 0, pitchDegrees: -90).forwardDirection, SIMD3(0, -1, 0)))
        #expect(PovSpec(name: "t", yawDegrees: 0, pitchDegrees: 0).forwardDirection.y == 0)
    }

    /// Defaults are `pov.py::PovSpec`'s, not a rounder-looking pair. A 90° level lens would widen
    /// every wall sheet and drop the floor cue the 5° tilt gives.
    @Test("defaults mirror the Python original: 75° lens, 5° down")
    func defaultsMatchTheOriginal() {
        #expect(defaultFourWallPovs.allSatisfy { $0.fovHorizontalDegrees == 75 })
        #expect(defaultFourWallPovs.allSatisfy { $0.pitchDegrees == -5 })
        #expect(defaultPovSize == (width: 1280, height: 720))
    }
}
