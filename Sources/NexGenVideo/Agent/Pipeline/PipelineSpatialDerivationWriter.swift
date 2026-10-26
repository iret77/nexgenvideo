import AppKit
import Foundation
import NexGenEngine

enum PipelineSpatialDerivationWriter {
    struct PreparedSketch: Sendable {
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

    struct StoryboardBinding: Codable, Sendable, Equatable {
        let shotID: String
        let momentID: String
        let intentSHA256: String
        let framingSHA256: String
    }

    struct PlanningStateSelection: Codable, Sendable {
        var schema = "spatial-shot-state-selection/v1"
        let id: UUID
        let projectID: String
        let shotID: String
        let cameraID: String
        let state: CanonicalArtifactReferenceV1
        let scene: SpatialSceneHead
        let sceneReference: CanonicalArtifactReferenceV1
        let sceneManifest: CanonicalArtifactReferenceV1
        let draft: CanonicalArtifactReferenceV1
        let storyboardTiming: CanonicalArtifactReferenceV1
        let intentSHA256: String
        let cameraIntent: ShotPlanningDraftV1.CameraIntent
        var authoringFrames: [Int]? = nil
    }

    struct PlanningContext: Sendable {
        let draft: ShotPlanningDraftV1
        let timing: StoryboardTimingV1
        let shot: ShotPlanningDraftV1.ShotIntent
        let scene: SpatialSceneRevision
        let sceneReference: CanonicalArtifactReferenceV1
        let references: [CanonicalArtifactReferenceV1]
        let frameCount: Int
        let fingerprint: String
    }

    private struct Adoption: Codable, Sendable {
        var schema = "spatial-derivation-adoption/v1"
        let id: UUID
        let projectID: String
        let ownerArtifact: CanonicalArtifactReferenceV1
        let storyboardBinding: StoryboardBinding?
        let proof: CanonicalArtifactReferenceV1
        let media: [String: CanonicalArtifactReferenceV1]
        let sceneManifest: CanonicalArtifactReferenceV1
    }

    @MainActor
    static func renderStoryboard(shotID: String, momentID: String, scene: SpatialSceneHead, cameraID: String,
                                  expectedFingerprint: String, editor: EditorViewModel) async throws -> StoryboardBundleSnapshot {
        try PipelineStoryboardEditor.requireAvailable(editor: editor)
        guard let home = editor.workingRoot, let key = editor.openWorkingCopyKey,
              let root = DataRootResolver.dataRoot(of: home),
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }),
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Render Storyboard view") else {
            throw GateBlocked("Finish the current production action before creating a Storyboard view.")
        }
        var holdsLease = true
        defer { if holdsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) } }
        let operation = try BpyRuntimeHost.shared.acquireOperation(document: document, documentID: key)
        defer { BpyRuntimeHost.shared.releaseOperation(operation) }
        let runtime = operation.session
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let input = try await background {
            _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "storyboard")
            let before = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
            let revision = try currentScene(scene, dataRoot: root)
            guard before.fingerprint == expectedFingerprint,
                  let shot = before.timing.shots.first(where: { $0.id == shotID }),
                  let moment = shot.moments.first(where: { $0.id == momentID }),
                  let camera = revision.snapshot.cameras.first(where: { $0.id == cameraID }) else { throw changed() }
            let binding = StoryboardBinding(shotID: shotID, momentID: momentID,
                intentSHA256: FileDigest.sha256(of: Data(moment.intent.utf8)), framingSHA256: try shot.framing.fingerprint())
            let owner = try PlanningWriterIO.reference(StoryboardTimingV1.versionPath(before.timing.header.revision),
                id: "spatial-storyboard-source", role: "core.storyboard-timing", dataRoot: root)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root,
                additionalCanonicalPaths: before.references.map(\.path) + (try sceneReferences(dataRoot: root)).map(\.path))
            guard try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
            try fence.requireUnchanged()
            let dimensions = try SpatialClayRenderer.renderDimensions(width: camera.width, height: camera.height)
            let request = SpatialClayRequest(owner: .storyboard, ownerArtifactSHA256: owner.sha256,
                ownerBindingSHA256: FileDigest.sha256(of: try PlanningWriterIO.json(binding)), cameraID: cameraID,
                startFrame: revision.snapshot.restFrame, endFrame: revision.snapshot.restFrame,
                width: dimensions.width, height: dimensions.height, samples: 32, stateSHA256: nil)
            return (before, revision, binding, owner, fence, request)
        }
        try Task.checkCancellation()
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              BpyRuntimeHost.shared.isOperationActive(operation) else { throw changed() }
        let candidate = try await SpatialClayRenderer.prepare(request: input.5, revision: input.1, runtime: runtime,
            runtimeRoot: runtime.bundledRuntimeRoot)
        let transaction = try await background {
            try Task.checkCancellation()
            try input.4.requireUnchanged()
            try runtime.authenticateSpatialDerivation(candidate, source: input.1)
            let prepared = try prepareSketch(candidate, owner: input.3, binding: input.2,
                projectID: input.0.storyboard.header.projectID, revision: input.1, dataRoot: root)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                let access = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: declaration, phase: "storyboard")
                guard try PlanningWriterIO.storyboard(dataRoot: staging, requireVisuals: false).fingerprint == expectedFingerprint else { throw changed() }
                return try PipelineStoryboardBundleWriter.write(
                    PipelineStoryboardBundleWriter.proposal(from: input.0, replacing: momentID, in: shotID, with: prepared.asset),
                    origin: .userRevision, access: access, derivedSketches: [prepared])
            }
            do {
                try input.4.requireUnchanged()
                return transaction
            } catch { transaction.discard(); throw error }
        }
        defer { Task.detached { transaction.discard() } }
        try Task.checkCancellation()
        let result = try transaction.commit { _ in
            guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
                  editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
                  editor.declaredProductionContract == declaration.productionContract,
                  !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
                  editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease),
                  BpyRuntimeHost.shared.isOperationActive(operation) else { throw changed() }
            try input.4.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: key)
        }
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
        holdsLease = false
        PipelineStoryboardEditor.recordNativeAssignment(before: input.0, after: result, editor: editor)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return result
    }

    private static func prepareSketch(_ candidate: SpatialClayCandidate, owner: CanonicalArtifactReferenceV1,
                                       binding: StoryboardBinding, projectID: String,
                                       revision: SpatialSceneRevision, dataRoot: URL) throws -> PreparedSketch {
        try SpatialClayRenderer.validate(candidate, against: revision)
        guard candidate.proof.request.owner == .storyboard, candidate.proof.outputs.count == 1,
              let output = candidate.proof.outputs.first, output.mediaKind == "image/png" else { throw changed() }
        let proofPath = try ProductionWorkflowRecoveryMigration.outputPath(area: "storyboard/sketches",
            leaf: "spatial-\(candidate.proof.id.uuidString.lowercased())/derivation.v1.json", dataRoot: dataRoot)
        let directory = (proofPath as NSString).deletingLastPathComponent
        let derivation = PlanningWriterIO.reference(directory + "/derivation.v1.json", id: "spatial-derivation.\(candidate.proof.id)",
            role: "core.spatial-derivation", bytes: candidate.proofData)
        let image = CanonicalArtifactReferenceV1(id: "spatial-sketch.\(candidate.proof.id)", role: "core.storyboard-sketch",
            path: directory + "/" + output.filename, sha256: output.sha256)
        let proof = StoryboardSketchProofV1(projectID: projectID, shotID: binding.shotID, momentID: binding.momentID,
            intentSHA256: binding.intentSHA256, framingSHA256: binding.framingSHA256, image: image,
            source: .spatialDerived(proof: derivation))
        try proof.validate()
        let proofData = try PlanningWriterIO.json(proof)
        let proofReference = PlanningWriterIO.reference(directory + "/sketch-proof.v1.json", id: "sketch-proof.\(candidate.proof.id)",
            role: "core.storyboard-sketch-proof", bytes: proofData)
        let adoption = Adoption(id: candidate.proof.id, projectID: projectID, ownerArtifact: owner, storyboardBinding: binding,
            proof: derivation, media: [output.filename: image], sceneManifest: manifestReference(revision))
        let files: [(path: String, bytes: Data)] = candidate.files.map { (directory + "/" + $0.key, $0.value) }
            + [(derivation.path, candidate.proofData), (proofReference.path, proofData),
               (adoptionPath(candidate.proof.id), try PlanningWriterIO.json(adoption))]
        return PreparedSketch(targetShotID: binding.shotID, targetMomentID: binding.momentID,
            asset: .init(image: image, proof: proofReference), files: files)
    }

    static func background<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func planningContext(shotID: String, scene head: SpatialSceneHead, dataRoot: URL) throws -> PlanningContext {
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: storyboard)
        let scene = try currentScene(head, dataRoot: dataRoot)
        guard let shot = draft.shots.first(where: { $0.shotID == shotID }),
              let planned = storyboard.timing.shots.first(where: { $0.id == shotID }) else { throw changed() }
        let source = CanonicalArtifactReferenceV1(id: "spatial-scene.\(head.id)", role: "core.production-spatial",
            path: scenePath(scene), sha256: scene.manifest.sceneSHA256)
        let references = storyboard.references + (try sceneReferences(dataRoot: dataRoot))
            + [try PlanningWriterIO.reference(ShotPlanningDraftV1.currentPath, id: "planning.current", role: "core.shot-planning", dataRoot: dataRoot)]
        return PlanningContext(draft: draft, timing: storyboard.timing, shot: shot, scene: scene, sceneReference: source,
            references: references, frameCount: try frameCount(durationTicks: planned.durationTicks, timebase: storyboard.timing.timebase, scene: scene),
            fingerprint: FileDigest.sha256(of: try PlanningWriterIO.json(references)))
    }

    @MainActor
    static func recordPlanningState(_ state: SpatialClayState, context: PlanningContext,
                                     editor: EditorViewModel, authoringFrames: [Int]? = nil) async throws -> ShotPlanningDraftV1 {
        try PipelineShotPlanningEditor.requireAvailable(editor: editor)
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home), let key = editor.openWorkingCopyKey,
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Confirm shot state") else {
            throw GateBlocked("Finish the current production action before confirming this shot state.")
        }
        var holdsLease = true
        defer { if holdsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) } }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let publication = try await background {
            let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "shot_planning")
            let scene = SpatialSceneHead(id: context.scene.manifest.sceneID, name: context.scene.manifest.name,
                revision: context.scene.manifest.revision, manifestSHA256: FileDigest.sha256(of: context.scene.manifestData))
            let current = try planningContext(shotID: context.shot.shotID, scene: scene, dataRoot: root)
            guard current.fingerprint == context.fingerprint,
                  state.frames.map(\.frame) == Array(0..<context.frameCount),
                  let camera = context.scene.snapshot.cameras.first(where: { $0.id == state.cameraID }) else { throw changed() }
            let id = UUID()
            _ = try SpatialShotPoseTimeline(state: state, authoringFrames: authoringFrames)
            let directory = stateDirectory(id)
            let stateBytes = try SpatialSceneStore.encode(state)
            let reference = PlanningWriterIO.reference(directory + "/state.v1.json", id: "spatial-state.\(id)",
                role: "core.shot-spatial-state", bytes: stateBytes)
            let original = context.shot
            let intent = ShotPlanningDraftV1.CameraIntent(framing: original.camera.framing, movement: original.camera.movement,
                movementDetail: original.camera.movementDetail, blocking: original.camera.blocking, sceneReference: context.sceneReference)
            let intentHash = try cameraIntentFingerprint(intent)
            let draftRef = try PlanningWriterIO.reference(ShotPlanningDraftV1.versionPath(context.draft.header.revision),
                id: "spatial-state-source-draft", role: "core.shot-planning", dataRoot: root)
            let timingRef = try PlanningWriterIO.reference(StoryboardTimingV1.versionPath(context.timing.header.revision),
                id: "spatial-state-source-timing", role: "core.storyboard-timing", dataRoot: root)
            let record = PlanningStateSelection(id: id,
                projectID: context.draft.header.projectID, shotID: original.shotID, cameraID: state.cameraID,
                state: reference, scene: scene, sceneReference: context.sceneReference, sceneManifest: manifestReference(context.scene),
                draft: draftRef, storyboardTiming: timingRef, intentSHA256: intentHash, cameraIntent: intent, authoringFrames: authoringFrames)
            let dimensions = try SpatialClayRenderer.renderDimensions(width: camera.width, height: camera.height)
            let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: draftRef.sha256,
                ownerBindingSHA256: intentHash, cameraID: state.cameraID, startFrame: 0, endFrame: context.frameCount - 1,
                width: dimensions.width, height: dimensions.height, samples: 32, stateSHA256: reference.sha256)
            try SpatialClayRenderer.validateSequenceState(state, request: request, revision: context.scene)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root,
                additionalCanonicalPaths: context.references.map(\.path))
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                let access = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: declaration, phase: "shot_planning")
                let files = [(reference.path, stateBytes), (directory + "/selection.v1.json", try PlanningWriterIO.json(record))]
                for (path, data) in files {
                    try requireNewMetadata(path, dataRoot: staging)
                    _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: staging)
                    try data.write(to: staging.appendingPathComponent(path), options: .atomic)
                }
                let cameraIntent = ShotPlanningDraftV1.CameraIntent(framing: intent.framing, movement: intent.movement,
                    movementDetail: intent.movementDetail, blocking: intent.blocking, sceneReference: intent.sceneReference,
                    spatialState: reference, spatialCameraID: state.cameraID)
                let changed = ShotPlanningDraftV1.ShotIntent(shotID: original.shotID, sourceMode: original.sourceMode,
                    source: original.source, sourceObligationID: original.sourceObligationID, camera: cameraIntent,
                    obligations: original.obligations, chainKind: original.chainKind, predecessorShotID: original.predecessorShotID,
                    narrativeBeat: original.narrativeBeat, sourceInputRange: original.sourceInputRange)
                return try PipelineShotPlanningWriter.write(shots: context.draft.shots.map { $0.shotID == original.shotID ? changed : $0 },
                    origin: .userRevision, access: access)
            }
            do {
                try access.revalidate()
                try fence.requireUnchanged()
                guard try planningContext(shotID: original.shotID, scene: scene, dataRoot: root).fingerprint == context.fingerprint else { throw changed() }
                return (transaction, fence)
            } catch { transaction.discard(); throw error }
        }
        defer { Task.detached { publication.0.discard() } }
        try Task.checkCancellation()
        let result = try publication.0.commit { _ in
            guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
                  editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
                  editor.declaredProductionContract == declaration.productionContract,
                  !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
                  editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else { throw changed() }
            try publication.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: key)
        }
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
        holdsLease = false
        PipelineShotPlanningEditor.recordNativeAssignment(before: context.draft, after: result, editor: editor, name: "Confirm Shot State")
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return result
    }

    private static func frameCount(durationTicks: Int64, timebase: RationalTimebaseV1, scene: SpatialSceneRevision) throws -> Int {
        guard durationTicks > 0, scene.snapshot.timebaseNumerator > 0, scene.snapshot.timebaseDenominator > 0 else { throw changed() }
        var value = Decimal(durationTicks) * Decimal(scene.snapshot.timebaseNumerator)
            / Decimal(timebase.ticksPerSecond) / Decimal(scene.snapshot.timebaseDenominator)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .up)
        guard rounded > 0, rounded <= 1_000_000 else { throw GateBlocked("The planned shot has an unsupported spatial time range.") }
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static func requirePlanningState(reference: CanonicalArtifactReferenceV1, cameraID: String,
                                     sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                     dataRoot: URL) throws -> SpatialClayState {
        try validatedPlanningState(reference: reference, cameraID: cameraID, sceneReference: sceneReference,
            shotID: shotID, dataRoot: dataRoot).state
    }

    static func planningStateReferences(reference: CanonicalArtifactReferenceV1, cameraID: String,
                                         sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                         dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        try validatedPlanningState(reference: reference, cameraID: cameraID, sceneReference: sceneReference,
            shotID: shotID, dataRoot: dataRoot).references
    }

    static func planningPoseTimeline(reference: CanonicalArtifactReferenceV1, cameraID: String,
                                     sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                     dataRoot: URL) throws -> SpatialShotPoseTimeline {
        let validated = try validatedPlanningState(reference: reference, cameraID: cameraID,
            sceneReference: sceneReference, shotID: shotID, dataRoot: dataRoot)
        return try SpatialShotPoseTimeline(state: validated.state, authoringFrames: validated.authoringFrames)
    }

    private static func validatedPlanningState(reference: CanonicalArtifactReferenceV1, cameraID: String,
                                               sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                               dataRoot: URL) throws -> (state: SpatialClayState, references: [CanonicalArtifactReferenceV1], authoringFrames: [Int]?) {
        let directory = (reference.path as NSString).deletingLastPathComponent
        guard reference.path == directory + "/state.v1.json",
              directory.hasPrefix("shot-planning/spatial-states/"),
              let id = UUID(uuidString: (directory as NSString).lastPathComponent),
              directory == stateDirectory(id) else { throw changed() }
        let selectionPath = directory + "/selection.v1.json"
        let record = try PlanningWriterIO.read(PlanningStateSelection.self, at: selectionPath, dataRoot: dataRoot)
        let state = try JSONDecoder().decode(SpatialClayState.self, from: bytes(reference, dataRoot: dataRoot))
        let scene = try currentScene(record.scene, dataRoot: dataRoot)
        let draft = try JSONDecoder().decode(ShotPlanningDraftV1.self, from: bytes(record.draft, dataRoot: dataRoot))
        let timing = try JSONDecoder().decode(StoryboardTimingV1.self, from: bytes(record.storyboardTiming, dataRoot: dataRoot))
        guard record.schema == "spatial-shot-state-selection/v1", record.id == id,
              record.projectID == draft.header.projectID, record.projectID == timing.header.projectID,
              record.shotID == shotID, record.cameraID == cameraID,
              record.state == reference, record.sceneReference == sceneReference,
              record.sceneManifest == manifestReference(scene),
              sceneReference.path == scenePath(scene), sceneReference.sha256 == scene.manifest.sceneSHA256,
              state.cameraID == cameraID, state.sceneManifestSHA256 == record.scene.manifestSHA256,
              let original = draft.shots.first(where: { $0.shotID == shotID }),
              record.cameraIntent.sceneReference == sceneReference,
              record.cameraIntent.framing == original.camera.framing,
              record.cameraIntent.movement == original.camera.movement,
              record.cameraIntent.movementDetail == original.camera.movementDetail,
              record.cameraIntent.blocking == original.camera.blocking,
              try cameraIntentFingerprint(record.cameraIntent) == record.intentSHA256,
              let planned = timing.shots.first(where: { $0.id == shotID }) else { throw changed() }
        try draft.header.requireCurrentInputs(dataRoot: dataRoot)
        let currentTiming = try PlanningWriterIO.read(StoryboardTimingV1.self, at: StoryboardTimingV1.currentPath, dataRoot: dataRoot)
        guard currentTiming.header.projectID == record.projectID,
              currentTiming.timebase == timing.timebase,
              currentTiming.shots.first(where: { $0.id == shotID }) == planned else { throw changed() }
        let currentDraft = try PlanningWriterIO.read(ShotPlanningDraftV1.self, at: ShotPlanningDraftV1.currentPath, dataRoot: dataRoot)
        if let current = currentDraft.shots.first(where: { $0.shotID == shotID }), current.camera.spatialState == reference {
            guard try cameraIntentFingerprint(current.camera) == record.intentSHA256 else { throw changed() }
        }
        guard let first = state.frames.first, let last = state.frames.last,
              let camera = scene.snapshot.cameras.first(where: { $0.id == cameraID }) else { throw changed() }
        let dimensions = try SpatialClayRenderer.renderDimensions(width: camera.width, height: camera.height)
        let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: record.draft.sha256,
            ownerBindingSHA256: record.intentSHA256, cameraID: cameraID, startFrame: first.frame, endFrame: last.frame,
            width: dimensions.width, height: dimensions.height, samples: 32, stateSHA256: reference.sha256)
        guard state.frames.map(\.frame) == Array(0..<(try frameCount(durationTicks: planned.durationTicks, timebase: timing.timebase, scene: scene))) else { throw changed() }
        try SpatialClayRenderer.validateSequenceState(state, request: request, revision: scene)
        let references = [reference, record.sceneReference, record.sceneManifest, record.draft, record.storyboardTiming,
            try PlanningWriterIO.reference(selectionPath, id: "spatial-state-selection.\(id)",
                role: "core.spatial-state-selection", dataRoot: dataRoot)] + (try sceneReferences(dataRoot: dataRoot))
        _ = try SpatialShotPoseTimeline(state: state, authoringFrames: record.authoringFrames)
        return (state, references, record.authoringFrames)
    }

    static func requireStoryboardSketch(_ sketch: StoryboardSketchProofV1, dataRoot: URL) throws {
        _ = try storyboardReferences(sketch, dataRoot: dataRoot)
    }

    static func storyboardReferences(_ sketch: StoryboardSketchProofV1, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        guard case .spatialDerived(let reference) = sketch.source else { throw changed() }
        let proof = try JSONDecoder().decode(SpatialDerivationProof.self, from: bytes(reference, dataRoot: dataRoot))
        let recordPath = adoptionPath(proof.id)
        let adoption = try PlanningWriterIO.read(Adoption.self, at: recordPath, dataRoot: dataRoot)
        let directory = (reference.path as NSString).deletingLastPathComponent
        let components = directory.split(separator: "/")
        guard adoption.schema == "spatial-derivation-adoption/v1", adoption.id == proof.id,
              adoption.projectID == sketch.projectID, adoption.proof == reference,
              proof.request.owner == .storyboard, let binding = adoption.storyboardBinding,
              binding == StoryboardBinding(shotID: sketch.shotID, momentID: sketch.momentID,
                  intentSHA256: sketch.intentSHA256, framingSHA256: sketch.framingSHA256),
              proof.request.ownerBindingSHA256 == FileDigest.sha256(of: try PlanningWriterIO.json(binding)),
              proof.request.ownerArtifactSHA256 == adoption.ownerArtifact.sha256,
              proof.outputs.count == 1,
              adoption.media.values.contains(sketch.image), components.count == 4,
              components[0] == "storyboard", components[1] == "sketches", UUID(uuidString: String(components[2])) != nil,
              components[3] == "spatial-\(proof.id.uuidString.lowercased())" else { throw changed() }
        let timing = try JSONDecoder().decode(StoryboardTimingV1.self, from: bytes(adoption.ownerArtifact, dataRoot: dataRoot))
        guard timing.header.projectID == sketch.projectID,
              let shot = timing.shots.first(where: { $0.id == sketch.shotID }),
              let moment = shot.moments.first(where: { $0.id == sketch.momentID }),
              FileDigest.sha256(of: Data(moment.intent.utf8)) == binding.intentSHA256,
              try shot.framing.fingerprint() == binding.framingSHA256 else { throw changed() }
        let scene = try currentScene(proof.scene, dataRoot: dataRoot)
        guard adoption.sceneManifest == manifestReference(scene) else { throw changed() }
        var files: [String: Data] = [:]
        for (name, media) in adoption.media {
            guard media.path == directory + "/" + name else { throw changed() }
            files[name] = try bytes(media, dataRoot: dataRoot)
        }
        guard reference.path == directory + "/derivation.v1.json" else { throw changed() }
        try SpatialClayRenderer.validate(.init(proof: proof, proofData: bytes(reference, dataRoot: dataRoot), files: files), against: scene)
        return [reference, adoption.ownerArtifact, adoption.sceneManifest,
            try PlanningWriterIO.reference(recordPath, id: "spatial-adoption.\(proof.id)",
                role: "core.spatial-adoption", dataRoot: dataRoot)] + Array(adoption.media.values) + (try sceneReferences(dataRoot: dataRoot))
    }

    static func cameraIntentFingerprint(_ camera: ShotPlanningDraftV1.CameraIntent) throws -> String {
        let value = ShotPlanningDraftV1.CameraIntent(framing: camera.framing, movement: camera.movement,
            movementDetail: camera.movementDetail, blocking: camera.blocking, sceneReference: camera.sceneReference)
        return FileDigest.sha256(of: try PlanningWriterIO.json(value))
    }

    static func currentScene(_ head: SpatialSceneHead, dataRoot: URL) throws -> SpatialSceneRevision {
        _ = try sceneReferences(dataRoot: dataRoot)
        guard try SpatialSceneStore.index(in: dataRoot).scenes.contains(head) else { throw changed() }
        return try SpatialSceneStore.load(head, in: dataRoot)
    }

    static func sceneReferences(dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        guard let inventory = try ProductionSpatialInventoryV1.loadIfPresent(dataRoot: dataRoot) else { throw changed() }
        try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: dataRoot)
        return inventory.references + [try PlanningWriterIO.reference(ProductionSpatialInventoryV1.currentPath,
            id: "spatial-inventory", role: "core.production-spatial", dataRoot: dataRoot)]
    }

    static func manifestReference(_ scene: SpatialSceneRevision) -> CanonicalArtifactReferenceV1 {
        PlanningWriterIO.reference(SpatialSceneStore.revisionPath(scene: scene.manifest.sceneID, revision: scene.manifest.revision) + "/manifest.v1.json",
            id: "spatial-scene.\(scene.manifest.sceneID)", role: "core.production-spatial", bytes: scene.manifestData)
    }

    static func scenePath(_ scene: SpatialSceneRevision) -> String {
        SpatialSceneStore.revisionPath(scene: scene.manifest.sceneID, revision: scene.manifest.revision) + "/scene.blend"
    }
    private static func stateDirectory(_ id: UUID) -> String { "shot-planning/spatial-states/\(id.uuidString.lowercased())" }
    static func adoptionPath(_ id: UUID) -> String { "pipeline/spatial-adoptions/\(id.uuidString.lowercased()).v1.json" }
    static func requireNewMetadata(_ path: String, dataRoot: URL) throws {
        let url = dataRoot.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url, !FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw changed() }
    }
    static func bytes(_ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
    }
    static func changed() -> GateBlocked {
        GateBlocked("The location, camera or confirmed shot state changed. Review the current planning before creating this view.")
    }
}
