import AppKit
import Foundation
import NexGenEngine

extension PipelineSpatialDerivationWriter {
    static func planningFrameReference(shotID: String, role: String, dataRoot: URL) throws -> CanonicalArtifactReferenceV1? {
        guard role == "start" || role == "end" else { throw GateBlocked("Choose the shot's start or end frame.") }
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
        guard let shot = draft.shots.first(where: { $0.shotID == shotID }) else { throw changed() }
        guard let derivation = shot.camera.spatialDerivation else { return nil }
        guard let state = shot.camera.spatialState, let camera = shot.camera.spatialCameraID,
              let scene = shot.camera.sceneReference else { throw changed() }
        let references = try planningDerivationReferences(reference: derivation, stateReference: state,
            cameraID: camera, sceneReference: scene, shotID: shotID, dataRoot: dataRoot)
        let proof = try JSONDecoder().decode(SpatialClaySequenceProof.self, from: bytes(derivation, dataRoot: dataRoot))
        let frame = role == "start" ? proof.request.startFrame : proof.request.endFrame
        let name = String(format: "clay-%08d.png", frame)
        let path = (derivation.path as NSString).deletingLastPathComponent + "/" + name
        guard let output = proof.outputs.first(where: { $0.filename == name }), output.mediaKind == "image/png",
              let reference = references.first(where: { $0.path == path && $0.sha256 == output.sha256 }),
              references.allSatisfy({ ref in draft.header.inputs.contains(where: { $0.path == ref.path && $0.sha256 == ref.sha256 }) }) else { throw changed() }
        return reference
    }

    private struct SequenceBinding: Codable, Sendable, Equatable {
        let shotID: String
        let state: CanonicalArtifactReferenceV1
        let cameraID: String
        let scene: CanonicalArtifactReferenceV1
        let intentSHA256: String
    }

    private struct SequenceAdoption: Codable, Sendable {
        var schema = "spatial-sequence-adoption/v1"
        let id: UUID
        let projectID: String
        let binding: SequenceBinding
        let draft: CanonicalArtifactReferenceV1
        let proof: CanonicalArtifactReferenceV1
        let sceneManifest: CanonicalArtifactReferenceV1
        let media: [String: CanonicalArtifactReferenceV1]
    }

    @MainActor
    static func renderPlanning(shotID: String, expectedState: CanonicalArtifactReferenceV1,
                               editor: EditorViewModel) async throws -> ShotPlanningDraftV1 {
        try PipelineShotPlanningEditor.requireAvailable(editor: editor)
        guard let home = editor.workingRoot, let key = editor.openWorkingCopyKey,
              let root = DataRootResolver.dataRoot(of: home),
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }),
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Render shot geometry") else {
            throw GateBlocked("Finish the current production action before rendering shot geometry.")
        }
        var holdsLease = true
        defer { if holdsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) } }
        let operation = try BpyRuntimeHost.shared.acquireOperation(document: document, documentID: key)
        defer { BpyRuntimeHost.shared.releaseOperation(operation) }
        let runtime = operation.session
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let input = try await background {
            _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "shot_planning")
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board)
            guard let shot = draft.shots.first(where: { $0.shotID == shotID }), shot.camera.spatialState == expectedState,
                  let cameraID = shot.camera.spatialCameraID, let sceneReference = shot.camera.sceneReference,
                  let head = try SpatialSceneStore.index(in: root).scenes.first(where: {
                      SpatialSceneStore.revisionPath(scene: $0.id, revision: $0.revision) + "/scene.blend" == sceneReference.path
                  }), let timing = board.timing.shots.first(where: { $0.id == shotID }) else { throw changed() }
            let context = try planningContext(shotID: shotID, scene: head, dataRoot: root)
            let state = try requirePlanningState(reference: expectedState, cameraID: cameraID,
                sceneReference: sceneReference, shotID: shotID, dataRoot: root)
            guard let camera = context.scene.snapshot.cameras.first(where: { $0.id == cameraID }) else { throw changed() }
            let owner = try PlanningWriterIO.reference(ShotPlanningDraftV1.versionPath(draft.header.revision),
                id: "spatial-sequence-source-draft", role: "core.shot-planning", dataRoot: root)
            let binding = SequenceBinding(shotID: shotID, state: expectedState, cameraID: cameraID, scene: sceneReference,
                intentSHA256: try cameraIntentFingerprint(shot.camera))
            let dimensions = try SpatialClayRenderer.renderDimensions(width: camera.width, height: camera.height)
            let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: owner.sha256,
                ownerBindingSHA256: FileDigest.sha256(of: try PlanningWriterIO.json(binding)), cameraID: cameraID,
                startFrame: 0, endFrame: context.frameCount - 1, width: dimensions.width, height: dimensions.height,
                samples: 32, stateSHA256: expectedState.sha256)
            let duration = SpatialClaySequenceTiming(numerator: timing.durationTicks, denominator: Int32(board.timing.timebase.ticksPerSecond))
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root,
                additionalCanonicalPaths: context.references.map(\.path) + draft.header.inputs.map(\.path))
            guard try planningContext(shotID: shotID, scene: head, dataRoot: root).fingerprint == context.fingerprint else { throw changed() }
            return (context, state, owner, binding, request, duration, fence)
        }
        try Task.checkCancellation()
        guard editor.workingRoot == home, BpyRuntimeHost.shared.isOperationActive(operation) else { throw changed() }
        let candidate = try await SpatialClayRenderer.prepareSequence(request: input.4, revision: input.0.scene, state: input.1,
            timing: input.5, runtime: runtime, runtimeRoot: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BpyRuntime"))
        defer { candidate.discard() }
        let transaction = try await background {
            try Task.checkCancellation()
            try input.6.requireUnchanged()
            try runtime.authenticateSpatialSequence(candidate, source: input.0.scene)
            let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "execution/blockout",
                leaf: "shot-\(candidate.proof.id.uuidString.lowercased())/sequence.v1.json", dataRoot: root)
            let directory = (path as NSString).deletingLastPathComponent
            let proof = PlanningWriterIO.reference(path, id: "spatial-sequence.\(candidate.proof.id)",
                role: "core.shot-spatial-derivation", bytes: candidate.proofData)
            let media = Dictionary(uniqueKeysWithValues: candidate.proof.outputs.map { output in
                (output.filename, CanonicalArtifactReferenceV1(id: "spatial-output." + FileDigest.sha256(of: Data((path + "/" + output.filename).utf8)),
                    role: output.filename == "clay.mov" ? "core.shot-clay-video" : "core.spatial-sequence-evidence",
                    path: directory + "/" + output.filename, sha256: output.sha256))
            })
            let adoption = SequenceAdoption(id: candidate.proof.id, projectID: input.0.draft.header.projectID,
                binding: input.3, draft: input.2, proof: proof, sceneManifest: manifestReference(input.0.scene), media: media)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                let access = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: declaration, phase: "shot_planning")
                for (name, reference) in media {
                    try Task.checkCancellation()
                    guard let source = candidate.files[name] else { throw changed() }
                    try ProductionWorkflowRecoveryMigration.requireNewOutput(reference.path, dataRoot: staging)
                    _ = try ProjectLocalFile.ensureDirectory((reference.path as NSString).deletingLastPathComponent, dataRoot: staging)
                    try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(reference.path))
                }
                for (file, data) in [(proof.path, candidate.proofData), (adoptionPath(candidate.proof.id), try PlanningWriterIO.json(adoption))] {
                    try requireNewMetadata(file, dataRoot: staging)
                    _ = try ProjectLocalFile.ensureDirectory((file as NSString).deletingLastPathComponent, dataRoot: staging)
                    try data.write(to: staging.appendingPathComponent(file), options: .atomic)
                }
                _ = try planningDerivationReferences(reference: proof, stateReference: expectedState, cameraID: input.3.cameraID,
                    sceneReference: input.3.scene, shotID: shotID, dataRoot: staging)
                let shot = input.0.shot, camera = shot.camera
                let replacement = ShotPlanningDraftV1.ShotIntent(shotID: shotID, sourceMode: shot.sourceMode, source: shot.source,
                    sourceObligationID: shot.sourceObligationID,
                    camera: .init(framing: camera.framing, movement: camera.movement, movementDetail: camera.movementDetail,
                        blocking: camera.blocking, sceneReference: camera.sceneReference, spatialState: camera.spatialState,
                        spatialCameraID: camera.spatialCameraID, spatialDerivation: proof),
                    obligations: shot.obligations, chainKind: shot.chainKind, predecessorShotID: shot.predecessorShotID,
                    narrativeBeat: shot.narrativeBeat, sourceInputRange: shot.sourceInputRange)
                return try PipelineShotPlanningWriter.write(shots: input.0.draft.shots.map { $0.shotID == shotID ? replacement : $0 },
                    origin: .userRevision, access: access)
            }
            do { try input.6.requireUnchanged(); return transaction }
            catch { transaction.discard(); throw error }
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
            try input.6.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: key)
        }
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
        holdsLease = false
        PipelineShotPlanningEditor.recordNativeAssignment(before: input.0.draft, after: result, editor: editor, name: "Render Shot Geometry")
        editor.onPipelineChanged?(); await editor.refreshEngineState()
        return result
    }

    static func planningDerivationReferences(reference: CanonicalArtifactReferenceV1, stateReference: CanonicalArtifactReferenceV1,
                                             cameraID: String, sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                             dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        let data = try bytes(reference, dataRoot: dataRoot)
        let proof = try JSONDecoder().decode(SpatialClaySequenceProof.self, from: data)
        let recordPath = adoptionPath(proof.id)
        let adoption = try PlanningWriterIO.read(SequenceAdoption.self, at: recordPath, dataRoot: dataRoot)
        let scene = try currentScene(proof.scene, dataRoot: dataRoot)
        let state = try requirePlanningState(reference: stateReference, cameraID: cameraID,
            sceneReference: sceneReference, shotID: shotID, dataRoot: dataRoot)
        let draft = try JSONDecoder().decode(ShotPlanningDraftV1.self, from: bytes(adoption.draft, dataRoot: dataRoot))
        guard let shot = draft.shots.first(where: { $0.shotID == shotID }),
              shot.camera.spatialState == stateReference, shot.camera.spatialCameraID == cameraID,
              shot.camera.sceneReference == sceneReference,
              adoption.schema == "spatial-sequence-adoption/v1", adoption.id == proof.id,
              adoption.projectID == draft.header.projectID, adoption.proof == reference,
              adoption.sceneManifest == manifestReference(scene), proof.request.owner == .shotPlanning, proof.state == state,
              adoption.binding == SequenceBinding(shotID: shotID, state: stateReference, cameraID: cameraID,
                  scene: sceneReference, intentSHA256: try cameraIntentFingerprint(shot.camera)),
              proof.request.ownerArtifactSHA256 == adoption.draft.sha256,
              proof.request.ownerBindingSHA256 == FileDigest.sha256(of: try PlanningWriterIO.json(adoption.binding)) else { throw changed() }
        let currentTiming = try PlanningWriterIO.read(StoryboardTimingV1.self, at: StoryboardTimingV1.currentPath, dataRoot: dataRoot)
        guard let planned = currentTiming.shots.first(where: { $0.id == shotID }),
              proof.timing.numerator == planned.durationTicks, Int64(proof.timing.denominator) == currentTiming.timebase.ticksPerSecond else { throw changed() }
        let directory = (reference.path as NSString).deletingLastPathComponent
        let parts = directory.split(separator: "/")
        guard parts.count == 4, parts[0] == "execution", parts[1] == "blockout", UUID(uuidString: String(parts[2])) != nil,
              parts[3] == "shot-\(proof.id.uuidString.lowercased())", reference.path == directory + "/sequence.v1.json",
              adoption.media["clay.mov"]?.role == "core.shot-clay-video" else { throw changed() }
        var files: [String: URL] = [:]
        for (name, media) in adoption.media {
            guard media.path == directory + "/" + name else { throw changed() }
            files[name] = try ProjectLocalFile.requireHash(media.sha256, at: media.path, dataRoot: dataRoot)
        }
        try SpatialClayRenderer.validateSequence(proofData: data, files: files, against: scene)
        return [reference, adoption.draft, adoption.sceneManifest,
            try PlanningWriterIO.reference(recordPath, id: "spatial-sequence-adoption.\(proof.id)", role: "core.spatial-adoption", dataRoot: dataRoot)]
            + Array(adoption.media.values) + (try planningStateReferences(reference: stateReference, cameraID: cameraID,
                sceneReference: sceneReference, shotID: shotID, dataRoot: dataRoot))
    }
}
