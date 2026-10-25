import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Shared video rendering context")
struct VideoRenderContextTests {
    private actor Start {
        private var waiting: CheckedContinuation<Void, Never>?
        func arrive() async {
            if let waiting { self.waiting = nil; waiting.resume() }
            else { await withCheckedContinuation { waiting = $0 } }
        }
    }

    @Test func compositorAndScopesRenderTheSameLazyGlowConcurrently() async throws {
        _ = try #require(VideoRenderContext.device, "Production rendering requires the CI runner's Metal device")
        #expect(CustomVideoCompositor.ciContext === ColorScopes.context)
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        let black = CIImage(color: .black).cropped(to: bounds)
        let spot = CIImage(color: .white).cropped(to: CGRect(x: 21, y: 21, width: 6, height: 6)).composited(over: black)
        let glow = GlowKernel.apply(spot, extent: bounds, intensity: 1, radius: 6, threshold: 0.3, warmth: 0)
        let start = Start()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                await start.arrive()
                for _ in 0..<16 {
                    var buffer: CVPixelBuffer?
                    let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
                    let status = CVPixelBufferCreate(kCFAllocatorDefault, 48, 48, kCVPixelFormatType_32BGRA,
                        attributes as CFDictionary, &buffer)
                    try #require(status == kCVReturnSuccess)
                    let output = try #require(buffer)
                    CustomVideoCompositor.ciContext.render(glow, to: output, bounds: bounds, colorSpace: nil)
                    try #require(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
                    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
                    let bytes = try #require(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt8.self)
                    let offset = 24 * CVPixelBufferGetBytesPerRow(output) + 32 * 4
                    for channel in 0..<3 { #expect(bytes[offset + channel] > 2 && bytes[offset + channel] < 80) }
                }
                return 16
            }
            group.addTask {
                await start.arrive()
                for _ in 0..<16 {
                    let measured = try #require(ColorScopes.measure(glow, gridEdge: 48))
                    #expect(measured.lumaMean.isFinite && measured.lumaMean > 36.0 / (48 * 48) && measured.lumaMean < 0.2)
                    #expect(abs(measured.meanRGB.x - measured.meanRGB.y) < 0.01)
                    #expect(abs(measured.meanRGB.y - measured.meanRGB.z) < 0.01)
                    let image = try #require(ColorScopes.context.createCGImage(glow, from: bounds,
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
                    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
                    #expect(image.width == 48 && image.height == 48)
                    let pixels = ColorProbeHelpers.srgbBytes(image, size: bounds.size)
                    let offset = (24 * 48 + 32) * 4
                    for channel in 0..<3 { #expect(pixels[offset + channel] > 2 && pixels[offset + channel] < 200) }
                }
                return 16
            }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }
        #expect(results == [16, 16])
    }
}
