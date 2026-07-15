import Foundation
import Testing
@testable import NexGenEngine

/// #166: the equirect→perspective cut. These tests pin the CONVENTIONS (which way is right, which
/// way is up, where yaw 0 points) against synthetic panoramas whose ground truth is known — a
/// mirrored or rotated sampler would produce plausible-looking sheets that silently break the
/// spatial contract the whole scene-3D pipeline rests on.
@Suite("Equirect → perspective projection")
struct EquirectProjectorTests {

    // MARK: - Fixtures

    /// A 2:1 panorama painted by a longitude/latitude rule. `lon` ∈ (−180, 180] with 0 at the
    /// horizontal centre, `lat` ∈ [−90, 90] with +90 at the top row.
    private func panorama(
        width: Int = 512, height: Int = 256,
        _ color: (_ lon: Double, _ lat: Double) -> (UInt8, UInt8, UInt8)
    ) -> EquirectProjector.PixelBuffer {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let lat = 90 - (Double(y) + 0.5) / Double(height) * 180
            for x in 0..<width {
                let lon = (Double(x) + 0.5) / Double(width) * 360 - 180
                let (r, g, b) = color(lon, lat)
                let i = (y * width + x) * 4
                rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = 255
            }
        }
        return EquirectProjector.PixelBuffer(width: width, height: height, rgba: rgba)
    }

    /// Four coloured quadrants, one per cardinal direction.
    private var quadrants: EquirectProjector.PixelBuffer {
        panorama { lon, _ in
            switch lon {
            case -45..<45: return (255, 0, 0)      // front  (yaw 0)
            case 45..<135: return (0, 255, 0)      // right  (yaw +90)
            case -135..<(-45): return (0, 0, 255)  // left   (yaw −90)
            default: return (255, 255, 0)          // back   (yaw 180 / the seam)
            }
        }
    }

    private func centrePixel(_ img: EquirectProjector.PixelBuffer) -> (UInt8, UInt8, UInt8) {
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return (img.rgba[i], img.rgba[i + 1], img.rgba[i + 2])
    }

    private func pixel(_ img: EquirectProjector.PixelBuffer, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * img.width + x) * 4
        return (img.rgba[i], img.rgba[i + 1], img.rgba[i + 2])
    }

    // MARK: - Conventions

    /// Yaw 0 is the panorama's centre and each cardinal POV lands in its own quadrant. If the
    /// sampler flipped or rotated, this is where it shows.
    @Test("each cardinal POV looks at its own quadrant")
    func cardinalPovsHitTheirQuadrant() {
        let pano = quadrants
        func centre(_ name: String) -> (UInt8, UInt8, UInt8) {
            let pov = defaultFourWallPovs.first { $0.name == name }!
            return centrePixel(EquirectProjector.project(pano: pano, pov: pov, width: 64, height: 36))
        }
        #expect(centre("wide_front") == (255, 0, 0))
        #expect(centre("wide_right") == (0, 255, 0))
        #expect(centre("wide_back") == (255, 255, 0))
        #expect(centre("wide_left") == (0, 0, 255))
    }

    /// Left/right must not be mirrored: content east of the panorama's centre has to appear on the
    /// RIGHT of the front view. This is the rule #166 exists for.
    @Test("horizontal order is preserved, not mirrored")
    func horizontalOrderIsNotMirrored() {
        // Green to the east of centre, blue to the west.
        let pano = panorama { lon, _ in
            if lon > 5 && lon < 30 { return (0, 255, 0) }
            if lon < -5 && lon > -30 { return (0, 0, 255) }
            return (0, 0, 0)
        }
        let pov = PovSpec(name: "front", yawDegrees: 0, pitchDegrees: 0)
        let view = EquirectProjector.project(pano: pano, pov: pov, width: 128, height: 72)
        let row = view.height / 2
        // Sample well inside each half.
        #expect(pixel(view, x: 100, y: row) == (0, 255, 0))   // east → right
        #expect(pixel(view, x: 28, y: row) == (0, 0, 255))    // west → left
    }

    /// Pitch sign: a negative pitch looks DOWN, so the view's centre samples below the equator.
    @Test("negative pitch looks down")
    func negativePitchLooksDown() {
        let pano = panorama { _, lat in lat >= 0 ? (255, 255, 255) : (0, 0, 0) }
        let level = PovSpec(name: "l", yawDegrees: 0, pitchDegrees: 0, fovHorizontalDegrees: 20)
        let down = PovSpec(name: "d", yawDegrees: 0, pitchDegrees: -30, fovHorizontalDegrees: 20)
        // A level 20° lens straddles the equator; its centre row is the boundary. Tilted 30° down,
        // the whole frame is below it.
        #expect(centrePixel(EquirectProjector.project(pano: pano, pov: down, width: 32, height: 18)) == (0, 0, 0))
        let levelTop = pixel(EquirectProjector.project(pano: pano, pov: level, width: 32, height: 18), x: 16, y: 1)
        #expect(levelTop == (255, 255, 255))   // up is up
    }

    /// The panorama is seamless in longitude. The back view straddles ±180, so a sampler that
    /// clamped instead of wrapping would smear the seam — here it must read clean yellow.
    @Test("the seam at ±180 wraps instead of clamping")
    func seamWraps() {
        let pano = quadrants
        let back = defaultFourWallPovs.first { $0.name == "wide_back" }!
        let view = EquirectProjector.project(pano: pano, pov: back, width: 64, height: 36)
        let row = view.height / 2
        // Both sides of the seam are the same quadrant → the whole row is yellow.
        for x in [4, 20, 32, 44, 60] {
            #expect(pixel(view, x: x, y: row) == (255, 255, 0), "column \(x) smeared at the seam")
        }
    }

    // MARK: - Consistency (the actual product promise)

    /// The guarantee that makes the pipeline worth having: every POV is cut from ONE panorama, so
    /// two views of the same wall agree. A 20° window on the right wall, reached directly (yaw 90)
    /// or as the right edge of a wider frame, must show the same content.
    @Test("two POVs onto the same wall agree, because they share one panorama")
    func twoPovsOfOneWallAgree() {
        let pano = panorama { lon, _ in
            // A distinctive vertical band on the right wall.
            (lon > 85 && lon < 95) ? (255, 0, 255) : (10, 10, 10)
        }
        let direct = PovSpec(name: "a", yawDegrees: 90, pitchDegrees: 0, fovHorizontalDegrees: 40)
        let shifted = PovSpec(name: "b", yawDegrees: 70, pitchDegrees: 0, fovHorizontalDegrees: 40)
        let a = EquirectProjector.project(pano: pano, pov: direct, width: 128, height: 72)
        let b = EquirectProjector.project(pano: pano, pov: shifted, width: 128, height: 72)
        func hasBand(_ img: EquirectProjector.PixelBuffer) -> Bool {
            (0..<img.width).contains { pixel(img, x: $0, y: img.height / 2) == (255, 0, 255) }
        }
        #expect(hasBand(a))
        #expect(hasBand(b))
        // In the direct view the band is centred; from 20° left of it, it sits to the right.
        func bandCentroid(_ img: EquirectProjector.PixelBuffer) -> Double {
            let xs = (0..<img.width).filter { pixel(img, x: $0, y: img.height / 2) == (255, 0, 255) }
            return xs.map(Double.init).reduce(0, +) / Double(xs.count)
        }
        #expect(abs(bandCentroid(a) - 63.5) < 2)
        #expect(bandCentroid(b) > bandCentroid(a))
    }

    @Test("output size is honoured")
    func outputSize() {
        let view = EquirectProjector.project(
            pano: quadrants, pov: defaultFourWallPovs[0],
            width: defaultPovSize.width, height: defaultPovSize.height)
        #expect(view.width == 1280)
        #expect(view.height == 720)
        #expect(view.rgba.count == 1280 * 720 * 4)
    }

    /// Vertical FOV follows the output aspect, exactly as `pov.py` computes it before calling e2p.
    @Test("vertical FOV derives from the output aspect")
    func verticalFov() {
        let pov = PovSpec(name: "t", yawDegrees: 0, fovHorizontalDegrees: 75)
        let v = EquirectProjector.verticalFOV(pov, width: 1280, height: 720)
        #expect(abs(v - 75.0 * 720.0 / 1280.0) < 1e-12)
    }
}
