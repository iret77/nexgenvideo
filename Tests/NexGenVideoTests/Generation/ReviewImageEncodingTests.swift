import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Review images encode the exact supplied bytes")
struct ReviewImageEncodingTests {
    @Test func smallImagesRetainTheirExactBytesWithoutAPathCache() async throws {
        let first = try smallImage(red: 0.2)
        let second = try smallImage(red: 0.8)
        #expect(first != second)
        let firstOutput = await Task.detached { ImageEncoder.encode(data: first) }.value
        let secondOutput = await Task.detached { ImageEncoder.encode(data: second) }.value
        let encoded = try #require(firstOutput)
        let changed = try #require(secondOutput)
        #expect(encoded.data == first && encoded.mime == "image/png")
        #expect(changed.data == second && changed.mime == "image/png")
        #expect(ImageEncoder.encode(data: Data("not an image".utf8)) == nil)
    }

    @Test func largeReviewImageIsActuallyDownsampledOutsideTheMainActor() async throws {
        let context = try #require(CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        let source = try #require(context.makeImage())
        let bytes = try #require(ImageEncoder.encodePNG(source))
        let result = await Task.detached { ImageEncoder.encode(data: bytes) }.value
        let encoded = try #require(result)
        #expect(encoded.mime == "image/jpeg")
        #expect(encoded.data.count <= ImageEncoder.maxBytes)
        let image = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) == ImageEncoder.maxLongestEdge)
        #expect(width > 0 && height > 0)
    }

    private func smallImage(red: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let image = try #require(context.makeImage())
        return try #require(ImageEncoder.encodePNG(image))
    }
}
