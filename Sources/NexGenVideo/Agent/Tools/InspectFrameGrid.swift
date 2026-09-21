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
        func stroke(lineWidth: CGFloat, gray: CGFloat, alpha: CGFloat) {
            context.setLineWidth(lineWidth)
            context.setStrokeColor(CGColor(gray: gray, alpha: alpha))
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
        stroke(lineWidth: 2.5, gray: 0, alpha: 0.65)
        stroke(lineWidth: 1, gray: 1, alpha: 0.9)
    }

    private nonisolated static func drawLabels(in context: CGContext, width: CGFloat, height: CGFloat) {
        let fontSize = min(12, max(8, min(width, height) / 42))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]

        for index in 0...10 {
            let fraction = CGFloat(index) / 10
            let label = labels[index]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let chipHeight = fontSize + 4

            let x = min(max(1, fraction * width - textWidth / 2 - 2), width - textWidth - 5)
            fillChip(in: context, rect: CGRect(x: x, y: 1, width: textWidth + 4, height: chipHeight))
            context.textPosition = CGPoint(x: x + 2, y: 3)
            CTLineDraw(line, context)

            let contextY = drawingY(forTopOriginFraction: fraction, height: height)
            let alignedY = min(max(1, contextY - fontSize / 2 - 2), height - chipHeight - 1)
            let y = index == 10 ? min(max(1, chipHeight + 3), height - chipHeight - 1) : alignedY
            let rightX = width - textWidth - 5
            fillChip(in: context, rect: CGRect(x: rightX, y: y, width: textWidth + 4, height: chipHeight))
            context.textPosition = CGPoint(x: rightX + 2, y: y + 2)
            CTLineDraw(line, context)
        }
    }

    private nonisolated static func fillChip(in context: CGContext, rect: CGRect) {
        context.setFillColor(CGColor(gray: 0, alpha: 0.7))
        context.fill(rect)
    }

    nonisolated static func drawingY(forTopOriginFraction fraction: CGFloat, height: CGFloat) -> CGFloat {
        (1 - fraction) * height
    }
}
