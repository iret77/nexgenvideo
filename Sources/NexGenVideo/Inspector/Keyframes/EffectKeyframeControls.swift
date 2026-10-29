import SwiftUI

extension InspectorView {
    func effectKeyframeControls(_ control: EffectControl, clip: Clip, label: String) -> some View {
        let target = InspectorKeyframeTarget.effect(type: control.effectId, key: control.paramKey)
        let frame = editor.activeFrame
        let frames = target.frames(in: clip)
        let previous = frames.filter { $0 < frame }.max()
        let next = frames.filter { $0 > frame }.min()
        let stamped = frames.contains(frame)
        let inRange = clip.contains(timelineFrame: frame)
        let id = "editing.effect." + control.effectId + "." + control.paramKey
        return HStack(spacing: AppTheme.Spacing.none) {
            keyframeNavButton(systemName: "chevron.left", help: "Go to previous \(label) keyframe", enabled: previous != nil) {
                if let previous { editor.seekToFrame(previous) }
            }
            .reviewAcceptanceProbe(id + ".previous", state: previous != nil)
            Button {
                editor.editEffectKeyframe(clipID: clip.id, type: control.effectId, key: control.paramKey, action: stamped ? .remove : .stamp)
            } label: {
                Image(systemName: stamped ? "diamond.fill" : "diamond")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
            }
            .buttonStyle(ToolbarIconButtonStyle(isSelected: stamped))
            .disabled(!inRange)
            .accessibilityLabel((stamped ? "Remove " : "Add ") + label + " keyframe")
            .help(inRange ? (stamped ? "Remove keyframe at playhead" : "Add keyframe at playhead") : "Move playhead inside the clip")
            .reviewAcceptanceProbe(id + ".stamp", state: inRange)
            .contextMenu {
                ForEach(Interpolation.allCases, id: \.self) { interpolation in
                    Button(interpolation.rawValue.capitalized) {
                        target.setInterpolation(interpolation, clipID: clip.id, frame: frame, editor: editor)
                    }
                    .disabled(!stamped)
                }
                Divider() // app-theme: native-menu-divider
                Button("Clear Animation", role: .destructive) { target.clear(clipID: clip.id, editor: editor) }
                    .disabled(frames.isEmpty || !inRange)
            }
            keyframeNavButton(systemName: "chevron.right", help: "Go to next \(label) keyframe", enabled: next != nil) {
                if let next { editor.seekToFrame(next) }
            }
            .reviewAcceptanceProbe(id + ".next", state: next != nil)
        }
    }
}
