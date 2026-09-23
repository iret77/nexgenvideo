import AppKit
import SwiftUI
import Testing
@testable import NexGenVideo

@Suite("Inspector form geometry", .serialized)
@MainActor
struct InspectorFormLayoutTests {
    @Test func adaptiveKeyframeContentKeepsRealControlsInsideRows() throws {
        for totalWidth: CGFloat in [AppTheme.Layout.inspectorMin, 184, 260, 360, 800] {
            for scale in [1.0, 1.3, 1.5] {
                for keyframesPanelVisible in [false, true] {
                    let fixture = InspectorAxisFixture(keyframesPanelVisible: keyframesPanelVisible)
                        .environment(\.interfaceScale, scale)
                        .padding(AppTheme.Spacing.lg)
                        .frame(width: totalWidth)
                    let host = NSHostingView(rootView: fixture)
                    host.setFrameSize(.init(width: totalWidth, height: AppTheme.Window.projectMin.height))
                    host.layoutSubtreeIfNeeded()
                    _ = host.fittingSize
                    host.layoutSubtreeIfNeeded()

                    let controls = try frames(
                        ["position-control", "volume-value", "fade-value", "crop-control", "flip-control"],
                        in: host
                    )
                    let rows = try frames(
                        ["position-row", "volume-row", "fade-row", "crop-row", "flip-row"],
                        in: host
                    )
                    for (control, row) in zip(controls, rows) {
                        #expect(isContained(control, in: row))
                        #expect(control.minX >= row.minX - 1)
                        #expect(control.maxX <= row.maxX + 1)
                    }
                    for name in ["position-x", "position-y"] {
                        let field = try frame(name, in: host)
                        #expect(isContained(field, in: rows[0]))
                    }
                    for name in ["crop-toggle", "crop-menu", "crop-keyframe"] {
                        let control = try frame(name, in: host)
                        #expect(isContained(control, in: rows[3]))
                    }
                    let volumeKeyframe = try frame("volume-keyframe", in: host)
                    let positionKeyframe = try frame("position-keyframe", in: host)
                    let cropKeyframe = try frame("crop-keyframe", in: host)
                    #expect(isContained(volumeKeyframe, in: rows[1]))
                    #expect(isContained(positionKeyframe, in: rows[0]))

                    let expectedAxis = controls[0].maxX
                    for control in controls.dropFirst() {
                        #expect(abs(control.maxX - expectedAxis) < 1)
                    }
                    let accessories = [positionKeyframe, volumeKeyframe, cropKeyframe]
                    let expectedAccessoryAxis = accessories[0].maxX
                    for accessory in accessories.dropFirst() {
                        #expect(abs(accessory.maxX - expectedAccessoryAxis) < 1)
                    }
                    for (control, accessory) in zip(
                        [controls[0], controls[1], controls[3]],
                        accessories
                    ) {
                        let horizontallySeparated = accessory.minX
                            >= control.maxX + AppTheme.Spacing.sm - 1
                        let verticallySeparated = accessory.minY
                            >= control.maxY + AppTheme.Spacing.sm - 1
                        #expect(horizontallySeparated || verticallySeparated)
                    }

                    if keyframesPanelVisible {
                        let controlsPane = try frame("controls-pane", in: host)
                        let keyframesPane = try frame("keyframes-pane", in: host)
                        if totalWidth == 800 {
                            #expect(controlsPane.maxX < keyframesPane.minX)
                        } else {
                            #expect(controlsPane.maxY < keyframesPane.minY)
                        }
                    } else {
                        #expect(find("keyframes-pane", in: host) == nil)
                    }
                }
            }
        }
    }

    @Test func everyCropAspectLabelFitsAtMinimumWidthAndLargestScale() throws {
        for aspect in CropAspectLock.allCases {
            let totalWidth = AppTheme.Layout.inspectorMin
            let fixture = InspectorAxisFixture(
                keyframesPanelVisible: true,
                cropAspect: aspect
            )
            .environment(\.interfaceScale, 1.5)
            .padding(AppTheme.Spacing.lg)
            .frame(width: totalWidth)
            let host = NSHostingView(rootView: fixture)
            host.setFrameSize(.init(width: totalWidth, height: AppTheme.Window.projectMin.height))
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            host.layoutSubtreeIfNeeded()

            let label = try frame("crop-menu-label", in: host)
            let menu = try frame("crop-menu", in: host)
            let control = try frame("crop-control", in: host)
            let row = try frame("crop-row", in: host)
            #expect(label.width > 0)
            #expect(label.height > 0)
            #expect(isContained(label, in: menu))
            #expect(isContained(menu, in: control))
            #expect(isContained(control, in: row))
        }
    }

    @Test func realAudioAndVideoPanelsExposeVisibleNamedAlignedLanes() throws {
        let video = Fixtures.clip(id: "video", mediaType: .video, start: 0, duration: 90)
        let audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 90)
        for (clip, properties) in [
            (video, [AnimatableProperty.position, .scale, .rotation, .opacity, .crop]),
            (audio, [AnimatableProperty.volume]),
        ] {
            let editor = EditorViewModel()
            let track = clip.mediaType == .audio
                ? Fixtures.audioTrack(clips: [clip])
                : Fixtures.videoTrack(clips: [clip])
            editor.timeline = Fixtures.timeline(tracks: [track])
            let panelWidth = AppTheme.Layout.inspectorDefault - AppTheme.Spacing.lg * 2
            let fixture = KeyframesPanel(clip: clip)
                .environment(editor)
                .environment(\.interfaceScale, 1.5)
                .frame(width: panelWidth)
                .background(InspectorGeometryProbe(name: "keyframes-panel"))
            let host = NSHostingView(rootView: fixture)
            host.setFrameSize(.init(width: panelWidth, height: AppTheme.Window.projectMin.height))
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            host.layoutSubtreeIfNeeded()

            let panel = try frame("keyframes-panel", in: host)
            let ruler = try frame("inspector.keyframes.ruler", in: host)
            #expect(isContained(ruler, in: panel))
            for property in properties {
                let label = try frame(
                    "inspector.keyframes.lane.\(property.rawValue).label",
                    in: host
                )
                let track = try frame(
                    "inspector.keyframes.lane.\(property.rawValue).track",
                    in: host
                )
                #expect(label.width > 0)
                #expect(label.height > 0)
                #expect(isContained(label, in: panel))
                #expect(isContained(track, in: panel))
                #expect(label.maxX + AppTheme.Spacing.sm <= track.minX + 1)
                #expect(abs(track.minX - ruler.minX) < 1)
                #expect(abs(track.maxX - ruler.maxX) < 1)
            }
        }
    }

    @Test func selectionAndTextRowsDoNotReserveAnEmptyAccessorySlot() throws {
        for totalWidth: CGFloat in [AppTheme.Layout.inspectorMin, 184, 260, 360] {
            for scale in [1.0, 1.3, 1.5] {
                let fixture = InspectorRowsWithoutAccessories()
                    .environment(\.interfaceScale, scale)
                    .padding(AppTheme.Spacing.lg)
                    .frame(width: totalWidth)
                let host = NSHostingView(rootView: fixture)
                host.setFrameSize(.init(width: totalWidth, height: AppTheme.Window.projectMin.height))
                host.layoutSubtreeIfNeeded()
                _ = host.fittingSize
                host.layoutSubtreeIfNeeded()

                for pair in [
                    ("mixed-value", "mixed-row"),
                    ("text-value", "text-row"),
                    ("caption-value", "caption-row"),
                ] {
                    let value = try frame(pair.0, in: host)
                    let row = try frame(pair.1, in: host)
                    #expect(isContained(value, in: row))
                    #expect(abs(value.maxX - row.maxX) < 1)
                }
            }
        }
    }

    private func frames<Content: View>(_ names: [String], in host: NSHostingView<Content>) throws -> [CGRect] {
        try names.map { try frame($0, in: host) }
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
    let keyframesPanelVisible: Bool
    var cropAspect: CropAspectLock = .original

    var body: some View {
        InspectorKeyframesContent(isPresented: keyframesPanelVisible) {
            rows
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(InspectorGeometryProbe(name: "controls-pane"))
        } keyframes: {
            AppTheme.Background.clearColor
                .frame(
                    minHeight: AppTheme.Timeline.keyframeHeaderHeight
                        + AppTheme.Timeline.keyframeRowHeight * 5
                )
                .background(InspectorGeometryProbe(name: "keyframes-pane"))
        }
        .inspectorKeyframeAccessoryColumn(true)
    }

    private var rows: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            InspectorAnimatableFormRow(label: "Position", showsAccessory: true) {
                InspectorPositionFieldsLayout {
                    positionField(axis: "X")
                        .background(InspectorGeometryProbe(name: "position-x"))
                } yField: {
                    positionField(axis: "Y")
                        .background(InspectorGeometryProbe(name: "position-y"))
                }
                .background(InspectorGeometryProbe(name: "position-control"))
            } accessory: {
                keyframeControls(name: "position-keyframe")
            }
            .background(InspectorGeometryProbe(name: "position-row"))

            InspectorAnimatableFormRow(label: "Volume", showsAccessory: true) {
                numberField(value: -12, suffix: " dB")
                    .background(InspectorGeometryProbe(name: "volume-value"))
            } accessory: {
                keyframeControls(name: "volume-keyframe")
            }
            .background(InspectorGeometryProbe(name: "volume-row"))

            InspectorFormRow(label: "Fade Out") {
                numberField(value: 0.25, suffix: " s")
                    .background(InspectorGeometryProbe(name: "fade-value"))
            }
            .background(InspectorGeometryProbe(name: "fade-row"))

            InspectorAnimatableFormRow(label: "Crop", showsAccessory: true) {
                InspectorAdaptiveControlPair(spacing: AppTheme.Spacing.sm) {
                    toggleButton(systemName: "crop")
                        .background(InspectorGeometryProbe(name: "crop-toggle"))
                } second: {
                    Menu {
                        Button("Custom") {}
                    } label: {
                        InspectorCropAspectLabel(label: cropAspect.label)
                            .background(InspectorGeometryProbe(name: "crop-menu-label"))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .background(InspectorGeometryProbe(name: "crop-menu"))
                }
                .background(InspectorGeometryProbe(name: "crop-control"))
            } accessory: {
                keyframeControls(name: "crop-keyframe")
            }
            .background(InspectorGeometryProbe(name: "crop-row"))

            InspectorFormRow(label: "Flip") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    toggleButton(systemName: "arrow.left.and.right")
                    toggleButton(systemName: "arrow.up.and.down")
                }
                .background(InspectorGeometryProbe(name: "flip-control"))
            }
            .background(InspectorGeometryProbe(name: "flip-row"))
        }
    }

    private func numberField(value: Double?, suffix: String) -> some View {
        ScrubbableNumberField(
            value: value,
            range: -96...96,
            format: "%.2f",
            valueSuffix: suffix,
            accessibilityName: "Geometry value",
            fieldWidth: 56
        ) { _ in }
    }

    private func positionField(axis: String) -> some View {
        ScrubbableNumberField(
            value: 0.5,
            range: -10...10,
            accessibilityName: "Position \(axis)",
            fieldWidth: 36,
            trailingLabel: axis
        ) { _ in }
    }

    private func keyframeControls(name: String) -> some View {
        HStack(spacing: AppTheme.Spacing.none) {
            keyframeButton(systemName: "chevron.left", width: AppTheme.Timeline.keyframeNavigationButtonWidth)
            keyframeButton(systemName: "diamond", width: AppTheme.Timeline.keyframeStampButtonWidth)
                .background(InspectorGeometryProbe(name: name))
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

private struct InspectorRowsWithoutAccessories: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            InspectorAnimatableFormRow(label: "Opacity", showsAccessory: false) {
                ScrubbableNumberField(
                    value: nil,
                    range: 0...1,
                    accessibilityName: "Mixed opacity",
                    fieldWidth: 56
                ) { _ in }
                .background(InspectorGeometryProbe(name: "mixed-value"))
            } accessory: {
                EmptyView()
            }
            .background(InspectorGeometryProbe(name: "mixed-row"))

            InspectorFormRow(label: "Text") {
                Text("Title")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .background(InspectorGeometryProbe(name: "text-value"))
            }
            .background(InspectorGeometryProbe(name: "text-row"))

            InspectorFormRow(label: "Caption") {
                Text("Subtitle")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .background(InspectorGeometryProbe(name: "caption-value"))
            }
            .background(InspectorGeometryProbe(name: "caption-row"))
        }
        .inspectorKeyframeAccessoryColumn(false)
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
