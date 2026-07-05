import Foundation

/// Generates music from music tab and places it on the timeline
struct MusicGenerationSubmission {
    enum Mode { case videoToMusic, textToMusic }

    let mode: Mode
    let model: AudioModelConfig
    let prompt: String?
    let source: EditorViewModel.TimelineSpan
    let spanSeconds: Double
    let name: String?

    enum Phase {
        case exporting, uploading, generating

        var label: String {
            switch self {
            case .exporting: "Exporting..."
            case .uploading: "Uploading…"
            case .generating: "Generating..."
            }
        }
    }

    @MainActor
    func run(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        onPhase: @MainActor (Phase) -> Void = { _ in },
        onFinished: @escaping @MainActor () -> Void = {},
        onSucceeded: @escaping @MainActor () -> Void = {}
    ) async throws {
        let videoURL: String? = nil
        if mode == .videoToMusic {
            onPhase(.exporting)
            let mp4 = try await TimelineRenderer.render(
                timeline: editor.timeline,
                resolver: editor.mediaResolver,
                startFrame: source.startFrame,
                frameCount: source.frameCount,
                shortSide: 360,
                includeAudio: false
            )
            try? FileManager.default.removeItem(at: mp4)
            onPhase(.uploading)
            throw GenerationBackendError.notConfigured
        }

        let durationSeconds = max(1, Int(spanSeconds.rounded()))
        let params = AudioGenerationParams(
            prompt: prompt ?? "",
            voice: nil,
            lyrics: nil,
            styleInstructions: nil,
            instrumental: false,
            durationSeconds: durationSeconds,
            videoURL: videoURL
        )

        var genInput = GenerationInput(
            prompt: prompt ?? "",
            model: model.id,
            duration: durationSeconds,
            aspectRatio: ""
        )
        genInput.createdAt = Date()

        onPhase(.generating)
        let startFrame = source.startFrame
        let placeholderId = AudioGenerationSubmission.make(
            genInput: genInput, model: model, params: params, name: name ?? model.displayName
        ).submit(
            service: service,
            projectURL: projectURL,
            editor: editor,
            onComplete: { asset in
                editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                onSucceeded()
                onFinished()
            },
            onFailure: { onFinished() }
        )
        editor.placeGeneratingAudioClip(
            placeholderId: placeholderId, startFrame: startFrame, spanSeconds: spanSeconds,
            actionName: "Add Music"
        )
        // Reveal where it landed — audio tracks sit below the fold, so the placeholder is easy to miss.
        editor.selectedClipIds = [placeholderId]
    }
}
