import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Settings row geometry", .serialized)
@MainActor
struct SettingsRowLayoutTests {
    @Test func descriptionsWrapWithoutMovingSwitchesBelowTheirLabels() throws {
        for width: CGFloat in [492, 712, 1000] {
            for scale in [1.0, 1.25, 1.5] {
                let host = NSHostingView(rootView: VStack(spacing: 14) {
                    fixture(id: "short", subtitle: "Notify when generations finish.")
                    fixture(id: "long", subtitle: "Sends technical diagnostics and coarse project statistics to Sentry. Media files are never attached.")
                }.environment(\.interfaceScale, scale).frame(width: width))
                host.setFrameSize(.init(width: width, height: 400))
                host.layoutSubtreeIfNeeded()
                _ = host.fittingSize
                host.layoutSubtreeIfNeeded()
                var rightEdges: [CGFloat] = []
                for id in ["short", "long"] {
                    let row = try #require(find("row-\(id)", in: host))
                    let control = try #require(find("control-\(id)", in: host))
                    let rowFrame = row.convert(row.bounds, to: host)
                    let controlFrame = control.convert(control.bounds, to: host)
                    #expect(abs(controlFrame.maxX - (rowFrame.maxX - AppTheme.Spacing.lgXl)) < 1)
                    #expect(abs(controlFrame.minY - (rowFrame.minY + AppTheme.Spacing.lgXl)) < 1)
                    rightEdges.append(controlFrame.maxX)
                }
                #expect(abs(rightEdges[0] - rightEdges[1]) < 1)
                let size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                #expect(size == host.fittingSize)
            }
        }
    }

    @Test func emptyAccessoriesStillRenderTheirText() {
        let host = NSHostingView(rootView: SettingsRow(title: "No matching models") {
            EmptyView()
        }.frame(width: 492))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > AppTheme.Spacing.lgXl * 2)
    }

    private func fixture(id: String, subtitle: String) -> some View {
        SettingsRow(title: "Setting", subtitle: subtitle) {
            Toggle("Setting", isOn: .constant(true)).labelsHidden().toggleStyle(.switch)
                .controlSize(.small)
                .background(SettingsGeometryProbe(name: "control-\(id)"))
        }.background(SettingsGeometryProbe(name: "row-\(id)"))
    }

    private func find(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        return view.subviews.lazy.compactMap { find(name, in: $0) }.first
    }
}

private struct SettingsGeometryProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
