import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo
@testable import MusicvideoPlugin

@Suite("Issue 531 host state", .serialized)
struct Issue531ProjectStateTests {
    @Test("historical approval is distinct from current evidence and recovery is shared state")
    func staleApprovalAndRecoveryDecode() throws {
        let snapshot = ProjectStateBuilder.ProjectState(
            project: "demo",
            mode: "beat",
            budgetEur: 50,
            budgetSpentEur: 0,
            budgetRemainingEur: 50,
            phases: [
                ProjectStateBuilder.PhaseStatus(
                    phase: "brief",
                    approved: true,
                    state: .approved,
                    notes: nil
                ),
            ],
            nextPhase: nil
        )
        let recovery = ConfirmedIdentityProvenanceRecoveryStatus(
            affectedTargets: ["bible/refs/mouse/face.png"],
            discardedTargets: [],
            eligible: true,
            blocker: nil
        )
        let dictionary = NativeCockpitReader.stateDictionary(
            snapshot,
            spend: ProjectSpendSnapshot(
                verifiedEur: 0,
                providerCredits: [],
                unknownCostCount: 0,
                inFlightCount: 0,
                legacyGenerationCount: 0
            ),
            approvalEvidence: [
                "brief": NativeCockpitReader.PhaseApprovalEvidence(
                    current: false,
                    blocker: "The Brief lineage changed."
                ),
            ],
            confirmedIdentityRecovery: recovery
        )
        let data = try NativeCockpitReader.serialize(dictionary)
        let decoded = try JSONDecoder().decode(ProjectStateData.self, from: data)
        let phase = try #require(decoded.phases.first)

        #expect(phase.approved)
        #expect(!phase.approvalCurrent)
        #expect(phase.approvalBlocker == "The Brief lineage changed.")
        #expect(decoded.currentApprovalCount == 0)
        #expect(!decoded.isComplete)
        #expect(decoded.progress == 0)
        #expect(decoded.nextPhaseName == nil)
        #expect(decoded.confirmedIdentityRecovery?.affectedTargets
            == ["bible/refs/mouse/face.png"])
        #expect(decoded.confirmedIdentityRecovery?.eligible == true)
        #expect(decoded.confirmedIdentityRecovery?.action
            == "recover_confirmed_identity_provenance")
    }

    @Test("identity adoption and recovery require the lineage-aware pack")
    func recoveryVersionFloor() throws {
        let old = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.5.8",
            projectSchema: "musicvideo/2.0.0"
        ))
        let current = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.5.9",
            projectSchema: "musicvideo/2.0.0"
        ))

        #expect(throws: ConfirmedIdentityProvenanceRecovery.RecoveryError.self) {
            try ConfirmedIdentityProvenanceRecovery.requireCompatibleBinding(old)
        }
        try ConfirmedIdentityProvenanceRecovery.requireCompatibleBinding(current)
    }

    @Test("V2 approval evidence binds exact Brief bytes while alias recovery retains its version floor")
    @MainActor
    func hostApprovalEvidenceUsesCurrentLineage() async throws {
        let context = try await CurrentMusicvideoFixture.makeScript(stopBeforeBrief: true)
        defer {
            context.document.close()
            try? FileManager.default.removeItem(at: context.packageURL)
        }
        let home = try #require(context.editor.workingRoot)
        let root = context.dataRoot
        let binding = try CurrentMusicvideoFixture.binding
        let resolvedWorkflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root,
            expectedPack: binding, expectedProductionContract: nil)
        let workflow = try #require(resolvedWorkflow)
        let sourcePath = "import/characters/mouse/face.png"
        let targetPath = "bible/refs/mouse/face.png"
        let bytes = Data("confirmed-face-v1".utf8)
        for path in [sourcePath, targetPath] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
        }
        try ConfirmedIdentityAssetStoreV1.recordIntake(
            role: .character,
            identityName: "Mouse",
            identitySlug: "mouse",
            paths: [sourcePath],
            dataRoot: root,
            confirmedAt: "2026-09-21T00:00:00Z"
        )
        try await ProductionPlanningAcceptanceFixture.run("record_affect", args: [
            "detected": [["tag": "meditative", "weight": 1.0]], "basis": "inferred",
            "rationale": "Deterministic test interpretation of the measured track.",
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.run("write_brief", args: [
            "mission": "single_release", "target_platform": "YouTube", "aspect_ratio": "16:9",
            "project_mode": "section", "concept_type": "abstract", "visual_medium": "live_action_realistic",
            "figures": "none", "lyrics_integration": "metaphorical",
        ], in: context)
        try await ProductionPlanningAcceptanceFixture.approve("brief", in: context)
        let snapshot = try ProjectStateBuilder.buildSnapshot(dataRoot: root,
            order: PhaseContractRuntime.order(workflow: workflow))
        #expect(NativeCockpitReader.phaseApprovalEvidence(snapshot, dataRoot: root,
            activePack: "musicvideo", workflow: workflow)["brief"]?.current == true)

        let briefURL = root.appendingPathComponent(PipelineLayout.briefFile)
        let originalBrief = try Data(contentsOf: briefURL)
        var changedBrief = originalBrief
        changedBrief.append(Data("\n".utf8))
        try changedBrief.write(to: briefURL)
        let stale = NativeCockpitReader.phaseApprovalEvidence(snapshot, dataRoot: root,
            activePack: "musicvideo", workflow: workflow)["brief"]
        #expect(stale?.current == false)
        #expect(stale?.blocker?.isEmpty == false)
        try originalBrief.write(to: briefURL)
        #expect(NativeCockpitReader.phaseApprovalEvidence(snapshot, dataRoot: root,
            activePack: "musicvideo", workflow: workflow)["brief"]?.current == true)

        let source = try #require(
            try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                .entries[sourcePath]
        )
        let idData = Data(
            "\(source.id)\n\(targetPath)\n\(source.sha256)".utf8
        )
        var mixed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
        mixed.entries[targetPath] = ConfirmedIdentityAssetV1(
            id: "confirmed-identity-\(FileDigest.sha256(of: idData))",
            role: source.role,
            identityName: source.identityName,
            identitySlug: source.identitySlug,
            path: targetPath,
            sha256: source.sha256,
            originalPath: source.path,
            originalSHA256: source.originalSHA256,
            confirmedAt: source.confirmedAt
        )
        try JSONArtifactStore(dataRoot: root).save(
            mixed,
            to: PipelineLayout.confirmedIdentityAssetsFile
        )
        let recovery = try #require(
            ConfirmedIdentityProvenanceRecovery.status(dataRoot: root)
        )
        #expect(recovery.eligible)
        #expect(recovery.affectedTargets == [targetPath])
        let oldBinding = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: "0.5.8",
            projectSchema: "musicvideo/2.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(
            oldBinding,
            projectURL: home
        )
        let blocked = try #require(
            ConfirmedIdentityProvenanceRecovery.status(dataRoot: root)
        )
        #expect(!blocked.eligible)
        #expect(blocked.blocker?.contains("0.5.9") == true)
        #expect(blocked.affectedTargets == recovery.affectedTargets)
    }
}
