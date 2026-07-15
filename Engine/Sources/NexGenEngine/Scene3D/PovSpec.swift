import Foundation
import simd

/// A point-of-view onto a 3D scene reference: a named camera direction (yaw/pitch) + horizontal FOV,
/// from which a rectilinear view is cut out of the location's equirectangular panorama. This is the
/// deterministic spatial contract behind #166 — every shot of a location derives its camera from ONE
/// scene reference, so layout stays fixed across angles and a reverse shot mirrors left/right correctly
/// because the camera is placed in a real 3D model, not guessed by a 2D net. Port of the spec half of
/// `bible/scene3d/pov.py` (the `PovSpec` + `DEFAULT_4_WALL_POVS`). The pixel resampling (py360convert
/// `e2p`) runs on-device once the panorama image exists; this pure spec + geometry is what guarantees
/// the relationships and is CI-testable without an image.
public struct PovSpec: Sendable, Equatable {
    /// Identifier — becomes the `Location.sheets` key (e.g. `wide_chalkboard`), which is what a
    /// shot's `locationView` names and `LOCATION_VIEW_MISSING` validates against.
    public let name: String
    /// Horizontal rotation in degrees: 0 = the panorama's centre (front), +90 = right, 180 = back,
    /// −90 = left.
    public let yawDegrees: Double
    /// Vertical rotation in degrees (up positive, so a downward tilt is negative).
    public let pitchDegrees: Double
    /// Horizontal field of view in degrees.
    public let fovHorizontalDegrees: Double

    /// Defaults mirror `pov.py::PovSpec` — a 75° lens tilted 5° down, not a 90° level one.
    public init(name: String, yawDegrees: Double, pitchDegrees: Double = -5, fovHorizontalDegrees: Double = 75) {
        self.name = name
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.fovHorizontalDegrees = fovHorizontalDegrees
    }

    /// Unit forward direction in a right-handed world (x = right, y = up, z = forward at yaw 0, pitch 0).
    /// Yaw rotates about the vertical axis, pitch about the horizontal — the same convention the
    /// equirect→perspective sampler uses, so `back` is exactly `−front` and `left` exactly `−right`.
    public var forwardDirection: SIMD3<Double> {
        let yaw = yawDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        return SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }
}

/// The four cardinal wall POVs — front / right / back / left at yaw 0 / 90 / 180 / −90, each a 75°
/// lens tilted 5° down. Port of `pov.py::DEFAULT_4_WALL_POVS`: one master panorama yields all four
/// geometrically-consistent angles, so opposite walls are the same wall and reverse shots mirror
/// correctly.
public let defaultFourWallPovs: [PovSpec] = [
    PovSpec(name: "wide_front", yawDegrees: 0),
    PovSpec(name: "wide_right", yawDegrees: 90),
    PovSpec(name: "wide_back", yawDegrees: 180),
    PovSpec(name: "wide_left", yawDegrees: -90),
]

/// Default POV resolution. 1280×720 because Seedance requires at least 1024 px on the short edge —
/// the same reason `pov.py` picks it.
public let defaultPovSize = (width: 1280, height: 720)
