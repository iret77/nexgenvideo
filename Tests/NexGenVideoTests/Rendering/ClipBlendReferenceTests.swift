import AVFoundation
import CoreImage
import Testing
@testable import NexGenVideo

@Suite("Blend modes — reference pixels")
struct ClipBlendReferenceTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
    private let backdrop = [0.25, 0.5, 0.75]

    private func solid(_ rgb: [Double], alpha: Double = 1, rect: CGRect? = nil) -> CIImage {
        CIImage(color: CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha)).cropped(to: rect ?? bounds)
    }

    private func pixel(_ image: CIImage, x: Int = 8, y: Int = 8) -> [Double] {
        var rgba = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 16,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return rgba.map(Double.init)
    }

    static let references: [(ClipBlendMode, [Double])] = [
        (.normal, [0.8, 0.4, 0.2]), (.darken, [0.25, 0.4, 0.2]),
        (.multiply, [0.2, 0.2, 0.15]), (.colorBurn, [0.0625, 0, 0]),
        (.lighten, [0.8, 0.5, 0.75]), (.screen, [0.85, 0.7, 0.8]),
        (.colorDodge, [1, 5.0 / 6, 0.9375]), (.overlay, [0.4, 0.4, 0.6]),
        (.softLight, [0.4, 0.45, 0.6375]), (.hardLight, [0.7, 0.4, 0.3]),
        (.difference, [0.55, 0.1, 0.55]), (.exclusion, [0.65, 0.5, 0.65]),
        (.hue, [0.704167, 0.370833, 0.204167]), (.saturation, [0.2095, 0.5095, 0.8095]),
        (.color, [0.7545, 0.3545, 0.1545]), (.luminosity, [0.2955, 0.5455, 0.7955]),
    ]

    @Test(arguments: references)
    func opaqueAndFractionalAlphaMatchIndependentReference(mode: ClipBlendMode, expected: [Double]) {
        for alpha in [0.0, 0.4, 1.0] {
            for opacity in [0.0, 0.35, 1.0] {
                let image = ClipBlendRenderer.composite(solid([0.8, 0.4, 0.2], alpha: alpha),
                    over: solid(backdrop), mode: mode, opacity: opacity, bounds: bounds)
                let actual = pixel(image)
                for channel in 0..<3 {
                    let reference = backdrop[channel] + alpha * opacity * (expected[channel] - backdrop[channel])
                    #expect(abs(actual[channel] - reference) < 0.025,
                            "\(mode) alpha=\(alpha) opacity=\(opacity) channel=\(channel): \(actual[channel]) vs \(reference)")
                }
                #expect(abs(actual[3] - 1) < 0.001)
            }
        }
    }

    @Test(arguments: ClipBlendMode.allCases)
    func croppedLayerDoesNotEraseBackdrop(mode: ClipBlendMode) {
        let image = ClipBlendRenderer.composite(
            solid([0.8, 0.4, 0.2], rect: CGRect(x: 4, y: 4, width: 8, height: 8)),
            over: solid(backdrop), mode: mode, opacity: 0.5, bounds: bounds)
        for channel in 0..<3 { #expect(abs(pixel(image, x: 1, y: 1)[channel] - backdrop[channel]) < 0.001) }
        #expect(image.extent == bounds)
    }

    @Test(arguments: ClipBlendMode.allCases)
    func keyedMatteRevealsBackdrop(mode: ClipBlendMode) {
        let keyed = ChromaKeyKernel.apply(solid([0.1, 0.8, 0.15]), keyHue: 0.333,
                                         tolerance: 0.5, softness: 0.3, spill: 0)
        #expect(pixel(keyed)[3] < 0.05)
        let image = ClipBlendRenderer.composite(keyed, over: solid(backdrop), mode: mode, opacity: 0.6, bounds: bounds)
        for channel in 0..<3 { #expect(abs(pixel(image)[channel] - backdrop[channel]) < 0.025) }
    }

    @Test func completeVersionOneReferenceSet() {
        #expect(Set(Self.references.map { $0.0 }) == Set(ClipBlendMode.allCases))
    }
}
