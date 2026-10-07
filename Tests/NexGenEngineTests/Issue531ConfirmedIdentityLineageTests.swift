import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

@Suite("Issue 531 confirmed identity lineage", .serialized)
struct Issue531ConfirmedIdentityLineageTests {
    private struct Fixture: Decodable {
        let schema: String
        let project: String
        let role: ConfirmedIdentityAssetRoleV1
        let identityName: String
        let identitySlug: String
        let sourcePath: String
        let targetPaths: [String]
        let productionDesignTarget: String
        let sourceBytes: String
        let replacementBytes: String

        enum CodingKeys: String, CodingKey {
            case schema, project, role
            case identityName = "identity_name"
            case identitySlug = "identity_slug"
            case sourcePath = "source_path"
            case targetPaths = "target_paths"
            case productionDesignTarget = "production_design_target"
            case sourceBytes = "source_bytes"
            case replacementBytes = "replacement_bytes"
        }
    }

    private let upstreamPhases = [
        "brief", "production_design", "treatment",
    ]

    private func fixture() throws -> Fixture {
        let directory = try #require(Bundle.module.url(
            forResource: "issue-531-confirmed-identity",
            withExtension: nil,
            subdirectory: "Fixtures"
        ))
        let data = try Data(
            contentsOf: directory.appendingPathComponent("acceptance.json")
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(fixture.schema == "issue-531-confirmed-identity/v1")
        return fixture
    }

    private func scaffold(_ fixture: Fixture) throws -> (URL, URL) {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "issue-531-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = cleanup.appendingPathComponent("Project.ngv")
        let root = try ProjectScaffold.initProject(
            home: home,
            name: fixture.project,
            mode: .beat,
            extraDirs: ["import", "bible", "production_design"]
        )
        let source = root.appendingPathComponent(fixture.sourcePath)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(fixture.sourceBytes.utf8).write(to: source)
        try ConfirmedIdentityAssetStoreV1.recordIntake(
            role: fixture.role,
            identityName: fixture.identityName,
            identitySlug: fixture.identitySlug,
            paths: [fixture.sourcePath],
            dataRoot: root,
            confirmedAt: "2026-09-21T00:00:00Z"
        )
        return (root, cleanup)
    }

    private func stage(
        _ path: String,
        fixture: Fixture,
        root: URL
    ) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(fixture.sourceBytes.utf8).write(to: target)
    }

    private func recordUpstreamLineage(root: URL) throws {
        for phase in upstreamPhases {
            try PipelineLineageStore.record(
                phase: phase,
                snapshot: try MusicvideoPipelineLineage.snapshot(
                    phase: phase,
                    dataRoot: root
                ),
                dataRoot: root
            )
        }
    }

    private func requireUpstreamCurrent(root: URL) throws {
        for phase in upstreamPhases {
            try MusicvideoPipelineLineage.requireCurrent(
                phase: phase,
                dataRoot: root
            )
        }
    }

    private func approveThroughTreatment(root: URL) throws {
        let store = YAMLArtifactStore(dataRoot: root)
        var gates = try store.load(Gates.self, at: PipelineLayout.gatesFile)
        for phase in [
            "project_init", "analysis", "brief", "production_design",
            "treatment",
        ] {
            GatesOperations.approve(&gates, phase: phase)
        }
        try store.save(gates, to: PipelineLayout.gatesFile)
    }

    private func requireStoryboardCanContinue(root: URL) throws {
        let gates = try YAMLArtifactStore(dataRoot: root).load(
            Gates.self,
            at: PipelineLayout.gatesFile
        )
        try GateGuard.requirePriorApproved(
            gates,
            order: ["project_init"] + MusicvideoPipelineLineage.phases,
            phase: "storyboard"
        )
        try MusicvideoPipelineLineage.requireCurrent(
            phase: "treatment",
            dataRoot: root
        )
    }

    @Test("derived Bible aliases preserve upstream exact-byte lineage")
    func derivedAliasesPreserveUpstreamLineage() throws {
        let fixture = try fixture()
        let (root, cleanup) = try scaffold(fixture)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try recordUpstreamLineage(root: root)
        try approveThroughTreatment(root: root)
        let intakeURL = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAssetsFile,
            in: root
        )
        let intakeBefore = try Data(contentsOf: intakeURL)

        try stage(fixture.targetPaths[0], fixture: fixture, root: root)
        #expect(try ConfirmedIdentityAssetStoreV1.prepareAdoption(
            from: fixture.sourcePath,
            to: fixture.targetPaths[0],
            dataRoot: root
        ))
        #expect(try ConfirmedIdentityAssetStoreV1.adopt(
            from: fixture.sourcePath,
            to: fixture.targetPaths[0],
            dataRoot: root
        ))
        #expect(try Data(contentsOf: intakeURL) == intakeBefore)
        try requireUpstreamCurrent(root: root)
        try requireStoryboardCanContinue(root: root)

        let proofURL = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAdoptionsFile,
            in: root
        )
        let firstProofBytes = try Data(contentsOf: proofURL)
        let firstProof = try ConfirmedIdentityAssetStoreV1.loadAdoptions(
            dataRoot: root
        )
        let first = try #require(firstProof.entries[fixture.targetPaths[0]])
        let source = try #require(
            try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                .entries[fixture.sourcePath]
        )
        #expect(first.sourceConfirmationID == source.id)
        #expect(first.sourceSHA256 == source.sha256)
        #expect(first.originalPath == fixture.sourcePath)
        #expect(first.originalSHA256 == source.originalSHA256)
        #expect(first.targetSHA256 == source.sha256)

        #expect(try ConfirmedIdentityAssetStoreV1.adopt(
            from: fixture.sourcePath,
            to: fixture.targetPaths[0],
            dataRoot: root
        ))
        #expect(try Data(contentsOf: proofURL) == firstProofBytes)
        try requireUpstreamCurrent(root: root)
        try requireStoryboardCanContinue(root: root)

        let bibleBefore = try MusicvideoPipelineLineage.snapshot(
            phase: "bible",
            dataRoot: root
        )
        try stage(fixture.targetPaths[1], fixture: fixture, root: root)
        #expect(try ConfirmedIdentityAssetStoreV1.adopt(
            from: fixture.sourcePath,
            to: fixture.targetPaths[1],
            dataRoot: root
        ))
        try requireUpstreamCurrent(root: root)
        try requireStoryboardCanContinue(root: root)
        #expect(try Data(contentsOf: intakeURL) == intakeBefore)
        let bibleAfter = try MusicvideoPipelineLineage.snapshot(
            phase: "bible",
            dataRoot: root
        )
        #expect(bibleBefore.inputFingerprint == bibleAfter.inputFingerprint)
        #expect(bibleBefore.artifactFingerprint != bibleAfter.artifactFingerprint)
    }

    @Test("real source and identity edits stale lineage; altered targets are rejected")
    func realEditsStillInvalidate() throws {
        let fixture = try fixture()
        let (root, cleanup) = try scaffold(fixture)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try stage(fixture.targetPaths[0], fixture: fixture, root: root)
        try stage(
            fixture.productionDesignTarget,
            fixture: fixture,
            root: root
        )
        #expect(try ConfirmedIdentityAssetStoreV1.adopt(
            from: fixture.sourcePath,
            to: fixture.targetPaths[0],
            dataRoot: root
        ))
        try recordUpstreamLineage(root: root)

        let target = root.appendingPathComponent(fixture.targetPaths[0])
        try Data(fixture.replacementBytes.utf8).write(to: target)
        #expect(try ConfirmedIdentityAssetStoreV1.currentEntry(
            fixture.targetPaths[0],
            dataRoot: root
        ) == nil)
        try stage(fixture.targetPaths[1], fixture: fixture, root: root)
        #expect(try ConfirmedIdentityAssetStoreV1.adopt(
            from: fixture.sourcePath,
            to: fixture.targetPaths[1],
            dataRoot: root
        ))
        #expect(try ConfirmedIdentityAssetStoreV1.currentEntry(
            fixture.targetPaths[1],
            dataRoot: root
        ) != nil)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: root.appendingPathComponent(fixture.sourcePath)
        )
        #expect(throws: ProjectLocalFileError.self) {
            try ConfirmedIdentityAssetStoreV1.currentEntry(
                fixture.targetPaths[0],
                dataRoot: root
            )
        }
        try FileManager.default.removeItem(at: target)
        try Data(fixture.sourceBytes.utf8).write(to: target)

        try Data(fixture.replacementBytes.utf8).write(
            to: root.appendingPathComponent(fixture.sourcePath)
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoPipelineLineage.requireCurrent(
                phase: "brief",
                dataRoot: root
            )
        }
        #expect(try ConfirmedIdentityAssetStoreV1.currentEntry(
            fixture.targetPaths[0],
            dataRoot: root
        ) == nil)
        #expect(throws: GateBlocked.self) {
            try ConfirmedIdentityAssetStoreV1.prepareAdoption(
                from: fixture.sourcePath,
                to: fixture.targetPaths[1],
                dataRoot: root
            )
        }

        try Data(fixture.sourceBytes.utf8).write(
            to: root.appendingPathComponent(fixture.sourcePath)
        )
        try ConfirmedIdentityAssetStoreV1.recordIntake(
            role: .location,
            identityName: fixture.identityName,
            identitySlug: fixture.identitySlug,
            paths: [fixture.sourcePath],
            dataRoot: root,
            confirmedAt: "2026-09-21T01:00:00Z"
        )
        #expect(throws: GateBlocked.self) {
            try MusicvideoPipelineLineage.requireCurrent(
                phase: "brief",
                dataRoot: root
            )
        }
        #expect(try ConfirmedIdentityAssetStoreV1.currentEntry(
            fixture.targetPaths[0],
            dataRoot: root
        ) == nil)
        try ConfirmedIdentityAssetStoreV1.recordIntake(
            role: fixture.role,
            identityName: "Different Mouse",
            identitySlug: "different-mouse",
            paths: [fixture.sourcePath],
            dataRoot: root,
            confirmedAt: "2026-09-21T02:00:00Z"
        )
        #expect(try ConfirmedIdentityAssetStoreV1.currentEntry(
            fixture.targetPaths[0],
            dataRoot: root
        ) == nil)
    }

    @Test("legacy recovery is explicit, transactional, and auditable")
    func legacyRecovery() throws {
        let fixture = try fixture()
        let (root, cleanup) = try scaffold(fixture)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try stage(fixture.targetPaths[0], fixture: fixture, root: root)
        try stage(
            fixture.productionDesignTarget,
            fixture: fixture,
            root: root
        )
        try recordUpstreamLineage(root: root)
        let intakeURL = PipelineLayout.url(
            PipelineLayout.confirmedIdentityAssetsFile,
            in: root
        )
        let intakeOnlyBytes = try Data(contentsOf: intakeURL)
        let source = try #require(
            try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                .entries[fixture.sourcePath]
        )
        let legacyIDData = Data(
            "\(source.id)\n\(fixture.targetPaths[0])\n\(source.sha256)".utf8
        )
        var mixed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
        mixed.entries[fixture.targetPaths[0]] = ConfirmedIdentityAssetV1(
            id: "confirmed-identity-\(FileDigest.sha256(of: legacyIDData))",
            role: source.role,
            identityName: source.identityName,
            identitySlug: source.identitySlug,
            path: fixture.targetPaths[0],
            sha256: source.sha256,
            originalPath: source.path,
            originalSHA256: source.originalSHA256,
            confirmedAt: source.confirmedAt
        )
        let productionDesignIDData = Data(
            "\(source.id)\n\(fixture.productionDesignTarget)\n\(source.sha256)"
                .utf8
        )
        mixed.entries[fixture.productionDesignTarget] =
            ConfirmedIdentityAssetV1(
                id: "confirmed-identity-\(FileDigest.sha256(of: productionDesignIDData))",
                role: source.role,
                identityName: source.identityName,
                identitySlug: source.identitySlug,
                path: fixture.productionDesignTarget,
                sha256: source.sha256,
                originalPath: source.path,
                originalSHA256: source.originalSHA256,
                confirmedAt: source.confirmedAt
            )
        try JSONArtifactStore(dataRoot: root).save(
            mixed,
            to: PipelineLayout.confirmedIdentityAssetsFile
        )
        try approveThroughTreatment(root: root)
        let gateBytes = try Data(contentsOf: PipelineLayout.url(
            PipelineLayout.gatesFile,
            in: root
        ))
        #expect(throws: GateBlocked.self) {
            try MusicvideoPipelineLineage.requireCurrent(
                phase: "brief",
                dataRoot: root
            )
        }
        let status = try #require(
            ConfirmedIdentityAssetStoreV1.legacyRecoveryStatus(dataRoot: root)
        )
        #expect(status.eligible)
        #expect(status.affectedTargets == [
            fixture.targetPaths[0], fixture.productionDesignTarget,
        ].sorted())
        #expect(status.discardedTargets == [fixture.productionDesignTarget])
        #expect(try Data(contentsOf: intakeURL) != intakeOnlyBytes)

        let result = try #require(
            try ConfirmedIdentityAssetStoreV1.recoverLegacyAdoptions(
                dataRoot: root,
                recoveredAt: "2026-09-21T02:00:00Z"
            )
        )
        #expect(result.recoveredTargets == [fixture.targetPaths[0]])
        #expect(result.discardedNonBibleTargets
            == [fixture.productionDesignTarget])
        #expect(result.discardedStaleTargets.isEmpty)
        #expect(try Data(contentsOf: intakeURL) == intakeOnlyBytes)
        #expect(try Data(contentsOf: PipelineLayout.url(
            PipelineLayout.gatesFile,
            in: root
        )) == gateBytes)
        try requireUpstreamCurrent(root: root)
        try requireStoryboardCanContinue(root: root)
        let recovered = try ConfirmedIdentityAssetStoreV1.loadAdoptions(
            dataRoot: root
        )
        #expect(recovered.entries[fixture.targetPaths[0]]?.targetSHA256
            == source.sha256)
        #expect(recovered.recoveries.last?.id == result.receiptID)
        #expect(recovered.recoveries.last?.discardedNonBibleTargets
            == [fixture.productionDesignTarget])
        #expect(recovered.recoveries.last?.legacyManifestSHA256
            == result.legacyManifestSHA256)
        #expect(recovered.recoveries.last?.recoveredManifestSHA256
            == result.recoveredManifestSHA256)
    }

    @Test("recovery never makes lineage recorded from mixed bytes current")
    func recoveryDoesNotReapproveMixedLineage() throws {
        let fixture = try fixture()
        let (root, cleanup) = try scaffold(fixture)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try stage(fixture.targetPaths[0], fixture: fixture, root: root)
        let source = try #require(
            try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                .entries[fixture.sourcePath]
        )
        let idData = Data(
            "\(source.id)\n\(fixture.targetPaths[0])\n\(source.sha256)".utf8
        )
        var mixed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
        mixed.entries[fixture.targetPaths[0]] = ConfirmedIdentityAssetV1(
            id: "confirmed-identity-\(FileDigest.sha256(of: idData))",
            role: source.role,
            identityName: source.identityName,
            identitySlug: source.identitySlug,
            path: fixture.targetPaths[0],
            sha256: source.sha256,
            originalPath: source.path,
            originalSHA256: source.originalSHA256,
            confirmedAt: source.confirmedAt
        )
        try JSONArtifactStore(dataRoot: root).save(
            mixed,
            to: PipelineLayout.confirmedIdentityAssetsFile
        )
        try recordUpstreamLineage(root: root)
        try approveThroughTreatment(root: root)
        let gateURL = PipelineLayout.url(PipelineLayout.gatesFile, in: root)
        let gatesBefore = try Data(contentsOf: gateURL)

        _ = try #require(
            try ConfirmedIdentityAssetStoreV1.recoverLegacyAdoptions(
                dataRoot: root
            )
        )

        #expect(try Data(contentsOf: gateURL) == gatesBefore)
        for phase in upstreamPhases {
            #expect(throws: GateBlocked.self) {
                try MusicvideoPipelineLineage.requireCurrent(
                    phase: phase,
                    dataRoot: root
                )
            }
        }
    }

    @Test("legacy recovery rejects and audits altered and symlink proofs")
    func legacyRecoveryRejectsUnsafeTargets() throws {
        let fixture = try fixture()
        for damage in ["overwritten", "symlink", "deleted"] {
            let (root, cleanup) = try scaffold(fixture)
            defer { try? FileManager.default.removeItem(at: cleanup) }
            try stage(fixture.targetPaths[0], fixture: fixture, root: root)
            let source = try #require(
                try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                    .entries[fixture.sourcePath]
            )
            let idData = Data(
                "\(source.id)\n\(fixture.targetPaths[0])\n\(source.sha256)".utf8
            )
            var mixed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
            mixed.entries[fixture.targetPaths[0]] = ConfirmedIdentityAssetV1(
                id: "confirmed-identity-\(FileDigest.sha256(of: idData))",
                role: source.role,
                identityName: source.identityName,
                identitySlug: source.identitySlug,
                path: fixture.targetPaths[0],
                sha256: source.sha256,
                originalPath: source.path,
                originalSHA256: source.originalSHA256,
                confirmedAt: source.confirmedAt
            )
            try JSONArtifactStore(dataRoot: root).save(
                mixed,
                to: PipelineLayout.confirmedIdentityAssetsFile
            )
            let target = root.appendingPathComponent(fixture.targetPaths[0])
            if damage == "symlink" {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(
                    at: target,
                    withDestinationURL: root.appendingPathComponent(
                        fixture.sourcePath
                    )
                )
            } else if damage == "overwritten" {
                try Data(fixture.replacementBytes.utf8).write(to: target)
            } else {
                try FileManager.default.removeItem(at: target)
            }
            let status = try #require(
                ConfirmedIdentityAssetStoreV1.legacyRecoveryStatus(
                    dataRoot: root
                )
            )
            #expect(status.eligible)
            #expect(status.discardedTargets == [fixture.targetPaths[0]])
            let result = try #require(
                try ConfirmedIdentityAssetStoreV1.recoverLegacyAdoptions(
                    dataRoot: root
                )
            )
            #expect(result.recoveredTargets.isEmpty)
            #expect(result.discardedStaleTargets == [fixture.targetPaths[0]])
            let adoptions = try ConfirmedIdentityAssetStoreV1.loadAdoptions(
                dataRoot: root
            )
            #expect(adoptions.entries[fixture.targetPaths[0]] == nil)
            #expect(adoptions.recoveries.last?.discardedStaleEntries.first?
                .entry.path == fixture.targetPaths[0])
            #expect(adoptions.recoveries.last?.discardedStaleEntries.first?
                .reason == (damage == "overwritten"
                    ? "target_bytes_changed"
                    : "target_missing_or_unsafe"))
            #expect(try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                .entries[fixture.targetPaths[0]] == nil)
        }
    }

    @Test("legacy recovery audits an alias after source reconfirmation")
    func legacyRecoveryAfterSourceReconfirmation() throws {
        let fixture = try fixture()
        let (root, cleanup) = try scaffold(fixture)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try stage(fixture.targetPaths[0], fixture: fixture, root: root)
        let source = try #require(
            try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
                .entries[fixture.sourcePath]
        )
        let idData = Data(
            "\(source.id)\n\(fixture.targetPaths[0])\n\(source.sha256)".utf8
        )
        var mixed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
        mixed.entries[fixture.targetPaths[0]] = ConfirmedIdentityAssetV1(
            id: "confirmed-identity-\(FileDigest.sha256(of: idData))",
            role: source.role,
            identityName: source.identityName,
            identitySlug: source.identitySlug,
            path: fixture.targetPaths[0],
            sha256: source.sha256,
            originalPath: source.path,
            originalSHA256: source.originalSHA256,
            confirmedAt: source.confirmedAt
        )
        mixed.entries[fixture.sourcePath] = ConfirmedIdentityAssetV1(
            id: source.id,
            role: source.role,
            identityName: "Mouse Reconfirmed",
            identitySlug: source.identitySlug,
            path: source.path,
            sha256: source.sha256,
            originalPath: source.originalPath,
            originalSHA256: source.originalSHA256,
            confirmedAt: "2026-09-21T03:00:00Z"
        )
        try JSONArtifactStore(dataRoot: root).save(
            mixed,
            to: PipelineLayout.confirmedIdentityAssetsFile
        )

        let status = try #require(
            ConfirmedIdentityAssetStoreV1.legacyRecoveryStatus(dataRoot: root)
        )
        #expect(status.eligible)
        #expect(status.discardedTargets == [fixture.targetPaths[0]])
        let result = try #require(
            try ConfirmedIdentityAssetStoreV1.recoverLegacyAdoptions(
                dataRoot: root
            )
        )
        #expect(result.recoveredTargets.isEmpty)
        #expect(result.discardedStaleTargets == [fixture.targetPaths[0]])
        let receipt = try #require(
            try ConfirmedIdentityAssetStoreV1.loadAdoptions(dataRoot: root)
                .recoveries.last
        )
        #expect(receipt.discardedStaleEntries.first?.reason
            == "source_confirmation_changed_or_proof_invalid")
        #expect(try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
            .entries[fixture.sourcePath]?.identityName == "Mouse Reconfirmed")
    }
}
