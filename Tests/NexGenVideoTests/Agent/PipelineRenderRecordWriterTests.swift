import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo
@testable import MusicvideoPlugin

@MainActor
@Suite("Pipeline render-record writer")
struct PipelineRenderRecordWriterTests {
    private enum InjectedFailure: Error {
        case stop
    }

    @Test("Publication rechecks the exact pack binding before canonical writes")
    func publicationRejectsBindingChangeAtCommit() throws {
        PackCatalog.register(MusicvideoPack())
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let trusted = try #require(ProjectPackBinding(
            id: "musicvideo",
            version: MusicvideoPack().version,
            projectSchema: "musicvideo/2.0.0"
        ))
        let sibling = try #require(ProjectPackBinding(
            id: trusted.id,
            version: "0.4.5",
            projectSchema: trusted.projectSchema
        ))
        try ProjectPluginSettings.setActivePlugin(
            trusted,
            projectURL: fixture.home
        )
        let manifestURL = PipelineLayout.url(
            PipelineLayout.renderManifestFile(phase: "frames"),
            in: fixture.dataRoot
        )
        let before = try Data(contentsOf: manifestURL)
        var manifest = RenderManifest(project: "demo", phase: "frames")
        record(
            &manifest,
            shotId: "s001",
            output: "frame.png",
            costEur: 0.1,
            phase: "frames"
        )
        let frames = FramesManifest(
            project: "demo",
            generated: "2026-08-31T00:00:00+00:00",
            shots: [
                ShotFrames(
                    shotId: "s001",
                    keyframeStrategy: "start",
                    frames: [
                        FrameEntry(
                            role: "start",
                            path: "frame.png",
                            providerPrompt: "Compiled frame prompt."
                        ),
                    ]
                ),
            ]
        )

        #expect(throws: PipelineRenderRecordError.self) {
            _ = try PipelineRenderRecordWriter.publish(
                manifest: manifest,
                proof: nil,
                routingProof: nil,
                framesManifest: frames,
                replacingShotID: "s001",
                preparedLastFrame: nil,
                expectedPublicationTransactionID: nil,
                dataRoot: fixture.dataRoot,
                declaredPack: trusted.id,
                declaredBinding: trusted,
                failureProbe: { point in
                    guard point == .transactionStarted else { return }
                    try ProjectPluginSettings.setActivePlugin(
                        sibling,
                        projectURL: fixture.home
                    )
                }
            )
        }

        #expect(try Data(contentsOf: manifestURL) == before)
    }

    @Test("Frames manifest and render ledger publish under one commit marker")
    func framesPublicationIsHashBound() throws {
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        var manifest = RenderManifest(project: "demo", phase: "frames")
        record(
            &manifest,
            shotId: "s001",
            output: "frame.png",
            costEur: 0.1,
            phase: "frames"
        )
        let frames = FramesManifest(
            project: "demo",
            generated: "2026-08-31T00:00:00+00:00",
            shots: [
                ShotFrames(
                    shotId: "s001",
                    keyframeStrategy: "start",
                    frames: [
                        FrameEntry(
                            role: "start",
                            path: "frame.png",
                            providerPrompt: "Compiled frame prompt."
                        ),
                    ]
                ),
            ]
        )

        let publication = try PipelineRenderRecordWriter.publish(
            manifest: manifest,
            proof: nil,
            routingProof: nil,
            framesManifest: frames,
            replacingShotID: "s001",
            preparedLastFrame: nil,
            expectedPublicationTransactionID: nil,
            dataRoot: fixture.dataRoot
        )

        #expect(publication.renderProof == nil)
        #expect(publication.renderRoutingProof == nil)
        #expect(publication.framesManifest?.path == PipelineLayout.framesManifestFile)
        #expect(
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "frames"
            ) == publication
        )
        let frameURL = PipelineLayout.url("frame.png", in: fixture.dataRoot)
        let frameProvenance = try PipelineRenderRecordWriter
            .requireCurrentShotProvenance(
                dataRoot: fixture.dataRoot,
                phase: "frames",
                shotID: "s001"
            )
        #expect(frameProvenance.proof.outputs == [RenderPublishedArtifactV1(
            path: "frame.png",
            sha256: try FileDigest.sha256(of: frameURL)
        )])
        let frameData = try Data(contentsOf: frameURL)
        try Data("replaced-frame".utf8).write(to: frameURL, options: .atomic)
        #expect(throws: PipelineRenderRecordError.self) {
            _ = try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "frames"
            )
        }
        try frameData.write(to: frameURL, options: .atomic)

        try Data("tampered".utf8).write(
            to: PipelineLayout.url(PipelineLayout.framesManifestFile, in: fixture.dataRoot),
            options: .atomic
        )
        #expect(throws: PipelineRenderRecordError.self) {
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "frames"
            )
        }
    }

    @Test("Failure after canonical writes restores every prior byte")
    func publicationFailureRollsBackAllArtifacts() throws {
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        var initialManifest = RenderManifest(project: "demo", phase: "frames")
        record(
            &initialManifest,
            shotId: "s001",
            output: "first.png",
            costEur: 0.1,
            phase: "frames"
        )
        let initialFrames = FramesManifest(
            project: "demo",
            generated: "2026-08-31T00:00:00+00:00",
            shots: [
                ShotFrames(
                    shotId: "s001",
                    keyframeStrategy: "start",
                    frames: [FrameEntry(role: "start", path: "first.png")]
                ),
            ]
        )
        let initialPublication = try PipelineRenderRecordWriter.publish(
            manifest: initialManifest,
            proof: nil,
            routingProof: nil,
            framesManifest: initialFrames,
            replacingShotID: "s001",
            preparedLastFrame: nil,
            expectedPublicationTransactionID: nil,
            dataRoot: fixture.dataRoot
        )
        let provenancePublicationPath = RenderShotProvenancePublicationV1.artifactPath(
            phase: "frames"
        )
        let provenancePublication = try JSONDecoder().decode(
            RenderShotProvenancePublicationV1.self,
            from: Data(
                contentsOf: PipelineLayout.url(
                    provenancePublicationPath,
                    in: fixture.dataRoot
                )
            )
        )
        let immutableProofPath = try #require(
            provenancePublication.proofs["s001"]?.path
        )
        let paths = [
            PipelineLayout.renderManifestFile(phase: "frames"),
            PipelineLayout.framesManifestFile,
            provenancePublicationPath,
            immutableProofPath,
            RenderRecordPublicationV1.artifactPath(phase: "frames"),
        ]
        let before = try Dictionary(uniqueKeysWithValues: paths.map {
            ($0, try Data(contentsOf: PipelineLayout.url($0, in: fixture.dataRoot)))
        })
        var changedManifest = initialManifest
        record(
            &changedManifest,
            shotId: "s002",
            output: "second.png",
            costEur: 0.2,
            phase: "frames"
        )
        let changedFrames = FramesManifest(
            project: "demo",
            generated: "2026-08-31T00:01:00+00:00",
            shots: [
                ShotFrames(
                    shotId: "s001",
                    keyframeStrategy: "start",
                    frames: [FrameEntry(role: "start", path: "first.png")]
                ),
                ShotFrames(
                    shotId: "s002",
                    keyframeStrategy: "start",
                    frames: [FrameEntry(role: "start", path: "second.png")]
                ),
            ]
        )

        #expect(throws: PipelineRenderRecordError.self) {
            _ = try PipelineRenderRecordWriter.publish(
                manifest: changedManifest,
                proof: nil,
                routingProof: nil,
                framesManifest: changedFrames,
                replacingShotID: "s002",
                preparedLastFrame: nil,
                expectedPublicationTransactionID: initialPublication.transactionID,
                dataRoot: fixture.dataRoot,
                failureProbe: { point in
                    if point == .publication { throw InjectedFailure.stop }
                }
            )
        }
        for path in paths {
            #expect(
                try Data(contentsOf: PipelineLayout.url(path, in: fixture.dataRoot))
                    == before[path]
            )
        }
        #expect(
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "frames"
            ) != nil
        )
    }

    @Test("Required predecessor frame is committed with exact source provenance")
    func lastFramePublicationIsExactAndRollbackSafe() throws {
        let fixture = try makeDataRoot(project: "project-001")
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let outputPath = "render.mov"
        let outputURL = fixture.home.appendingPathComponent(outputPath)
        let outputData = Data("render-v1".utf8)
        try outputData.write(to: outputURL, options: .atomic)
        let outputSHA = FileDigest.sha256(of: outputData)
        let lastFramePath = "render.last_frame.png"
        let firstFrameData = Data("png-v1".utf8)
        let shotID = "shot-001"
        var manifest = RenderManifest(project: "project-001", phase: "preview")
        record(
            &manifest,
            shotId: shotID,
            output: outputPath,
            costEur: 0.2,
            phase: "preview",
            lastFramePath: lastFramePath
        )
        let proof = RenderProofManifest(
            project: "project-001",
            phase: "preview",
            entries: [
                shotID: RenderProofEntry(
                    shotId: shotID,
                    output: outputPath,
                    outputSha256: outputSHA,
                    providerPrompt: "Compiled video prompt.",
                    generationModel: "fixture-model"
                ),
            ]
        )
        let generation = try #require(
            PipelineProductionRoutingTests.generationInput(
                requirement: PipelineProductionRoutingTests.requirement()
            ).productionRouting
        )
        let routing = PipelineRenderRoutingProofManifestV1(
            project: "project-001",
            phase: "preview",
            entries: [
                shotID: PipelineRenderRoutingProofEntryV1(
                    shotID: shotID,
                    output: outputPath,
                    outputSHA256: outputSHA,
                    generation: generation
                ),
            ]
        )
        let firstProof = RenderLastFrameProofV1(
            shotID: shotID,
            phase: "preview",
            path: lastFramePath,
            sha256: FileDigest.sha256(of: firstFrameData),
            sourceOutput: outputPath,
            sourceOutputSHA256: outputSHA,
            extractedAt: "2026-08-31T00:00:00+00:00"
        )
        let initialPublication = try PipelineRenderRecordWriter.publish(
            manifest: manifest,
            proof: proof,
            routingProof: routing,
            framesManifest: nil,
            replacingShotID: shotID,
            preparedLastFrame: .init(proof: firstProof, data: firstFrameData),
            expectedPublicationTransactionID: nil,
            dataRoot: fixture.dataRoot
        )
        let frameURL = fixture.home.appendingPathComponent(lastFramePath)
        let publicationPath = RenderRecordPublicationV1.artifactPath(phase: "preview")
        let publicationBefore = try Data(
            contentsOf: PipelineLayout.url(publicationPath, in: fixture.dataRoot)
        )
        #expect(try Data(contentsOf: frameURL) == firstFrameData)
        #expect(
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "preview"
            )?.lastFrames[shotID] == firstProof
        )

        let replacementData = Data("png-v2".utf8)
        let replacementProof = RenderLastFrameProofV1(
            shotID: shotID,
            phase: "preview",
            path: lastFramePath,
            sha256: FileDigest.sha256(of: replacementData),
            sourceOutput: outputPath,
            sourceOutputSHA256: outputSHA,
            extractedAt: "2026-08-31T00:01:00+00:00"
        )
        #expect(throws: PipelineRenderRecordError.self) {
            _ = try PipelineRenderRecordWriter.publish(
                manifest: manifest,
                proof: proof,
                routingProof: routing,
                framesManifest: nil,
                replacingShotID: shotID,
                preparedLastFrame: .init(
                    proof: replacementProof,
                    data: replacementData
                ),
                expectedPublicationTransactionID: initialPublication.transactionID,
                dataRoot: fixture.dataRoot,
                failureProbe: { point in
                    if point == .renderManifest { throw InjectedFailure.stop }
                }
            )
        }
        #expect(try Data(contentsOf: frameURL) == firstFrameData)
        #expect(
            try Data(
                contentsOf: PipelineLayout.url(publicationPath, in: fixture.dataRoot)
            ) == publicationBefore
        )
    }

    @Test("Changed provenance produces a new content-addressed core asset version")
    func changedProvenanceReidentifiesCoreAsset() throws {
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let cases = [
            (
                kind: CoreAssetProvenanceKindIDV1.approvedFrame,
                path: "approved-frame.png",
                shotID: "shot-frame",
                roleID: CoreReferenceSemanticJobIDV1.firstFrame,
                proofPath: RenderRecordPublicationV1.artifactPath(phase: "frames")
            ),
            (
                kind: CoreAssetProvenanceKindIDV1.renderFrame,
                path: "predecessor-frame.png",
                shotID: "shot-render",
                roleID: CoreReferenceSemanticJobIDV1.lastFrame,
                proofPath: PipelineLayout.renderProofFile(phase: "preview")
            ),
        ]
        for item in cases {
            let bytes = Data("same-frame-bytes".utf8)
            try bytes.write(
                to: fixture.dataRoot.appendingPathComponent(item.path),
                options: .atomic
            )
            let oldProvenance = AssetProvenanceV1(
                kindID: item.kind,
                sourceShotID: item.shotID,
                sourceRoleID: item.roleID,
                sourceProofPath: item.proofPath,
                sourceProofSHA256: String(repeating: "a", count: 64),
                recordedAt: "2026-08-31T00:00:00Z"
            )
            let currentProvenance = AssetProvenanceV1(
                kindID: item.kind,
                sourceShotID: item.shotID,
                sourceRoleID: item.roleID,
                sourceProofPath: item.proofPath,
                sourceProofSHA256: String(repeating: "b", count: 64),
                recordedAt: "2026-08-31T00:01:00Z"
            )
            let existing = AssetGraphNodeV1(
                id: "asset-\(item.shotID)",
                version: 1,
                path: item.path,
                sha256: FileDigest.sha256(of: bytes),
                modality: .image,
                approval: .approved,
                provenance: oldProvenance,
                allowedUseIDs: [item.roleID]
            )
            var assets = [item.path: existing]

            let refreshed = try PipelineProductionInputsWriter.upsertingAsset(
                path: item.path,
                modality: .image,
                semanticJobID: item.roleID,
                provenance: currentProvenance,
                assetsByPath: &assets,
                dataRoot: fixture.dataRoot
            )

            #expect(refreshed.id != existing.id)
            #expect(refreshed.version == 2)
            #expect(refreshed.provenance == currentProvenance)
            #expect(assets[item.path]?.provenance == currentProvenance)
        }
    }

    @Test("Phase preparation reconciles Frames through a fresh atomic publication")
    func phasePreparationReconcilesFramesTransactionally() throws {
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        var manifest = RenderManifest(project: "demo", phase: "frames")
        record(
            &manifest,
            shotId: "s001",
            output: "frame.png",
            costEur: 0.1,
            phase: "frames"
        )
        let frames = FramesManifest(
            project: "demo",
            generated: "2026-08-31T00:00:00Z",
            shots: [
                ShotFrames(
                    shotId: "s001",
                    keyframeStrategy: "start",
                    frames: [FrameEntry(role: "start", path: "frame.png")]
                ),
            ]
        )
        let before = try PipelineRenderRecordWriter.publish(
            manifest: manifest,
            proof: nil,
            routingProof: nil,
            framesManifest: frames,
            replacingShotID: "s001",
            preparedLastFrame: nil,
            expectedPublicationTransactionID: nil,
            dataRoot: fixture.dataRoot
        )

        let after = try PipelineRenderRecordWriter.reconcilePhasePreparation(
            shotlist: try importedOnlyShotlist(),
            phase: "frames",
            dataRoot: fixture.dataRoot
        )

        #expect(after.transactionID != before.transactionID)
        #expect(try loadFramesManifest(dataRoot: fixture.dataRoot).shots.isEmpty)
        #expect(
            try loadRenderManifest(
                dataRoot: fixture.dataRoot,
                phase: "frames"
            ).entries.isEmpty
        )
        #expect(
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "frames"
            ) == after
        )
    }

    @Test("Final preparation filters render and routing proofs in one publication")
    func finalPreparationReconcilesRoutingTransactionally() throws {
        let fixture = try makeDataRoot(project: "project-001")
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let outputPath = "render.mov"
        let outputData = Data("render-output".utf8)
        try outputData.write(
            to: fixture.home.appendingPathComponent(outputPath),
            options: .atomic
        )
        let outputSHA256 = FileDigest.sha256(of: outputData)
        var manifest = RenderManifest(project: "project-001", phase: "final")
        record(
            &manifest,
            shotId: "shot-001",
            output: outputPath,
            costEur: 0.2,
            phase: "final"
        )
        let proof = RenderProofManifest(
            project: "project-001",
            phase: "final",
            entries: [
                "shot-001": RenderProofEntry(
                    shotId: "shot-001",
                    output: outputPath,
                    outputSha256: outputSHA256,
                    providerPrompt: "Compiled prompt.",
                    generationModel: "fixture-model"
                ),
            ]
        )
        let generation = try #require(
            PipelineProductionRoutingTests.generationInput(
                requirement: PipelineProductionRoutingTests.requirement()
            ).productionRouting
        )
        let routing = PipelineRenderRoutingProofManifestV1(
            project: "project-001",
            phase: "final",
            entries: [
                "shot-001": PipelineRenderRoutingProofEntryV1(
                    shotID: "shot-001",
                    output: outputPath,
                    outputSHA256: outputSHA256,
                    generation: generation
                ),
            ]
        )
        let before = try PipelineRenderRecordWriter.publish(
            manifest: manifest,
            proof: proof,
            routingProof: routing,
            framesManifest: nil,
            replacingShotID: "shot-001",
            preparedLastFrame: nil,
            expectedPublicationTransactionID: nil,
            dataRoot: fixture.dataRoot
        )

        let after = try PipelineRenderRecordWriter.reconcilePhasePreparation(
            shotlist: try importedOnlyShotlist(project: "project-001"),
            phase: "final",
            dataRoot: fixture.dataRoot
        )

        #expect(after.transactionID != before.transactionID)
        #expect(
            try loadRenderManifest(
                dataRoot: fixture.dataRoot,
                phase: "final"
            ).entries.isEmpty
        )
        #expect(
            try loadRenderProofManifest(
                dataRoot: fixture.dataRoot,
                phase: "final"
            ).entries.isEmpty
        )
        #expect(
            try PipelineRenderRoutingProofStore.load(
                dataRoot: fixture.dataRoot,
                phase: "final"
            ).entries.isEmpty
        )
        #expect(
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "final"
            ) == after
        )
    }

    @Test("A truncated stale lock cannot brick a render phase")
    func truncatedStaleLockRecovers() throws {
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let lockURL = PipelineLayout.url(
            "renders/.record-frames.in-progress",
            in: fixture.dataRoot
        )
        try Data("truncated".utf8).write(to: lockURL, options: .atomic)

        let snapshot = try PipelineRenderRecordWriter.loadMutationSnapshot(
            dataRoot: fixture.dataRoot,
            phase: "frames"
        )

        #expect(snapshot.manifest.phase == "frames")
        #expect(!FileManager.default.fileExists(atPath: lockURL.path))
    }

    @Test("Final preparation refuses a rendered predecessor without its required last-frame proof")
    func finalPreparationRequiresChainedPredecessorProof() throws {
        let fixture = try makeDataRoot(project: "project-001")
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let outputPath = "render.mov"
        let outputData = Data("render-output".utf8)
        try outputData.write(
            to: fixture.home.appendingPathComponent(outputPath),
            options: .atomic
        )
        let outputSHA256 = FileDigest.sha256(of: outputData)
        let shotID = "shot-001"
        var manifest = RenderManifest(project: "project-001", phase: "final")
        record(
            &manifest,
            shotId: shotID,
            output: outputPath,
            costEur: 0.2,
            phase: "final"
        )
        let generation = try #require(
            PipelineProductionRoutingTests.generationInput(
                requirement: PipelineProductionRoutingTests.requirement()
            ).productionRouting
        )
        let proof = RenderProofManifest(
            project: "project-001",
            phase: "final",
            entries: [
                shotID: RenderProofEntry(
                    shotId: shotID,
                    output: outputPath,
                    outputSha256: outputSHA256,
                    providerPrompt: "Compiled prompt.",
                    generationModel: generation.modelID
                ),
            ]
        )
        let routing = PipelineRenderRoutingProofManifestV1(
            project: "project-001",
            phase: "final",
            entries: [
                shotID: PipelineRenderRoutingProofEntryV1(
                    shotID: shotID,
                    output: outputPath,
                    outputSHA256: outputSHA256,
                    generation: generation
                ),
            ]
        )
        let publication = try PipelineRenderRecordWriter.publish(
            manifest: manifest,
            proof: proof,
            routingProof: routing,
            framesManifest: nil,
            replacingShotID: shotID,
            preparedLastFrame: nil,
            expectedPublicationTransactionID: nil,
            dataRoot: fixture.dataRoot
        )

        #expect(throws: PipelineRenderRecordError.self) {
            _ = try PipelineRenderRecordWriter.reconcilePhasePreparation(
                shotlist: try chainedShotlist(),
                phase: "final",
                dataRoot: fixture.dataRoot
            )
        }
        #expect(
            try PipelineRenderRecordWriter.requireCurrentPublicationIfPresent(
                dataRoot: fixture.dataRoot,
                phase: "final"
            ) == publication
        )
    }

    @Test("Three chained renders retain immutable predecessor provenance")
    func threeChainedRendersRetainImmutablePredecessorProvenance() throws {
        let fixture = try makeDataRoot(project: "project-001")
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        var manifest = RenderManifest(project: "project-001", phase: "final")
        var proofEntries: [String: RenderProofEntry] = [:]
        var routingEntries: [String: PipelineRenderRoutingProofEntryV1] = [:]
        var publicationTransactionID: String?
        var immutableArtifacts: [String: RenderPublishedArtifactV1] = [:]
        var predecessorAssets: [String: AssetGraphNodeV1] = [:]

        for index in 1...3 {
            let shotID = String(format: "shot-%03d", index)
            let outputPath = "renders/\(shotID).mov"
            let outputData = Data("video-\(index)".utf8)
            let outputURL = fixture.home.appendingPathComponent(outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try outputData.write(to: outputURL, options: .atomic)
            let outputSHA256 = FileDigest.sha256(of: outputData)
            let lastFramePath = "renders/\(shotID).last-frame.png"
            let lastFrameData = Data("last-frame-\(index)".utf8)
            let generation = try validGenerationProof(
                shotID: shotID,
                predecessor: index == 1
                    ? nil
                    : predecessorAssets[String(format: "shot-%03d", index - 1)]
            )
            record(
                &manifest,
                shotId: shotID,
                output: outputPath,
                costEur: 0.1,
                phase: "final",
                lastFramePath: lastFramePath
            )
            proofEntries[shotID] = RenderProofEntry(
                shotId: shotID,
                output: outputPath,
                outputSha256: outputSHA256,
                providerPrompt: "Compiled prompt for \(shotID).",
                generationModel: generation.modelID,
                startFrame: index == 1 ? nil : RenderInputProof(
                    path: predecessorAssets[
                        String(format: "shot-%03d", index - 1)
                    ]!.path,
                    sha256: predecessorAssets[
                        String(format: "shot-%03d", index - 1)
                    ]!.sha256
                )
            )
            routingEntries[shotID] = PipelineRenderRoutingProofEntryV1(
                shotID: shotID,
                output: outputPath,
                outputSHA256: outputSHA256,
                generation: generation
            )
            let lastFrameProof = RenderLastFrameProofV1(
                shotID: shotID,
                phase: "final",
                path: lastFramePath,
                sha256: FileDigest.sha256(of: lastFrameData),
                sourceOutput: outputPath,
                sourceOutputSHA256: outputSHA256,
                extractedAt: "2026-08-31T00:0\(index):00Z"
            )
            let publication = try PipelineRenderRecordWriter.publish(
                manifest: manifest,
                proof: RenderProofManifest(
                    project: "project-001",
                    phase: "final",
                    entries: proofEntries
                ),
                routingProof: PipelineRenderRoutingProofManifestV1(
                    project: "project-001",
                    phase: "final",
                    entries: routingEntries
                ),
                framesManifest: nil,
                replacingShotID: shotID,
                preparedLastFrame: .init(
                    proof: lastFrameProof,
                    data: lastFrameData
                ),
                expectedPublicationTransactionID: publicationTransactionID,
                dataRoot: fixture.dataRoot
            )
            publicationTransactionID = publication.transactionID

            for priorIndex in 1...index {
                let priorShotID = String(format: "shot-%03d", priorIndex)
                let provenance = try PipelineRenderRecordWriter
                    .requireCurrentShotProvenance(
                        dataRoot: fixture.dataRoot,
                        phase: "final",
                        shotID: priorShotID
                    )
                if let original = immutableArtifacts[priorShotID] {
                    #expect(provenance.artifact == original)
                } else {
                    immutableArtifacts[priorShotID] = provenance.artifact
                }
            }

            let provenance = try PipelineRenderRecordWriter
                .requireCurrentShotProvenance(
                    dataRoot: fixture.dataRoot,
                    phase: "final",
                    shotID: shotID
                )
            #expect(provenance.proof.outputs.contains(
                RenderPublishedArtifactV1(
                    path: outputPath,
                    sha256: outputSHA256
                )
            ))
            #expect(provenance.proof.outputs.contains(
                RenderPublishedArtifactV1(
                    path: lastFramePath,
                    sha256: lastFrameProof.sha256
                )
            ))
            if index > 1,
               let predecessor = predecessorAssets[
                   String(format: "shot-%03d", index - 1)
               ] {
                let predecessorProofPath = try #require(
                    predecessor.provenance.sourceProofPath
                )
                let predecessorProofSHA256 = try #require(
                    predecessor.provenance.sourceProofSHA256
                )
                #expect(provenance.proof.dependencies.contains(
                    RenderPublishedArtifactV1(
                        path: predecessor.path,
                        sha256: predecessor.sha256
                    )
                ))
                #expect(provenance.proof.dependencies.contains(
                    RenderPublishedArtifactV1(
                        path: predecessorProofPath,
                        sha256: predecessorProofSHA256
                    )
                ))
            }
            let predecessorAsset = try AssetGraphContentAddressV1.reidentified(
                AssetGraphNodeV1(
                    id: "pending",
                    version: 1,
                    path: lastFramePath,
                    sha256: lastFrameProof.sha256,
                    modality: .image,
                    approval: .approved,
                    provenance: AssetProvenanceV1(
                        kindID: CoreAssetProvenanceKindIDV1.renderFrame,
                        sourceShotID: shotID,
                        sourceRoleID: CoreReferenceSemanticJobIDV1.lastFrame,
                        sourceProofPath: provenance.artifact.path,
                        sourceProofSHA256: provenance.artifact.sha256,
                        recordedAt: lastFrameProof.extractedAt
                    ),
                    allowedUseIDs: [
                        CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                    ]
                )
            )
            predecessorAssets[shotID] = predecessorAsset
        }

        let graphAssets = (1...2).compactMap {
            predecessorAssets[String(format: "shot-%03d", $0)]
        }
        let graph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: "project-001",
                assets: graphAssets
            ),
            projectID: "project-001",
            assets: graphAssets
        )
        try AssetGraphValidatorV1.validateProjectFiles(
            graph,
            dataRoot: fixture.dataRoot
        )
        let shotTwoGeneration = try #require(
            routingEntries["shot-002"]?.generation
        )
        let historicalAssetID = try #require(
            shotTwoGeneration.orderedBindings.first?.graphAssetID
        )
        let shotOneAsset = try #require(predecessorAssets["shot-001"])
        let rotatedCurrentAsset = try AssetGraphContentAddressV1.reidentified(
            AssetGraphNodeV1(
                id: "pending",
                version: shotOneAsset.version + 1,
                path: shotOneAsset.path,
                sha256: shotOneAsset.sha256,
                modality: shotOneAsset.modality,
                approval: shotOneAsset.approval,
                provenance: AssetProvenanceV1(
                    kindID: shotOneAsset.provenance.kindID,
                    sourceShotID: shotOneAsset.provenance.sourceShotID,
                    sourceRoleID: shotOneAsset.provenance.sourceRoleID,
                    sourceProofPath: shotOneAsset.provenance.sourceProofPath,
                    sourceProofSHA256: shotOneAsset.provenance.sourceProofSHA256,
                    recordedAt: "2026-08-31T00:10:00Z"
                ),
                allowedUseIDs: shotOneAsset.allowedUseIDs
            )
        )
        #expect(historicalAssetID == shotOneAsset.id)
        #expect(rotatedCurrentAsset.id != historicalAssetID)
        try PipelineProductionRouting.validateHistoricalProof(
            shotTwoGeneration,
            dataRoot: fixture.dataRoot
        )
        #expect(immutableArtifacts.count == 3)
        #expect(Set(predecessorAssets.keys).count == 3)
    }

    @Test("Historical routing rejects a self-consistent divergent offering contract")
    func historicalRoutingRejectsDivergentOfferingContract() throws {
        let fixture = try makeDataRoot()
        defer { try? FileManager.default.removeItem(at: fixture.cleanup) }
        let proof = try validGenerationProof(
            shotID: "shot-001",
            predecessor: nil
        )
        try PipelineProductionRouting.validateHistoricalProof(
            proof,
            dataRoot: fixture.dataRoot
        )

        let divergentCapabilities = PipelineProductionRoutingTests.videoCapabilities(
            supportsNativeAudio: false
        )
        let divergentCapabilitiesData = try ReferencePlanCanonicalCodecV2.encode(
            divergentCapabilities
        )
        func replacingCapabilities(
            sha256: String
        ) -> ProductionGenerationRoutingProofV1 {
            ProductionGenerationRoutingProofV1(
                projectID: proof.projectID,
                shotID: proof.shotID,
                modelID: proof.modelID,
                providerID: proof.providerID,
                transportID: proof.transportID,
                endpointID: proof.endpointID,
                modelParam: proof.modelParam,
                offeringID: proof.offeringID,
                requirement: proof.requirement,
                route: proof.route,
                referencePlan: proof.referencePlan,
                routeArtifactSHA256: proof.routeArtifactSHA256,
                requirementSHA256: proof.requirementSHA256,
                capabilitiesSHA256: proof.capabilitiesSHA256,
                routeSHA256: proof.routeSHA256,
                referencePlanSHA256: proof.referencePlanSHA256,
                orderedBindingsSHA256: proof.orderedBindingsSHA256,
                orderedBindings: proof.orderedBindings,
                offeringCapabilities: divergentCapabilities,
                offeringCapabilitiesSHA256: sha256,
                historicalAssetGraph: proof.historicalAssetGraph,
                historicalDemandSet: proof.historicalDemandSet
            )
        }

        #expect(throws: PipelineProductionRoutingError.self) {
            try PipelineProductionRouting.validateHistoricalProof(
                replacingCapabilities(sha256: proof.offeringCapabilitiesSHA256),
                dataRoot: fixture.dataRoot
            )
        }
        let divergentProof = replacingCapabilities(
            sha256: FileDigest.sha256(of: divergentCapabilitiesData)
        )

        #expect(throws: PipelineProductionRoutingError.self) {
            try PipelineProductionRouting.validateHistoricalProof(
                divergentProof,
                dataRoot: fixture.dataRoot
            )
        }
    }

    private func validGenerationProof(
        shotID: String,
        predecessor: AssetGraphNodeV1?
    ) throws -> ProductionGenerationRoutingProofV1 {
        let modelID = "fixture-model"
        let providerID = GenerationProvider.fal.rawValue
        let transportID = ProviderTransport.api.rawValue
        let endpointID = modelID
        let offeringID = [providerID, transportID, endpointID, modelID]
            .joined(separator: "/")
        let requirement = ProductionRequirementV1(
            modalityID: CapabilityModalityV1.video.rawValue,
            modeIDs: ["image-to-video"],
            visibleEntityCount: 0,
            requiresFirstFrame: predecessor != nil,
            duration: RequestedDurationV1(
                preferredSeconds: 5,
                minimumSeconds: 5,
                maximumSeconds: 5
            ),
            resolution: "720p",
            aspectRatio: "16:9",
            requiresOutputAudio: true
        )
        let base = try #require(
            PipelineProductionRoutingTests.generationInput(
                requirement: PipelineProductionRoutingTests.requirement(),
                modelID: modelID
            ).productionRouting
        )
        let offering = CapabilityOfferingIdentityV1(
            providerID: providerID,
            offeringID: offeringID,
            endpointID: endpointID,
            catalogModelID: modelID,
            modality: .video
        )
        let origin = ResolvedCapabilityOriginV1(
            kind: .exact,
            profileID: "immutable-proof-fixture"
        )
        var fields = base.route.capabilitySnapshot.capabilities.effective.fields
        fields.integers[CapabilityFieldIDV1.visibleCharacters] =
            ResolvedCapabilityValueV1(
                value: 0,
                semantics: .hardAPILimit,
                origin: origin,
                evidence: []
            )
        fields.booleans[CapabilityFieldIDV1.firstFrame] =
            ResolvedCapabilityValueV1(
                value: predecessor != nil,
                semantics: .hardAPILimit,
                origin: origin,
                evidence: []
            )
        let profile = ResolvedCapabilityProfileV1(
            requestedIdentity: nil,
            resolvedIdentity: nil,
            defensiveProfileID: nil,
            researchNeeded: false,
            fields: fields
        )
        let capabilities = ResolvedOfferingCapabilityProfileV1(
            offering: offering,
            intrinsic: profile,
            effective: profile
        )
        let inputSlots: [ProductionInputSlotCapabilityV1] = predecessor == nil
            ? []
            : [ProductionInputSlotCapabilityV1(
                id: CoreReferenceInputSlotIDV1.firstFrame,
                modality: .image,
                modeIDs: ["image-to-video"],
                requestOrder: 0,
                countsTowardModalityBudget: false,
                countsTowardTotalBudget: false,
                countsTowardCombinedDuration: false
            )]
        let candidate = ProductionRouteCandidateV1(
            capabilities: capabilities,
            providerActivated: true,
            liveAvailable: true,
            inputSlots: inputSlots
        )
        let fingerprints = try ProductionRequirementResolverV1.fingerprints(
            requirement: requirement,
            candidate: candidate
        )
        let route = ProductionRouteV1(
            id: "route-\(shotID)",
            projectID: "project-001",
            shotID: shotID,
            offering: offering,
            capabilitySnapshot: ProductionRouteCapabilitySnapshotV1(
                candidate: candidate
            ),
            requirementSHA256: fingerprints.requirementSHA256,
            capabilitiesSHA256: fingerprints.capabilitiesSHA256,
            routeSHA256: fingerprints.routeSHA256,
            researchNeeded: false,
            qualityScore: 0,
            preferenceScore: 0,
            estimatedCost: nil,
            estimatedLatencySeconds: nil
        )
        let bindings: [ReferenceBindingV2]
        let submittedBindings: [ProductionGenerationRoutingBindingV1]
        let demands: [ReferenceDemandV1]
        if let predecessor {
            let sourceShotID = try #require(
                predecessor.provenance.sourceShotID
            )
            let demand = ReferenceDemandV1(
                id: "predecessor-\(shotID)",
                assetID: predecessor.id,
                modality: .image,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                isRequired: true,
                priority: 100,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                modeID: "image-to-video",
                expectedSourceShotID: sourceShotID
            )
            let binding = ReferenceBindingV2(demand: demand, asset: predecessor)
            demands = [demand]
            bindings = [binding]
            submittedBindings = [ProductionGenerationRoutingBindingV1(
                demandID: binding.demandID,
                graphAssetID: binding.assetID,
                graphAssetVersion: binding.assetVersion,
                mediaAssetID: "media-\(sourceShotID)",
                path: binding.path,
                sha256: binding.sha256,
                modalityID: binding.modality.rawValue,
                semanticJobID: binding.semanticJobID,
                inputSlotID: binding.inputSlotID,
                modeID: binding.modeID
            )]
        } else {
            demands = []
            bindings = []
            submittedBindings = []
        }
        let historicalAssets = predecessor.map { [$0] } ?? []
        let historicalGraph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: "project-001",
                assets: historicalAssets
            ),
            projectID: "project-001",
            assets: historicalAssets
        )
        let graphData = try AssetGraphCanonicalCodecV1.encode(historicalGraph)
        let historicalDemandSet = ReferenceDemandSetV1(
            id: "demand-set-\(shotID)",
            projectID: "project-001",
            shotID: shotID,
            assetGraph: CanonicalArtifactReferenceV1(
                id: historicalGraph.id,
                role: AssetGraphV1.artifactRole,
                path: PipelineLayout.assetGraphFile,
                sha256: FileDigest.sha256(of: graphData)
            ),
            demands: demands
        )
        let demandData = try AssetGraphCanonicalCodecV1.encode(
            historicalDemandSet
        )
        let plan = ReferencePlanV2(
            id: "reference-plan-\(shotID)",
            projectID: "project-001",
            shotID: shotID,
            demandSet: CanonicalArtifactReferenceV1(
                id: historicalDemandSet.id,
                role: ReferenceDemandSetV1.artifactRole,
                path: PipelineLayout.referenceDemandSetFile(shotID: shotID),
                sha256: FileDigest.sha256(of: demandData)
            ),
            route: ReferencePlanRouteBindingV2(
                offering: offering,
                requirementSHA256: route.requirementSHA256,
                capabilitiesSHA256: route.capabilitiesSHA256,
                routeSHA256: route.routeSHA256
            ),
            budget: ReferencePlanBudgetV2(
                imageCount: 0,
                videoCount: 0,
                audioCount: 0,
                geometryCount: 0,
                totalCount: 0
            ),
            bindings: bindings,
            optionalDrops: []
        )
        return ProductionGenerationRoutingProofV1(
            projectID: "project-001",
            shotID: shotID,
            modelID: modelID,
            providerID: providerID,
            transportID: transportID,
            endpointID: endpointID,
            modelParam: nil,
            offeringID: offeringID,
            requirement: requirement,
            route: route,
            referencePlan: plan,
            routeArtifactSHA256: FileDigest.sha256(
                of: try ReferencePlanCanonicalCodecV2.encode(route)
            ),
            requirementSHA256: route.requirementSHA256,
            capabilitiesSHA256: route.capabilitiesSHA256,
            routeSHA256: route.routeSHA256,
            referencePlanSHA256: FileDigest.sha256(
                of: try ReferencePlanCanonicalCodecV2.encode(plan)
            ),
            orderedBindingsSHA256: FileDigest.sha256(
                of: try ReferencePlanCanonicalCodecV2.encode(bindings)
            ),
            orderedBindings: submittedBindings,
            offeringCapabilities: base.offeringCapabilities,
            offeringCapabilitiesSHA256: base.offeringCapabilitiesSHA256,
            historicalAssetGraph: historicalGraph,
            historicalDemandSet: historicalDemandSet
        )
    }

    private func importedOnlyShotlist(project: String = "demo") throws -> Shotlist {
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 4
        )
        let shot = try Shot(
            id: "s001",
            section: "intro",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            sourceMode: .imported,
            description: "Imported footage.",
            visualPrompt: "Imported footage.",
            mood: "restrained",
            keyframeStrategy: .none
        )
        return try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: project,
            song: song,
            generated: "2026-08-31T00:00:00Z",
            generator: "test",
            shots: [shot]
        )
    }

    private func chainedShotlist() throws -> Shotlist {
        let song = try Song(
            title: "song",
            audioPath: "audio/song.wav",
            analysisPath: "analysis/song.json",
            bpm: 120,
            durationS: 8
        )
        let first = try Shot(
            id: "shot-001",
            section: "intro",
            timeStart: 0,
            timeEnd: 4,
            durationS: 4,
            type: .performance,
            description: "First shot.",
            visualPrompt: "First shot.",
            mood: "restrained",
            keyframeStrategy: .start
        )
        let successor = try Shot(
            id: "shot-002",
            section: "verse",
            timeStart: 4,
            timeEnd: 8,
            durationS: 4,
            type: .performance,
            description: "Continue the composition.",
            visualPrompt: "Continue the composition.",
            mood: "restrained",
            keyframeStrategy: .none,
            seedanceInputMode: .keyframe,
            chainWithPreviousEnd: true
        )
        return try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "project-001",
            song: song,
            generated: "2026-08-31T00:00:00Z",
            generator: "test",
            shots: [first, successor]
        )
    }

    private func makeDataRoot(
        project: String = "demo"
    ) throws -> (cleanup: URL, home: URL, dataRoot: URL) {
        let cleanup = FileManager.default.temporaryDirectory.appendingPathComponent(
            "render-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(
            home: home,
            name: project,
            mode: .beat
        )
        return (cleanup, home, dataRoot)
    }
}
