import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionRenderWriter {
    struct Record: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let shotID: String
        let takeID: String
        let projection: CanonicalArtifactReferenceV1
        let generation: CanonicalArtifactReferenceV1
        let submission: CanonicalArtifactReferenceV1
        let output: CanonicalArtifactReferenceV1
        let durationValue: Int64
        let durationTimescale: Int32
    }

    struct StillRecord: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let shotID: String
        let projection: CanonicalArtifactReferenceV1
        let frameReceipt: CanonicalArtifactReferenceV1
        let renderReview: CanonicalArtifactReferenceV1
        let output: CanonicalArtifactReferenceV1
        let framesApproval: Gate
    }

    struct Selection: Codable, Sendable, Equatable {
        let schema: String
        let projectKey: String
        let shotID: String
        let takeID: String
        let record: CanonicalArtifactReferenceV1
        let review: CanonicalArtifactReferenceV1
        let durationValue: Int64
        let durationTimescale: Int32
        let lastFrame: RenderLastFrameProofV1?
        let nativeRange: CanonicalArtifactReferenceV1?
    }

    nonisolated static func recordPath(_ takeID: String) -> String { "renders/production-records/\(takeID).v1.json" }
    nonisolated static func currentPath(_ shotID: String) -> String { "renders/production-records/current-\(shotID).v1.json" }
    nonisolated static func selectionPath(_ shotID: String) -> String { "renders/selections/\(shotID)/current.v1.json" }

    nonisolated static func prepare(access: PipelinePlanningWriteAccess) throws {
        guard access.phase == "render" else { throw changed() }
        try access.revalidate()
        let root = access.dataRoot
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let path = PipelineLayout.renderManifestFile(phase: "final")
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else {
            _ = try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(dataRoot: root, phase: "final")
            return
        }
        _ = try PipelineRenderRecordWriter.publish(manifest: RenderManifest(project: projection.header.projectID, phase: "final"),
            proof: RenderProofManifest(project: projection.header.projectID, phase: "final"),
            routingProof: PipelineRenderRoutingProofManifestV1(project: projection.header.projectID, phase: "final"),
            framesManifest: nil, replacingShotID: nil, preparedLastFrame: nil, reconciledLastFrames: [:],
            expectedPublicationTransactionID: nil, dataRoot: root,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
    }

    nonisolated static func nextPending(dataRoot: URL) throws -> ExecutionShotV1? {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        for shot in projection.shots where shot.sourceMode != .imported {
            if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill {
                if (try? requireStill(shotID: shot.id, dataRoot: dataRoot)) == nil { return shot }
            } else if (try? requireRecorded(shotID: shot.id, dataRoot: dataRoot)) == nil { return shot }
        }
        return nil
    }

    nonisolated static func stillPath(_ shotID: String) -> String { "renders/still-deliveries/\(shotID)/current.v1.json" }

    nonisolated private static func stillCandidate(shotID: String, dataRoot: URL) throws -> StillRecord {
        let home = FrameInventory.projectHome(of: dataRoot)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        guard let shot = projection.shots.first(where: { $0.id == shotID }),
              ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill,
              let key = ProjectIdentity.existingUUID(for: home),
              let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: dataRoot) else { throw changed() }
        try PipelineRenderReviewWriter.requireCurrent(review, dataRoot)
        _ = try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: dataRoot)
        let frame = try PipelineProductionFramesWriter.requireFrame(shotID: shotID, role: "start", projection: projection, dataRoot: dataRoot)
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        let declaration = try ProjectPackGate.captureMutationDeclaration(projectURL: home)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract) else { throw changed() }
        try GateGuard.requirePriorApproved(gates, order: PhaseContractRuntime.order(workflow: workflow), phase: "render")
        if let provider = try PhaseContractRuntime.lineageProvider(workflow: workflow, phase: "frames",
            registry: PackCatalog.registry(activePack: declaration.packName)) {
            try PipelineLineageStore.requireCurrent(phase: "frames", snapshot: provider(dataRoot), dataRoot: dataRoot)
        } else { throw changed() }
        let url = try ProjectLocalFile.resolve(frame.path, dataRoot: dataRoot)
        return StillRecord(schema: "production-still-delivery/v1", projectKey: key, shotID: shotID,
            projection: try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
                id: "production-plan", role: "core.production-plan", dataRoot: dataRoot),
            frameReceipt: try PlanningWriterIO.reference(PipelineProductionFramesWriter.receiptPath(shotID: shotID, role: "start"),
                id: shotID, role: "host.production-frame-receipt", dataRoot: dataRoot),
            renderReview: try PlanningWriterIO.reference(RenderReviewV1.versionPath(review.header.revision),
                id: "render-review", role: "core.render-review", dataRoot: dataRoot),
            output: .init(id: shotID, role: "host.approved-still-delivery", path: FrameInventory.relativePath(of: url, to: home),
                sha256: try FileDigest.sha256(of: url)), framesApproval: gates.get("frames"))
    }

    nonisolated static func requireStill(shotID: String, dataRoot: URL) throws -> (record: StillRecord, reference: CanonicalArtifactReferenceV1) {
        let expected = try stillCandidate(shotID: shotID, dataRoot: dataRoot)
        let bytes = try PlanningWriterIO.json(expected)
        let hash = FileDigest.sha256(of: bytes)
        let path = "renders/still-deliveries/\(shotID)/\(hash).v1.json"
        guard try Data(contentsOf: ProjectLocalFile.resolve(stillPath(shotID), dataRoot: dataRoot)) == bytes,
              try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)) == bytes,
              try loadRenderManifest(dataRoot: dataRoot, phase: "final").entries[shotID]?.output == expected.output.path else { throw changed() }
        _ = try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(dataRoot: dataRoot, phase: "final")
        return (expected, .init(id: hash, role: "host.approved-still-delivery", path: path, sha256: hash))
    }

    nonisolated static func recordStill(shotID: String, access: PipelinePlanningWriteAccess) throws -> CanonicalArtifactReferenceV1 {
        try access.revalidate()
        let root = access.dataRoot
        let record = try stillCandidate(shotID: shotID, dataRoot: root)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let frame = try PipelineProductionFramesWriter.requireFrame(shotID: shotID, role: "start", projection: projection, dataRoot: root)
        let bytes = try PlanningWriterIO.json(record)
        let hash = FileDigest.sha256(of: bytes)
        let path = "renders/still-deliveries/\(shotID)/\(hash).v1.json"
        let snapshot = try PipelineRenderRecordWriter.loadMutationSnapshot(dataRoot: root, phase: "final",
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        guard var proof = snapshot.proof, var routing = snapshot.routingProof else { throw changed() }
        var manifest = snapshot.manifest
        manifest.entries[shotID] = .init(shotId: shotID, phase: "final", status: .rendered, output: record.output.path,
            costEur: 0, updatedAt: currentTimestamp())
        proof.entries[shotID] = .init(shotId: shotID, output: record.output.path, outputSha256: record.output.sha256,
            providerPrompt: frame.providerPrompt, generationModel: frame.runwayModel)
        routing.entries.removeValue(forKey: shotID)
        let stills = ShotDeliveryModeResolverV1.stillShotIDs(in: projection.executionPlan).intersection(Set(manifest.entries.keys))
        _ = try PipelineRenderRecordWriter.publish(manifest: manifest, proof: proof, routingProof: routing,
            framesManifest: nil, replacingShotID: shotID, preparedLastFrame: nil,
            additionalArtifacts: [path: bytes, stillPath(shotID): bytes], stillShotIDs: stills,
            expectedPublicationTransactionID: snapshot.publication?.transactionID, dataRoot: root,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        try PipelinePhaseMutationRecorder.record(phase: "render", dataRoot: root, captureLineage: false,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        return try requireStill(shotID: shotID, dataRoot: root).reference
    }

    static func record(shotID: String, media: MediaAsset, access: PipelinePlanningWriteAccess,
                       editor: EditorViewModel) async throws -> Record {
        guard access.phase == "render", media.type == .video, media.generationStatus == .none,
              editor.mediaAssets.contains(where: { $0 === media }), let input = media.generationInput,
              let routing = input.productionRouting, routing.shotID == shotID else { throw changed() }
        let root = access.dataRoot
        let home = FrameInventory.projectHome(of: root)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        guard let shot = projection.shots.first(where: { $0.id == shotID }), shot.sourceMode != .imported,
              ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo else { throw changed() }
        let submission = try PipelineProductionSubmissionAuthority.prepare(media: media, editor: editor, dataRoot: root)
        let completed = try GenerationOutputReceipt.load(assetID: media.id, home: home)
        let takeID = PipelineRenderTakeStore.identity(eventID: media.id, outputSHA256: completed.output.sha256)
        let record: Record
        let existingPath = root.appendingPathComponent(recordPath(takeID))
        if FileManager.default.fileExists(atPath: existingPath.path) {
            record = try requireRecord(takeID: takeID, dataRoot: root)
            guard record.submission == submission.reference, record.shotID == shotID else { throw changed() }
        } else {
            let source = try ProjectLocalFile.requireHash(completed.output.sha256, at: completed.output.path, dataRoot: home)
            guard media.url.standardizedFileURL == source.standardizedFileURL else { throw changed() }
            let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "renders",
                leaf: takeID + "." + source.pathExtension.lowercased(), dataRoot: root)
            let destination = root.appendingPathComponent(path)
            let duration = try await Task.detached(priority: .userInitiated) {
                try ProductionWorkflowRecoveryMigration.requireNewOutput(path, dataRoot: root)
                _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: root)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                guard try FileDigest.sha256(of: destination) == completed.output.sha256 else { throw changed() }
                let asset = AVURLAsset(url: destination)
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration.value > 0, duration.timescale > 0,
                      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw changed() }
                if routing.requirement.requiresOutputAudio, (try await asset.loadTracks(withMediaType: .audio)).isEmpty { throw changed() }
                _ = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
                return duration
            }.value
            try access.revalidate()
            guard editor.workingRoot == home, media.generationInput == input,
                  try ProductionPlanningLineageV2.projection(dataRoot: root) == projection else { throw changed() }
            let projectionRef = try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
                id: "production-plan", role: "core.production-plan", dataRoot: root)
            record = Record(schema: "production-render-record/v1", projectKey: completed.projectKey,
                shotID: shotID, takeID: takeID, projection: projectionRef,
                generation: try PlanningWriterIO.reference(GenerationOutputReceipt.path(assetID: media.id),
                    id: media.id, role: "host.generation-output-receipt", dataRoot: home),
                submission: submission.reference,
                output: .init(id: takeID, role: "host.production-video", path: FrameInventory.relativePath(of: destination, to: home),
                    sha256: completed.output.sha256), durationValue: duration.value, durationTimescale: duration.timescale)
        }
        try publish(record: record, input: input, eventID: media.id, submissionFiles: submission.files,
            reviewedSelection: false, selection: nil, preparedLastFrame: nil, access: access)
        media.url = try ProjectLocalFile.resolve(record.output.path, dataRoot: home)
        return record
    }

    static func selectNative(snapshot: TakeReview.Snapshot, editor: EditorViewModel) async throws {
        guard editor.workingRoot == snapshot.home else { throw changed() }
        try await select(snapshot: snapshot, nativeRange: nil, editor: editor)
    }

    static func selectRangeNative(reviewID: String, editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { throw changed() }
        let range = try await Task.detached(priority: .userInitiated) {
            try ReviewedTakeRange.load(id: reviewID, dataRoot: root)
        }.value
        guard range.range.fps == editor.timeline.fps else { throw changed() }
        let snapshot = try await TakeReview.capture(takeID: range.takeID, home: home)
        guard snapshot.take.output == range.source, snapshot.durationValue == range.sourceDurationValue,
              snapshot.durationTimescale == range.sourceDurationTimescale else { throw changed() }
        _ = try await TakeReview.retainedAsset(snapshot: snapshot, editor: editor)
        try await select(snapshot: snapshot, nativeRange: (reviewID, range), editor: editor)
    }

    private static func select(snapshot: TakeReview.Snapshot, nativeRange: (id: String, range: ReviewedTakeRange)?,
                               editor: EditorViewModel) async throws {
        guard editor.workingRoot == snapshot.home else { throw changed() }
        let access = try PipelineNativeEditAccess(editor: editor, label: nativeRange == nil ? "Select reviewed take" : "Select reviewed take range")
        defer { access.end(editor: editor) }
        let timelineFPS = editor.timeline.fps
        let preparation = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "render")
            let sourceFence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: [recordPath(snapshot.take.id), TakeReview.path(takeID: snapshot.take.id)]
                    + (nativeRange.map { [ReviewedTakeRange.path(id: $0.id)] } ?? []))
            let record = try requireRecord(takeID: snapshot.take.id, dataRoot: access.root)
            guard record.output.path == snapshot.take.output.path, record.output.sha256 == snapshot.take.output.sha256,
                  record.durationValue == snapshot.durationValue, record.durationTimescale == snapshot.durationTimescale else { throw changed() }
            let completed = try GenerationOutputReceipt.load(assetID: record.generation.id, home: access.home)
            let generationFence = try PipelineNativeTakeSourceFence.capture([
                try ProjectLocalFile.resolve(record.generation.path, dataRoot: access.home),
                try ProjectLocalFile.resolve(completed.output.path, dataRoot: access.home),
                try ProjectLocalFile.resolve(completed.package.path, dataRoot: access.home)])
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: access.root)
            let reviewReference: CanonicalArtifactReferenceV1
            let endsAtSourceEnd: Bool
            if let nativeRange {
                let range = nativeRange.range
                guard try ReviewedTakeRange.load(id: nativeRange.id, dataRoot: access.root) == range,
                      range.range.fps == timelineFPS, projection.timebase.fpsDenominator > 0,
                      projection.timebase.fpsNumerator % projection.timebase.fpsDenominator == 0,
                      projection.timebase.fpsNumerator / projection.timebase.fpsDenominator == Int64(range.range.fps),
                      let timing = projection.timing(for: record.shotID),
                      CMTimeCompare(CMTime(value: Int64(range.range.endFrame), timescale: Int32(range.range.fps)),
                        CMTime(value: record.durationValue, timescale: record.durationTimescale)) <= 0,
                      try ProductionPlanAssemblyV1.coveringFrameCount(for: timing.durationTicks, timebase: projection.timebase)
                        == Int64(range.range.endFrame - range.range.startFrame),
                      range.source == snapshot.take.output, record.durationValue == range.sourceDurationValue,
                      record.durationTimescale == range.sourceDurationTimescale else { throw changed() }
                endsAtSourceEnd = CMTimeCompare(CMTime(value: Int64(range.range.endFrame), timescale: Int32(range.range.fps)),
                    CMTime(value: record.durationValue, timescale: record.durationTimescale)) == 0
                reviewReference = try PlanningWriterIO.reference(ReviewedTakeRange.path(id: nativeRange.id), id: nativeRange.id,
                    role: "host.native-take-range", dataRoot: access.root)
            } else {
                guard let review = try TakeReview.load(take: snapshot.take, dataRoot: access.root), review.accepted,
                      review.durationValue == record.durationValue, review.durationTimescale == record.durationTimescale else { throw changed() }
                let bytes = try Data(contentsOf: ProjectLocalFile.resolve(TakeReview.path(takeID: record.takeID), dataRoot: access.root))
                let hash = FileDigest.sha256(of: bytes)
                reviewReference = .init(id: record.takeID, role: "host.native-take-review",
                    path: "renders/takes/reviews/\(record.takeID)/\(hash).v1.json", sha256: hash)
                endsAtSourceEnd = true
            }
            let lastFrame: PipelineRenderRecordWriter.PreparedLastFrame?
            if endsAtSourceEnd, projection.chains.contains(where: { $0.predecessorShotID == record.shotID }) {
                lastFrame = try await prepareLastFrame(record: record, dataRoot: access.root)
            } else { lastFrame = nil }
            let selection = Selection(schema: "production-take-selection/v1", projectKey: record.projectKey,
                shotID: record.shotID, takeID: record.takeID,
                record: try PlanningWriterIO.reference(recordPath(record.takeID), id: record.takeID,
                    role: "host.production-render-record", dataRoot: access.root), review: reviewReference,
                durationValue: record.durationValue, durationTimescale: record.durationTimescale,
                lastFrame: lastFrame?.proof, nativeRange: nativeRange == nil ? nil : reviewReference)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "render")
                guard try requireRecord(takeID: record.takeID, dataRoot: staging) == record else { throw changed() }
                try publish(record: record, input: snapshot.take.generationInput, eventID: snapshot.take.generationEventID,
                    submissionFiles: [], reviewedSelection: true, selection: selection, preparedLastFrame: lastFrame, access: writer)
                _ = try requireSelected(shotID: record.shotID, dataRoot: staging)
                return selection
            }
            do {
                try sourceFence.requireUnchanged()
                try generationFence.requireUnchanged()
                return (transaction, sourceFence, generationFence)
            } catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        _ = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            if let nativeRange, editor.timeline.fps != nativeRange.range.range.fps { throw changed() }
            try result.1.requireCanonicalRootsUnchanged()
            try result.2.requireUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
    }

    nonisolated static func requireRecord(takeID: String, dataRoot: URL) throws -> Record {
        let record = try PlanningWriterIO.read(Record.self, at: recordPath(takeID), dataRoot: dataRoot)
        let home = FrameInventory.projectHome(of: dataRoot)
        let completed = try GenerationOutputReceipt.load(assetID: record.generation.id, home: home)
        guard record.schema == "production-render-record/v1", record.takeID == takeID,
              record.projectKey == ProjectIdentity.existingUUID(for: home), record.durationValue > 0, record.durationTimescale > 0,
              record.takeID == PipelineRenderTakeStore.identity(eventID: completed.assetID, outputSHA256: completed.output.sha256),
              record.output.sha256 == completed.output.sha256,
              record.shotID == completed.input.promptShotId else { throw changed() }
        for ref in [record.projection, record.generation, record.submission, record.output] {
            _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot)
        }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        guard try PlanningWriterIO.read(ProductionPlanProjectionV1.self, at: record.projection.path, dataRoot: dataRoot) == projection else { throw changed() }
        let binding = try PlanningWriterIO.read(RenderSubmissionBindingV1.self, at: record.submission.path, dataRoot: dataRoot)
        guard binding.shotID == record.shotID, binding.requestID == "host-event:" + completed.assetID else { throw changed() }
        try PipelineProductionSubmissionAuthority.requireBinding(binding, dataRoot)
        return record
    }

    nonisolated static func requireRecorded(shotID: String, dataRoot: URL) throws -> Record {
        let ref = try PlanningWriterIO.read(CanonicalArtifactReferenceV1.self, at: currentPath(shotID), dataRoot: dataRoot)
        guard ref.path == recordPath(ref.id) else { throw changed() }
        _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot)
        let record = try requireRecord(takeID: ref.id, dataRoot: dataRoot)
        let manifest = try loadRenderManifest(dataRoot: dataRoot, phase: "final")
        guard record.shotID == shotID, manifest.entries[shotID]?.output == record.output.path,
              manifest.entries[shotID]?.status == .rendered else { throw changed() }
        _ = try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(dataRoot: dataRoot, phase: "final")
        return record
    }

    nonisolated static func requireSelected(shotID: String, dataRoot: URL) throws -> (record: Record, selection: Selection, reference: CanonicalArtifactReferenceV1) {
        let selection = try PlanningWriterIO.read(Selection.self, at: selectionPath(shotID), dataRoot: dataRoot)
        let bytes = try PlanningWriterIO.json(selection)
        let hash = FileDigest.sha256(of: bytes)
        let path = "renders/selections/\(shotID)/\(hash).v1.json"
        guard try Data(contentsOf: ProjectLocalFile.resolve(selectionPath(shotID), dataRoot: dataRoot)) == bytes,
              try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)) == bytes else { throw changed() }
        let record = try requireRecorded(shotID: shotID, dataRoot: dataRoot)
        let take = try PipelineRenderTakeStore.take(id: selection.takeID, dataRoot: dataRoot, phase: "final")
        let index = try PipelineRenderTakeStore.load(dataRoot: dataRoot, project: take.project, phase: "final")
        guard selection.schema == "production-take-selection/v1", selection.shotID == shotID,
              selection.takeID == record.takeID, selection.projectKey == record.projectKey,
              index.selected[shotID] == record.takeID,
              selection.record.path == recordPath(record.takeID),
              selection.durationValue == record.durationValue, selection.durationTimescale == record.durationTimescale else { throw changed() }
        for ref in [selection.record, selection.review] { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        if let nativeRange = selection.nativeRange {
            let range = try ReviewedTakeRange.load(id: nativeRange.id, dataRoot: dataRoot)
            guard selection.review == nativeRange, nativeRange.path == ReviewedTakeRange.path(id: nativeRange.id),
                  range.takeID == take.id, range.source == take.output, range.sourceDurationValue == record.durationValue,
                  range.sourceDurationTimescale == record.durationTimescale else { throw changed() }
        } else {
            guard let review = try TakeReview.load(take: take, dataRoot: dataRoot), review.accepted,
                  review.durationValue == record.durationValue, review.durationTimescale == record.durationTimescale,
                  try PlanningWriterIO.read(TakeReview.self, at: selection.review.path, dataRoot: dataRoot) == review else { throw changed() }
        }
        if let frame = selection.lastFrame {
            let publication = try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(dataRoot: dataRoot, phase: "final")
            guard publication?.lastFrames[shotID] == frame, frame.sourceOutput == record.output.path,
                  frame.sourceOutputSHA256 == record.output.sha256, frame.extractor == RenderLastFrameProofV1.extractorID else { throw changed() }
            _ = try ProjectLocalFile.requireHash(frame.sha256, at: frame.path, dataRoot: dataRoot)
        }
        return (record, selection, .init(id: hash, role: "host.native-take-selection", path: path, sha256: hash))
    }

    struct SourceRange: Sendable {
        let timebase: SourceMediaTimebaseV1
        let fullDurationTicks: Int64
        let startTicks: Int64
        let endTicks: Int64
    }

    nonisolated static func sourceRange(record: Record, selection: Selection, dataRoot: URL) throws -> SourceRange {
        guard let reference = selection.nativeRange else {
            return .init(timebase: .init(ticksPerSecond: Int64(record.durationTimescale)),
                fullDurationTicks: record.durationValue, startTicks: 0, endTicks: record.durationValue)
        }
        let range = try ReviewedTakeRange.load(id: reference.id, dataRoot: dataRoot)
        guard range.takeID == record.takeID, range.sourceDurationValue == record.durationValue,
              range.sourceDurationTimescale == record.durationTimescale else { throw changed() }
        var a = Int64(range.range.fps), b = Int64(record.durationTimescale)
        while b != 0 { let next = a % b; a = b; b = next }
        let clockValue = (Int64(range.range.fps) / a).multipliedReportingOverflow(by: Int64(record.durationTimescale))
        guard !clockValue.overflow else { throw changed() }
        let clock = SourceMediaTimebaseV1(ticksPerSecond: clockValue.partialValue)
        try clock.validate()
        let full = record.durationValue.multipliedReportingOverflow(by: clock.ticksPerSecond / Int64(record.durationTimescale))
        let start = Int64(range.range.startFrame).multipliedReportingOverflow(by: clock.ticksPerSecond / Int64(range.range.fps))
        let end = Int64(range.range.endFrame).multipliedReportingOverflow(by: clock.ticksPerSecond / Int64(range.range.fps))
        guard !full.overflow, !start.overflow, !end.overflow, start.partialValue >= 0,
              start.partialValue < end.partialValue, end.partialValue <= full.partialValue else { throw changed() }
        return .init(timebase: clock, fullDurationTicks: full.partialValue, startTicks: start.partialValue, endTicks: end.partialValue)
    }

    nonisolated private static func publish(record: Record, input: GenerationInput, eventID: String,
        submissionFiles: [(path: String, bytes: Data)], reviewedSelection: Bool, selection: Selection?,
        preparedLastFrame: PipelineRenderRecordWriter.PreparedLastFrame?, access: PipelinePlanningWriteAccess) throws {
        let root = access.dataRoot
        try access.revalidate()
        let snapshot = try PipelineRenderRecordWriter.loadMutationSnapshot(dataRoot: root, phase: "final",
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        guard var proof = snapshot.proof, var routingProof = snapshot.routingProof,
              let routing = input.productionRouting else { throw changed() }
        var manifest = snapshot.manifest
        let entry = try renderProof(record: record, input: input)
        proof.entries[record.shotID] = entry
        routingProof.entries[record.shotID] = .init(shotID: record.shotID, output: record.output.path,
            outputSHA256: record.output.sha256, generation: routing)
        manifest.entries[record.shotID] = .init(shotId: record.shotID, phase: "final", status: .rendered,
            output: record.output.path, costEur: 0, updatedAt: currentTimestamp(), lastFramePath: preparedLastFrame?.proof.path,
            startFramePath: entry.startFrame?.path, referencePaths: entry.referenceImages.map(\.path))
        var files = Dictionary(uniqueKeysWithValues: submissionFiles.map { ($0.path, $0.bytes) })
        let recordBytes = try PlanningWriterIO.json(record)
        files[recordPath(record.takeID)] = recordBytes
        files[currentPath(record.shotID)] = try PlanningWriterIO.json(PlanningWriterIO.reference(recordPath(record.takeID),
            id: record.takeID, role: "host.production-render-record", bytes: recordBytes))
        if let selection {
            let bytes = try PlanningWriterIO.json(selection)
            files[selectionPath(record.shotID)] = bytes
            files["renders/selections/\(record.shotID)/\(FileDigest.sha256(of: bytes)).v1.json"] = bytes
        }
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
        let stills = ShotDeliveryModeResolverV1.stillShotIDs(in: projection.executionPlan).intersection(Set(manifest.entries.keys))
        _ = try PipelineRenderRecordWriter.publish(manifest: manifest, proof: proof, routingProof: routingProof,
            framesManifest: nil, replacingShotID: record.shotID, preparedLastFrame: preparedLastFrame,
            completedTake: .init(eventID: eventID, generationInput: input, reviewedSelection: reviewedSelection),
            additionalArtifacts: files, stillShotIDs: stills,
            expectedPublicationTransactionID: snapshot.publication?.transactionID, dataRoot: root,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
        try PipelinePhaseMutationRecorder.record(phase: "render", dataRoot: root, captureLineage: false,
            declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
            declaredProductionContract: access.declaration.productionContract)
    }

    nonisolated private static func prepareLastFrame(record: Record, dataRoot: URL) async throws -> PipelineRenderRecordWriter.PreparedLastFrame {
        let source = try ProjectLocalFile.requireHash(record.output.sha256, at: record.output.path, dataRoot: dataRoot)
        if let publication = try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(dataRoot: dataRoot, phase: "final"),
           let frame = publication.lastFrames[record.shotID], frame.sourceOutput == record.output.path,
           frame.sourceOutputSHA256 == record.output.sha256, frame.extractor == RenderLastFrameProofV1.extractorID {
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(frame.sha256, at: frame.path, dataRoot: dataRoot))
            return .init(proof: frame, data: bytes)
        }
        return try await Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await LastFrameExtractor.extractLastFrame(video: source, dest: temporary)
            let bytes = try Data(contentsOf: temporary)
            _ = try FrameRasterizer.loadImage(at: temporary)
            guard try FileDigest.sha256(of: source) == record.output.sha256 else { throw changed() }
            let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "renders",
                leaf: record.takeID + ".last_frame.png", dataRoot: dataRoot)
            try ProductionWorkflowRecoveryMigration.requireNewOutput(path, dataRoot: dataRoot)
            let homePath = FrameInventory.relativePath(of: dataRoot.appendingPathComponent(path), to: FrameInventory.projectHome(of: dataRoot))
            return .init(proof: .init(shotID: record.shotID, phase: "final", path: homePath,
                sha256: FileDigest.sha256(of: bytes), sourceOutput: record.output.path,
                sourceOutputSHA256: record.output.sha256, extractor: RenderLastFrameProofV1.extractorID,
                extractedAt: currentTimestamp()), data: bytes)
        }.value
    }

    nonisolated private static func renderProof(record: Record, input: GenerationInput) throws -> RenderProofEntry {
        guard let routing = input.productionRouting else { throw changed() }
        var source: RenderInputProof?, start: RenderInputProof?, end: RenderInputProof?
        var images: [RenderInputProof] = [], videos: [RenderInputProof] = [], audio: [RenderInputProof] = []
        for binding in routing.orderedBindings {
            let ref = RenderInputProof(path: binding.path, sha256: binding.sha256)
            switch binding.semanticJobID {
            case CoreReferenceSemanticJobIDV1.sourceVideo: guard source == nil else { throw changed() }; source = ref
            case CoreReferenceSemanticJobIDV1.firstFrame, CoreReferenceSemanticJobIDV1.predecessorLastFrame:
                guard start == nil else { throw changed() }; start = ref
            case CoreReferenceSemanticJobIDV1.lastFrame: guard end == nil else { throw changed() }; end = ref
            default:
                switch binding.modalityID {
                case "image": images.append(ref)
                case "video": videos.append(ref)
                case "audio": audio.append(ref)
                default: throw changed()
                }
            }
        }
        return RenderProofEntry(shotId: record.shotID, output: record.output.path, outputSha256: record.output.sha256,
            providerPrompt: input.prompt, generationModel: input.model, sourceVideo: source, startFrame: start, endFrame: end,
            referenceImages: images, referenceVideos: videos, referenceAudio: audio)
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("The rendered take or its approved inputs changed. Refresh the actual take and Render Review before recording or selecting it.")
    }
}
