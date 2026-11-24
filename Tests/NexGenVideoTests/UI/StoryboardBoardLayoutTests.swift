import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Storyboard board geometry", .serialized)
@MainActor
struct StoryboardBoardLayoutTests {
    @Test func sketchInspectControlFitsBoardViewportAboveTheMaximumDock() throws {
        let window = AppTheme.Window.projectMin
        for scale in [AppTheme.Typography.standardScale, AppTheme.Typography.largeScale, AppTheme.Typography.largestScale] {
            for pixels in [(1920, 1080), (1080, 1920)] {
                let image = try sketch(width: pixels.0, height: pixels.1)
                let host = NSHostingView(rootView: ProductionBoardFixture(image: image)
                    .environment(\.interfaceScale, scale)
                    .frame(width: window.width, height: window.height))
                host.setFrameSize(window)
                host.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()

                let control = try #require(find("storyboard.sketch.inspect", in: host))
                let scroll = try #require(enclosingScroll(of: control))
                let clip = scroll.contentView
                let frame = control.convert(control.bounds, to: clip)
                let context = "scale=\(scale), image=\(pixels), control=\(frame), clip=\(clip.bounds)"
                #expect(frame.height > 0 && frame.width > 0, "\(context)")
                #expect(frame.height <= clip.bounds.height, "\(context)")
                #expect(frame.width <= clip.bounds.width, "\(context)")
                #expect(frame.height <= AppTheme.Layout.storyboardSketchThumbnailMaxHeight + 1, "\(context)")
                let aspect = CGFloat(pixels.0) / CGFloat(pixels.1)
                #expect(abs(frame.width / frame.height - aspect) < 0.02, "\(context)")
            }
        }
    }

    private func sketch(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func find(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        return view.subviews.lazy.compactMap { find(name, in: $0) }.first
    }

    private func enclosingScroll(of view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView { return scroll }
            ancestor = current.superview
        }
        return nil
    }
}

// Mirrors the production cockpit: title bar, panel header, Board controls, and the phase dock at its height cap.
private struct ProductionBoardFixture: View {
    let image: CGImage
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let content = geometry.size.height - AppTheme.Layout.titleBarChromeHeight
                - AppTheme.Layout.workspaceHeaderHeight * scale - AppTheme.BorderWidth.thin
            VStack(spacing: AppTheme.Spacing.none) {
                Color.clear.frame(height: AppTheme.Layout.titleBarChromeHeight + AppTheme.Layout.workspaceHeaderHeight * scale)
                AppDivider()
                VStack(spacing: AppTheme.Spacing.md) {
                    Picker("Storyboard view", selection: .constant(false)) {
                        Text("Board").tag(false)
                        Text("Animatic").tag(true)
                    }.pickerStyle(.segmented).padding(.horizontal, AppTheme.Spacing.lg)
                    HStack(spacing: AppTheme.Spacing.md) {
                        Button("Undo") {}
                        Button("Redo") {}
                        Spacer(minLength: AppTheme.Spacing.sm)
                    }.buttonStyle(InlineActionButtonStyle()).padding(.horizontal, AppTheme.Spacing.lg)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            Text("Summary")
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                                Text("Shot 1")
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                    Text("Moment 1")
                                    StoryboardSketchThumbnail(image: image, intent: "Moment") {}
                                        .background(StoryboardGeometryProbe(name: "storyboard.sketch.inspect"))
                                    Text("Moment")
                                }
                            }
                            .padding(AppTheme.Spacing.lg)
                        }.padding(AppTheme.Spacing.lg)
                    }
                }
                .padding(.top, AppTheme.Spacing.md)
                .interfaceFont(size: AppTheme.Typography.ui)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                AppDivider()
                Color.clear.frame(height: content * AppTheme.Layout.productionDockMaximumFraction)
            }
        }
    }
}

private struct StoryboardGeometryProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
