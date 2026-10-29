import AppKit
import AVFoundation

extension EditorViewModel {
    @discardableResult
    func saveClipAsMedia(clipId: String) -> Task<Void, Never>? {
        guard let clip = clipFor(id: clipId), clip.mediaType == .video || clip.mediaType == .audio else { return nil }
        let consumed = (Double(clip.durationFrames) * clip.speed).rounded()
        guard timeline.fps > 0, timeline.fps <= Int(Int32.max), clip.trimStartFrame >= 0,
              clip.durationFrames > 0, clip.speed.isFinite, clip.speed > 0,
              consumed.isFinite, consumed > 0, consumed < Double(Int.max),
              !clip.trimStartFrame.addingReportingOverflow(Int(consumed)).overflow else {
            mediaPanelToast = "The clip has an invalid source range. Adjust its trim or speed before saving it as media."
            return nil
        }
        let sourceName = mediaResolver.displayName(for: clip.mediaRef)
        var source = timeline
        source.tracks = source.tracks.compactMap { track in
            guard track.clips.contains(where: { $0.id == clipId }) else { return nil }
            var track = track
            var raw = clip
            raw.effects = nil
            track.clips = [raw]
            track.hidden = false
            track.muted = false
            return track
        }
        return saveAsMedia(source: source, name: "\(sourceName) (clip)", type: clip.mediaType) { timeline, resolver in
            guard let url = resolver.resolveURL(for: clip.mediaRef) else {
                throw ToolError("The clip source is offline. Relink it before saving the clip as media.")
            }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(Self.uniqueClipFilename(for: clip.mediaType))
            do {
                try await Self.exportClipRange(sourceURL: url, destURL: output, fps: timeline.fps,
                    trimStartFrame: clip.trimStartFrame, sourceFramesConsumed: clip.sourceFramesConsumed,
                    durationFrames: clip.durationFrames, speed: clip.speed, mediaType: clip.mediaType)
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
    }

    @discardableResult
    func saveTimelineRangeAsMedia() -> Task<Void, Never>? {
        guard let range = validSelectedTimelineRange else { return nil }
        return saveAsMedia(source: timeline, name: "Timeline range", type: .video) { timeline, resolver in
            try await TimelineRenderer.render(timeline: timeline, resolver: resolver,
                startFrame: range.startFrame, frameCount: range.endFrame - range.startFrame,
                preset: AVAssetExportPresetHighestQuality)
        }
    }

    @discardableResult
    func saveAsMedia(source: Timeline, name: String, type: ClipType,
                     render: @escaping @MainActor (Timeline, MediaResolver) async throws -> URL) -> Task<Void, Never>? {
        let output: URL
        do { output = try prepareWorkingMediaDirectory().appendingPathComponent(Self.uniqueClipFilename(for: type)) }
        catch { mediaPanelToast = MediaPanelToast(message: error.localizedDescription); return nil }
        let destination = MediaLibraryDestination(self, folderID: nil)
        let resolver = mediaResolver.snapshot()
        let asset = MediaAsset(url: output, type: type, name: name,
            originalFilename: name + "." + output.pathExtension)
        asset.generationStatus = .rendering
        importMediaAsset(asset)
        return Task { @MainActor [weak self] in
            do {
                let captured = try await Task.detached(priority: .userInitiated) {
                    let binding = try ExportQueue.SourceBinding.video(timeline: source, resolver: resolver,
                        additionalFiles: [], isCancelled: { Task.isCancelled })
                    let frozen = try binding.freeze(jobID: "saved-media-" + UUID().uuidString, isCancelled: { Task.isCancelled })
                    return (binding, frozen)
                }.value
                defer { captured.1.remove() }
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try self.requireMediaSaveDestination(destination, asset: asset)
                let rendered = try await render(Self.savedMediaTimeline(source, sources: captured.1), captured.1.resolver(basedOn: resolver))
                defer { try? FileManager.default.removeItem(at: rendered) }
                try Task.checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    try captured.0.verify(isCancelled: { Task.isCancelled })
                    try captured.1.verify(isCancelled: { Task.isCancelled })
                }.value
                try self.requireMediaSaveDestination(destination, asset: asset)
                try FileManager.default.moveItem(at: rendered, to: output)
                guard await self.finalizeImportedAsset(asset) else { throw MediaImportError.projectChanged }
                try self.requireMediaSaveDestination(destination, asset: asset)
                asset.generationStatus = .none
                self.onPipelineChanged?()
            } catch {
                try? FileManager.default.removeItem(at: output)
                guard let self, (try? destination.validate(self)) != nil,
                      self.mediaAssets.contains(where: { $0 === asset }) else { return }
                let message = error is CancellationError ? "Saving media was cancelled." : error.localizedDescription
                asset.generationStatus = .failed(message)
                self.mediaPanelToast = MediaPanelToast(message: message)
            }
        }
    }

    private func requireMediaSaveDestination(_ destination: MediaLibraryDestination, asset: MediaAsset) throws {
        try destination.validate(self)
        guard mediaAssets.contains(where: { $0 === asset }),
              mediaResolver.expectedURL(for: asset.id)?.standardizedFileURL == asset.url.standardizedFileURL else {
            throw ToolError("The media destination changed. Save the clip or range again.")
        }
    }

    private static func savedMediaTimeline(_ timeline: Timeline, sources: ExportQueue.FrozenSources) -> Timeline {
        let resources = Dictionary(uniqueKeysWithValues: sources.files.compactMap { file -> (String, String)? in
            guard file.ref.hasPrefix("effect resource ") else { return nil }
            return (String(file.ref.dropFirst("effect resource ".count)), file.url.path)
        })
        var result = timeline
        for ti in result.tracks.indices {
            for ci in result.tracks[ti].clips.indices {
                guard var effects = result.tracks[ti].clips[ci].effects else { continue }
                for ei in effects.indices {
                    guard let key = EffectRegistry.descriptor(id: effects[ei].type)?.resourceKey,
                          let path = effects[ei].params[key]?.string, let frozen = resources[path] else { continue }
                    effects[ei].params[key] = EffectParam(string: frozen)
                }
                result.tracks[ti].clips[ci].effects = effects
            }
        }
        return result
    }

    private static func uniqueClipFilename(for type: ClipType) -> String {
        let ext = type == .video ? "mp4" : "m4a"
        return "clip-\(UUID().uuidString).\(ext)"
    }

    private static func exportClipRange(
        sourceURL: URL,
        destURL: URL,
        fps: Int,
        trimStartFrame: Int,
        sourceFramesConsumed: Int,
        durationFrames: Int,
        speed: Double,
        mediaType: ClipType
    ) async throws {
        struct ExportError: LocalizedError {
            let reason: String
            var errorDescription: String? { reason }
        }

        let asset = AVURLAsset(url: sourceURL)
        let primaryType: AVMediaType = mediaType == .audio ? .audio : .video
        guard let primarySource = try await asset.loadTracks(withMediaType: primaryType).first else {
            throw ExportError(reason: "no \(primaryType.rawValue) track in source")
        }

        let composition = AVMutableComposition()
        guard let primaryComp = composition.addMutableTrack(
            withMediaType: primaryType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError(reason: "could not create composition track")
        }

        let timescale = CMTimeScale(max(1, fps))
        let sourceFrames = max(1, sourceFramesConsumed)
        let timelineFrames = max(1, durationFrames)
        let trimStart = CMTime(value: CMTimeValue(trimStartFrame), timescale: timescale)
        let sourceDuration = CMTime(value: CMTimeValue(sourceFrames), timescale: timescale)
        let timelineDuration = CMTime(value: CMTimeValue(timelineFrames), timescale: timescale)
        let sourceRange = CMTimeRange(start: trimStart, duration: sourceDuration)

        try primaryComp.insertTimeRange(sourceRange, of: primarySource, at: .zero)
        if mediaType == .video {
            primaryComp.preferredTransform = try await primarySource.load(.preferredTransform)
        }
        if speed != 1.0 {
            primaryComp.scaleTimeRange(
                CMTimeRange(start: .zero, duration: sourceDuration),
                toDuration: timelineDuration
            )
        }

        if mediaType == .video,
           let audioSource = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioComp = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? audioComp.insertTimeRange(sourceRange, of: audioSource, at: .zero)
            if speed != 1.0 {
                audioComp.scaleTimeRange(
                    CMTimeRange(start: .zero, duration: sourceDuration),
                    toDuration: timelineDuration
                )
            }
        }

        try? FileManager.default.removeItem(at: destURL)

        let presetName = mediaType == .audio
            ? AVAssetExportPresetAppleM4A
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError(reason: "export preset unsupported")
        }
        let outType: AVFileType = mediaType == .audio ? .m4a : .mp4
        try await session.export(to: destURL, as: outType)
    }
}
