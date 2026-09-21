import AVFoundation
import AppKit
import QuartzCore

/// Preview owns a long-lived `CATextLayer` tree with imperative opacity;
/// export hands a one-shot tree to `AVVideoCompositionCoreAnimationTool`.
@MainActor
final class TextLayerController {

    let textRoot: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.isGeometryFlipped = true
        return layer
    }()

    private var clips: [Clip] = []
    private var videoRect: CGRect = .zero
    private var layersByID: [String: CATextLayer] = [:]
    private var currentFrame = 0

    // Materialize layers slightly early so playback never hitches on typesetting.
    private static let prerollFrames = 30

    func sync(timeline: Timeline, videoRect: CGRect) {
        textRoot.frame = videoRect
        self.videoRect = videoRect
        clips = TextLayerController.visibleTextClips(in: timeline)
        reconcile(restyle: true)
    }

    func tick(_ frame: Int) {
        currentFrame = frame
        reconcile(restyle: false)
    }

    // Only clips within the preroll window own a CATextLayer; everything else stays unmaterialized.
    private func reconcile(restyle: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var needed = Set<String>()
        for (index, clip) in clips.enumerated() {
            guard currentFrame >= clip.startFrame - Self.prerollFrames,
                  currentFrame < clip.endFrame else { continue }
            needed.insert(clip.id)

            let layer: CATextLayer
            if let existing = layersByID[clip.id] {
                layer = existing
                if restyle { Self.applyStyle(to: layer, clip: clip, containerSize: videoRect.size) }
            } else {
                layer = Self.makeTextLayer()
                Self.applyStyle(to: layer, clip: clip, containerSize: videoRect.size)
                layersByID[clip.id] = layer
                textRoot.addSublayer(layer)
            }
            layer.zPosition = CGFloat(index)

            let visible = currentFrame >= clip.startFrame
            let target: Float = visible ? Float(clip.opacityAt(frame: currentFrame)) : 0
            if layer.opacity != target { layer.opacity = target }
        }

        for (id, layer) in layersByID where !needed.contains(id) {
            layer.removeFromSuperlayer()
            layersByID[id] = nil
        }

        CATransaction.commit()
    }

    // MARK: - Static builders

    static func buildForExport(
        timeline: Timeline,
        fps: Int,
        renderSize: CGSize
    ) -> (parent: CALayer, videoLayer: CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true
        parent.backgroundColor = AppTheme.Background.clearNSColor.cgColor
        parent.beginTime = AVCoreAnimationBeginTimeAtZero

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        let fpsD = Double(max(1, fps))
        let totalSeconds = max(0.001, Double(max(1, timeline.totalFrames)) / fpsD)
        for clip in visibleTextClips(in: timeline) {
            let layer = makeTextLayer()
            applyStyle(to: layer, clip: clip, containerSize: renderSize)
            applyOpacityAnimation(to: layer, clip: clip, fps: fps, totalSeconds: totalSeconds)
            layer.displayIfNeeded()
            parent.addSublayer(layer)
        }
        return (parent, videoLayer)
    }

    static func buildSnapshot(
        timeline: Timeline,
        canvasSize: CGSize,
        atFrame frame: Int
    ) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: canvasSize)
        host.isGeometryFlipped = true
        for clip in visibleTextClips(in: timeline) {
            let layer = makeTextLayer()
            applyStyle(to: layer, clip: clip, containerSize: canvasSize)
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            layer.opacity = visible ? Float(clip.opacityAt(frame: frame)) : 0
            host.addSublayer(layer)
        }
        return host
    }

    static func hasVisibleText(in timeline: Timeline) -> Bool {
        !visibleTextClips(in: timeline).isEmpty
    }

    static func buildHDRExportOverlays(
        timeline: Timeline,
        renderSize: CGSize
    ) throws -> [HDRVideoExporter.TextOverlay] {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
        return try visibleTextClips(in: timeline).compactMap { clip in
            let textLayer = makeTextLayer()
            applyStyle(to: textLayer, clip: clip, containerSize: renderSize)
            textLayer.opacity = 1
            textLayer.displayIfNeeded()

            let overflow = ceil(
                textLayer.shadowRadius * 2
                    + max(abs(textLayer.shadowOffset.width), abs(textLayer.shadowOffset.height))
                    + textLayer.borderWidth
            )
            let drawingRect = textLayer.frame
                .insetBy(dx: -overflow, dy: -overflow)
                .integral
                .intersection(canvas)
            guard !drawingRect.isEmpty else { return nil }

            let width = Int(drawingRect.width)
            let height = Int(drawingRect.height)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                throw HDRVideoExporter.HDRExportError(reason: "a title overlay could not be rasterized")
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))

            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: width, height: height)
            root.isGeometryFlipped = true
            textLayer.frame = CGRect(
                origin: CGPoint(
                    x: textLayer.frame.minX - drawingRect.minX,
                    y: textLayer.frame.minY - drawingRect.minY
                ),
                size: textLayer.frame.size
            )
            root.addSublayer(textLayer)
            root.render(in: context)
            guard let image = context.makeImage() else {
                throw HDRVideoExporter.HDRExportError(reason: "a title overlay produced no pixels")
            }
            return HDRVideoExporter.TextOverlay(
                image: image,
                placement: CGPoint(
                    x: drawingRect.minX,
                    y: renderSize.height - drawingRect.maxY
                ),
                clip: clip
            )
        }
    }

    // MARK: - Private

    private static func visibleTextClips(in timeline: Timeline) -> [Clip] {
        var result: [Clip] = []
        for track in timeline.tracks where !track.hidden {
            for clip in track.clips where clip.mediaType == .text && clip.endFrame > clip.startFrame {
                result.append(clip)
            }
        }
        return result
    }

    private static func makeTextLayer() -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.allowsFontSubpixelQuantization = true
        // NSNull suppresses CATextLayer's implicit per-property cross-fade.
        layer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "transform": NSNull(),
            "string": NSNull(),
        ]
        return layer
    }

    private static let referenceCanvasHeight: CGFloat = 1080

    private static func applyStyle(to layer: CATextLayer, clip: Clip, containerSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let content = clip.textContent ?? ""
        let scale = containerSize.height / referenceCanvasHeight

        let tl = clip.transform.topLeft
        layer.frame = CGRect(
            x: tl.x * containerSize.width,
            y: tl.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )

        let fontSize = CGFloat(style.fontSize * style.fontScale) * scale
        layer.string = NSAttributedString(
            string: content,
            attributes: style.attributes(size: fontSize)
        )
        layer.alignmentMode = style.alignment.caTextAlignmentMode

        layer.backgroundColor = style.background.enabled ? style.background.color.nsColor.cgColor : nil
        layer.borderColor = style.border.enabled ? style.border.color.nsColor.cgColor : nil
        layer.borderWidth = style.border.enabled ? AppTheme.BorderWidth.thin * scale : 0

        if style.shadow.enabled {
            layer.shadowColor = style.shadow.color.nsColor.cgColor
            layer.shadowOpacity = 1
            layer.shadowOffset = CGSize(
                width: style.shadow.offsetX * scale,
                height: style.shadow.offsetY * scale
            )
            layer.shadowRadius = max(0, CGFloat(style.shadow.blur) * scale)
        } else {
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
        }
    }

    /// Export-time opacity
    private static func applyOpacityAnimation(
        to layer: CATextLayer,
        clip: Clip,
        fps: Int,
        totalSeconds: Double
    ) {
        let fpsD = Double(max(1, fps))
        let total = max(0.001, totalSeconds)
        let totalFrames = max(1, Int((total * fpsD).rounded()))

        layer.opacity = 0

        // Discrete keyframes: values[i] holds in [keyTimes[i], keyTimes[i+1]),
        // so values.count == keyTimes.count - 1. https://developer.apple.com/documentation/quartzcore/cakeyframeanimation
        var keyTimes: [NSNumber] = [NSNumber(value: 0)]
        var values: [NSNumber] = []
        for frame in 0..<totalFrames {
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            let v = visible ? clip.opacityAt(frame: frame) : 0
            values.append(NSNumber(value: Float(v)))
            keyTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.calculationMode = .discrete
        anim.values = values
        anim.keyTimes = keyTimes
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = total
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "opacity")
    }
}
