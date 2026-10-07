import CoreGraphics
import CoreText
import Foundation

enum InspectFrameGrid: Sendable {
    static let labels = (0...10).map { index in
        index == 0 || index == 10 ? "\(index / 10)" : String(format: "%.1f", Double(index) / 10)
    }
    static var metadata: [String: Any] {
        [
            "enabled": true,
            "space": Crop.coordinateSpace,
            "origin": "topLeft",
            "range": [0, 1],
            "labels": labels,
            "cropMapping": "left=x0, top=y0, right=1-x1, bottom=1-y1",
        ]
    }

    nonisolated static func apply(to image: CGImage) -> CGImage {
        overlay(on: image) ?? image
    }

    nonisolated static func encode(_ image: CGImage) -> ImageEncoder.Output? {
        ImageEncoder.encodeWithinBudget(apply(to: image), preferPNG: hasAlpha(image))
    }

    private nonisolated static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private nonisolated static func overlay(on image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        drawLines(in: context, width: width, height: height)
        drawLabels(in: context, width: width, height: height)
        return context.makeImage()
    }

    private nonisolated static func drawLines(in context: CGContext, width: CGFloat, height: CGFloat) {
        func stroke(lineWidth: CGFloat, color: CGColor) {
            context.setLineWidth(lineWidth)
            context.setStrokeColor(color)
            for index in 0...10 {
                let fraction = CGFloat(index) / 10
                let x = min(max(0.5, fraction * width), width - 0.5)
                let y = min(max(0.5, drawingY(forTopOriginFraction: fraction, height: height)), height - 0.5)
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: height))
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: width, y: y))
            }
            context.strokePath()
        }
        stroke(
            lineWidth: AppTheme.BorderWidth.thick,
            color: AppTheme.Background.overlay.withAlphaComponent(AppTheme.Opacity.disabled).cgColor
        )
        stroke(
            lineWidth: AppTheme.BorderWidth.thin,
            color: AppTheme.Text.primary.withAlphaComponent(AppTheme.Opacity.high).cgColor
        )
    }

    private nonisolated static func drawLabels(in context: CGContext, width: CGFloat, height: CGFloat) {
        let fontSize = min(
            AppTheme.FontSize.xs,
            max(AppTheme.FontSize.minimumReadable, min(width, height) / 42)
        )
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: AppTheme.Text.primary.cgColor,
        ]

        for index in 0...10 {
            let fraction = CGFloat(index) / 10
            let label = labels[index]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let chipHeight = fontSize + AppTheme.Spacing.xs

            let x = min(
                max(AppTheme.Spacing.micro, fraction * width - textWidth / 2 - AppTheme.Spacing.xxs),
                width - textWidth - AppTheme.Spacing.xs - AppTheme.Spacing.micro
            )
            fillChip(in: context, rect: CGRect(
                x: x,
                y: AppTheme.Spacing.micro,
                width: textWidth + AppTheme.Spacing.xs,
                height: chipHeight
            ))
            context.textPosition = CGPoint(x: x + AppTheme.Spacing.xxs, y: AppTheme.Spacing.xxs)
            CTLineDraw(line, context)

            let contextY = drawingY(forTopOriginFraction: fraction, height: height)
            let alignedY = min(
                max(AppTheme.Spacing.micro, contextY - fontSize / 2 - AppTheme.Spacing.xxs),
                height - chipHeight - AppTheme.Spacing.micro
            )
            let y = index == 10
                ? min(
                    max(AppTheme.Spacing.micro, chipHeight + AppTheme.Spacing.xxs),
                    height - chipHeight - AppTheme.Spacing.micro
                )
                : alignedY
            let rightX = width - textWidth - AppTheme.Spacing.xs - AppTheme.Spacing.micro
            fillChip(in: context, rect: CGRect(
                x: rightX,
                y: y,
                width: textWidth + AppTheme.Spacing.xs,
                height: chipHeight
            ))
            context.textPosition = CGPoint(
                x: rightX + AppTheme.Spacing.xxs,
                y: y + AppTheme.Spacing.xxs
            )
            CTLineDraw(line, context)
        }
    }

    private nonisolated static func fillChip(in context: CGContext, rect: CGRect) {
        context.setFillColor(
            AppTheme.Background.overlay.withAlphaComponent(AppTheme.Opacity.scrim).cgColor
        )
        context.fill(rect)
    }

    nonisolated static func drawingY(forTopOriginFraction fraction: CGFloat, height: CGFloat) -> CGFloat {
        (1 - fraction) * height
    }
}
