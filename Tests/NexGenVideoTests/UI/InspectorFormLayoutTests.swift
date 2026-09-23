import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Inspector form geometry", .serialized)
@MainActor
struct InspectorFormLayoutTests {
    @Test func fieldsAndTogglesKeepOneAxisWithKeyframeAccessories() throws {
        for width: CGFloat in [184, 260, 360] {
            for scale in [1.0, 1.3, 1.5] {
                for keyframesPanelVisible in [false, true] {
                    let fixture = InspectorAxisFixture(
                        rowWidth: width,
                        keyframesPanelVisible: keyframesPanelVisible
                    )
                    .environment(\.interfaceScale, scale)
                    let host = NSHostingView(rootView: fixture)
                    let hostWidth = keyframesPanelVisible
                        ? width * 2 + AppTheme.BorderWidth.thin
                        : width
                    host.setFrameSize(.init(width: hostWidth, height: AppTheme.Window.projectMin.height))
                    host.layoutSubtreeIfNeeded()
                    _ = host.fittingSize
                    host.layoutSubtreeIfNeeded()

                    let animated = try frame("animatable-value", in: host)
                    let plain = try frame("plain-value", in: host)
                    let toggle = try frame("plain-toggle", in: host)
                    let keyframe = try frame("keyframe-toggle", in: host)
                    let animatedRow = try frame("animatable-row", in: host)
                    let plainRow = try frame("plain-row", in: host)
                    let toggleRow = try frame("toggle-row", in: host)
                    let expectedAxis = animatedRow.maxX
                        - AppTheme.Timeline.keyframeControlsColumnWidth
                        - AppTheme.Spacing.sm

                    #expect(abs(animated.maxX - plain.maxX) < 1)
                    #expect(abs(animated.maxX - toggle.maxX) < 1)
                    #expect(abs(animated.maxX - expectedAxis) < 1)
                    #expect(keyframe.minX >= animated.maxX + AppTheme.Spacing.sm - 1)
                    #expect(isContained(animated, in: animatedRow))
                    #expect(isContained(plain, in: plainRow))
                    #expect(isContained(toggle, in: toggleRow))
                    #expect(animatedRow.width <= width + 1)
                    #expect(plainRow.width <= width + 1)
                    #expect(toggleRow.width <= width + 1)
                }
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

    private func isContained(_ child: CGRect, in parent: CGRect) -> Bool {
        parent.insetBy(dx: -1, dy: -1).contains(child)
    }
}

private struct InspectorAxisFixture: View {
    let rowWidth: CGFloat
    let keyframesPanelVisible: Bool

    var body: some View {
        Group {
            if keyframesPanelVisible {
                HStack(alignment: .top, spacing: AppTheme.Spacing.none) {
                    rows.frame(width: rowWidth)
                    AppDivider()
                    AppTheme.Background.clearColor.frame(width: rowWidth)
                }
            } else {
                rows.frame(width: rowWidth)
            }
        }
        .inspectorKeyframeAccessoryColumn(true)
    }

    private var rows: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            InspectorAnimatableFormRow(label: "Volume", showsAccessory: true) {
                numberField(value: -12, suffix: " dB")
                    .background(InspectorGeometryProbe(name: "animatable-value"))
            } accessory: {
                keyframeControls
            }
            .background(InspectorGeometryProbe(name: "animatable-row"))

            InspectorFormRow(label: "Fade Out") {
                numberField(value: 0.25, suffix: " s")
                    .background(InspectorGeometryProbe(name: "plain-value"))
            }
            .background(InspectorGeometryProbe(name: "plain-row"))

            InspectorFormRow(label: "Flip") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    toggleButton(systemName: "arrow.left.and.right")
                    toggleButton(systemName: "arrow.up.and.down")
                }
                .background(InspectorGeometryProbe(name: "plain-toggle"))
            }
            .background(InspectorGeometryProbe(name: "toggle-row"))
        }
    }

    private func numberField(value: Double, suffix: String) -> some View {
        ScrubbableNumberField(
            value: value,
            range: -96...96,
            format: "%.2f",
            valueSuffix: suffix,
            accessibilityName: "Geometry value",
            fieldWidth: 56
        ) { _ in }
    }

    private var keyframeControls: some View {
        HStack(spacing: AppTheme.Spacing.none) {
            keyframeButton(systemName: "chevron.left", width: AppTheme.Timeline.keyframeNavigationButtonWidth)
            keyframeButton(systemName: "diamond", width: AppTheme.Timeline.keyframeStampButtonWidth)
                .background(InspectorGeometryProbe(name: "keyframe-toggle"))
            keyframeButton(systemName: "chevron.right", width: AppTheme.Timeline.keyframeNavigationButtonWidth)
        }
    }

    private func keyframeButton(systemName: String, width: CGFloat) -> some View {
        Button {} label: {
            Image(systemName: systemName)
                .frame(width: width, height: AppTheme.Timeline.keyframeRulerHeight)
        }
        .buttonStyle(.plain)
    }

    private func toggleButton(systemName: String) -> some View {
        Button {} label: {
            Image(systemName: systemName)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
        }
        .buttonStyle(.plain)
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
