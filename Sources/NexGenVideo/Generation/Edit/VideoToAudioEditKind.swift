import Foundation

enum VideoToAudioEditKind {
    case music
    case sfx

    var title: String {
        switch self {
        case .music: "Generate Music"
        case .sfx: "Generate SFX"
        }
    }

    var providerName: String {
        switch self {
        case .music: "Sonilo"
        case .sfx: "Mirelo"
        }
    }

    var action: EditAction {
        switch self {
        case .music: .generateMusic
        case .sfx: .generateSFX
        }
    }

    var iconName: String {
        switch self {
        case .music: "music.note"
        case .sfx: "waveform"
        }
    }

    var description: String {
        switch self {
        case .music: "Generate music that fits the video"
        case .sfx: "Create matching sound for the video"
        }
    }

    var timelineActionName: String {
        switch self {
        case .music: "Add Music"
        case .sfx: "Add Sound Effects"
        }
    }

    var preferredModelId: String {
        switch self {
        case .music: "sonilo-v1.1-video-to-music"
        case .sfx: "mirelo-sfx-v1.5-video-to-audio"
        }
    }

    var category: AudioModelConfig.Category {
        switch self {
        case .music: .music
        case .sfx: .sfx
        }
    }

    @MainActor
    var model: AudioModelConfig? { model(spanSeconds: nil) }

    @MainActor
    func model(spanSeconds: Double?) -> AudioModelConfig? {
        select(in: AudioModelConfig.allModels, spanSeconds: spanSeconds,
            isEnabled: ModelPreferences.shared.isEnabled, canRun: { GenerationProvider.canRun(modelId: $0) })
    }

    func select(in models: [AudioModelConfig], spanSeconds: Double?,
                isEnabled: (String) -> Bool, canRun: (String) -> Bool) -> AudioModelConfig? {
        let available = models.filter { model in
            model.category == category && model.inputs.contains(.video) && isEnabled(model.id) && canRun(model.id)
                && (spanSeconds.map { $0.isFinite && $0 > 0 && model.validate(spanSeconds: $0) == nil } ?? true)
        }
        return available.first { $0.id == preferredModelId } ?? available.first
    }
}
