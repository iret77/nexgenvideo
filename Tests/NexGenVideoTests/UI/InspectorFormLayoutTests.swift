import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Inspector form geometry", .serialized)
@MainActor
struct InspectorFormLayoutTests {
    @Test func valuesKeepOneTrailingAxisAcrossWidthsAndTextScales() throws {
        for width: CGFloat in [184, 260, 360] {
            for scale in [1.0, 1.3] {
                let host = NSHostingView(rootView: VStack(spacing: AppTheme.Spacing.md) {
                    InspectorFormRow(label: "White Balance Temperature") {
                        Text("5600 K")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .background(InspectorGeometryProbe(name: "value-first"))
                    }
                    .background(InspectorGeometryProbe(name: "row-first"))
                    InspectorRow(icon: "speaker.wave.2", label: "Volume") {
                        Text("-12.0 dB")
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .background(InspectorGeometryProbe(name: "value-second"))
                    }
                    .background(InspectorGeometryProbe(name: "row-second"))
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .environment(\.interfaceScale, scale)
                .frame(width: width))
                host.setFrameSize(.init(width: width, height: 240))
                host.layoutSubtreeIfNeeded()
                _ = host.fittingSize
                host.layoutSubtreeIfNeeded()

                let first = try frame("value-first", in: host)
                let second = try frame("value-second", in: host)
                let firstRow = try frame("row-first", in: host)
                let secondRow = try frame("row-second", in: host)
                #expect(abs(first.maxX - second.maxX) < 1)
                #expect(first.minX >= firstRow.minX - 1)
                #expect(second.minX >= secondRow.minX - 1)
                #expect(first.maxX <= firstRow.maxX + 1)
                #expect(second.maxX <= secondRow.maxX + 1)
                #expect(firstRow.maxX <= width - AppTheme.Spacing.lg + 1)
                #expect(secondRow.maxX <= width - AppTheme.Spacing.lg + 1)
            }
        }
    }

    private func frame<Content: View>(_ name: String, in host: NSHostingView<Content>) throws -> CGRect {
        let view = try #require(find(name, in: host))
        return view.convert(view.bounds, to: host)
    }

    private func find(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        return view.subviews.lazy.compactMap { find(name, in: $0) }.first
    }
}

private struct InspectorGeometryProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
