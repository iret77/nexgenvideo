import Foundation

extension EditorViewModel {
    var aiEditAllowed: Bool { true }

    func aiEditActions(clipId: String) -> [EditAction] {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual else { return [] }
        return EditAction.available(
            for: asset,
            effectiveDurationOverride: aiEditTrimmedSource(clip: clip, asset: asset)?.durationSeconds
        )
    }

    func aiEditUpscaleSelections(clipId: String) -> [UpscaleSelection] {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return [] }
        let duration = aiEditTrimmedSource(clip: clip, asset: asset)?.durationSeconds
        return UpscaleModelConfig.selections(for: asset, effectiveDuration: duration)
    }

    func aiEditUpscaleLabel(clipId: String, selection: UpscaleSelection) -> String {
        guard let (clip, asset) = aiEditClipAsset(clipId) else {
            return selection.displayName
        }
        let duration = aiEditTrimmedSource(clip: clip, asset: asset)?.durationSeconds
            ?? asset.duration
        return selection.label(durationSeconds: duration)
    }

    // MARK: - Clip-aware actions (trim + replace-on-complete where applicable)

    /// Edit: seed the panel with the trimmed range, replacing the clip's source on completion.
    func beginAIEdit(clipId: String) {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual,
              let stored = EditSubmitter.editSeed(for: asset) else { return }
        seedGenerationPanel(
            asset: asset,
            stored: stored,
            replacementClipId: clipId,
            trimmedSource: aiEditTrimmedSource(clip: clip, asset: asset)
        )
    }

    func runAIUpscale(clipId: String, selection: UpscaleSelection) {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return }
        let trim = aiEditTrimmedSource(clip: clip, asset: asset)
        let replacement = GenerationClipReplacement.Snapshot(clipID: clipId, resetTrim: trim != nil, editor: self)
        Task { @MainActor in
            _ = await EditSubmitter.submitUpscale(
                asset: asset,
                model: selection.model,
                targetResolution: selection.targetResolution,
                editor: self,
                trimmedSource: trim,
                replacementTarget: replacement
            )
        }
    }

    /// Music/SFX: output is new audio, so no source replacement — place it on the timeline at the clip.
    func beginAIVideoAudio(clipId: String, kind: VideoToAudioEditKind) {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return }
        let trim = aiEditTrimmedSource(clip: clip, asset: asset)
        guard let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind, effectiveDuration: trim?.durationSeconds) else { return }
        let span = trim?.durationSeconds
            ?? (asset.duration > 0 ? asset.duration : Double(clip.durationFrames) / Double(max(1, timeline.fps)))
        let placement = PendingAudioPlacement(
            startFrame: clip.startFrame,
            spanSeconds: max(span, 1 / Double(max(1, timeline.fps))),
            actionName: kind.timelineActionName
        )
        seedGenerationPanel(asset: asset, stored: stored, trimmedSource: trim, audioPlacement: placement)
    }

    func beginAIRerun(clipId: String) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        let modelId = asset.generationInput?.model ?? ""
        if UpscaleModelConfig.allIds.contains(modelId) {
            let replacement = GenerationClipReplacement.Snapshot(clipID: clipId, resetTrim: false, editor: self)
            Task { @MainActor in
                do {
                    _ = try await EditSubmitter.rerun(
                        asset: asset, editor: self, replacementTarget: replacement
                    )
                } catch {
                    mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
                }
            }
        } else if let stored = asset.generationInput {
            seedGenerationPanel(asset: asset, stored: stored, replacementClipId: clipId)
        }
    }

    func beginAICreateVideo(clipId: String, asReference: Bool) {
        guard let (_, asset) = aiEditClipAsset(clipId),
              let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        seedGenerationPanel(asset: asset, stored: stored, replacementClipId: clipId)
    }

    func seedGenerationPanel(
        asset: MediaAsset,
        stored: GenerationInput,
        replacementClipId: String? = nil,
        trimmedSource: TrimmedSource? = nil,
        audioPlacement: PendingAudioPlacement? = nil
    ) {
        pendingPanelSeed = PendingPanelSeed(asset: asset, stored: stored, context: .init(editor: self),
            replacementClipID: replacementClipId, trimmedSource: trimmedSource, audioPlacement: audioPlacement)
        revealMediaTools()
        showGenerationPanel = true
    }

    private func aiEditClipAsset(_ clipId: String) -> (clip: Clip, asset: MediaAsset)? {
        guard let clip = clipFor(id: clipId),
              let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return nil }
        return (clip, asset)
    }

    private func aiEditTrimmedSource(clip: Clip, asset: MediaAsset) -> TrimmedSource? {
        guard asset.type == .video, clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: asset.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: timeline.fps
        )
    }

}
