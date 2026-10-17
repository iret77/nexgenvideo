import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum ReviewReelBuilder {
    static func build(
        plan: AssemblyPlanV1,
        dataRoot: URL,
        timeline assembledTimeline: Timeline? = nil,
        resolver sourceResolver: MediaResolver? = nil
    ) async throws -> ReviewReelV1 {
        let selectedMedia = plan.selectedMedia
        guard let fps = selectedMedia.first?.sourceFPS,
              fps > 0,
              selectedMedia.allSatisfy({ $0.sourceFPS == fps }),
              selectedMedia.map(\.shotID) == plan.placements.map(\.shotID),
              Set(plan.placements.map(\.trackID)).count == 1,
              plan.placements.allSatisfy({
                  $0.transitionIn.kind == .cut && $0.transitionIn.durationFrames == 0
              }),
              let firstStart = plan.placements.map(\.timelineStartFrame).min() else {
            throw ToolError("Sequence review requires one frame rate, one picture track and transitions the editor can reproduce exactly.")
        }
        try PipelineAssemblyStore.requireCurrentSources(selectedMedia, dataRoot: dataRoot)
        let soundtrack = try ReviewReelSoundtrack.capture(timeline: assembledTimeline, resolver: sourceResolver,
            fps: fps, dataRoot: dataRoot)
        let reelID = try soundtrack.reelID(plan: plan)
        let reelPath = "reviews/sequence/reels/\(reelID).mp4"
        let edlPath = "reviews/sequence/reels/\(reelID).edl.v1.json"
        let reelURL = dataRoot.appendingPathComponent(reelPath)
        let edlURL = dataRoot.appendingPathComponent(edlPath)

        var durationFrames = 0
        var videoClips: [Clip] = []
        var media = MediaManifest()
        var entries: [ReviewReelEDLEntryV1] = []
        for (selected, placement) in zip(selectedMedia, plan.placements) {
            let duration = selected.sourceEndFrame - selected.sourceStartFrame
            let reelStart = placement.timelineStartFrame - firstStart
            guard duration > 0 else { throw ToolError("Sequence review source ranges must be nonempty.") }
            let mediaID = "review-\(selected.shotID)"
            let sourceURL = try ProjectLocalFile.resolve(selected.sourcePath, dataRoot: dataRoot)
            let mediaType: ClipType
            let hasAudio: Bool
            let imageExtensions: Set<String> = [
                "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp",
            ]
            if selected.sourceKind == .timelineAnimatedStill
                || imageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                mediaType = .image
                hasAudio = false
            } else {
                let sourceAsset = AVURLAsset(url: sourceURL)
                let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
                guard !sourceVideoTracks.isEmpty else {
                    throw ToolError("Sequence review source '\(selected.shotID)' has no playable video track.")
                }
                mediaType = .video
                let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
                hasAudio = !sourceAudioTracks.isEmpty
                let sourceDuration = try await sourceAsset.load(.duration)
                guard sourceDuration.isNumeric,
                      sourceDuration.seconds + (1 / Double(fps)) >= Double(selected.sourceEndFrame) / Double(fps) else {
                    throw ToolError("Sequence review range for '\(selected.shotID)' exceeds its source duration.")
                }
            }
            media.entries.append(MediaManifestEntry(
                id: mediaID,
                name: selected.shotID,
                type: mediaType,
                source: .external(absolutePath: sourceURL.path),
                duration: Double(selected.sourceEndFrame) / Double(fps),
                sourceFPS: Double(fps),
                hasAudio: hasAudio
            ))
            var videoClip = Clip(
                mediaRef: mediaID,
                mediaType: mediaType,
                sourceClipType: mediaType,
                startFrame: reelStart,
                durationFrames: duration
            )
            videoClip.trimStartFrame = selected.sourceStartFrame
            videoClips.append(videoClip)
            entries.append(ReviewReelEDLEntryV1(
                shotID: selected.shotID,
                sourcePath: selected.sourcePath,
                sourceSHA256: selected.sourceSHA256,
                sourceStartFrame: selected.sourceStartFrame,
                sourceEndFrame: selected.sourceEndFrame,
                reelStartFrame: reelStart,
                reelEndFrame: reelStart + duration,
                transitionIn: placement.transitionIn
            ))
            durationFrames = max(durationFrames, reelStart + duration)
        }
        guard soundtrack.tracks.flatMap(\.clips).allSatisfy({
            $0.startFrame >= firstStart && $0.endFrame <= firstStart + durationFrames
        }) else { throw ToolError("The soundtrack extends beyond the assembled picture. Extend the picture cut to cover it or trim the audio, then rebuild the reel.") }
        for source in soundtrack.sources {
            let sourceURL = try source.resolve(dataRoot: dataRoot)
            let asset = AVURLAsset(url: sourceURL)
            let audioDuration = try await asset.load(.duration)
            guard audioDuration.isNumeric, audioDuration.seconds > 0,
                  try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                  !media.entries.contains(where: { $0.id == source.mediaID }) else {
                throw ToolError("The reviewed soundtrack source is not playable or has an ambiguous media identity.")
            }
            media.entries.append(MediaManifestEntry(id: source.mediaID, name: source.mediaID, type: .audio,
                source: .external(absolutePath: sourceURL.path), duration: audioDuration.seconds, hasAudio: true))
        }
        let audioData = try PipelineAssemblyStore.canonical(soundtrack)
        let audioURL = dataRoot.appendingPathComponent(ReviewReelSoundtrack.path(reelPath: reelPath))
        let edl = ReviewReelEDLV1(fps: fps, entries: entries)
        let edlData = try PipelineAssemblyStore.canonical(edl)
        try FileManager.default.createDirectory(at: reelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            guard try Data(contentsOf: audioURL) == audioData else { throw ToolError("The immutable review soundtrack has different bytes.") }
        } else {
            try audioData.write(to: audioURL, options: .atomic)
        }
        if FileManager.default.fileExists(atPath: edlURL.path) {
            guard try Data(contentsOf: edlURL) == edlData else {
                throw ToolError("The immutable review EDL has different bytes.")
            }
        } else {
            try edlData.write(to: edlURL, options: .atomic)
        }

        if !FileManager.default.fileExists(atPath: reelURL.path) {
            var track = Track(type: .video, clips: videoClips)
            track.id = "review-reel-video-v1"
            var timeline = Timeline()
            timeline.fps = fps
            timeline.width = 1280
            timeline.height = 720
            timeline.settingsConfigured = true
            timeline.tracks = [track]
            timeline.tracks += soundtrack.tracks.map { original in
                var track = original
                track.clips = original.clips.map { original in
                    var clip = original
                    clip.startFrame -= firstStart
                    return clip
                }
                return track
            }
            let finalMedia = media
            let resolver = MediaResolver(manifest: { finalMedia }, projectURL: { nil })
            let service = ExportService()
            await service.export(
                timeline: timeline,
                resolver: resolver,
                format: .h264,
                resolution: .r720p,
                outputURL: reelURL,
                acquireSlot: false
            )
            if let error = service.error { throw ToolError("Review reel export failed: \(error)") }
            guard service.lastReport?.offlineMediaRefs.isEmpty == true,
                  service.lastReport?.unprocessableMediaRefs.isEmpty == true else {
                throw ToolError("Review reel export did not consume every selected source.")
            }
        }

        let values = try reelURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize, byteCount > 0 else {
            throw ToolError("The canonical review reel is missing or empty.")
        }
        let asset = AVURLAsset(url: reelURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isNumeric, !tracks.isEmpty,
              abs(duration.seconds - Double(durationFrames) / Double(fps)) <= 1 / Double(fps) else {
            throw ToolError("The canonical review reel does not match its exact EDL duration.")
        }
        let reel = ReviewReelV1(
            path: reelPath,
            sha256: try FileDigest.sha256(of: reelURL),
            byteCount: Int64(byteCount),
            fps: fps,
            durationFrames: durationFrames,
            edlPath: edlPath,
            edlSHA256: FileDigest.sha256(of: edlData),
            entries: entries
        )
        try SequenceReviewValidatorV1.validate(reel: reel, selectedMedia: selectedMedia)
        try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: plan, dataRoot: dataRoot,
            timeline: assembledTimeline, resolver: sourceResolver)
        return reel
    }
}
