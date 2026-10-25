import CoreImage
import Foundation
import Metal

enum VideoRenderContext {
    static let device = MTLCreateSystemDefaultDevice()

    // Preview, export and scopes evaluate lazy effects through the same GPU context.
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: true,
        ]
        if let device {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
}
