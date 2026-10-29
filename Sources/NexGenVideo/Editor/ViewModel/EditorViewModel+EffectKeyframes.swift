import Foundation

extension EditorViewModel {
    func setEffectParameter(clipIDs: [String], type: String, key: String, value: Double, commit: Bool, action: String) {
        setEffectParameters(clipIDs: clipIDs, type: type, values: [key: value], commit: commit, action: action)
    }

    func setEffectParameters(clipIDs: [String], type: String, values: [String: Double], commit: Bool, action: String) {
        let frame = activeFrame
        let mutate: (inout Clip) -> Void = { clip in
            ClipEffectAnimation.setValues(values, type: type, frame: frame, clip: &clip)
        }
        if commit {
            undoManager?.beginUndoGrouping()
            commitClipProperties(clipIds: clipIDs, mutate)
            undoManager?.endUndoGrouping()
            undoManager?.setActionName(action)
        } else {
            applyClipProperties(clipIds: clipIDs, mutate)
        }
    }

    func editEffectKeyframe(clipID: String, type: String, key: String, action: ClipEffectAnimation.Action) {
        let frame = activeFrame
        commitClipProperty(clipId: clipID) { clip in
            ClipEffectAnimation.edit(action, type: type, key: key, frame: frame, clip: &clip)
        }
        undoManager?.setActionName(action.name)
    }
}

enum ClipEffectAnimation {
    enum Action {
        case stamp, remove, clear
        case interpolate(Interpolation)

        var name: String {
            switch self {
            case .stamp: "Add Effect Keyframe"
            case .remove: "Remove Effect Keyframe"
            case .clear: "Clear Effect Animation"
            case .interpolate: "Change Effect Interpolation"
            }
        }
    }

    static func setValue(_ value: Double, type: String, key: String, frame: Int, clip: inout Clip) {
        setValues([key: value], type: type, frame: frame, clip: &clip)
    }

    static func setValues(_ values: [String: Double], type: String, frame: Int, clip: inout Clip) {
        guard !values.isEmpty, let descriptor = EffectRegistry.descriptor(id: type),
              values.allSatisfy({ key, value in value.isFinite && descriptor.params.contains(where: { $0.key == key }) }) else { return }
        var effects = clip.effects ?? []
        guard let index = ensureEffect(type: type, effects: &effects),
              clip.contains(timelineFrame: frame) || values.keys.allSatisfy({ effects[index].params[$0]?.track?.isActive != true }) else { return }
        for (key, raw) in values {
            guard let spec = descriptor.params.first(where: { $0.key == key }) else { return }
            let value = min(spec.range.upperBound, max(spec.range.lowerBound, raw))
            var parameter = effects[index].params[key] ?? EffectParam(value: spec.defaultValue)
            if var track = parameter.track, track.isActive {
                let offset = frame - clip.startFrame
                let interpolation = track.keyframes.first(where: { $0.frame == offset })?.interpolationOut ?? .smooth
                track.upsert(.init(frame: offset, value: value, interpolationOut: interpolation))
                parameter.track = track
            } else { parameter.value = value }
            effects[index].params[key] = parameter
        }
        pruneNeutral(type: type, effects: &effects)
        clip.effects = effects.isEmpty ? nil : effects
    }

    static func edit(_ action: Action, type: String, key: String, frame: Int, clip: inout Clip) {
        let allowed: Bool
        switch action {
        case .stamp: allowed = clip.contains(timelineFrame: frame)
        case .remove, .interpolate: allowed = (clip.startFrame...clip.endFrame).contains(frame)
        case .clear: allowed = true
        }
        guard allowed, let spec = EffectRegistry.descriptor(id: type)?.params.first(where: { $0.key == key }) else { return }
        var effects = clip.effects ?? []
        guard let index = ensureEffect(type: type, effects: &effects) else { return }
        let offset = frame - clip.startFrame
        var parameter = effects[index].params[key] ?? EffectParam(value: spec.defaultValue)
        var track = parameter.track ?? KeyframeTrack<Double>()
        let displayed = parameter.resolved(at: offset, default: spec.defaultValue)
        switch action {
        case .stamp:
            guard !track.keyframes.contains(where: { $0.frame == offset }) else { return }
            track.upsert(.init(frame: offset, value: displayed))
        case .remove:
            guard track.keyframes.contains(where: { $0.frame == offset }) else { return }
            track.remove(at: offset)
            if !track.isActive { parameter.value = displayed }
        case .clear:
            guard track.isActive else { return }
            track = KeyframeTrack<Double>()
            parameter.value = displayed
        case .interpolate(let interpolation):
            guard let keyframe = track.keyframes.firstIndex(where: { $0.frame == offset }) else { return }
            track.keyframes[keyframe].interpolationOut = interpolation
        }
        parameter.track = track.isActive ? track : nil
        effects[index].params[key] = parameter
        pruneNeutral(type: type, effects: &effects)
        clip.effects = effects.isEmpty ? nil : effects
    }

    private static func ensureEffect(type: String, effects: inout [Effect]) -> Int? {
        if let index = effects.firstIndex(where: { $0.type == type }) { return index }
        guard let descriptor = EffectRegistry.descriptor(id: type) else { return nil }
        let index = EffectRegistry.insertIndex(effects, for: type)
        effects.insert(descriptor.makeEffect(), at: index)
        return index
    }

    private static func pruneNeutral(type: String, effects: inout [Effect]) {
        guard let descriptor = EffectRegistry.descriptor(id: type), let index = effects.firstIndex(where: { $0.type == type }) else { return }
        guard effects[index].enabled else { return }
        let parameters = effects[index].params
        guard !parameters.values.contains(where: { $0.track?.isActive == true || $0.string?.isEmpty == false }),
              descriptor.params.allSatisfy({ (parameters[$0.key]?.value ?? $0.defaultValue) == $0.defaultValue }) else { return }
        effects.remove(at: index)
    }
}
