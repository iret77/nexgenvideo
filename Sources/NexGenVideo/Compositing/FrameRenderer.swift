import AVFoundation
import CoreImage

// Shared bottom-to-top compositor for preview, capture, final render and export.
enum FrameRenderer {

    static func render(
        instruction: CompositorInstruction,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        compositionTime: CMTime,
        into output: CVPixelBuffer,
        context: CIContext
    ) {
        let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
        let frame = Int((compositionTime.seconds * Double(instruction.fps)).rounded())

        var accum = CIImage(color: .black).cropped(to: renderRect)
        for layer in instruction.layers {
            let source: CIImage
            let sourceHeight: CGFloat
            if let still = layer.stillImage {
                source = still
                sourceHeight = layer.natSize.height
            } else if let text = layer.textSource {
                guard let image = text.image() else { continue }
                source = image
                sourceHeight = layer.natSize.height
            } else if let buffer = sourceFrame(layer.trackID) {
                source = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]).unpremultiplyingAlpha()
                sourceHeight = CGFloat(CVPixelBufferGetHeight(buffer))
            } else { continue }
            let image = composedLayer(layer, source: source, sourceHeight: sourceHeight,
                                      frame: frame, renderSize: instruction.renderSize)
            accum = ClipBlendRenderer.composite(
                image, over: accum, mode: layer.clip.blendMode,
                opacity: layer.clip.opacityAt(frame: frame), bounds: renderRect
            )
        }
        context.render(accum, to: output, bounds: renderRect, colorSpace: nil)
        tag709(output)
    }

    /// Tag output Rec. 709 at the buffer level so downstream reads our bytes correctly.
    private static func tag709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func composedLayer(
        _ layer: LayerPlan,
        source: CIImage,
        sourceHeight: CGFloat,
        frame: Int,
        renderSize: CGSize
    ) -> CIImage {
        let clip = layer.clip
        var image = source
        let srcHeight = sourceHeight

        let crop = clip.cropAt(frame: frame)
        if !crop.isIdentity {
            // Display-space insets → source pixels → CI's bottom-left origin.
            let avRect = CGRect(
                x: crop.left * layer.natSize.width,
                y: crop.top * layer.natSize.height,
                width: max(1, crop.visibleWidthFraction * layer.natSize.width),
                height: max(1, crop.visibleHeightFraction * layer.natSize.height)
            ).applying(layer.preferredTransform.inverted())
            image = image.cropped(to: CGRect(
                x: avRect.origin.x,
                y: srcHeight - avRect.origin.y - avRect.height,
                width: avRect.width,
                height: avRect.height
            ))
        }

        // Effects apply in source-pixel space: after crop, before placement.
        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset)
            }
        }

        // Animated geometry retains the clip's static reflection axes.
        var t = clip.hasTransformAnimation ? clip.transformAt(frame: frame) : clip.transform
        t.flipHorizontal = clip.transform.flipHorizontal
        t.flipVertical = clip.transform.flipVertical
        let av = layer.preferredTransform.concatenating(
            CompositionBuilder.affineTransform(for: t, natSize: layer.natSize, renderSize: renderSize)
        )
        // Conjugate the AV top-left-origin mapping into CI's bottom-left space.
        let ci = flipY(srcHeight).concatenating(av).concatenating(flipY(renderSize.height))
        image = image.transformed(by: ci)

        return image
    }

    private static func flipY(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
