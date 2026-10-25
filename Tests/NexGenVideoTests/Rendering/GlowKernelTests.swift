import CoreImage
import Foundation
import Metal
import Testing
@testable import NexGenVideo

@Suite("GlowKernel")
struct GlowKernelTests {

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let ctx: CIContext
    private let n = 48

    init() throws {
        let device = try #require(VideoRenderContext.device, "Glow pixel tests require a Metal device")
        let queue = try #require(device.makeCommandQueue(), "Couldn't create the Glow pixel command queue")
        self.device = device
        self.queue = queue
        ctx = VideoRenderContext.context
    }

    private func spot() throws -> CIImage {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in (n / 2 - 3)..<(n / 2 + 3) {
            for x in (n / 2 - 3)..<(n / 2 + 3) {
                let i = (y * n + x) * 4
                px[i] = 255; px[i + 1] = 255; px[i + 2] = 255; px[i + 3] = 255
            }
        }
        let c = try #require(CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "Couldn't create the Glow spot bitmap")
        let destination = try #require(c.data, "The Glow spot bitmap has no writable storage")
        try px.withUnsafeBytes { bytes in
            let source = try #require(bytes.baseAddress, "The Glow spot fixture has no pixel storage")
            destination.copyMemory(from: source, byteCount: bytes.count)
        }
        let image = try #require(c.makeImage(), "Couldn't create the Glow spot image")
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) throws -> (Double, Double, Double) {
        let bytesPerRow = n * 4 * MemoryLayout<Float>.stride
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: n, height: n, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor), "Couldn't allocate the Glow GPU texture")
        let readback = try #require(device.makeBuffer(length: bytesPerRow * n, options: .storageModeShared),
            "Couldn't allocate the Glow GPU readback buffer")
        let command = try #require(queue.makeCommandBuffer(), "Couldn't create the Glow GPU command buffer")
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        destination.colorSpace = nil
        destination.blendKernel = nil
        destination.alphaMode = .premultiplied
        destination.isFlipped = false
        destination.isClamped = false
        destination.isDithered = false
        let renderTask = try ctx.startTask(toRender: image,
            from: CGRect(x: 0, y: 0, width: n, height: n), to: destination, at: .zero)
        let blit = try #require(command.makeBlitCommandEncoder(), "Couldn't encode the Glow GPU readback")
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: n, height: n, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: 0)
        blit.endEncoding()
        return try withExtendedLifetime((device, queue, ctx, image, texture, readback, command, destination, renderTask)) {
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed,
                "Glow GPU render/readback failed: \(command.error?.localizedDescription ?? "no command error supplied")")
            _ = try renderTask.waitUntilCompleted()
            let px = readback.contents().bindMemory(to: Float.self, capacity: n * n * 4)
            let i = (y * n + x) * 4
            return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
        }
    }

    private func glow(_ intensity: Double, warmth: Double = 0) throws -> CIImage {
        let img = try spot()
        return GlowKernel.apply(img, extent: img.extent, intensity: intensity,
                                radius: 6, threshold: 0.3, warmth: warmth)
    }

    @Test func neutralIsNoOp() throws {
        #expect(try pixel(glow(0), n / 2 + 8, n / 2).0 < 0.01)
    }

    @Test func bleedsLightIntoNeighbors() throws {
        let off = try pixel(spot(), n / 2 + 8, n / 2).0
        let on = try pixel(glow(1), n / 2 + 8, n / 2).0
        #expect(on > off + 0.05, "glow should bleed light onto neighbors (\(off) → \(on))")
    }

    @Test func warmthTintsTheBleedRed() throws {
        let neutral = try pixel(glow(1, warmth: 0), n / 2 + 5, n / 2)
        let warm = try pixel(glow(1, warmth: 1), n / 2 + 5, n / 2)
        #expect(warm.0 - warm.2 > neutral.0 - neutral.2 + 0.03, "warm halation bleeds redder than blue")
    }
}
