import Foundation

enum InspectorKeyframeTarget: Hashable {
    case clip(AnimatableProperty)
    case effect(type: String, key: String)

    var identifier: String {
        switch self {
        case .clip(let property): property.rawValue
        case .effect(let type, let key): "effect." + type + "." + key
        }
    }

    var label: String {
        switch self {
        case .clip(let property): property.displayName
        case .effect(let type, let key):
            let descriptor = EffectRegistry.descriptor(id: type)
            let parameter = descriptor?.params.first(where: { $0.key == key })?.label ?? key
            let suffix = type == "color.wheels" ? (key.hasSuffix("_x") ? " X" : key.hasSuffix("_y") ? " Y" : " Level") : ""
            return (descriptor?.displayName ?? type) + " · " + parameter + suffix
        }
    }

    func frames(in clip: Clip) -> [Int] {
        switch self {
        case .clip(let property): clip.keyframeFrames(for: property)
        case .effect(let type, let key):
            clip.effects?.first(where: { $0.type == type })?.params[key]?.track?.keyframes.map { clip.startFrame + $0.frame } ?? []
        }
    }

    func interpolation(in clip: Clip, at frame: Int) -> Interpolation? {
        switch self {
        case .clip(let property): clip.interpolation(for: property, atFrame: frame)
        case .effect(let type, let key):
            clip.effects?.first(where: { $0.type == type })?.params[key]?.track?.keyframes
                .first(where: { $0.frame == frame - clip.startFrame })?.interpolationOut
        }
    }

    @MainActor
    func move(clipID: String, from: Int, to: Int, editor: EditorViewModel) {
        switch self {
        case .clip(let property): editor.applyMoveKeyframe(clipId: clipID, property: property, fromFrame: from, toFrame: to)
        case .effect(let type, let key):
            editor.applyClipProperty(clipId: clipID) { clip in
                guard (clip.startFrame...clip.endFrame).contains(to),
                      let index = clip.effects?.firstIndex(where: { $0.type == type }) else { return }
                clip.effects?[index].params[key]?.track?.move(from: from - clip.startFrame, to: to - clip.startFrame)
            }
        }
    }

    @MainActor
    func setInterpolation(_ interpolation: Interpolation, clipID: String, frame: Int, editor: EditorViewModel) {
        switch self {
        case .clip(let property): editor.setInterpolation(clipId: clipID, property: property, frame: frame, interpolation: interpolation)
        case .effect(let type, let key):
            editor.commitClipProperty(clipId: clipID) { clip in
                ClipEffectAnimation.edit(.interpolate(interpolation), type: type, key: key, frame: frame, clip: &clip)
            }
            editor.undoManager?.setActionName("Change Effect Interpolation")
        }
    }

    @MainActor
    func remove(clipID: String, frame: Int, editor: EditorViewModel) {
        switch self {
        case .clip(let property): editor.removeKeyframe(clipId: clipID, property: property, at: frame)
        case .effect(let type, let key):
            editor.commitClipProperty(clipId: clipID) { clip in
                ClipEffectAnimation.edit(.remove, type: type, key: key, frame: frame, clip: &clip)
            }
            editor.undoManager?.setActionName("Remove Effect Keyframe")
        }
    }

    @MainActor
    func clear(clipID: String, editor: EditorViewModel) {
        switch self {
        case .clip(let property): editor.clearAnimation(clipId: clipID, property: property)
        case .effect(let type, let key): editor.editEffectKeyframe(clipID: clipID, type: type, key: key, action: .clear)
        }
    }
}
