import CoreImage
import Foundation
import Testing
@testable import NexGenVideo

/// #219: the denoise kernel's two promises — it removes noise WITHOUT eating edges, and it smooths
/// chroma harder than luma (that is where the noise lives, and it is what keeps the result from
/// just being "soft").
@Suite("DenoiseKernel")
struct DenoiseKernelTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let n = 64

    /// Builds an image from a per-pixel RGB rule (values 0…1).
    private func image(_ rule: (_ x: Int, _ y: Int) -> (Double, Double, Double)) -> CIImage {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let (r, g, b) = rule(x, y)
                let i = (y * n + x) * 4
                px[i] = UInt8(max(0, min(255, r * 255)))
                px[i + 1] = UInt8(max(0, min(255, g * 255)))
                px[i + 2] = UInt8(max(0, min(255, b * 255)))
                px[i + 3] = 255
            }
        }
        let cg = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        px.withUnsafeBytes {
            cg.data!.copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        return CIImage(cgImage: cg.makeImage()!, options: [.colorSpace: NSNull()])
    }

    private func rgba(_ img: CIImage) -> [Float] {
        var px = [Float](repeating: 0, count: n * n * 4)
        ctx.render(img, toBitmap: &px, rowBytes: n * 16,
                   bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBAf, colorSpace: nil)
        return px
    }

    private func lumaAt(_ a: [Float], _ x: Int, _ y: Int) -> Float {
        let i = (y * n + x) * 4
        return 0.2126 * a[i] + 0.7152 * a[i + 1] + 0.0722 * a[i + 2]
    }

    /// Deterministic pseudo-noise — a hash, so the test never flakes.
    private func noise(_ x: Int, _ y: Int, _ salt: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ salt &* 83_492_791)
        h ^= h >> 33; h = h &* 0xff51_afd7_ed55_8ccd; h ^= h >> 33
        return Double(h % 1000) / 1000.0 - 0.5   // −0.5 … +0.5
    }

    /// A flat grey field with luma noise on it.
    private func noisyFlat() -> CIImage {
        image { x, y in
            let v = 0.5 + noise(x, y, 1) * 0.12
            return (v, v, v)
        }
    }

    private func standardDeviation(_ values: [Float]) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
    }

    @Test("amount 0 is a no-op")
    func neutralIsNoOp() {
        let img = noisyFlat()
        let before = rgba(img)
        let after = rgba(DenoiseKernel.apply(img, extent: img.extent, luma: 0, chromaBias: 0.6, detail: 0.5))
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    /// The point of the thing: less noise in a flat field.
    @Test("noise in a flat field is reduced")
    func flatFieldGetsCleaner() {
        let img = noisyFlat()
        let out = DenoiseKernel.apply(img, extent: img.extent, luma: 1, chromaBias: 0.6, detail: 0)
        // Sample the interior only — the blur clamps at the border.
        func interiorLuma(_ a: [Float]) -> [Float] {
            (8..<(n - 8)).flatMap { y in (8..<(n - 8)).map { x in lumaAt(a, x, y) } }
        }
        let before = standardDeviation(interiorLuma(rgba(img)))
        let after = standardDeviation(interiorLuma(rgba(out)))
        #expect(after < before * 0.75, "noise not reduced: σ \(before) → \(after)")
    }

    /// The promise that separates this from a blur: a hard edge survives.
    @Test("a hard edge survives denoising")
    func edgeSurvives() {
        // Clean vertical edge, no noise — an edge is exactly what must NOT be averaged away.
        let img = image { x, _ in
            let v = x < 32 ? 0.25 : 0.75
            return (v, v, v)
        }
        let out = DenoiseKernel.apply(img, extent: img.extent, luma: 1, chromaBias: 0.6, detail: 0.5)
        let a = rgba(out)
        // Contrast across the edge, sampled two pixels either side of it.
        let dark = lumaAt(a, 29, 32), bright = lumaAt(a, 34, 32)
        #expect(bright - dark > 0.40, "edge washed out: \(dark) → \(bright)")
        // And the flat sides stay at their level rather than drifting toward each other.
        #expect(abs(lumaAt(a, 8, 32) - 0.25) < 0.03)
        #expect(abs(lumaAt(a, 56, 32) - 0.75) < 0.03)
    }

    /// Chroma is smoothed harder than luma — the reason this reads as "clean" and not "soft".
    @Test("chroma is smoothed harder than luma")
    func chromaIsSmoothedHarder() {
        // Constant luma, noise ONLY in chroma: red and blue wobble in opposite directions, so the
        // Rec.709 luma stays put while the colour speckles.
        let img = image { x, y in
            let c = noise(x, y, 2) * 0.25
            return (0.5 + c, 0.5, 0.5 - c * 0.7)
        }
        func chromaSpread(_ a: [Float]) -> Float {
            let cr = (8..<(n - 8)).flatMap { y in
                (8..<(n - 8)).map { x -> Float in
                    let i = (y * n + x) * 4
                    return a[i] - (0.2126 * a[i] + 0.7152 * a[i + 1] + 0.0722 * a[i + 2])
                }
            }
            return standardDeviation(cr)
        }
        let before = chromaSpread(rgba(img))
        // A low `luma` amount: chroma still gets pushed harder thanks to the bias.
        let out = DenoiseKernel.apply(img, extent: img.extent, luma: 0.5, chromaBias: 1.0, detail: 0.5)
        let after = chromaSpread(rgba(out))
        #expect(after < before * 0.6, "chroma noise not preferentially removed: σ \(before) → \(after)")
    }

    /// `detail` protects fine texture: the same field keeps more of its variance at detail 1.
    @Test("detail protects texture")
    func detailProtectsTexture() {
        let img = noisyFlat()
        func spread(_ image: CIImage) -> Float {
            let a = rgba(image)
            return standardDeviation((8..<(n - 8)).flatMap { y in (8..<(n - 8)).map { x in lumaAt(a, x, y) } })
        }
        let aggressive = spread(DenoiseKernel.apply(img, extent: img.extent, luma: 1, chromaBias: 0.6, detail: 0))
        let protective = spread(DenoiseKernel.apply(img, extent: img.extent, luma: 1, chromaBias: 0.6, detail: 1))
        #expect(protective > aggressive, "detail should preserve more variance (\(aggressive) vs \(protective))")
    }

    /// The registry entry drives the kernel (not the old CINoiseReduction) and keeps its id, so
    /// effects saved on existing projects still resolve.
    @Test("the registry entry is wired to the kernel")
    func registryEntry() throws {
        let descriptor = try #require(EffectRegistry.byId["blur.noiseReduction"])
        // The id is unchanged on purpose: effects saved on existing projects must still resolve.
        #expect(Set(descriptor.params.map(\.key)) == ["amount", "chroma", "detail"])
        let img = noisyFlat()
        var effect = descriptor.makeEffect()
        effect.params["amount"] = EffectParam(value: 1)
        let out = descriptor.render(img, effect: effect, atOffset: 0)
        func spread(_ image: CIImage) -> Float {
            let a = rgba(image)
            return standardDeviation((8..<(n - 8)).flatMap { y in (8..<(n - 8)).map { x in lumaAt(a, x, y) } })
        }
        #expect(spread(out) < spread(img))
    }
}
