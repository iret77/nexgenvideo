import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionInputMedia {
    struct Selection: Codable, Sendable, Equatable {
        let source: CanonicalArtifactReferenceV1
        let timebase: RationalTimebaseV1
        let startTicks: Int64
        let durationTicks: Int64
        let modality: AssetPhysicalModalityV1
    }

    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let selection: Selection
        let output: CanonicalArtifactReferenceV1
        let durationValue: Int64
        let durationTimescale: Int32
        let encoder: String
        let recordedAt: String
    }

    nonisolated static func prepare(_ selection: Selection, access: PipelinePlanningWriteAccess) async throws -> CanonicalArtifactReferenceV1 {
        try selection.timebase.validate()
        let end = selection.startTicks.addingReportingOverflow(selection.durationTicks)
        guard !end.overflow, selection.startTicks >= 0, selection.durationTicks > 0,
              selection.modality == .video || selection.modality == .audio else { throw changed() }
        let source = try ProjectLocalFile.requireHash(selection.source.sha256, at: selection.source.path, dataRoot: access.dataRoot)
        let identity = FileDigest.sha256(of: try PlanningWriterIO.json(selection))
        let receiptPath = "execution/materialized-media/\(identity).v1.json"
        let receiptURL = access.dataRoot.appendingPathComponent(receiptPath)
        if FileManager.default.fileExists(atPath: receiptURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: receiptURL.path)) != nil {
            let receipt = try PlanningWriterIO.read(Receipt.self, at: receiptPath, dataRoot: access.dataRoot)
            try require(receipt, selection: selection, dataRoot: access.dataRoot)
            return try PlanningWriterIO.reference(receiptPath, id: identity, role: "host.materialized-input-media", dataRoot: access.dataRoot)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-production-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent(selection.modality == .video ? "input.mov" : "input.m4a")
        let duration = try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: source)
            let available = try await asset.load(.duration)
            let type: AVMediaType = selection.modality == .video ? .video : .audio
            guard !(try await asset.loadTracks(withMediaType: type)).isEmpty else { throw changed() }
            let range = CMTimeRange(start: CMTime(value: selection.startTicks, timescale: Int32(selection.timebase.ticksPerSecond)),
                duration: CMTime(value: selection.durationTicks, timescale: Int32(selection.timebase.ticksPerSecond)))
            guard available.isNumeric, CMTimeCompare(range.end, available) <= 0,
                  let session = AVAssetExportSession(asset: asset, presetName: selection.modality == .video
                    ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A) else { throw changed() }
            session.timeRange = range
            try await session.export(to: staged, as: selection.modality == .video ? .mov : .m4a)
            let output = AVURLAsset(url: staged)
            let measured = try await output.load(.duration)
            let tolerance = CMTime(value: 1, timescale: Int32(selection.timebase.ticksPerSecond))
            guard measured.isNumeric, measured.value > 0,
                  CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(measured, range.duration)), tolerance) <= 0,
                  !(try await output.loadTracks(withMediaType: type)).isEmpty else { throw changed() }
            if selection.modality == .video { _ = try await AVAssetImageGenerator(asset: output).image(at: .zero) }
            return measured
        }.value
        try Task.checkCancellation()
        try access.revalidate()
        _ = try ProjectLocalFile.requireHash(selection.source.sha256, at: selection.source.path, dataRoot: access.dataRoot)
        let bytes = try Data(contentsOf: staged)
        let outputPath = try ProductionWorkflowRecoveryMigration.outputPath(area: "execution/resources",
            leaf: "input-\(identity)." + (selection.modality == .video ? "mov" : "m4a"), dataRoot: access.dataRoot)
        let output = PlanningWriterIO.reference(outputPath, id: "materialized-media-" + identity,
            role: selection.modality == .video ? "core.source-video" : "core.audio-timing", bytes: bytes)
        let receipt = Receipt(schema: "production-input-media/v1", selection: selection, output: output,
            durationValue: duration.value, durationTimescale: duration.timescale,
            encoder: selection.modality == .video ? "avfoundation-highest-quality-mov/v1" : "avfoundation-apple-m4a/v1", recordedAt: currentTimestamp())
        let receiptBytes = try PlanningWriterIO.json(receipt)
        try access.publish([(outputPath, bytes), (receiptPath, receiptBytes)], captureLineage: false) {
            try require(receipt, selection: selection, dataRoot: access.dataRoot)
        }
        return PlanningWriterIO.reference(receiptPath, id: identity, role: "host.materialized-input-media", bytes: receiptBytes)
    }

    nonisolated static func requirePrepared(_ selection: Selection, dataRoot: URL) throws -> (receipt: Receipt, reference: CanonicalArtifactReferenceV1) {
        let identity = FileDigest.sha256(of: try PlanningWriterIO.json(selection))
        let path = "execution/materialized-media/\(identity).v1.json"
        let receipt = try PlanningWriterIO.read(Receipt.self, at: path, dataRoot: dataRoot)
        try require(receipt, selection: selection, dataRoot: dataRoot)
        return (receipt, try PlanningWriterIO.reference(path, id: identity, role: "host.materialized-input-media", dataRoot: dataRoot))
    }

    nonisolated static func require(_ value: Receipt, selection: Selection, dataRoot: URL) throws {
        guard value.schema == "production-input-media/v1", value.selection == selection,
              value.durationValue > 0, value.durationTimescale > 0,
              value.encoder == (selection.modality == .video ? "avfoundation-highest-quality-mov/v1" : "avfoundation-apple-m4a/v1"),
              value.output.role == (selection.modality == .video ? "core.source-video" : "core.audio-timing") else { throw changed() }
        try selection.timebase.validate()
        let measured = CMTime(value: value.durationValue, timescale: value.durationTimescale)
        let expected = CMTime(value: selection.durationTicks, timescale: Int32(selection.timebase.ticksPerSecond))
        guard CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(measured, expected)),
            CMTime(value: 1, timescale: Int32(selection.timebase.ticksPerSecond))) <= 0 else { throw changed() }
        _ = try ProjectLocalFile.requireHash(selection.source.sha256, at: selection.source.path, dataRoot: dataRoot)
        _ = try ProjectLocalFile.requireHash(value.output.sha256, at: value.output.path, dataRoot: dataRoot)
    }

    nonisolated private static func changed() -> GateBlocked { GateBlocked("The exact selected source range could not be prepared. Inspect the current source and its actual duration.") }
}
