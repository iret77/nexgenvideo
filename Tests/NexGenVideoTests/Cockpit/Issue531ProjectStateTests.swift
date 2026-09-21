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
                isComplete: true,
                activeReservationCount: 0,
                unpricedTransactionCount: 0,
                legacyGenerationCount: 0
            ),
            budgetStopEur: nil,
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

    @Test("host approval evidence uses the pack's exact current lineage")
    func hostApprovalEvidenceUsesCurrentLineage() throws {
        PackCatalog.register(MusicvideoPack())
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-531-host-\(UUID().uuidString)")
        let home = cleanup.appendingPathComponent("Project.ngv")
        let root = try ProjectScaffold.initProject(
            home: home,
            name: "demo",
            mode: .section,
            extraDirs: ["import", "bible"]
        )
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let binding = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: MusicvideoPack().version,
            projectSchema: "musicvideo/2.0.0"
        ))
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
        try YAMLArtifactStore(dataRoot: root).save(
            try Brief(
                project: "demo",
                generated: "2026-09-21T00:00:00Z",
                mission: .demo,
                targetPlatform: "YouTube",
                aspectRatio: .landscape16x9,
                projectMode: "section",
                budgetEur: 50,
                conceptType: .narrative,
                visualMedium: .animation2d,
                visualMediumNotes: "restrained hand-drawn animation",
                tone: [.quiet],
                figures: .none,
                lyricsIntegration: .metaphorical
            ),
            to: PipelineLayout.briefFile
        )
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
        try PipelineLineageStore.record(
            phase: "brief",
            snapshot: try MusicvideoPipelineLineage.snapshot(
                phase: "brief",
                dataRoot: root
            ),
            dataRoot: root
        )
        let snapshot = ProjectStateBuilder.ProjectState(
            project: "demo",
            mode: "section",
            budgetEur: 50,
            budgetSpentEur: 0,
            budgetRemainingEur: 50,
            phases: [ProjectStateBuilder.PhaseStatus(
                phase: "brief",
                approved: true,
                state: .approved,
                notes: nil
            )],
            nextPhase: nil
        )
        #expect(NativeCockpitReader.phaseApprovalEvidence(
            snapshot,
            dataRoot: root,
            activePack: "musicvideo"
        )["brief"]?.current == true)

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
        let stale = NativeCockpitReader.phaseApprovalEvidence(
            snapshot,
            dataRoot: root,
            activePack: "musicvideo"
        )["brief"]
        #expect(stale?.current == false)
        #expect(stale?.blocker?.contains("lineage") == true)
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
