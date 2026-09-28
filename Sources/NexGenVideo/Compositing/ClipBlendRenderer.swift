import CoreImage

enum ClipBlendRenderer {
    static func composite(
        _ foreground: CIImage, over background: CIImage,
        mode: ClipBlendMode, opacity: Double, bounds: CGRect
    ) -> CIImage {
        let opacity = opacity.isFinite ? min(1, max(0, opacity)) : 0
        guard opacity > 0 else { return background.cropped(to: bounds) }
        let blended: CIImage
        if let name = mode.filterName, let filter = CIFilter(name: name) {
            filter.setValue(foreground, forKey: kCIInputImageKey)
            filter.setValue(background, forKey: kCIInputBackgroundImageKey)
            blended = filter.outputImage ?? foreground.composited(over: background)
        } else {
            blended = foreground.composited(over: background)
        }
        let fullFrame = blended.composited(over: background).cropped(to: bounds)
        guard opacity < 1 else { return fullFrame }
        // Fade the blend result, including its matte, rather than changing blend inputs.
        return background.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: fullFrame,
            kCIInputTimeKey: opacity,
        ]).cropped(to: bounds)
    }
}
