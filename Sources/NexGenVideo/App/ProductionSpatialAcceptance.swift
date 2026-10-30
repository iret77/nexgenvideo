import AppKit
import NexGenEngine

@MainActor
enum ProductionSpatialAcceptance {
    static func run(output: URL) async throws -> [String: Any] {
        var opened: ProductionPlanningAcceptanceFixture.Context?
        var selectedScene: SpatialSceneHead?
        var nativeSceneUI: [[String: Any]] = []
        var postCommitCancellation: [String: String] = [:]
        var hashCancellation: [String: String] = [:]
        defer { opened?.document.close() }
        let context = try await ProductionPlanningAcceptanceFixture.makeScript { value in
            opened = value
            NSDocumentController.shared.addDocument(value.document)
            let native = try await ProductionSceneUIAcceptance.run(context: value, output: output)
            selectedScene = native.0; nativeSceneUI = native.1
            postCommitCancellation = try await ProductionSpatialCommitCancellationAcceptance.run(context: value, output: output)
            hashCancellation = try await ProductionSpatialHashCancellationAcceptance.run(context: value, output: output)
        }
        guard let selectedScene else { throw failed("The real location was not retained.") }
        let root = context.dataRoot
        let scene = try SpatialSceneStore.load(selectedScene, in: root)
        guard let camera = scene.snapshot.cameras.first else { throw failed("No camera is available.") }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        var board = try await ProductionPlanningAcceptanceFixture.attachSketches(in: context)
        let nativeStoryboardUI = try await ProductionVisualSourcesAcceptance.storyboard(context: context, output: output,
            sourceVideo: output.appendingPathComponent("complete-shot/clay.mov"))
        board = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        guard let shot = board.timing.shots.first, let moment = shot.moments.first else { throw failed("No Storyboard moment is available.") }
        let nativeSpatialStoryboardUI = try await ProductionSpatialClayAcceptance.storyboard(context: context, scene: selectedScene,
            cameraID: camera.id, shotID: shot.id, momentID: moment.id, output: output)
        board = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        guard let visual = board.timing.shots.first?.moments.first?.asset else { throw failed("The actual location sketch was not assigned.") }
        let sketchProof = try PlanningWriterIO.read(StoryboardSketchProofV1.self, at: visual.proof.path, dataRoot: root)
        try PipelineSpatialDerivationWriter.requireStoryboardSketch(sketchProof, dataRoot: root)
        let sketchBytes = try Data(contentsOf: ProjectLocalFile.requireHash(visual.image.sha256, at: visual.image.path, dataRoot: root))
        try sketchBytes.write(to: output.appendingPathComponent("production-spatial-storyboard.png"), options: .atomic)
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: context)
        let nativePoseUI = try await ProductionSpatialPoseAcceptance.run(context: context, scene: selectedScene,
            cameraID: camera.id, shotID: shot.id, output: output)
        let nativePlanUI = try await ProductionRetainedSpatialAcceptance.blockout(context: context, shotID: shot.id, imported: false, output: output)
        let nativeClayUI = try await ProductionSpatialClayAcceptance.run(context: context, shotID: shot.id, output: output)
        let withVideo = try await Task.detached {
            try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root))
        }.value
        guard withVideo.shots.first?.camera.spatialDerivation != nil else { throw failed("The full shot video was not recorded.") }
        let endpoints = try await Task.detached(priority: .userInitiated) {
            (try PipelineSpatialDerivationWriter.planningFrameReference(shotID: shot.id, role: "start", dataRoot: root),
             try PipelineSpatialDerivationWriter.planningFrameReference(shotID: shot.id, role: "end", dataRoot: root))
        }.value
        guard let start = endpoints.0, let end = endpoints.1, start.path != end.path, start.sha256 != end.sha256 else {
            throw failed("Distinct planned poses did not produce distinct start and end images.")
        }
        try await Task.detached(priority: .userInitiated) {
            guard let video = withVideo.header.inputs.first(where: { $0.role == "core.shot-clay-video" }),
                  let proof = withVideo.shots.first?.camera.spatialDerivation else { throw GateBlocked("The recorded Clay output is missing.") }
            for (reference, name) in [(start, "production-spatial-start.png"), (end, "production-spatial-end.png"),
                                      (video, "production-spatial-shot.mov"), (proof, "production-spatial-shot-proof.json")] {
                try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root),
                    to: output.appendingPathComponent(name))
            }
        }.value
        let nativeBlockoutImportUI = try await ProductionRetainedSpatialAcceptance.blockout(context: context, shotID: shot.id, imported: true, output: output)
        try await ProductionPlanningAcceptanceFixture.approve("shot_planning", in: context)
        try await ProductionPlanningAcceptanceFixture.writeBible(in: context)
        let baseline = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
        let appearance = try await ProductionRetainedSpatialAcceptance.prepareAppearanceFixture(context: context,
            locationID: "pale_room", locationName: "Pale room")
        let location = try Location(id: "pale_room", name: "Pale room", visualPrompt: "A neutral room around one cube.",
            referenceImages: ["production_design/refs/lighting.png"], sheets: ["owner_appearance": appearance])
        var withLocation = baseline
        withLocation.locations = [location]
        try await ProductionPlanningAcceptanceFixture.run("write_bible", args: ProductionBibleToolFixture.arguments(withLocation), in: context)
        let nativePanoramaUI = try await ProductionRetainedSpatialAcceptance.panorama(context: context, locationID: location.id, output: output)
        let nativeBibleUI = try await ProductionVisualSourcesAcceptance.bible(context: context, output: output,
            scene: selectedScene, cameraID: camera.id, locationID: location.id)
        let expected = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
        let view = try await PipelineSpatialDerivationWriter.prepareBibleView(locationID: location.id, viewID: "wide",
            purpose: "Show the complete room and its cube.", scene: selectedScene, cameraID: camera.id,
            expectedBibleSHA256: expected, editor: context.editor)
        guard NSImage(data: view.imageData) != nil else { throw failed("The native Bible preview is not readable.") }
        try await PipelineSpatialDerivationWriter.confirmBibleView(view, editor: context.editor)
        let after = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
        var staleRejected = false
        do { try await PipelineSpatialDerivationWriter.confirmBibleView(view, editor: context.editor) }
        catch { staleRejected = true }
        guard staleRejected, after == (try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))) else {
            throw failed("A stale Bible assignment changed the current Bible.")
        }
        let bible = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
        try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root)
        guard let assigned = bible.locations.first,
              let references = try PipelineSpatialDerivationWriter.bibleViewReferences(location: assigned, viewID: "wide", dataRoot: root),
              references.contains(where: { $0.role == "core.spatial-derivation" }) else { throw failed("The Bible lost the actual render proof.") }
        let promotion = try await Task.detached {
            try ProductionSpatialPromotionAcceptance.verify(location: assigned, viewID: "wide", bible: bible, dataRoot: root)
        }.value
        let referencePurpose = try await Task.detached {
            try ProductionSpatialReferencePurposeAcceptance.verify(location: assigned, viewID: "wide", bible: bible, dataRoot: root)
        }.value
        try view.imageData.write(to: output.appendingPathComponent("production-spatial-bible.png"), options: .atomic)
        guard let proof = references.first(where: { $0.role == "core.spatial-derivation" }) else { throw failed("The derivation is missing.") }
        let proofURL = try ProjectLocalFile.resolve(proof.path, dataRoot: root)
        let originalProof = try Data(contentsOf: proofURL)
        try Data("changed derivation".utf8).write(to: proofURL, options: .atomic)
        var changedProofRejected = false
        do { try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root) }
        catch { changedProofRejected = true }
        try originalProof.write(to: proofURL, options: .atomic)
        guard changedProofRejected else { throw failed("Changed derivation bytes were accepted.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.document.save(to: context.packageURL, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        context.document.close(); opened = nil
        let reopened = try await VideoProject.load(from: context.packageURL)
        defer { reopened.close() }
        guard let reopenedHome = reopened.editorViewModel.workingRoot, let reopenedRoot = DataRootResolver.dataRoot(of: reopenedHome) else { throw failed("The project did not reopen.") }
        try await Task.detached(priority: .userInitiated) {
            let reopenedBible = try YAMLArtifactStore(dataRoot: reopenedRoot).load(Bible.self, at: PipelineLayout.bibleFile)
            try PipelineProductionAssetEvidence.requireBible(reopenedBible, dataRoot: reopenedRoot)
            let board = try PlanningWriterIO.storyboard(dataRoot: reopenedRoot)
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: reopenedRoot, storyboard: board)
            try PipelineShotPlanningWriter.requireSpatialInputs(draft, dataRoot: reopenedRoot)
        }.value
        return ["nativeSceneAndCamera": true, "storyboardNativeDerivation": true, "completeShotState": true,
            "fullShotClayAndDistinctEndpoints": true, "biblePreviewAndAssignment": true, "staleBibleRejected": true,
            "changedBibleProofRejected": true, "savedProjectReopened": true,
            "nativePlanUI": nativePlanUI, "nativeBlockoutImportUI": nativeBlockoutImportUI, "nativePanoramaUI": nativePanoramaUI,
            "nativeSceneUI": nativeSceneUI, "nativePoseUI": nativePoseUI, "nativeClayUI": nativeClayUI,
            "nativeSpatialStoryboardUI": nativeSpatialStoryboardUI,
            "nativeStoryboardUI": nativeStoryboardUI, "nativeBibleUI": nativeBibleUI,
            "promotion": promotion, "referencePurpose": referencePurpose, "postCommitCancellation": postCommitCancellation,
            "hashCancellation": hashCancellation]
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Spatial production acceptance: " + message) }
}
