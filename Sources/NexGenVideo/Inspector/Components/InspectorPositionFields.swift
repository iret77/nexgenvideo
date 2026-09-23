import SwiftUI

struct InspectorPositionFields: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)
        let frame = editor.activeFrame
        let xShared = sharedClipValue(clips) { $0.topLeftAt(frame: frame).x }
        let yShared = sharedClipValue(clips) { $0.topLeftAt(frame: frame).y }

        InspectorPositionFieldsLayout {
            positionField(axis: .x, value: xShared, displayMultiplier: canvasW)
        } yField: {
            positionField(axis: .y, value: yShared, displayMultiplier: canvasH)
        }
    }

    private enum Axis: String {
        case x = "X"
        case y = "Y"
    }

    private func positionField(axis: Axis, value: Double?, displayMultiplier: Double) -> some View {
        ScrubbableNumberField(
            value: value,
            range: -10...10,
            displayMultiplier: displayMultiplier,
            format: "%.0f",
            accessibilityName: "Position \(axis.rawValue)",
            fieldWidth: 36,
            trailingLabel: axis.rawValue,
            onChanged: { newValue in
                apply(
                    setX: axis == .x ? newValue : nil,
                    setY: axis == .y ? newValue : nil
                )
            }
        ) { newValue in
            commit(
                setX: axis == .x ? newValue : nil,
                setY: axis == .y ? newValue : nil
            )
        }
    }

    private func apply(setX: Double?, setY: Double?) {
        for c in clips { editor.applyPosition(clipId: c.id, setX: setX, setY: setY) }
    }

    private func commit(setX: Double?, setY: Double?) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips { editor.commitPosition(clipId: c.id, setX: setX, setY: setY) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Change Position")
    }
}

struct InspectorPositionFieldsLayout<XField: View, YField: View>: View {
    @ViewBuilder let xField: () -> XField
    @ViewBuilder let yField: () -> YField

    init(
        @ViewBuilder xField: @escaping () -> XField,
        @ViewBuilder yField: @escaping () -> YField
    ) {
        self.xField = xField
        self.yField = yField
    }

    var body: some View {
        InspectorAdaptiveControlPair(spacing: AppTheme.Spacing.xs) {
            xField()
        } second: {
            yField()
        }
    }
}
