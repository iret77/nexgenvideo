import Foundation
import NexGenEngine

enum PipelineProductionKnownAudio {
    struct Input: Sendable {
        let asset: AssetGraphNodeV1
        let demand: ReferenceDemandV1
        let references: [CanonicalArtifactReferenceV1]
        let preparedMedia: CanonicalArtifactReferenceV1?
    }

    static func prepare(shotID: String, projection: ProductionPlanProjectionV1, modeID: String,
                        access: PipelinePlanningWriteAccess) async throws -> Input {
        if let performance = try performance(shotID: shotID, projection: projection, modeID: modeID, dataRoot: access.dataRoot) {
            return performance
        }
        let selection = try selection(shotID: shotID, projection: projection, dataRoot: access.dataRoot)
        _ = try await PipelineProductionInputMedia.prepare(selection, access: access)
        return try requirePrepared(shotID: shotID, projection: projection, modeID: modeID, dataRoot: access.dataRoot)
    }

    static func requirePrepared(shotID: String, projection: ProductionPlanProjectionV1, modeID: String, dataRoot: URL) throws -> Input {
        if let performance = try performance(shotID: shotID, projection: projection, modeID: modeID, dataRoot: dataRoot) {
            return performance
        }
        let selection = try selection(shotID: shotID, projection: projection, dataRoot: dataRoot)
        let prepared = try PipelineProductionInputMedia.requirePrepared(selection, dataRoot: dataRoot)
        return try input(output: prepared.receipt.output, source: selection.source,
            seconds: Double(prepared.receipt.durationValue) / Double(prepared.receipt.durationTimescale),
            recordedAt: prepared.receipt.recordedAt, shotID: shotID, modeID: modeID,
            references: [selection.source, prepared.receipt.output, prepared.reference], preparedMedia: prepared.reference, dataRoot: dataRoot)
    }

    private static func performance(shotID: String, projection: ProductionPlanProjectionV1, modeID: String, dataRoot: URL) throws -> Input? {
        let extensions = projection.executionPlan.extensionReferences.filter { $0.id == MusicvideoProductionExtensionV2.artifactID }
        guard !extensions.isEmpty else { return nil }
        guard extensions.count == 1, let binding = extensions.first else { throw changed() }
        let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        let matches = music.performanceSegments.enumerated().filter { $0.element.draft.shotIDs.contains(shotID) }
        guard matches.count <= 1 else { throw changed() }
        guard let match = matches.first else { return nil }
        let segment = match.element
        let receipt = try PlanningWriterIO.read(MusicPerformanceAudioReceiptV2.self,
            at: music.performanceReceipts[match.offset].path, dataRoot: dataRoot)
        return try performanceInput(segment: segment, receipt: receipt, track: music.track,
            shotID: shotID, modeID: modeID, references: music.artifactReferences + [.init(id: binding.id,
                role: "musicvideo.production", path: binding.path, sha256: binding.sha256)], dataRoot: dataRoot)
    }

    static func performanceInput(segment: MaterializedMusicPerformanceSegmentV1, receipt: MusicPerformanceAudioReceiptV2,
        track: CanonicalArtifactReferenceV1, shotID: String, modeID: String,
        references: [CanonicalArtifactReferenceV1], dataRoot: URL) throws -> Input {
        guard segment.draft.shotIDs.contains(shotID), receipt.source == track,
              receipt.segmentID == segment.draft.id, receipt.startSample == segment.draft.sourceStartSample,
              receipt.endSample == segment.draft.sourceEndSample, receipt.sampleRate == segment.draft.sampleRate,
              receipt.exportedSampleCount == segment.exportedSampleCount, receipt.sampleRate > 0,
              receipt.output.path == segment.segmentPath, receipt.output.sha256 == segment.segmentSHA256,
              receipt.byteCount == segment.segmentByteCount, !receipt.recordedAt.isEmpty else { throw changed() }
        return try input(output: receipt.output, source: track,
            seconds: Double(segment.exportedSampleCount) / Double(segment.draft.sampleRate), recordedAt: receipt.recordedAt,
            shotID: shotID, modeID: modeID, references: references, preparedMedia: nil, dataRoot: dataRoot)
    }

    private static func selection(shotID: String, projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> PipelineProductionInputMedia.Selection {
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        guard let audio = board.timing.audio, let timing = projection.timing(for: shotID),
              let start = audio.sourceTick(atTimelineTick: timing.startTicks) else { throw changed() }
        return .init(source: audio.source, timebase: projection.timebase, startTicks: start,
            durationTicks: timing.durationTicks, modality: .audio)
    }

    private static func input(output: CanonicalArtifactReferenceV1, source: CanonicalArtifactReferenceV1, seconds: Double,
        recordedAt: String, shotID: String, modeID: String, references: [CanonicalArtifactReferenceV1],
        preparedMedia: CanonicalArtifactReferenceV1?, dataRoot: URL) throws -> Input {
        var assets: [String: AssetGraphNodeV1] = [:]
        let asset = try PipelineProductionInputsWriter.upsertingAsset(path: output.path, modality: .audio,
            semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
            provenance: .init(kindID: "core.audio-timing-segment", sourceAssetID: source.id, recordedAt: recordedAt),
            durationSeconds: seconds, assetsByPath: &assets, dataRoot: dataRoot)
        guard asset.sha256 == output.sha256 else { throw changed() }
        let demand = PipelineProductionInputsWriter.coreDemand(.audioTiming, shotID: shotID,
            assetID: asset.id, modeID: modeID, durationSeconds: seconds)
        return .init(asset: asset, demand: demand, references: references, preparedMedia: preparedMedia)
    }

    private static func changed() -> GateBlocked {
        GateBlocked("Prepare the exact approved song or performance phrase audio before reviewing this shot's inputs.")
    }
}
