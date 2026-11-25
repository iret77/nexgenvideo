import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Spatial shot state geometry", .serialized)
@MainActor
struct SpatialShotStateLayoutTests {
    @Test func posePreviewFitsTheSheetScrollViewport() throws {
        let size = NSSize(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        for scale in [AppTheme.Typography.standardScale, AppTheme.Typography.largeScale, AppTheme.Typography.largestScale] {
            for camera in [(1920, 1080), (1080, 1920), (2048, 858), (1024, 1024)] {
                let aspect = CGFloat(camera.0) / CGFloat(camera.1)
                let host = NSHostingView(rootView: SpatialShotStateFixture(aspect: aspect)
                    .environment(\.interfaceScale, scale))
                host.setFrameSize(size)
                host.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()

                let preview = try #require(find("shot-planning.spatial.preview", in: host))
                let scroll = try #require(enclosingScroll(of: preview))
                let clip = scroll.contentView
                let frame = preview.convert(preview.bounds, to: clip)
                let context = "scale=\(scale), camera=\(camera), preview=\(frame), clip=\(clip.bounds)"
                #expect(frame.height > 0 && frame.width > 0, "\(context)")
                #expect(frame.height <= clip.bounds.height, "\(context)")
                #expect(frame.width <= clip.bounds.width, "\(context)")
                #expect(frame.height <= AppTheme.Layout.spatialPosePreviewMaxHeight + 1, "\(context)")
                #expect(abs(frame.width / frame.height - aspect) < 0.02, "\(context)")
            }
        }
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

private struct SpatialShotStateFixture: View {
    let aspect: CGFloat

    var body: some View {
        SpatialShotStateLayout(number: 1) {
            Picker("Location", selection: .constant(0)) { Text("Stage").tag(0) }
            Picker("Camera", selection: .constant(0)) { Text("Camera").tag(0) }
            Color.clear.spatialPosePreviewFrame(aspect: aspect)
                .background(SpatialGeometryProbe(name: "shot-planning.spatial.preview"))
            Stepper("Frame 1 of 48", value: .constant(0), in: 0...47)
            Text("2 keyframes · 1, 48")
        } actions: {
            Button("Cancel") {}.buttonStyle(InlineActionButtonStyle())
            Spacer()
            Button("Confirm shot state") {}.buttonStyle(.capsule(.prominent, size: .regular))
        }
    }
}

private struct SpatialGeometryProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
