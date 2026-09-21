import AppKit
import QuartzCore

enum TextLayerStyle {
    static func hasVisibleText(in timeline: Timeline) -> Bool {
        timeline.tracks.contains { track in
            !track.hidden && track.type.isVisual && track.clips.contains {
                $0.mediaType == .text && $0.durationFrames > 0
            }
        }
    }

    static func makeLayer(clip: Clip, containerSize: CGSize) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = 1
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.allowsFontSubpixelQuantization = true
        let style = clip.textStyle ?? TextStyle()
        let scale = containerSize.height / 1080
        let tl = clip.transform.topLeft
        layer.frame = CGRect(
            x: tl.x * containerSize.width, y: tl.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )
        let fontSize = CGFloat(style.fontSize * style.fontScale) * scale
        layer.string = NSAttributedString(string: clip.textContent ?? "", attributes: style.attributes(size: fontSize))
        layer.alignmentMode = style.alignment.caTextAlignmentMode
        layer.backgroundColor = style.background.enabled ? style.background.color.nsColor.cgColor : nil
        layer.borderColor = style.border.enabled ? style.border.color.nsColor.cgColor : nil
        layer.borderWidth = style.border.enabled ? AppTheme.BorderWidth.thin * scale : 0
        if style.shadow.enabled {
            layer.shadowColor = style.shadow.color.nsColor.cgColor
            layer.shadowOpacity = Float(AppTheme.Opacity.opaque)
            layer.shadowOffset = CGSize(width: style.shadow.offsetX * scale, height: style.shadow.offsetY * scale)
            layer.shadowRadius = max(0, CGFloat(style.shadow.blur) * scale)
        }
        return layer
    }
}
