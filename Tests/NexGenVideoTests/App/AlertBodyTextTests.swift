import AppKit
import Testing

@testable import NexGenVideo

/// `NSAlert.informativeText` hyphenates, which chopped a pack id mid-word in the field
/// ("musi-cvideo") — unacceptable for a name the user has to recognize. The body is our own label so
/// the paragraph style can forbid it; this pins that, because such a regression is silent.
@MainActor
@Suite("alert body forbids hyphenation")
struct AlertBodyTextTests {

    private func paragraphStyle(of view: NSView) -> NSParagraphStyle? {
        guard let field = view as? NSTextField, field.attributedStringValue.length > 0 else { return nil }
        return field.attributedStringValue
            .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    }

    @Test("hyphenation is off and wrapping happens on word boundaries")
    func hyphenationDisabled() throws {
        let view = AppState.bodyText("Opening this project without the musicvideo pack falls back.")
        let style = try #require(paragraphStyle(of: view))
        #expect(style.hyphenationFactor == 0)
        #expect(style.lineBreakMode == .byWordWrapping)
    }

    @Test("the text survives verbatim — no truncation")
    func textIsIntact() throws {
        let text = "Built for a different version of NexGenVideo — update the pack."
        let field = try #require(AppState.bodyText(text) as? NSTextField)
        #expect(field.attributedStringValue.string == text)
        #expect(field.usesSingleLineMode == false)
    }

    @Test("the label reserves the full wrapped text height")
    func labelFitsWrappedText() throws {
        let long = String(repeating: "wrapping across several lines. ", count: 8)
        let field = try #require(AppState.bodyText(long) as? NSTextField)
        let oracle = NSTextFieldCell(textCell: "")
        oracle.attributedStringValue = field.attributedStringValue
        oracle.wraps = true
        oracle.usesSingleLineMode = false
        oracle.isScrollable = false
        let requiredHeight = oracle.cellSize(
            forBounds: NSRect(
                x: AppTheme.Spacing.none,
                y: AppTheme.Spacing.none,
                width: field.frame.width,
                height: .greatestFiniteMagnitude
            )
        ).height

        #expect(field.maximumNumberOfLines == 0)
        #expect(field.cell?.wraps == true)
        #expect(requiredHeight > 0)
        #expect(field.frame.height >= ceil(requiredHeight))
    }
}
