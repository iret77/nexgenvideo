import AVFoundation
import Foundation
import Darwin
import NexGenEngine

@MainActor
enum PipelineProductionInputMedia {
    private final class ExportCancellation: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
        func cancel() { session.cancelExport() }
    }

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

    private struct VerifiedFile: Sendable {
        let reference: CanonicalArtifactReferenceV1
        let url: URL
        let identity: [Int64]

        nonisolated static func capture(_ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> Self {
            try Task.checkCancellation()
            let url = try ProjectLocalFile.resolve(reference.path, dataRoot: dataRoot)
            let before = try stamp(url)
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
            guard try stamp(url) == before else { throw changed() }
            return .init(reference: reference, url: url, identity: before)
        }

        nonisolated func requireCurrent(dataRoot: URL) throws {
            guard try ProjectLocalFile.resolve(reference.path, dataRoot: dataRoot) == url,
                  try Self.stamp(url) == identity else { throw changed() }
        }

        nonisolated private static func stamp(_ url: URL) throws -> [Int64] {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw changed() }
            return [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size,
                Int64(value.st_mode), Int64(value.st_nlink), Int64(value.st_uid),
                Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
                Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
    }

    private struct CachedMedia: Sendable {
        let reference: CanonicalArtifactReferenceV1
        let bytes: Data
        let files: [VerifiedFile]

        nonisolated func requireCurrent(dataRoot: URL) throws {
            for file in files { try file.requireCurrent(dataRoot: dataRoot) }
            guard try Data(contentsOf: ProjectLocalFile.resolve(reference.path, dataRoot: dataRoot)) == bytes else { throw changed() }
        }
    }

    private enum Publication: Sendable {
        case cached(CachedMedia)
        case transaction(ProjectWorkingCopy.PreparedPipelineTransaction<CanonicalArtifactReferenceV1>, PipelineSpatialSceneAuthority.SourceFence, VerifiedFile)
    }

    nonisolated static func prepare(_ selection: Selection, access: PipelinePlanningWriteAccess,
        revalidate: (@MainActor @Sendable () throws -> Void)? = nil,
        exportMedia: @escaping @Sendable (URL, CMTimeRange, AssetPhysicalModalityV1, URL) async throws -> CMTime = PipelineProductionInputMedia.exportRange) async throws -> CanonicalArtifactReferenceV1 {
        try Task.checkCancellation()
        try await revalidate?()
        try Task.checkCancellation()
        try selection.timebase.validate()
        let end = selection.startTicks.addingReportingOverflow(selection.durationTicks)
        guard !end.overflow, selection.startTicks >= 0, selection.durationTicks > 0,
              selection.modality == .video || selection.modality == .audio else { throw changed() }
        let identity = FileDigest.sha256(of: try PlanningWriterIO.json(selection))
        let receiptPath = "execution/materialized-media/\(identity).v1.json"
        let receiptURL = access.dataRoot.appendingPathComponent(receiptPath)
        let initial: (VerifiedFile, CachedMedia?) = try await background {
            if let value = try cached(selection, identity: identity, receiptPath: receiptPath, dataRoot: access.dataRoot),
               let source = value.files.first(where: { $0.reference == selection.source }) { return (source, value) }
            return (try VerifiedFile.capture(selection.source, dataRoot: access.dataRoot), nil)
        }
        let cachedResult = try await MainActor.run {
            try Task.checkCancellation()
            try revalidate?()
            try Task.checkCancellation()
            try access.revalidate()
            try initial.0.requireCurrent(dataRoot: access.dataRoot)
            try initial.1?.requireCurrent(dataRoot: access.dataRoot)
            return initial.1?.reference
        }
        if let cachedResult { return cachedResult }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-production-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent(selection.modality == .video ? "input.mov" : "input.m4a")
        let export = Task.detached(priority: .userInitiated) {
            try await exportMedia(initial.0.url,
                CMTimeRange(start: CMTime(value: selection.startTicks, timescale: Int32(selection.timebase.ticksPerSecond)),
                    duration: CMTime(value: selection.durationTicks, timescale: Int32(selection.timebase.ticksPerSecond))),
                selection.modality, staged)
        }
        let duration = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
        try Task.checkCancellation()
        try await revalidate?()
        try Task.checkCancellation()
        let publication: Publication = try await background {
            if let value = try cached(selection, identity: identity, receiptPath: receiptPath, dataRoot: access.dataRoot) { return .cached(value) }
            do {
                try initial.0.requireCurrent(dataRoot: access.dataRoot)
                let source = try VerifiedFile.capture(selection.source, dataRoot: access.dataRoot)
                let bytes = try Data(contentsOf: staged)
                let outputPath = try ProductionWorkflowRecoveryMigration.outputPath(area: "execution/resources",
                    leaf: "input-\(identity)." + (selection.modality == .video ? "mov" : "m4a"), dataRoot: access.dataRoot)
                let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.dataRoot,
                    additionalCanonicalPaths: [selection.source.path, receiptPath, outputPath])
                let output = PlanningWriterIO.reference(outputPath, id: "materialized-media-" + identity,
                    role: selection.modality == .video ? "core.source-video" : "core.audio-timing", bytes: bytes)
                let receipt = Receipt(schema: "production-input-media/v1", selection: selection, output: output,
                    durationValue: duration.value, durationTimescale: duration.timescale,
                    encoder: selection.modality == .video ? "avfoundation-highest-quality-mov/v1" : "avfoundation-apple-m4a/v1", recordedAt: currentTimestamp())
                let receiptBytes = try PlanningWriterIO.json(receipt)
                let result = PlanningWriterIO.reference(receiptPath, id: identity, role: "host.materialized-input-media", bytes: receiptBytes)
                let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.dataRoot) { staging in
                    let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: access.phase)
                    try writer.publish([(outputPath, bytes), (receiptPath, receiptBytes)], captureLineage: false) {
                        try Task.checkCancellation()
                        try require(receipt, selection: selection, dataRoot: staging)
                    }
                    return result
                }
                do { try fence.requireUnchanged(); return .transaction(transaction, fence, source) }
                catch { transaction.discard(); throw error }
            } catch {
                try Task.checkCancellation()
                if let value = try cached(selection, identity: identity, receiptPath: receiptPath, dataRoot: access.dataRoot) { return .cached(value) }
                throw error
            }
        }
        if case .cached(let value) = publication {
            return try await MainActor.run {
                try Task.checkCancellation()
                try revalidate?()
                try Task.checkCancellation()
                try access.revalidate()
                try value.requireCurrent(dataRoot: access.dataRoot)
                return value.reference
            }
        }
        guard case .transaction(let transaction, let fence, let source) = publication else { throw changed() }
        let committed: Bool
        do {
            committed = try await MainActor.run {
                try Task.checkCancellation()
                try revalidate?()
                try Task.checkCancellation()
                try access.revalidate()
                // A concurrent preparation may already have published the immutable cache entry.
                if FileManager.default.fileExists(atPath: receiptURL.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: receiptURL.path)) != nil { return false }
                _ = try transaction.commit { _ in
                    try fence.requireCanonicalRootsUnchanged()
                    try source.requireCurrent(dataRoot: access.dataRoot)
                }
                return true
            }
        } catch {
            await Task.detached(priority: .utility) { transaction.discard() }.value
            throw error
        }
        await Task.detached(priority: .utility) { transaction.discard() }.value
        if committed { return transaction.output }
        let winner = try await background { try cached(selection, identity: identity, receiptPath: receiptPath, dataRoot: access.dataRoot) }
        return try await MainActor.run {
            try Task.checkCancellation()
            try revalidate?()
            try Task.checkCancellation()
            try access.revalidate()
            guard let winner else { throw changed() }
            try winner.requireCurrent(dataRoot: access.dataRoot)
            return winner.reference
        }
    }

    nonisolated private static func cached(_ selection: Selection, identity: String, receiptPath: String, dataRoot: URL) throws -> CachedMedia? {
        let url = dataRoot.appendingPathComponent(receiptPath)
        guard FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(receiptPath, dataRoot: dataRoot))
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        try requireShape(receipt, selection: selection)
        let reference = PlanningWriterIO.reference(receiptPath, id: identity, role: "host.materialized-input-media", bytes: bytes)
        let files = try [selection.source, receipt.output, reference].map { try VerifiedFile.capture($0, dataRoot: dataRoot) }
        return .init(reference: reference, bytes: bytes, files: files)
    }

    nonisolated private static func background<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated static func exportRange(source: URL, range: CMTimeRange, modality: AssetPhysicalModalityV1,
                                        to staged: URL) async throws -> CMTime {
        try Task.checkCancellation()
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              CMTimeCompare(range.start, .zero) >= 0, CMTimeCompare(range.duration, .zero) > 0,
              modality == .video || modality == .audio else { throw changed() }
        let asset = AVURLAsset(url: source)
        let type: AVMediaType = modality == .video ? .video : .audio
        let tracks = try await asset.loadTracks(withMediaType: type)
        try Task.checkCancellation()
        var containsRange = false
        for track in tracks {
            let actual = try await track.load(.timeRange)
            try Task.checkCancellation()
            if CMTimeCompare(range.start, actual.start) >= 0 && CMTimeCompare(range.end, actual.end) <= 0 { containsRange = true }
        }
        guard containsRange, let session = AVAssetExportSession(asset: asset, presetName: modality == .video
            ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A) else { throw changed() }
        session.timeRange = range
        let cancellation = ExportCancellation(session)
        try await withTaskCancellationHandler {
            try await session.export(to: staged, as: modality == .video ? .mov : .m4a)
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        let output = AVURLAsset(url: staged)
        let measured = try await output.load(.duration)
        let tolerance = CMTime(value: 1, timescale: range.duration.timescale)
        guard measured.isNumeric, measured.value > 0,
              CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(measured, range.duration)), tolerance) <= 0,
              !(try await output.loadTracks(withMediaType: type)).isEmpty else { throw changed() }
        if modality == .video { _ = try await AVAssetImageGenerator(asset: output).image(at: .zero) }
        return measured
    }

    nonisolated static func requirePrepared(_ selection: Selection, dataRoot: URL) throws -> (receipt: Receipt, reference: CanonicalArtifactReferenceV1) {
        let identity = FileDigest.sha256(of: try PlanningWriterIO.json(selection))
        let path = "execution/materialized-media/\(identity).v1.json"
        let receipt = try PlanningWriterIO.read(Receipt.self, at: path, dataRoot: dataRoot)
        try require(receipt, selection: selection, dataRoot: dataRoot)
        return (receipt, try PlanningWriterIO.reference(path, id: identity, role: "host.materialized-input-media", dataRoot: dataRoot))
    }

    nonisolated static func require(_ value: Receipt, selection: Selection, dataRoot: URL) throws {
        try requireShape(value, selection: selection)
        _ = try ProjectLocalFile.requireHash(selection.source.sha256, at: selection.source.path, dataRoot: dataRoot)
        _ = try ProjectLocalFile.requireHash(value.output.sha256, at: value.output.path, dataRoot: dataRoot)
    }

    nonisolated private static func requireShape(_ value: Receipt, selection: Selection) throws {
        guard value.schema == "production-input-media/v1", value.selection == selection,
              value.durationValue > 0, value.durationTimescale > 0,
              value.encoder == (selection.modality == .video ? "avfoundation-highest-quality-mov/v1" : "avfoundation-apple-m4a/v1"),
              value.output.role == (selection.modality == .video ? "core.source-video" : "core.audio-timing") else { throw changed() }
        try selection.timebase.validate()
        let measured = CMTime(value: value.durationValue, timescale: value.durationTimescale)
        let expected = CMTime(value: selection.durationTicks, timescale: Int32(selection.timebase.ticksPerSecond))
        guard CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(measured, expected)),
            CMTime(value: 1, timescale: Int32(selection.timebase.ticksPerSecond))) <= 0 else { throw changed() }
    }

    nonisolated private static func changed() -> GateBlocked { GateBlocked("The exact selected source range could not be prepared. Inspect the current source and its actual duration.") }
}
