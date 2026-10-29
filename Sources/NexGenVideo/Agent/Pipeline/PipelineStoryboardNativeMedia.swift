import AVFoundation
import Foundation
import ImageIO
import NexGenEngine

enum PipelineStoryboardNativeMedia {
    struct SourceSnapshot: Sendable {
        let source: CanonicalArtifactReferenceV1
        let originalFilename: String
        let timebase: SourceMediaTimebaseV1
        let durationTicks: Int64
        fileprivate let projectHome: URL
        fileprivate let projectKey: String
        fileprivate let duration: MediaTime
        fileprivate let selection: CanonicalArtifactReferenceV1
    }

    struct FrameCandidate: Sendable {
        let previewData: Data
        let source: SourceSnapshot
        let timebase: SourceMediaTimebaseV1
        let sourceTick: Int64
        let sourceDurationTicks: Int64
        let requestedSourceTick: Int64
        fileprivate let binding: Binding
        fileprivate let actualTime: MediaTime
        fileprivate let width: Int
        fileprivate let height: Int
    }

    struct ExternalCandidate: Sendable {
        let previewData: Data
        let originalFilename: String
        fileprivate let extensionName: String
        fileprivate let binding: Binding
        fileprivate let width: Int
        fileprivate let height: Int
    }

    struct Prepared: Sendable {
        let targetShotID: String
        let targetMomentID: String
        let asset: StoryboardTimingV1.SketchAsset
        let files: [(path: String, bytes: Data)]
        fileprivate init(targetShotID: String, targetMomentID: String, asset: StoryboardTimingV1.SketchAsset,
                         files: [(path: String, bytes: Data)]) {
            self.targetShotID = targetShotID; self.targetMomentID = targetMomentID
            self.asset = asset; self.files = files
        }
    }

    fileprivate struct Binding: Sendable {
        let home: URL
        let projectKey: String
        let projectID: String
        let shotID: String
        let momentID: String
        let intentSHA256: String
        let framingSHA256: String
        let fingerprint: String
    }

    fileprivate struct MediaTime: Codable, Sendable, Equatable {
        let value: Int64
        let timescale: Int32
        init(_ time: CMTime) throws {
            guard time.isNumeric, time.epoch == 0, time.value >= 0, time.timescale > 0 else { throw unreadableVideo() }
            value = time.value; timescale = time.timescale
        }
        var time: CMTime { CMTime(value: value, timescale: timescale) }
    }

    private struct SourceSelection: Codable, Sendable {
        var schema = "storyboard-source-video-selection/v1"
        let id: String
        let projectKey: String
        let workflow: HostWorkflowKey
        let source: CanonicalArtifactReferenceV1
        let originalFilename: String
        let duration: MediaTime
        let timebase: SourceMediaTimebaseV1
        let durationTicks: Int64
    }

    private struct FrameReceipt: Codable, Sendable {
        var schema = "storyboard-source-frame-selection/v1"
        let id: String
        let projectKey: String
        let workflow: HostWorkflowKey
        let proof: StoryboardSketchProofV1
        let sourceSelection: CanonicalArtifactReferenceV1
        let requestedTime: MediaTime
        let actualTime: MediaTime
        let sourceDuration: MediaTime
        let width: Int
        let height: Int
        let decoder: String
        let expectedFingerprint: String
    }

    private struct ExternalReceipt: Codable, Sendable {
        var schema = "storyboard-external-sketch-confirmation/v1"
        let id: String
        let projectKey: String
        let workflow: HostWorkflowKey
        let proof: StoryboardSketchProofV1
        let originalFilename: String
        let sourceDescription: String
        let declaration: String
        let width: Int
        let height: Int
        let expectedFingerprint: String
    }

    private struct Access: Sendable {
        let home: URL
        let root: URL
        let key: String
        let projectKey: String
        let declaration: ProjectPackGate.MutationDeclaration
        let lease: UUID
    }

    private final class Decoder: @unchecked Sendable {
        let generator: AVAssetImageGenerator
        init(asset: AVAsset) {
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
    }

    @MainActor
    static func importSource(from url: URL, expectedFingerprint: String, editor: EditorViewModel) async throws -> SourceSnapshot {
        let access = try begin(editor, label: "Import Storyboard source")
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: access.root, id: access.lease) }
        let prepared = try await background {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "storyboard")
            let board = try PlanningWriterIO.storyboard(dataRoot: access.root, requireVisuals: false)
            guard board.fingerprint == expectedFingerprint else { throw changed() }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw unreadableVideo() }
            let digest = try FileDigest.sha256(of: url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw unreadableVideo() }
            let naturalScale = try await track.load(.naturalTimeScale)
            let clock = try mediaClock(board.timing.timebase.ticksPerSecond, scales: [duration.timescale, naturalScale])
            let nativeDuration = try MediaTime(duration)
            let durationTicks = try exactTicks(duration, timebase: clock)
            guard durationTicks > 0, try FileDigest.sha256(of: url) == digest else { throw unreadableVideo() }
            let id = UUID().uuidString.lowercased()
            let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased()
            let path = "storyboard/source-media/" + id + "/source" + suffix
            let reference = CanonicalArtifactReferenceV1(id: "storyboard-source-" + id, role: "core.storyboard-source-video", path: path, sha256: digest)
            let owner = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root, additionalCanonicalPaths: board.references.map(\.path))
            let declaration = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "storyboard")
            let selection = SourceSelection(id: id, projectKey: access.projectKey, workflow: declaration.workflow, source: reference,
                originalFilename: url.lastPathComponent, duration: nativeDuration, timebase: clock, durationTicks: durationTicks)
            let selectionPath = "storyboard/source-media/" + id + "/selection.v1.json"
            let selectionBytes = try PlanningWriterIO.json(selection)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "storyboard")
                guard try PlanningWriterIO.storyboard(dataRoot: staging, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
                _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: staging)
                try FileManager.default.copyItem(at: url, to: staging.appendingPathComponent(path))
                guard try FileDigest.sha256(of: url) == digest else { throw changed() }
                _ = try ProjectLocalFile.requireHash(digest, at: path, dataRoot: staging)
                try writer.publish([(selectionPath, selectionBytes)], captureLineage: false) {
                    _ = try sourceSnapshot(selectionPath: selectionPath, home: access.home, dataRoot: staging)
                }
                return SourceSnapshot(source: reference, originalFilename: selection.originalFilename, timebase: clock,
                    durationTicks: durationTicks, projectHome: access.home, projectKey: access.projectKey, duration: nativeDuration,
                    selection: PlanningWriterIO.reference(selectionPath, id: id, role: "host.storyboard-source-selection", bytes: selectionBytes))
            }
            do { try owner.requireUnchanged(); return (transaction, owner) }
            catch { transaction.discard(); throw error }
        }
        defer { Task.detached { prepared.0.discard() } }
        try Task.checkCancellation()
        let result = try prepared.0.commit { _ in
            try requireCurrent(access, editor: editor)
            try prepared.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return result
    }

    @MainActor
    static func prepareFrame(source: SourceSnapshot, sourceTick: Int64, shotID: String, momentID: String,
                             expectedFingerprint: String, editor: EditorViewModel) async throws -> FrameCandidate {
        let access = try begin(editor, label: "Extract Storyboard frame")
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: access.root, id: access.lease) }
        let result = try await background {
            let targetBinding = try binding(shotID: shotID, momentID: momentID, fingerprint: expectedFingerprint, access: access)
            let selected = try sourceSnapshot(selectionPath: source.selection.path, home: access.home, dataRoot: access.root)
            guard selected.source == source.source, selected.duration == source.duration, selected.timebase == source.timebase,
                  selected.projectKey == source.projectKey, selected.selection == source.selection, source.projectHome == access.home,
                  sourceTick >= 0, sourceTick < source.durationTicks else { throw changed() }
            let sourceURL = try ProjectLocalFile.requireHash(source.source.sha256, at: source.source.path, dataRoot: access.root)
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration)
            guard try MediaTime(duration) == source.duration else { throw changed() }
            let requested = CMTime(value: sourceTick, timescale: Int32(source.timebase.ticksPerSecond))
            let decoder = Decoder(asset: asset)
            let decoded = try await withTaskCancellationHandler {
                try await decoder.generator.image(at: requested)
            } onCancel: { decoder.generator.cancelAllCGImageGeneration() }
            guard decoded.actualTime.isNumeric, CMTimeCompare(decoded.actualTime, .zero) >= 0,
                  CMTimeCompare(decoded.actualTime, duration) < 0,
                  let png = ImageEncoder.encodePNG(decoded.image) else { throw unreadableVideo() }
            let clock = try mediaClock(source.timebase.ticksPerSecond, scales: [decoded.actualTime.timescale, duration.timescale])
            let tick = try exactTicks(decoded.actualTime, timebase: clock), length = try exactTicks(duration, timebase: clock)
            guard tick >= 0, tick < length else { throw unreadableVideo() }
            _ = try ProjectLocalFile.requireHash(source.source.sha256, at: source.source.path, dataRoot: access.root)
            guard try PlanningWriterIO.storyboard(dataRoot: access.root, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
            return FrameCandidate(previewData: png, source: source, timebase: clock, sourceTick: tick,
                sourceDurationTicks: length, requestedSourceTick: sourceTick, binding: targetBinding,
                actualTime: try MediaTime(decoded.actualTime), width: decoded.image.width, height: decoded.image.height)
        }
        try Task.checkCancellation()
        try requireCurrent(access, editor: editor)
        return result
    }

    @MainActor
    static func assignFrame(_ candidate: FrameCandidate, editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        try await publish(binding: candidate.binding, editor: editor, name: "Assign Source Frame") { access, workflow in
            let selected = try sourceSnapshot(selectionPath: candidate.source.selection.path, home: access.home, dataRoot: access.root)
            guard selected.source == candidate.source.source, selected.duration == candidate.source.duration,
                  selected.selection == candidate.source.selection else { throw changed() }
            let id = UUID().uuidString.lowercased()
            let imagePath = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches", leaf: id + ".png", dataRoot: access.root)
            let image = PlanningWriterIO.reference(imagePath, id: "source-frame-" + id, role: "core.storyboard-sketch", bytes: candidate.previewData)
            let proof = sketchProof(binding: candidate.binding, image: image,
                source: .sourceFrame(video: candidate.source.source, timebase: candidate.timebase, sourceTick: candidate.sourceTick,
                    sourceDurationTicks: candidate.sourceDurationTicks, selectionReceiptID: id))
            let receipt = FrameReceipt(id: id, projectKey: candidate.binding.projectKey, workflow: workflow, proof: proof,
                sourceSelection: candidate.source.selection,
                requestedTime: try MediaTime(CMTime(value: candidate.requestedSourceTick, timescale: Int32(candidate.source.timebase.ticksPerSecond))),
                actualTime: candidate.actualTime, sourceDuration: candidate.source.duration, width: candidate.width, height: candidate.height,
                decoder: "AVAssetImageGenerator.image(at:)/zero-tolerances/preferred-track-transform", expectedFingerprint: candidate.binding.fingerprint)
            return try prepared(proof: proof, imageBytes: candidate.previewData,
                receiptPath: frameReceiptPath(id), receiptBytes: PlanningWriterIO.json(receipt))
        }
    }

    @MainActor
    static func prepareExternal(from url: URL, shotID: String, momentID: String, expectedFingerprint: String,
                                editor: EditorViewModel) async throws -> ExternalCandidate {
        let access = try begin(editor, label: "Inspect External Sketch")
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: access.root, id: access.lease) }
        let result = try await background {
            let targetBinding = try binding(shotID: shotID, momentID: momentID, fingerprint: expectedFingerprint, access: access)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  ProjectMediaExtensions.images.contains(url.pathExtension.lowercased()) else {
                throw GateBlocked("Choose a readable, regular image file for the external sketch.")
            }
            let data = try Data(contentsOf: url)
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  try FileDigest.sha256(of: url) == FileDigest.sha256(of: data) else { throw changed() }
            return ExternalCandidate(previewData: data, originalFilename: url.lastPathComponent,
                extensionName: url.pathExtension.lowercased(), binding: targetBinding, width: image.width, height: image.height)
        }
        try Task.checkCancellation()
        try requireCurrent(access, editor: editor)
        return result
    }

    @MainActor
    static func confirmExternal(_ candidate: ExternalCandidate, sourceDescription: String,
                                editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        let description = sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw GateBlocked("Describe where the external sketch came from before confirming it.") }
        return try await publish(binding: candidate.binding, editor: editor, name: "Confirm External Sketch") { access, workflow in
            let id = UUID().uuidString.lowercased()
            let imagePath = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches",
                leaf: id + "." + candidate.extensionName, dataRoot: access.root)
            let image = PlanningWriterIO.reference(imagePath, id: "external-sketch-" + id, role: "core.storyboard-sketch", bytes: candidate.previewData)
            let proof = sketchProof(binding: candidate.binding, image: image, source: .externalConfirmed(original: image, confirmationReceiptID: id))
            let receipt = ExternalReceipt(id: id, projectKey: candidate.binding.projectKey, workflow: workflow, proof: proof,
                originalFilename: candidate.originalFilename, sourceDescription: description,
                declaration: "native-confirmed-external-storyboard-sketch", width: candidate.width, height: candidate.height,
                expectedFingerprint: candidate.binding.fingerprint)
            return try prepared(proof: proof, imageBytes: candidate.previewData,
                receiptPath: externalReceiptPath(id), receiptBytes: PlanningWriterIO.json(receipt))
        }
    }

    static func requireCurrent(_ proof: StoryboardSketchProofV1, dataRoot: URL) throws {
        _ = try references(proof, dataRoot: dataRoot)
    }

    static func references(_ proof: StoryboardSketchProofV1, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        try proof.requireCurrentBytes(dataRoot: dataRoot)
        let home = FrameInventory.projectHome(of: dataRoot)
        guard let key = ProjectIdentity.existingUUID(for: home) else { throw changed() }
        let workflow = try actualWorkflow(dataRoot: dataRoot)
        let raster = try FrameRasterizer.loadImage(at: ProjectLocalFile.requireHash(proof.image.sha256, at: proof.image.path, dataRoot: dataRoot))
        switch proof.source {
        case .sourceFrame(let video, let timebase, let tick, let duration, let id):
            let path = try frameReceiptPath(id)
            let receipt = try PlanningWriterIO.read(FrameReceipt.self, at: path, dataRoot: dataRoot)
            let selection = try sourceSnapshot(selectionPath: receipt.sourceSelection.path, home: home, dataRoot: dataRoot)
            _ = try ProjectLocalFile.requireHash(receipt.sourceSelection.sha256, at: receipt.sourceSelection.path, dataRoot: dataRoot)
            guard receipt.schema == "storyboard-source-frame-selection/v1", receipt.id == id,
                  receipt.projectKey == key, receipt.workflow == workflow, receipt.proof == proof,
                  receipt.width == raster.width, receipt.height == raster.height, receipt.expectedFingerprint.count == 64,
                  receipt.decoder == "AVAssetImageGenerator.image(at:)/zero-tolerances/preferred-track-transform",
                  selection.projectKey == key, selection.source == video, selection.duration == receipt.sourceDuration,
                  receipt.sourceSelection == selection.selection,
                  timebase.ticksPerSecond % selection.timebase.ticksPerSecond == 0,
                  try exactTicks(receipt.requestedTime.time, timebase: selection.timebase) >= 0,
                  try exactTicks(receipt.actualTime.time, timebase: timebase) == tick,
                  try exactTicks(receipt.sourceDuration.time, timebase: timebase) == duration,
                  receipt.requestedTime.value >= 0, receipt.requestedTime.timescale > 0, CMTimeCompare(receipt.requestedTime.time, receipt.sourceDuration.time) < 0 else { throw changed() }
            return [video, receipt.sourceSelection,
                try PlanningWriterIO.reference(path, id: id, role: "host.storyboard-source-frame-selection", dataRoot: dataRoot)]
        case .externalConfirmed(let original, let id):
            let path = try externalReceiptPath(id)
            let receipt = try PlanningWriterIO.read(ExternalReceipt.self, at: path, dataRoot: dataRoot)
            guard receipt.schema == "storyboard-external-sketch-confirmation/v1", receipt.id == id,
                  receipt.projectKey == key, receipt.workflow == workflow, receipt.proof == proof, original == proof.image,
                  !receipt.originalFilename.isEmpty, !receipt.sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  receipt.declaration == "native-confirmed-external-storyboard-sketch", receipt.width == raster.width,
                  receipt.height == raster.height, receipt.expectedFingerprint.count == 64 else { throw changed() }
            return [original, try PlanningWriterIO.reference(path, id: id, role: "host.storyboard-external-confirmation", dataRoot: dataRoot)]
        default: throw changed()
        }
    }

    private static func sourceSnapshot(selectionPath: String, home: URL, dataRoot: URL) throws -> SourceSnapshot {
        let directory = (selectionPath as NSString).deletingLastPathComponent
        let id = (directory as NSString).lastPathComponent
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              directory == "storyboard/source-media/" + id, selectionPath == directory + "/selection.v1.json" else { throw changed() }
        let selection = try PlanningWriterIO.read(SourceSelection.self, at: selectionPath, dataRoot: dataRoot)
        guard selection.schema == "storyboard-source-video-selection/v1", selection.id == id,
              selection.source.path == directory + "/source" + ((selection.originalFilename as NSString).pathExtension.isEmpty ? "" : "." + (selection.originalFilename as NSString).pathExtension.lowercased()),
              !selection.originalFilename.isEmpty,
              selection.workflow == (try actualWorkflow(dataRoot: dataRoot)),
              selection.projectKey == ProjectIdentity.existingUUID(for: home),
              try exactTicks(selection.duration.time, timebase: selection.timebase) == selection.durationTicks,
              selection.durationTicks > 0 else { throw changed() }
        try selection.timebase.validate()
        _ = try ProjectLocalFile.requireHash(selection.source.sha256, at: selection.source.path, dataRoot: dataRoot)
        return SourceSnapshot(source: selection.source, originalFilename: selection.originalFilename, timebase: selection.timebase,
            durationTicks: selection.durationTicks, projectHome: home, projectKey: selection.projectKey, duration: selection.duration,
            selection: try PlanningWriterIO.reference(selectionPath, id: id, role: "host.storyboard-source-selection", dataRoot: dataRoot))
    }

    @MainActor
    private static func publish(binding expected: Binding, editor: EditorViewModel, name: String,
        prepare: @escaping @Sendable (Access, HostWorkflowKey) throws -> Prepared) async throws -> StoryboardBundleSnapshot {
        try PipelineStoryboardEditor.requireAvailable(editor: editor)
        let access = try begin(editor, label: name)
        var holdsLease = true
        defer { if holdsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: access.root, id: access.lease) } }
        guard access.home == expected.home, access.projectKey == expected.projectKey else { throw changed() }
        let result = try await background {
            let current = try binding(shotID: expected.shotID, momentID: expected.momentID, fingerprint: expected.fingerprint, access: access)
            guard current.projectID == expected.projectID, current.intentSHA256 == expected.intentSHA256,
                  current.framingSHA256 == expected.framingSHA256 else { throw changed() }
            let before = try PlanningWriterIO.storyboard(dataRoot: access.root, requireVisuals: false)
            let owner = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root, additionalCanonicalPaths: before.references.map(\.path))
            let live = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "storyboard")
            let prepared = try prepare(access, live.workflow)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "storyboard")
                guard try PlanningWriterIO.storyboard(dataRoot: staging, requireVisuals: false).fingerprint == expected.fingerprint else { throw changed() }
                let written = try PipelineStoryboardBundleWriter.write(
                    PipelineStoryboardBundleWriter.proposal(from: before, replacing: expected.momentID, in: expected.shotID, with: prepared.asset),
                    origin: .userRevision, access: writer, nativeMediaSketches: [prepared])
                guard let published = written.sketchProofs[prepared.asset.proof.path],
                      written.sketchProblems[expected.momentID] == nil else { throw changed() }
                try requireCurrent(published, dataRoot: staging)
                return written
            }
            do { try owner.requireUnchanged(); return (transaction, before, owner) }
            catch { transaction.discard(); throw error }
        }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let written = try result.0.commit { _ in
            try requireCurrent(access, editor: editor)
            try result.2.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: access.root, id: access.lease)
        holdsLease = false
        PipelineStoryboardEditor.recordNativeAssignment(before: result.1, after: written, editor: editor, name: name)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return written
    }

    private static func prepared(proof: StoryboardSketchProofV1, imageBytes: Data,
                                 receiptPath: String, receiptBytes: Data) throws -> Prepared {
        try proof.validate()
        guard FileDigest.sha256(of: imageBytes) == proof.image.sha256 else { throw changed() }
        let id = UUID().uuidString.lowercased()
        let path = "storyboard/sketch-proofs/" + id + ".v1.json"
        let bytes = try PlanningWriterIO.json(proof)
        return Prepared(targetShotID: proof.shotID, targetMomentID: proof.momentID,
            asset: .init(image: proof.image, proof: PlanningWriterIO.reference(path, id: "sketch-proof-" + id,
                role: "core.storyboard-sketch-proof", bytes: bytes)),
            files: [(proof.image.path, imageBytes), (receiptPath, receiptBytes), (path, bytes)])
    }

    private static func binding(shotID: String, momentID: String, fingerprint: String, access: Access) throws -> Binding {
        _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "storyboard")
        let board = try PlanningWriterIO.storyboard(dataRoot: access.root, requireVisuals: false)
        guard board.fingerprint == fingerprint, let shot = board.timing.shots.first(where: { $0.id == shotID }),
              let moment = shot.moments.first(where: { $0.id == momentID }) else { throw changed() }
        return Binding(home: access.home, projectKey: access.projectKey, projectID: board.storyboard.header.projectID,
            shotID: shotID, momentID: momentID, intentSHA256: FileDigest.sha256(of: Data(moment.intent.utf8)),
            framingSHA256: try shot.framing.fingerprint(), fingerprint: fingerprint)
    }

    private static func sketchProof(binding: Binding, image: CanonicalArtifactReferenceV1,
                                    source: StoryboardSketchProofV1.Source) -> StoryboardSketchProofV1 {
        .init(projectID: binding.projectID, shotID: binding.shotID, momentID: binding.momentID,
            intentSHA256: binding.intentSHA256, framingSHA256: binding.framingSHA256, image: image, source: source)
    }

    @MainActor
    private static func begin(_ editor: EditorViewModel, label: String) throws -> Access {
        try PipelineStoryboardEditor.requireAvailable(editor: editor)
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home), let key = editor.openWorkingCopyKey,
              let projectKey = ProjectIdentity.existingUUID(for: home),
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: label) else {
            throw GateBlocked("Finish the current production action before assigning this sketch.")
        }
        return Access(home: home, root: root, key: key, projectKey: projectKey, declaration: .init(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract), lease: lease)
    }

    @MainActor
    private static func requireCurrent(_ access: Access, editor: EditorViewModel) throws {
        guard editor.workingRoot == access.home, editor.openWorkingCopyKey == access.key,
              editor.declaredPluginName == access.declaration.packName, editor.declaredPluginBinding == access.declaration.binding,
              editor.declaredProductionContract == access.declaration.productionContract,
              editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: access.root, id: access.lease) else { throw changed() }
    }

    private static func actualWorkflow(dataRoot: URL) throws -> HostWorkflowKey {
        let home = FrameInventory.projectHome(of: dataRoot)
        let pack: ProjectPackBinding?
        switch ProjectPluginSettings.bindingResolution(projectURL: home) {
        case .absent: pack = nil
        case .bound(let value): pack = value
        default: throw changed()
        }
        let core: HostProductionContractBinding?
        switch ProjectPluginSettings.productionContractResolution(projectURL: home) {
        case .absent: core = nil
        case .bound(let value): core = value
        default: throw changed()
        }
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: pack,
            expectedProductionContract: core), workflow.isProductionV2 else { throw changed() }
        return workflow
    }

    private static func mediaClock(_ base: Int64, scales: [Int32]) throws -> SourceMediaTimebaseV1 {
        var result = base
        for scale in scales {
            guard scale > 0 else { throw unreadableVideo() }
            var a = result, b = Int64(scale)
            while b != 0 { (a, b) = (b, a % b) }
            let common = (result / a).multipliedReportingOverflow(by: Int64(scale))
            guard !common.overflow, common.partialValue <= Int64(Int32.max) else { throw unreadableVideo() }
            result = common.partialValue
        }
        let clock = SourceMediaTimebaseV1(ticksPerSecond: result)
        try clock.validate()
        return clock
    }

    private static func exactTicks(_ time: CMTime, timebase: SourceMediaTimebaseV1) throws -> Int64 {
        guard time.isNumeric, time.epoch == 0, time.timescale > 0, time.value >= 0,
              timebase.ticksPerSecond > 0, timebase.ticksPerSecond <= Int64(Int32.max) else { throw unreadableVideo() }
        let value = CMTimeConvertScale(time, timescale: Int32(timebase.ticksPerSecond), method: .roundTowardZero)
        guard value.isNumeric, CMTimeCompare(value, time) == 0 else { throw unreadableVideo() }
        return value.value
    }

    private static func frameReceiptPath(_ id: String) throws -> String { try receiptPath(id, directory: "storyboard/source-frame-receipts") }
    private static func externalReceiptPath(_ id: String) throws -> String { try receiptPath(id, directory: "storyboard/external-sketch-receipts") }
    private static func receiptPath(_ id: String, directory: String) throws -> String {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw changed() }
        return directory + "/" + id + ".v1.json"
    }

    private static func background<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await operation()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func changed() -> GateBlocked {
        GateBlocked("The project, source media or Storyboard moment changed. Review the current sketch again before assigning it.")
    }
    private static func unreadableVideo() -> GateBlocked {
        GateBlocked("Choose a readable video and a real frame inside its exact media duration.")
    }
}
