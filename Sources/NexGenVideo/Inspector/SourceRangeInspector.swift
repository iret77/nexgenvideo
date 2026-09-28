import SwiftUI

struct SourceRangeInspector: View {
    @Environment(EditorViewModel.self) private var editor
    let asset: MediaAsset

    var body: some View {
        InspectorSection("Source") {
            if let range = editor.sourceFrameRange(for: asset) {
                InspectorFormRow(label: "In") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        timecode(range.lowerBound)
                        Button("Mark In") { editor.markSourceIn(asset) }
                            .buttonStyle(.inlineAction())
                    }
                }
                InspectorFormRow(label: "Out", labelHelp: "The out point is the first frame excluded from the edit.") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        timecode(range.upperBound)
                        Button("Mark Out") { editor.markSourceOut(asset) }
                            .buttonStyle(.inlineAction())
                    }
                }
                InspectorFormRow(label: "Duration") {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        timecode(range.count)
                        Button("Clear Range") { editor.clearSourceRange(asset) }
                            .buttonStyle(.inlineAction())
                            .disabled(editor.sourcePreviewStates[asset.id]?.inSeconds == nil
                                      && editor.sourcePreviewStates[asset.id]?.outSeconds == nil)
                    }
                }
            }
            InspectorFormRow(label: "Target") {
                Picker("Target Track", selection: Binding(
                    get: { editor.sourcePreviewStates[asset.id]?.targetTrackID ?? "" },
                    set: { editor.sourcePreviewStates[asset.id, default: SourcePreviewState()].targetTrackID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("New Track").tag("")
                    ForEach(Array(editor.timeline.tracks.enumerated()), id: \.element.id) { index, track in
                        if track.type.isCompatible(with: asset.type) {
                            Text(editor.timelineTrackDisplayLabel(at: index)).tag(track.id)
                        }
                    }
                    if let target = editor.sourcePreviewStates[asset.id]?.targetTrackID,
                       !editor.timeline.tracks.contains(where: { $0.id == target && $0.type.isCompatible(with: asset.type) }) {
                        Text("Unavailable Track").tag(target)
                    }
                }
                .labelsHidden()
            }
            HStack(spacing: AppTheme.Spacing.md) {
                Button("Insert") { place(.insert) }
                    .buttonStyle(.inlineAction(.pack))
                Button("Overwrite") { place(.overwrite) }
                    .buttonStyle(.inlineAction(.pack))
            }
            .disabled(editor.sourceEditUnavailableReason(for: asset) != nil)
            if let reason = editor.sourceEditUnavailableReason(for: asset) {
                Text(reason)
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func timecode(_ frame: Int) -> some View {
        Text(formatTimecode(frame: frame, fps: editor.timeline.fps))
            .interfaceFont(size: AppTheme.Typography.ui)
            .monospacedDigit()
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }

    private func place(_ operation: EditorViewModel.SourceEditOperation) {
        editor.addClipsWithSettingsCheck(assets: [asset]) {
            editor.editSource(asset, operation: operation)
        }
    }
}
