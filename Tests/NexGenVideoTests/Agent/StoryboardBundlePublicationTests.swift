import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Storyboard publication binds actual audio, prepared sketches and archived identity")
struct StoryboardBundlePublicationTests {
    private func fixture(sketches: Bool = false) async throws -> (ProductionPlanningAcceptanceFixture.Context, StoryboardBundleSnapshot) {
        let context = try await ProductionPlanningAcceptanceFixture.makeScript()
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        let board = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        return (context, sketches ? try await ProductionPlanningAcceptanceFixture.attachSketches(in: context) : board)
    }

    private func write(_ proposal: PipelineStoryboardBundleWriter.Proposal,
                       in context: ProductionPlanningAcceptanceFixture.Context,
                       reassignments: [PipelineStoryboardImageReassignment.Prepared] = []) throws -> StoryboardBundleSnapshot {
        let editor = context.editor
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: context.dataRoot, label: "Storyboard") else {
            throw GateBlocked("The test's actual Storyboard writer is busy.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease) }
        let access = try PipelinePlanningWriteAccess(dataRoot: context.dataRoot,
            declaration: .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                productionContract: editor.declaredProductionContract), phase: "storyboard")
        return try PipelineStoryboardBundleWriter.write(proposal, origin: .userRevision, access: access,
            nativeReassignments: reassignments)
    }

    private func proposal(_ board: StoryboardBundleSnapshot, audio: StoryboardTimingV1.AudioBinding? = nil,
                          shots: [PipelineStoryboardBundleWriter.ShotProposal]? = nil) -> PipelineStoryboardBundleWriter.Proposal {
        .init(summary: board.storyboard.summary, steps: board.storyboard.steps, bindings: board.causality.bindings,
            timebase: board.timing.timebase, mode: board.timing.mode, rangeStartTicks: board.timing.rangeStartTicks,
            rangeDurationTicks: board.timing.rangeDurationTicks, audio: audio, shots: shots ?? board.timing.shots.map {
                .init(id: $0.id, primaryStepID: $0.primaryStepID, additionalStepIDs: $0.additionalStepIDs,
                    startTicks: $0.startTicks, durationTicks: $0.durationTicks, cameraID: $0.cameraID,
                    framing: $0.framing, moments: $0.moments)
            })
    }

    @Test func missingAudioCannotPublishAndChangedActualAudioInvalidatesSnapshot() async throws {
        let (context, board) = try await fixture()
        defer { context.document.close() }
        let missing = CanonicalArtifactReferenceV1(id: "audio", role: "core.storyboard-audio", path: "audio/missing.wav",
            sha256: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) {
            try write(proposal(board, audio: .init(source: missing, durationTicks: board.timing.rangeDurationTicks)), in: context)
        }
        #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false).fingerprint == board.fingerprint)
        let root = context.dataRoot
        _ = try ProjectLocalFile.ensureDirectory("audio", dataRoot: root)
        let url = root.appendingPathComponent("audio/storyboard.wav")
        try FullflowAcceptanceFixture.writeTone(to: url, duration: board.timing.timebase.seconds(for: board.timing.rangeDurationTicks))
        let bytes = try Data(contentsOf: url)
        let audio = CanonicalArtifactReferenceV1(id: "audio", role: "core.storyboard-audio", path: "audio/storyboard.wav",
            sha256: FileDigest.sha256(of: bytes))
        let written = try write(proposal(board, audio: .init(source: audio, durationTicks: board.timing.rangeDurationTicks)), in: context)
        #expect(written.references.contains { $0.path == audio.path && $0.sha256 == audio.sha256 })
        #expect(written.timing.header.inputs.contains { $0.path == audio.path && $0.sha256 == audio.sha256 })
        try Data("changed audio".utf8).write(to: url)
        #expect(throws: (any Error).self) { try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false) }
        try bytes.write(to: url)
        #expect(try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false).fingerprint == written.fingerprint)
    }

    @Test func preparedSketchIntentOrFramingMismatchRollsBackAllNewReceiptFiles() async throws {
        let (context, initial) = try await fixture(sketches: true)
        defer { context.document.close() }
        var current = initial
        for changeFraming in [false, true] {
            let shot = try #require(current.timing.shots.first), moment = try #require(shot.moments.first)
            let asset = try #require(moment.asset)
            let prepared = try PipelineStoryboardImageReassignment.prepare(originalAsset: asset, targetShotID: shot.id,
                targetMoment: moment, framing: shot.framing, projectID: current.storyboard.header.projectID,
                expectedFingerprint: current.fingerprint, dataRoot: context.dataRoot)
            let valid = PipelineStoryboardBundleWriter.proposal(from: current, replacing: moment.id, in: shot.id, with: prepared.asset)
            let invalidShots = valid.shots.map { value in
                guard value.id == shot.id else { return value }
                let framing = changeFraming ? StoryboardTimingV1.FramingIntent(scale: value.framing.scale + " changed after preparation",
                    composition: value.framing.composition, cameraView: value.framing.cameraView) : value.framing
                return PipelineStoryboardBundleWriter.ShotProposal(id: value.id, primaryStepID: value.primaryStepID,
                    additionalStepIDs: value.additionalStepIDs, startTicks: value.startTicks, durationTicks: value.durationTicks,
                    cameraID: value.cameraID, framing: framing, moments: value.moments.map {
                        guard $0.id == moment.id, !changeFraming else { return $0 }
                        return .init(id: $0.id, offsetTicks: $0.offsetTicks, intent: $0.intent + " changed after preparation", asset: $0.asset)
                    })
            }
            let next = current.storyboard.header.revision + 1
            #expect(throws: (any Error).self) { try write(proposal(current, shots: invalidShots), in: context, reassignments: [prepared]) }
            #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot).fingerprint == current.fingerprint)
            #expect(!FileManager.default.fileExists(atPath: context.dataRoot.appendingPathComponent(StoryboardV2.versionPath(next)).path))
            #expect(prepared.files.allSatisfy { !FileManager.default.fileExists(atPath: context.dataRoot.appendingPathComponent($0.path).path) })
            current = try write(valid, in: context, reassignments: [prepared])
            #expect(current.sketchProblems.isEmpty && current.sketchProofs[prepared.asset.proof.path] != nil)
        }
    }

    @Test func scriptRevisionRebuildsStoryboardUsingArchivedIdentityWithoutApprovingStaleInputs() async throws {
        let (context, initial) = try await fixture()
        defer { context.document.close() }
        let script = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        let home = try #require(context.editor.workingRoot)
        try NativeGateWriter.rewind(projectDir: home, targetPhase: "script", declaredPack: nil,
            declaredProductionContract: .current, executionCoordinator: context.editor.pipelinePhaseRunCoordinator)
        try await ProductionPlanningAcceptanceFixture.run("write_script", args: ["origin": "agentRevision",
            "summary": script.summary + " Reconsidered order.", "scenes": try ProductionPlanningAcceptanceFixture.object(script.scenes)], in: context)
        #expect(throws: (any Error).self) { try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false) }
        let prior = try #require(try ProductionPlanningStoreV1.readStoryboardIdentityHistory(dataRoot: context.dataRoot, through: 1))
        #expect(prior == initial.identity)
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        let replacement = try write(proposal(initial), in: context)
        #expect(replacement.storyboard.header.revision == 2 && replacement.timing.shots.map(\.id) == initial.timing.shots.map(\.id))
        let gates = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        #expect(gates.get("script").approved && !gates.get("storyboard").approved)
        let archivedScript = context.dataRoot.appendingPathComponent(ScriptV1.versionPath(script.header.revision))
        let bytes = try Data(contentsOf: archivedScript)
        try Data("changed archived Script".utf8).write(to: archivedScript)
        #expect(throws: (any Error).self) {
            try ProductionPlanningStoreV1.readStoryboardIdentityHistory(dataRoot: context.dataRoot, through: 2)
        }
        try bytes.write(to: archivedScript)
        #expect(try ProductionPlanningStoreV1.readStoryboardIdentityHistory(dataRoot: context.dataRoot, through: 2) == replacement.identity)
    }

    @Test func staleNativeImageAssignmentCannotOverwriteTheCurrentBundle() async throws {
        let (context, original) = try await fixture(sketches: true)
        defer { context.document.close() }
        let shot = try #require(original.timing.shots.first), moment = try #require(shot.moments.first)
        let asset = try #require(moment.asset)
        let current = try await PipelineStoryboardEditor.apply(.reorder(shotIDs: Array(original.timing.shots.map(\.id).reversed())),
            expectedFingerprint: original.fingerprint, editor: context.editor)
        await #expect(throws: (any Error).self) {
            try await PipelineStoryboardEditor.apply(.assignExistingSketch(shotID: shot.id, momentID: moment.id, asset: asset),
                expectedFingerprint: original.fingerprint, editor: context.editor)
        }
        #expect(try PlanningWriterIO.storyboard(dataRoot: context.dataRoot).fingerprint == current.fingerprint)
    }
}
