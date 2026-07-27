import Foundation

/// Generates music from music tab and places it on the timeline
struct MusicGenerationSubmission {
    enum Mode { case videoToMusic, textToMusic }

    let mode: Mode
    let model: AudioModelConfig
    let prompt: String?
    /// Original pre-compile intent, stored on the asset so a rerun recompiles against the current
    /// ledger (#114).
    var intent: String? = nil
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
        authorization: GenerationAuthorization,
        onPhase: @MainActor (Phase) -> Void = { _ in },
        onFinished: @escaping @MainActor () -> Void = {},
        onSucceeded: @escaping @MainActor () -> Void = {}
    ) async throws {
        var videoReference: MediaAsset?
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
            videoReference = MediaAsset(url: mp4, type: .video, name: "timeline-span")
        }
        // The rendered span is a throwaway temp file — hand it back via preprocessRef so
        // GenerationService's own upload pipeline deletes it once uploaded, same as video refs do.
        let preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? =
            videoReference == nil ? nil : { @Sendable _, asset in await MainActor.run { asset.url } }

        let durationSeconds = max(1, Int(spanSeconds.rounded()))
        let params = AudioGenerationParams(
            prompt: prompt ?? "",
            voice: nil,
            lyrics: nil,
            styleInstructions: nil,
            instrumental: false,
            durationSeconds: durationSeconds,
            videoURL: nil
        )

        var genInput = GenerationInput(
            prompt: prompt ?? "",
            intent: intent,
            model: model.id,
            duration: durationSeconds,
            aspectRatio: ""
        )
        genInput.createdAt = Date()

        if mode == .videoToMusic { onPhase(.uploading) } else { onPhase(.generating) }
        let startFrame = source.startFrame
        let placeholderId = AudioGenerationSubmission.make(
            genInput: genInput, model: model, params: params, name: name ?? model.displayName,
            references: videoReference.map { [$0] } ?? [],
            preprocessRef: preprocessRef
        ).submit(
            service: service,
            projectURL: projectURL,
            editor: editor,
            authorization: authorization,
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
