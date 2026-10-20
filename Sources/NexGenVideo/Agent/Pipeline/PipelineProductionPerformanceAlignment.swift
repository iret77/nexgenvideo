import AVFoundation
import Foundation
import NexGenEngine

enum PipelineProductionPerformanceAlignment {
    struct Time: Codable, Sendable, Equatable {
        let value: Int64
        let timescale: Int32
        var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    }

    struct Binding: Codable, Sendable, Equatable {
        let projectKey: String
        let shotID: String
        let segment: MaterializedMusicPerformanceSegmentV1
        let video: CanonicalArtifactReferenceV1
        let videoStart: Time
        let originalSong: CanonicalArtifactReferenceV1
        let songStart: Time
        let duration: Time
        let frameDuration: Time
        let references: [CanonicalArtifactReferenceV1]
    }

    struct Snapshot: Sendable {
        let home: URL
        let shotNumber: Int
        let binding: Binding
        let previewURL: URL
        let previewSHA256: String
        let sourceFence: PipelineNativeTakeSourceFence.Snapshot
        var shotID: String { binding.shotID }
        var phrase: MusicPerformanceSegmentDraftV1 { binding.segment.draft }
        var durationSeconds: Double { binding.duration.cmTime.seconds }
    }

    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let binding: Binding
        let preview: CanonicalArtifactReferenceV1
        let reviewer: String
        let watchedAndListened: Bool
        let observation: String
        let recordedAt: String
    }

    static func currentPath(_ shotID: String) -> String { "renders/performance-alignment/\(shotID)/current.v1.json" }

    @MainActor
    static func capture(shotID: String, editor: EditorViewModel) async throws -> Snapshot? {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Prepare phrase alignment preview")
        defer { access.end(editor: editor) }
        let preparation = Task.detached(priority: .userInitiated) {
            _ = try ProjectPackGate.requireMutation(projectURL: access.home, declaredPack: access.declaration.packName,
                declaredBinding: access.declaration.binding, declaredProductionContract: access.declaration.productionContract)
            guard try PhaseContractRuntime.resolveWorkflow(dataRoot: access.root, expectedPack: access.declaration.binding,
                expectedProductionContract: access.declaration.productionContract)?.isProductionV2 == true else { throw changed() }
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: access.root)
            guard let binding = try candidate(shotID: shotID, projection: projection, dataRoot: access.root),
                  let number = projection.shots.firstIndex(where: { $0.id == shotID }) else { return Optional<Snapshot>.none }
            let fence = try sourceFence(binding, projection: projection, dataRoot: access.root)
            let path = "Caches/PerformanceAlignment/" + UUID().uuidString + ".mov"
            _ = try ProjectLocalFile.ensureDirectory("Caches/PerformanceAlignment", dataRoot: access.home)
            let preview = access.home.appendingPathComponent(path)
            do {
                try await makePreview(binding: binding, dataRoot: access.root, destination: preview)
                try fence.requireUnchanged()
                guard try candidate(shotID: shotID, projection: ProductionPlanningLineageV2.projection(dataRoot: access.root),
                    dataRoot: access.root) == binding else { throw changed() }
                return Snapshot(home: access.home, shotNumber: number + 1, binding: binding, previewURL: preview,
                    previewSHA256: try FileDigest.sha256(of: preview), sourceFence: fence)
            } catch { try? FileManager.default.removeItem(at: preview); throw error }
        }
        let snapshot = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        do {
            try Task.checkCancellation()
            try access.requireCurrent(editor: editor)
            try snapshot?.sourceFence.requireUnchanged()
            return snapshot
        } catch {
            if let snapshot { discard(snapshot) }
            throw error
        }
    }

    static func discard(_ snapshot: Snapshot) {
        Task.detached(priority: .utility) {
            let directory = snapshot.home.appendingPathComponent("Caches/PerformanceAlignment").standardizedFileURL
            guard snapshot.previewURL.deletingLastPathComponent().standardizedFileURL == directory,
                  snapshot.previewURL.resolvingSymlinksInPath() == snapshot.previewURL.standardizedFileURL else { return }
            try? FileManager.default.removeItem(at: snapshot.previewURL)
        }
    }

    @MainActor
    static func record(snapshot: Snapshot, watchedAndListened: Bool, observation: String,
                       editor: EditorViewModel) async throws -> CanonicalArtifactReferenceV1 {
        let note = observation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard watchedAndListened, !note.isEmpty, editor.workingRoot == snapshot.home else { throw changed() }
        let access = try PipelineNativeEditAccess(editor: editor, label: "Confirm performance phrase alignment")
        defer { access.end(editor: editor) }
        let preparation = Task.detached(priority: .userInitiated) {
            let binding = snapshot.binding
            try snapshot.sourceFence.requireUnchanged()
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: access.root)
            guard try candidate(shotID: binding.shotID, projection: projection, dataRoot: access.root) == binding else { throw changed() }
            let fence = try sourceFence(binding, projection: projection, dataRoot: access.root)
            let previewURL = try ProjectLocalFile.requireHash(snapshot.previewSHA256,
                at: FrameInventory.relativePath(of: snapshot.previewURL, to: access.home), dataRoot: access.home)
            let previewFence = try PipelineNativeTakeSourceFence.capture([previewURL])
            let canonicalFence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: [ProductionPlanProjectionV1.versionPath(projection.header.revision), currentPath(binding.shotID),
                    PipelineProductionRenderWriter.selectionPath(binding.shotID)])
            let bytes = try Data(contentsOf: previewURL)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "render")
                guard try candidate(shotID: binding.shotID,
                    projection: ProductionPlanningLineageV2.projection(dataRoot: staging), dataRoot: staging) == binding else { throw changed() }
                let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "execution/resources",
                    leaf: "performance-alignment-" + UUID().uuidString + ".mov", dataRoot: staging)
                try ProductionWorkflowRecoveryMigration.requireNewOutput(path, dataRoot: staging)
                let preview = PlanningWriterIO.reference(path, id: "performance-preview", role: "host.performance-alignment-preview", bytes: bytes)
                let receipt = Receipt(schema: "native-performance-alignment/v1", binding: binding, preview: preview,
                    reviewer: "native-user", watchedAndListened: true, observation: note, recordedAt: currentTimestamp())
                let receiptBytes = try PlanningWriterIO.json(receipt)
                let hash = FileDigest.sha256(of: receiptBytes)
                let archive = "renders/performance-alignment/\(binding.shotID)/\(hash).v1.json"
                let reference = PlanningWriterIO.reference(archive, id: hash, role: "host.native-performance-alignment", bytes: receiptBytes)
                try writer.publish([(path, bytes), (archive, receiptBytes),
                    (currentPath(binding.shotID), try PlanningWriterIO.json(reference))], captureLineage: false) {
                    _ = try requireCurrent(shotID: binding.shotID, projection: projection, dataRoot: staging)
                }
                return reference
            }
            do {
                try fence.requireUnchanged(); try previewFence.requireUnchanged()
                try canonicalFence.requireUnchanged()
                return (transaction, fence, previewFence, canonicalFence)
            } catch { transaction.discard(); throw error }
        }
        let prepared = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { prepared.0.discard() } }
        try Task.checkCancellation()
        let result = try prepared.0.commit { _ in
            try access.requireCurrent(editor: editor)
            try prepared.1.requireUnchanged(); try prepared.2.requireUnchanged()
            try prepared.3.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return result
    }

    static func requireCurrent(shotID: String, projection: ProductionPlanProjectionV1,
                               dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        guard let expected = try candidate(shotID: shotID, projection: projection, dataRoot: dataRoot) else { return [] }
        let pointer = currentPath(shotID)
        do {
            let reference = try PlanningWriterIO.read(CanonicalArtifactReferenceV1.self, at: pointer, dataRoot: dataRoot)
            guard reference.path == "renders/performance-alignment/\(shotID)/\(reference.sha256).v1.json",
                  reference.id == reference.sha256, reference.role == "host.native-performance-alignment" else { throw changed() }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
            let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
            try require(receipt, expected: expected, dataRoot: dataRoot)
            return try unique(expected.references + [receipt.preview, reference,
                PlanningWriterIO.reference(pointer, id: shotID, role: "host.current-performance-alignment", dataRoot: dataRoot)])
        } catch { throw changed() }
    }

    static func require(_ receipt: Receipt, expected: Binding, dataRoot: URL) throws {
        guard receipt.schema == "native-performance-alignment/v1", receipt.binding == expected,
              receipt.reviewer == "native-user", receipt.watchedAndListened,
              !receipt.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !receipt.recordedAt.isEmpty, receipt.preview.role == "host.performance-alignment-preview" else { throw changed() }
        try validateWindows(expected)
        for reference in expected.references + [receipt.preview] {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
    }

    static func candidate(shotID: String, projection: ProductionPlanProjectionV1, dataRoot: URL) throws -> Binding? {
        guard projection.executionPlan.extensionReferences.contains(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else { return nil }
        let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        let matches = music.performanceSegments.filter { $0.draft.shotIDs.contains(shotID) }
        guard matches.count <= 1 else { throw changed() }
        guard let segment = matches.first else { return nil }
        guard let shot = projection.shots.first(where: { $0.id == shotID }), let timing = projection.timing(for: shotID),
              projection.timebase.ticksPerSecond > 0, projection.timebase.ticksPerSecond <= Int64(Int32.max),
              projection.timebase.fpsNumerator > 0, projection.timebase.fpsNumerator <= Int64(Int32.max),
              let key = ProjectIdentity.existingUUID(for: FrameInventory.projectHome(of: dataRoot)),
              let musicReference = projection.executionPlan.extensionReferences.first(where: { $0.id == MusicvideoProductionExtensionV2.artifactID }) else { throw changed() }
        let clock = Int32(projection.timebase.ticksPerSecond)
        let video: CanonicalArtifactReferenceV1
        let videoStart: Time
        var refs = music.artifactReferences + [CanonicalArtifactReferenceV1(id: musicReference.id,
            role: "musicvideo.production", path: musicReference.path, sha256: musicReference.sha256),
            try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
                id: "production-plan", role: "core.production-plan", dataRoot: dataRoot)]
        if shot.sourceMode == .imported {
            guard let source = projection.source(for: shotID) else { throw changed() }
            video = source
            videoStart = .init(value: timing.sourceInTicks, timescale: clock)
        } else {
            let selected = try PipelineProductionRenderWriter.requireSelected(shotID: shotID, dataRoot: dataRoot)
            video = selected.record.output
            if selected.selection.nativeRange != nil {
                let range = try PipelineProductionRenderWriter.sourceRange(record: selected.record, selection: selected.selection, dataRoot: dataRoot)
                guard range.timebase.ticksPerSecond <= Int64(Int32.max) else { throw changed() }
                videoStart = .init(value: range.startTicks, timescale: Int32(range.timebase.ticksPerSecond))
            } else { videoStart = .init(value: timing.sourceInTicks, timescale: clock) }
            let completed = try GenerationOutputReceipt.load(assetID: selected.record.generation.id,
                home: FrameInventory.projectHome(of: dataRoot))
            refs += [completed.output, completed.package]
            refs += [selected.reference, selected.selection.record, selected.selection.review, selected.record.generation,
                selected.record.submission, selected.record.projection] + [selected.selection.nativeRange].compactMap { $0 }
        }
        refs += [video, music.track]
        let binding = Binding(projectKey: key, shotID: shotID, segment: segment, video: video, videoStart: videoStart,
            originalSong: music.track, songStart: .init(value: timing.startTicks, timescale: clock),
            duration: .init(value: timing.durationTicks, timescale: clock),
            frameDuration: .init(value: projection.timebase.fpsDenominator, timescale: Int32(projection.timebase.fpsNumerator)),
            references: try unique(refs))
        try validateWindows(binding)
        return binding
    }

    static func validateWindows(_ binding: Binding) throws {
        let phrase = binding.segment.draft
        guard binding.videoStart.timescale > 0, binding.songStart.timescale > 0, binding.duration.timescale > 0,
              binding.videoStart.value >= 0, binding.songStart.value >= 0, binding.duration.value > 0,
              binding.frameDuration.timescale > 0, binding.frameDuration.value > 0,
              phrase.sampleRate > 0, phrase.sampleRate <= Int(Int32.max), phrase.sourceStartSample >= 0,
              phrase.sourceEndSample > phrase.sourceStartSample else { throw changed() }
        let start = CMTime(value: phrase.sourceStartSample, timescale: Int32(phrase.sampleRate))
        let end = CMTime(value: phrase.sourceEndSample, timescale: Int32(phrase.sampleRate))
        let tolerance = 0.5 / Double(phrase.sampleRate)
        guard binding.songStart.cmTime.seconds >= start.seconds - tolerance,
              CMTimeAdd(binding.songStart.cmTime, binding.duration.cmTime).seconds <= end.seconds + tolerance else { throw changed() }
    }

    static func makePreview(binding: Binding, dataRoot: URL, destination: URL) async throws {
        try validateWindows(binding)
        let video = AVURLAsset(url: try ProjectLocalFile.requireHash(binding.video.sha256, at: binding.video.path, dataRoot: dataRoot))
        let song = AVURLAsset(url: try ProjectLocalFile.requireHash(binding.originalSong.sha256, at: binding.originalSong.path, dataRoot: dataRoot))
        let composition = AVMutableComposition()
        guard let sourceVideo = try await video.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await song.loadTracks(withMediaType: .audio).first,
              let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw changed() }
        let videoRange = CMTimeRange(start: binding.videoStart.cmTime, duration: binding.duration.cmTime)
        let audioRange = CMTimeRange(start: binding.songStart.cmTime, duration: binding.duration.cmTime)
        for (track, range) in [(sourceVideo, videoRange), (sourceAudio, audioRange)] {
            let available = try await track.load(.timeRange)
            guard range.isValid, range.start.isNumeric, range.end.isNumeric,
                  available.isValid, available.start.isNumeric, available.end.isNumeric,
                  CMTimeCompare(range.start, available.start) >= 0, CMTimeCompare(range.end, available.end) <= 0 else { throw changed() }
        }
        try targetVideo.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        targetVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
        try targetAudio.insertTimeRange(audioRange, of: sourceAudio, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw changed() }
        exporter.timeRange = CMTimeRange(start: .zero, duration: binding.duration.cmTime)
        try await exporter.export(to: destination, as: .mov)
        let actual = AVURLAsset(url: destination)
        let measured = try await actual.load(.duration)
        guard measured.isNumeric, CMTimeCompare(measured,
                CMTimeSubtract(binding.duration.cmTime, CMTime(value: 1, timescale: binding.duration.timescale))) >= 0,
              CMTimeCompare(measured, CMTimeAdd(binding.duration.cmTime, binding.frameDuration.cmTime)) <= 0,
              try await actual.loadTracks(withMediaType: .video).count == 1,
              try await actual.loadTracks(withMediaType: .audio).count == 1 else { throw changed() }
        _ = try await AVAssetImageGenerator(asset: actual).image(at: .zero)
    }

    private static func sourceFence(_ binding: Binding, projection: ProductionPlanProjectionV1,
                                    dataRoot: URL) throws -> PipelineNativeTakeSourceFence.Snapshot {
        let home = FrameInventory.projectHome(of: dataRoot)
        var urls = try binding.references.map { try ProjectLocalFile.resolve($0.path, dataRoot: dataRoot) }
        for path in [ProductionPlanProjectionV1.versionPath(projection.header.revision), PipelineLayout.gatesFile,
                     PipelineProductionRenderWriter.selectionPath(binding.shotID),
                     PipelineProductionRenderWriter.currentPath(binding.shotID)] {
            if FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) {
                urls.append(try ProjectLocalFile.resolve(path, dataRoot: dataRoot))
            }
        }
        urls.append(try ProjectLocalFile.resolve("ngv.json", dataRoot: home))
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".ngv-open-generation").path) {
            urls.append(try ProjectLocalFile.resolve(".ngv-open-generation", dataRoot: home))
        }
        return try PipelineNativeTakeSourceFence.capture(urls)
    }

    private static func unique(_ refs: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var byPath: [String: CanonicalArtifactReferenceV1] = [:]
        for reference in refs {
            if let previous = byPath[reference.path], previous.sha256 != reference.sha256 { throw changed() }
            if byPath[reference.path] == nil { byPath[reference.path] = reference }
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    private static func changed() -> GateBlocked {
        GateBlocked("Review the selected shot range with its original performance phrase, then explicitly confirm their alignment. Changed takes, ranges or phrase inputs need a new review.")
    }
}
