import Foundation
import NexGenEngine

@MainActor
enum MusicSourcePreparation {
    static func timelineSpan(editor: EditorViewModel) -> EditorViewModel.TimelineSpan? {
        guard let span = editor.selectedTimelineSpan(), containsVisualContent(editor.timeline, in: span) else { return nil }
        return span
    }

    private static func containsVisualContent(_ timeline: Timeline, in span: EditorViewModel.TimelineSpan) -> Bool {
        timeline.tracks.contains(where: { track in
            !track.hidden && track.type != .audio && track.clips.contains { clip in
                clip.mediaType != .audio && (clip.opacity > 0 || clip.opacityTrack != nil)
                    && clip.startFrame < span.startFrame + span.frameCount && clip.endFrame > span.startFrame
            }
        })
    }

    struct Prepared {
        let submission: AudioGenerationSubmission
        let preflight: GenerationController.Preflight
    }

    static func providerDurationSeconds(spanSeconds: Double, model: AudioModelConfig) throws -> Int {
        guard spanSeconds.isFinite, spanSeconds > 0, spanSeconds.rounded(.up) < Double(Int.max),
              model.validate(spanSeconds: spanSeconds) == nil else {
            throw GenerationRequestError.optionsInvalid("Choose a music span within the selected model's duration limits.")
        }
        let minimum = max(1, Int(spanSeconds.rounded(.up)))
        if let options = model.durations, !options.isEmpty {
            guard let duration = options.filter({ $0 >= minimum && $0 >= model.minSeconds && $0 <= model.maxSeconds }).min() else {
                throw GenerationRequestError.optionsInvalid("The selected model has no supported duration covering this music span.")
            }
            return duration
        }
        guard minimum <= model.maxSeconds else { throw GenerationRequestError.optionsInvalid("The selected model cannot cover this music span.") }
        return minimum
    }

    static func prepare(_ music: MusicGenerationSubmission, editor: EditorViewModel) async throws -> Prepared {
        let home = editor.workingRoot
        let generation = editor.openWorkingCopyGeneration
        let scope = try home.map { try GenerationProjectMutationScope(projectHome: $0, editor: editor) }
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let selectedRange = editor.validSelectedTimelineRange
        let selectedClips = editor.selectedClipIds
        guard music.spanSeconds.isFinite, music.spanSeconds > 0, music.spanSeconds < Double(Int.max),
              music.source.startFrame >= 0, music.source.frameCount > 0,
              music.source.frameCount <= Int.max - music.source.startFrame,
              music.model.inputs.contains(music.mode == .videoToMusic ? .video : .text) else {
            throw GenerationRequestError.optionsInvalid("Choose a valid music duration and timeline range.")
        }
        var input = GenerationInput(prompt: music.prompt ?? "", intent: music.intent, model: music.model.id,
            duration: try providerDurationSeconds(spanSeconds: music.spanSeconds, model: music.model), aspectRatio: "")
        let params = AudioGenerationParams(prompt: input.prompt, voice: nil, lyrics: nil, styleInstructions: nil,
            instrumental: false, durationSeconds: input.duration)
        if let error = music.model.validate(params: params) { throw GenerationRequestError.optionsInvalid(error) }
        if let error = music.model.validate(spanSeconds: music.spanSeconds) { throw GenerationRequestError.optionsInvalid(error) }
        var reference: MediaAsset?
        var sourceFence: PipelineNativeTakeSourceFence.Snapshot?
        var boundSources: [ExportQueue.SourceBinding.Media] = []
        if music.mode == .videoToMusic {
            guard home != nil else { throw GenerationRequestError.storage("Save the project before preparing timeline music.") }
            guard timeline.fps > 0, containsVisualContent(timeline, in: music.source),
                  music.spanSeconds == Double(music.source.frameCount) / Double(timeline.fps) else {
                throw GenerationRequestError.optionsInvalid("Choose a timeline range containing visible video before preparing music.")
            }
            var visual = timeline
            visual.tracks = timeline.tracks.filter { !$0.hidden && $0.type != .audio }.map { track in
                var value = track
                value.clips = track.clips.filter { $0.startFrame < music.source.startFrame + music.source.frameCount
                    && $0.endFrame > music.source.startFrame }
                return value
            }
            let sourceTimeline = visual
            let captured = try await Task.detached(priority: .userInitiated) {
                let binding = try ExportQueue.SourceBinding.video(timeline: sourceTimeline, resolver: resolver,
                    additionalFiles: [], isCancelled: { Task.isCancelled })
                let frozen = try binding.freeze(jobID: "music-input-" + UUID().uuidString, isCancelled: { Task.isCancelled })
                return (binding, frozen)
            }.value
            defer { captured.1.remove() }
            try Task.checkCancellation()
            try scope?.requireCurrent(editor: editor)
            guard editor.timeline == timeline, editor.openWorkingCopyGeneration == generation else { throw changed() }
            var renderTimeline = visual
            let resources = Dictionary(uniqueKeysWithValues: captured.1.files.compactMap { file -> (String, String)? in
                guard file.ref.hasPrefix("effect resource ") else { return nil }
                return (String(file.ref.dropFirst("effect resource ".count)), file.url.path)
            })
            for ti in renderTimeline.tracks.indices {
                for ci in renderTimeline.tracks[ti].clips.indices {
                    guard var effects = renderTimeline.tracks[ti].clips[ci].effects else { continue }
                    for ei in effects.indices {
                        guard let key = EffectRegistry.descriptor(id: effects[ei].type)?.resourceKey,
                              let path = effects[ei].params[key]?.string, let frozen = resources[path] else { continue }
                        effects[ei].params[key] = EffectParam(string: frozen)
                    }
                    renderTimeline.tracks[ti].clips[ci].effects = effects
                }
            }
            let output = try await TimelineRenderer.render(timeline: renderTimeline,
                resolver: captured.1.resolver(basedOn: resolver), startFrame: music.source.startFrame,
                frameCount: music.source.frameCount, shortSide: 360, includeAudio: false)
            defer { try? FileManager.default.removeItem(at: output) }
            let media = try editor.prepareWorkingMediaDirectory()
            let destination = media.appendingPathComponent("music-input-" + UUID().uuidString + ".mp4")
            let fence = try await Task.detached(priority: .userInitiated) {
                try captured.0.verify(isCancelled: { Task.isCancelled })
                try captured.1.verify(isCancelled: { Task.isCancelled })
                try FileManager.default.copyItem(at: output, to: destination)
                guard try FileDigest.sha256(of: output) == FileDigest.sha256(of: destination) else { throw changed() }
                return try PipelineNativeTakeSourceFence.capture(captured.0.media.map(\.url) + [destination])
            }.value
            try Task.checkCancellation()
            try scope?.requireCurrent(editor: editor)
            guard editor.timeline == timeline, editor.openWorkingCopyGeneration == generation,
                  editor.validSelectedTimelineRange == selectedRange, editor.selectedClipIds == selectedClips else { throw changed() }
            let label = "Music input · \(music.source.startFrame)–\(music.source.startFrame + music.source.frameCount)"
            let asset = MediaAsset(url: destination, type: .video, name: label, duration: music.spanSeconds,
                originalFilename: label + ".mp4")
            editor.importMediaAsset(asset)
            reference = asset
            sourceFence = fence
            boundSources = captured.0.media
            input.referenceVideoAssetIds = [asset.id]
        }
        let finalFence = sourceFence
        let sources = boundSources
        let preflight: GenerationController.Preflight = { [weak editor] in
            guard let editor, editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else {
                return "The project changed. Prepare the music request again."
            }
            do {
                try scope?.requireCurrent(editor: editor)
                if music.mode == .videoToMusic {
                    guard editor.timeline == timeline, editor.validSelectedTimelineRange == selectedRange,
                          editor.selectedClipIds == selectedClips else { throw changed() }
                    for source in sources {
                        let current: URL?
                        if source.ref.hasPrefix("effect resource ") {
                            current = editor.mediaResolver.effectResourceURL(for: String(source.ref.dropFirst("effect resource ".count)))
                        } else { current = editor.mediaResolver.expectedURL(for: source.ref) }
                        guard current?.standardizedFileURL.resolvingSymlinksInPath() == source.url else { throw changed() }
                    }
                    do { try finalFence?.requireUnchanged() }
                    catch { throw changed() }
                }
                return nil
            } catch { return error.localizedDescription }
        }
        let submission = AudioGenerationSubmission.make(genInput: input, model: music.model, params: params,
            name: music.name ?? music.model.displayName, references: reference.map { [$0] } ?? [])
        return Prepared(submission: submission, preflight: preflight)
    }

    private nonisolated static func changed() -> GenerationRequestError {
        .gate("The timeline, selected range or source media changed. Prepare and review the music request again.")
    }
}
