import AVFoundation
import Foundation
import NexGenEngine

enum PipelineProductionMusicMix {
    struct Layer: Codable, Sendable, Equatable {
        let assetID: String
        let trackID: String
        let clipID: String
        let source: CanonicalArtifactReferenceV1
        let sourceStartValue: Int64
        let sourceStartTimescale: Int32
        let sourceEndValue: Int64
        let sourceEndTimescale: Int32
        let sourceTimescale: Int32
    }

    struct Prepared: Sendable {
        let tracks: [Track]
        let layers: [Layer]
        let media: [PipelineProductionAssemblyWriter.MediaBinding]
        let references: [CanonicalArtifactReferenceV1]
    }

    static func prepare(projection: ProductionPlanProjectionV1, context: PipelineProductionAssemblyWriter.Context,
                        dataRoot: URL) async throws -> Prepared? {
        guard projection.executionPlan.extensionReferences.contains(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else { return nil }
        let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        let assets = try declaredAssets(music: music, projection: projection, dataRoot: dataRoot)
        let (selected, byMedia) = try selectedTracks(assets: assets, context: context, dataRoot: dataRoot)
        var layers: [Layer] = []
        var media: [PipelineProductionAssemblyWriter.MediaBinding] = []
        for track in selected {
            for clip in track.clips {
                guard let asset = byMedia[clip.mediaRef], clip.mediaType == .audio else {
                    throw GateBlocked("Place each declared Music Video audio layer on a separate audio track before building the cut. This track also contains undeclared audio.")
                }
                let source = CanonicalArtifactReferenceV1(id: asset.id, role: "musicvideo.additional-audio", path: asset.path, sha256: asset.sha256)
                let actual = AVURLAsset(url: try ProjectLocalFile.resolve(source.path, dataRoot: dataRoot))
                guard let audio = try await actual.loadTracks(withMediaType: .audio).first else { throw changed() }
                let range = try await audio.load(.timeRange)
                guard range.isValid, range.start.isNumeric, range.end.isNumeric else { throw changed() }
                let layer = Layer(assetID: asset.id, trackID: track.id, clipID: clip.id, source: source,
                    sourceStartValue: range.start.value, sourceStartTimescale: range.start.timescale,
                    sourceEndValue: range.end.value, sourceEndTimescale: range.end.timescale,
                    sourceTimescale: try await audio.load(.naturalTimeScale))
                try requireRange(clip, layer: layer, fps: context.timeline.fps)
                layers.append(layer)
                if !media.contains(where: { $0.mediaID == clip.mediaRef }) { media.append(.init(mediaID: clip.mediaRef, source: source)) }
            }
        }
        guard Set(layers.map(\.assetID)) == Set(music.finalMix.approvedAdditionalLayerIDs) else {
            throw GateBlocked("Place every declared Music Video audio layer in the timeline at its intended start, range and level before building the cut.")
        }
        return .init(tracks: selected, layers: layers, media: media,
            references: music.artifactReferences + layers.map(\.source))
    }

    @discardableResult
    static func requireDeclaredPlacements(projection: ProductionPlanProjectionV1,
        context: PipelineProductionAssemblyWriter.Context, dataRoot: URL) throws -> Set<String> {
        let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        let assets = try declaredAssets(music: music, projection: projection, dataRoot: dataRoot)
        return Set(try selectedTracks(assets: assets, context: context, dataRoot: dataRoot).0.map(\.id))
    }

    static func startupSongTrack(timeline: Timeline, manifest: MediaManifest,
        media: [PipelineProductionAssemblyWriter.ExistingMedia], source: CanonicalArtifactReferenceV1) throws -> String? {
        guard let anchor = manifest.songAnchorAssetId else { return nil }
        let tracks = timeline.tracks.filter { $0.clips.contains { $0.mediaRef == anchor } }
        guard !tracks.isEmpty else { return nil }
        guard manifest.intakeRoleByAssetID[anchor] == "song", tracks.count == 1, let track = tracks.first,
              track.type == .audio, track.clips.count == 1, track.clips[0].mediaType == .audio,
              let actual = media.first(where: { $0.id == anchor }), actual.type == .audio,
              matchesSource(actual.url, sha256: source.sha256) else {
            throw GateBlocked("The original song's startup track contains other edits or changed source bytes. Keep the original song on its own audio track before building the production cut.")
        }
        return track.id
    }

    static func requireNoForeignTracks(_ timeline: Timeline, owned: Set<String>) throws {
        guard !timeline.tracks.contains(where: { track in
            !owned.contains(track.id) && !track.clips.isEmpty && (track.type == .audio ? !track.muted : !track.hidden)
        }) else {
            throw GateBlocked("The timeline contains active tracks outside this production cut. Hide or mute those tracks before building; keep visual finishing edits for after Render approval.")
        }
    }

    private static func selectedTracks(assets: [AssetGraphNodeV1], context: PipelineProductionAssemblyWriter.Context,
        dataRoot: URL) throws -> ([Track], [String: AssetGraphNodeV1]) {
        var byMedia: [String: AssetGraphNodeV1] = [:]
        for asset in assets { _ = try ProjectLocalFile.requireHash(asset.sha256, at: asset.path, dataRoot: dataRoot) }
        let used = Set(context.timeline.tracks.filter { $0.type == .audio && !$0.muted }.flatMap(\.clips).map(\.mediaRef))
        for item in context.media where item.type == .audio && used.contains(item.id) {
            let exact = assets.filter { "pipeline/" + $0.path == item.path }
            let matching = exact.isEmpty ? assets.filter { matchesSource(item.url, sha256: $0.sha256) } : exact
            guard matching.count <= 1 else {
                throw GateBlocked("This audio layer matches several declared assets. Keep one approved asset for these identical source bytes before building the cut.")
            }
            if let asset = matching.first, matchesSource(item.url, sha256: asset.sha256) { byMedia[item.id] = asset }
        }
        let selected = context.timeline.tracks.filter { track in
            track.type == .audio && !track.muted && track.clips.contains { byMedia[$0.mediaRef] != nil }
        }
        let active = selected.flatMap(\.clips)
        guard active.allSatisfy({ byMedia[$0.mediaRef] != nil }),
              Set(active.compactMap { byMedia[$0.mediaRef]?.id }) == Set(assets.map(\.id)) else {
            throw GateBlocked("Place every declared Music Video audio layer on its own timeline audio track at the intended start, range and level before building the cut.")
        }
        return (selected, byMedia)
    }

    static func matchesSource(_ url: URL, sha256: String) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        return (try? FileDigest.sha256(of: url)) == sha256
    }

    static func requireCurrent(_ layers: [Layer], tracks: [Track], media: [PipelineProductionAssemblyWriter.MediaBinding],
                               projection: ProductionPlanProjectionV1, fps: Int, dataRoot: URL) throws {
        let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        let assets = try declaredAssets(music: music, projection: projection, dataRoot: dataRoot)
        guard Set(layers.map(\.assetID)) == Set(assets.map(\.id)), Set(layers.map(\.clipID)).count == layers.count else { throw changed() }
        for layer in layers {
            guard let asset = assets.first(where: { $0.id == layer.assetID }), asset.path == layer.source.path,
                  asset.sha256 == layer.source.sha256, let track = tracks.first(where: { $0.id == layer.trackID }),
                  track.type == .audio, !track.muted, let clip = track.clips.first(where: { $0.id == layer.clipID }),
                  media.contains(.init(mediaID: clip.mediaRef, source: layer.source)) else { throw changed() }
            _ = try ProjectLocalFile.requireHash(layer.source.sha256, at: layer.source.path, dataRoot: dataRoot)
            try requireRange(clip, layer: layer, fps: fps)
        }
    }

    private static func declaredAssets(music: MusicvideoProductionExtensionV2, projection: ProductionPlanProjectionV1,
                                       dataRoot: URL) throws -> [AssetGraphNodeV1] {
        let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: projection, dataRoot: dataRoot)
        let graph = try PipelineShotPlanningPromotionStore.plannedGraph(promotion: promotion, dataRoot: dataRoot)
        return try music.finalMix.approvedAdditionalLayerIDs.map { id in
            guard let asset = graph.assets.first(where: { $0.id == id }), asset.modality == .audio,
                  asset.approval == .approved, asset.sha256 != music.track.sha256 else { throw changed() }
            return asset
        }
    }

    static func requireRange(_ clip: Clip, layer: Layer, fps: Int) throws {
        let end = clip.startFrame.addingReportingOverflow(clip.durationFrames)
        guard fps > 0, fps <= Int(Int32.max), clip.startFrame >= 0, clip.durationFrames > 0, !end.overflow,
              clip.trimStartFrame >= 0, clip.speed.isFinite, clip.speed > 0,
              clip.volume.isFinite, clip.volume >= 0, layer.sourceStartTimescale > 0,
              layer.sourceEndValue > 0, layer.sourceEndTimescale > 0 else { throw changed() }
        guard layer.sourceTimescale > 0 else { throw changed() }
        let sourceFramesValue = Double(clip.durationFrames) * clip.speed
        guard sourceFramesValue.isFinite, sourceFramesValue < Double(Int.max) else { throw changed() }
        let sourceFrames = clip.speed == 1 ? clip.durationFrames : max(1, Int(sourceFramesValue))
        let start = CMTime(seconds: Double(clip.trimStartFrame) / Double(fps), preferredTimescale: layer.sourceTimescale)
        let consumed = CMTime(seconds: Double(sourceFrames) / Double(fps), preferredTimescale: layer.sourceTimescale)
        let availableStart = CMTime(value: layer.sourceStartValue, timescale: layer.sourceStartTimescale)
        let availableEnd = CMTime(value: layer.sourceEndValue, timescale: layer.sourceEndTimescale)
        _ = try CompositionBuilder.availableSourceRange(start: start, requestedDuration: consumed,
            available: CMTimeRange(start: availableStart, end: availableEnd), coverage: CMTime(value: 1, timescale: Int32(fps)))
    }

    private static func changed() -> GateBlocked {
        GateBlocked("The declared Music Video audio layer is missing, changed or outside its actual source range. Restore its intended timeline placement before building the cut.")
    }
}
