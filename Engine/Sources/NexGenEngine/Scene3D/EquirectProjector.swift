import Foundation
import simd

/// Cuts a rectilinear view out of an equirectangular panorama — the deterministic core of the
/// scene-3D reference (#166) and the one link that was missing on the Swift side. Port of the
/// `py360convert.e2p` call in `bible/scene3d/pov.py`.
///
/// Why this is load-bearing: every POV is sampled from the SAME panorama, so the views are
/// geometrically consistent with each other by construction — opposite walls really are the same
/// wall, and a reverse shot mirrors left/right correctly. A 2D image model cannot give that
/// guarantee; it has no persistent spatial representation of the location.
///
/// Runs locally, costs nothing, and is pure: pixels in → pixels out, no I/O (`PovExtractor` does
/// the file handling). That keeps the geometry CI-testable without a GPU or a real panorama.
public enum EquirectProjector {

    /// A raw 8-bit RGBA image buffer, row-major, no padding.
    public struct PixelBuffer: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// `width * height * 4` bytes, RGBA order.
        public let rgba: [UInt8]

        public init(width: Int, height: Int, rgba: [UInt8]) {
            precondition(width > 0 && height > 0, "empty image")
            precondition(rgba.count == width * height * 4, "rgba must be width*height*4 bytes")
            self.width = width
            self.height = height
            self.rgba = rgba
        }

        @inline(__always)
        func pixel(x: Int, y: Int) -> SIMD4<Double> {
            let i = (y * width + x) * 4
            return SIMD4(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]), Double(rgba[i + 3]))
        }
    }

    /// The camera basis for a POV in the panorama's world frame: `forward` at (yaw, pitch), `right`
    /// horizontal (pitch never rolls the camera), `up` completing it. Exposed for tests — the
    /// left/right mirroring rule of #166 is a statement about `right`.
    public static func basis(_ pov: PovSpec) -> (forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        let yaw = pov.yawDegrees * .pi / 180
        let pitch = pov.pitchDegrees * .pi / 180
        let forward = SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        // Pitch rotates about `right`, so `right` stays in the horizontal plane.
        let right = SIMD3(cos(yaw), 0, -sin(yaw))
        let up = SIMD3(-sin(pitch) * sin(yaw), cos(pitch), -sin(pitch) * cos(yaw))
        return (forward, right, up)
    }

    /// Vertical FOV derived from the horizontal one and the output aspect — the same relation
    /// `pov.py` computes (`v_fov = fov_h * height / width`) before calling `e2p`.
    public static func verticalFOV(_ pov: PovSpec, width: Int, height: Int) -> Double {
        pov.fovHorizontalDegrees * Double(height) / Double(width)
    }

    /// Sample the panorama through `pov` into a `width × height` rectilinear view.
    ///
    /// Convention (matches `pov.py` / py360convert): the panorama's horizontal centre is yaw 0
    /// (straight ahead), yaw grows to the right, pitch grows upward, and the top row is +90°
    /// latitude. Sampling is bilinear; it wraps horizontally (the panorama is seamless in
    /// longitude) and clamps vertically (the poles are not).
    public static func project(pano: PixelBuffer, pov: PovSpec, width: Int, height: Int) -> PixelBuffer {
        precondition(width > 1 && height > 1, "output must be at least 2x2")
        let (forward, right, up) = basis(pov)
        let xMax = tan(pov.fovHorizontalDegrees * .pi / 180 / 2)
        let yMax = tan(verticalFOV(pov, width: width, height: height) * .pi / 180 / 2)

        var out = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            // Top row is +yMax: image y grows downward, world up grows upward.
            let yTan = yMax - Double(row) * (2 * yMax / Double(height - 1))
            for col in 0..<width {
                let xTan = -xMax + Double(col) * (2 * xMax / Double(width - 1))
                let dir = simd_normalize(forward + xTan * right + yTan * up)

                let lon = atan2(dir.x, dir.z)                       // 0 = panorama centre
                let lat = asin(max(-1, min(1, dir.y)))              // +pi/2 = top row
                // Pixel centres, hence the -0.5 (py360convert's uv2coor does the same).
                let px = (lon / (2 * .pi) + 0.5) * Double(pano.width) - 0.5
                let py = (0.5 - lat / .pi) * Double(pano.height) - 0.5

                let rgba = sampleBilinear(pano, x: px, y: py)
                let i = (row * width + col) * 4
                out[i] = round8(rgba.x)
                out[i + 1] = round8(rgba.y)
                out[i + 2] = round8(rgba.z)
                out[i + 3] = round8(rgba.w)
            }
        }
        return PixelBuffer(width: width, height: height, rgba: out)
    }

    @inline(__always)
    private static func round8(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    /// Bilinear sample at fractional pixel coordinates. Longitude wraps (seamless panorama),
    /// latitude clamps (sampling past a pole would otherwise fold the image).
    @inline(__always)
    private static func sampleBilinear(_ img: PixelBuffer, x: Double, y: Double) -> SIMD4<Double> {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)

        @inline(__always) func wrapX(_ v: Int) -> Int {
            let m = v % img.width
            return m < 0 ? m + img.width : m
        }
        @inline(__always) func clampY(_ v: Int) -> Int { max(0, min(img.height - 1, v)) }

        let xa = wrapX(x0), xb = wrapX(x0 + 1)
        let ya = clampY(y0), yb = clampY(y0 + 1)

        let top = img.pixel(x: xa, y: ya) * (1 - fx) + img.pixel(x: xb, y: ya) * fx
        let bottom = img.pixel(x: xa, y: yb) * (1 - fx) + img.pixel(x: xb, y: yb) * fx
        return top * (1 - fy) + bottom * fy
    }
}
