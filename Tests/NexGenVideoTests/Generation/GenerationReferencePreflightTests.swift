import AppKit
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Generation reference approval preflight")
@MainActor
struct GenerationReferencePreflightTests {
    @MainActor
    private struct Fixture {
        let project: URL
        let editor: EditorViewModel
        let source: URL
        let reference: MediaAsset
        let framePlan: FrameReferencePlanV1?

        func cleanup() {
            editor.releaseWorkingCopy()
            if let key = ProjectIdentity.existingKey(for: project) { ProjectWorkingCopy.discard(key: key) }
            try? FileManager.default.removeItem(at: project)
        }
    }

    private func fixture(kind: String) throws -> Fixture {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("reference-preflight-\(UUID().uuidString).ngv")
        _ = try ProjectScaffold.initProject(home: project, name: "references")
        try Fixtures.prepareProjectPackage(at: project)
        let editor = EditorViewModel()
        editor.projectURL = project
        let home = try #require(editor.workingRoot)
        let root = try #require(DataRootResolver.dataRoot(of: home))
        let path = "bible/characters/mara/Mara-front.png"
        let source = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(pixels.bitmapData).initialize(repeating: 180, count: pixels.bytesPerRow * pixels.pixelsHigh)
        try #require(pixels.representation(using: .png, properties: [:])).write(to: source)
        let hash = try FileDigest.sha256(of: source)
        let framePlan: FrameReferencePlanV1? = kind == "frame" ? .init(shotID: "shot-1", maxReferenceImages: 1,
            bindings: [.init(path: path, sha256: hash, role: "character", entityID: "mara", viewID: "front",
                purpose: "Identity", requirementIDs: ["identity"], isRequired: true, priority: 0)]) : nil
        let id = kind == "pipeline" ? "pipeline-reference:\(path)" : kind == "frame" ? "frame-reference:0:\(hash)" : "library-mara"
        let reference = MediaAsset(id: id, url: source, type: .image, name: "Mara front", originalFilename: "Mara-front.png")
        if kind == "library" { editor.mediaAssets.append(reference) }
        return .init(project: project, editor: editor, source: source, reference: reference, framePlan: framePlan)
    }

    private func prepare(_ fixture: Fixture) async throws -> GenerationController.PreparedGeneration {
        let target = ResolvedGenerationTarget(modelId: "fixture-image", provider: .fal, endpoint: "fixture-image", binding: nil)
        let request = GenerationRequest(modality: .image, modelId: target.modelId, intent: "", aspectRatio: "1:1",
            placement: .mediaLibrary(folderId: nil), origin: .panel, target: target, submission: .image { prompt in
                var input = GenerationInput(prompt: prompt, model: target.modelId, duration: 0, aspectRatio: "1:1")
                input.frameReferencePlan = fixture.framePlan
                return ImageGenerationSubmission(genInput: input, references: [fixture.reference], name: "Mara front",
                    numImages: 1, folderId: nil, buildParams: {
                        .image(.init(prompt: prompt, aspectRatio: "1:1", resolution: nil, quality: nil, imageURLs: $0, numImages: 1))
                    })
            })
        return try await GenerationController.prepare(request, editor: fixture.editor).get()
    }

    private func package(_ fixture: Fixture) async throws -> GenerationPackageV1 {
        let generation = try await prepare(fixture)
        let package = try await GenerationController.prepareReviewPackage(generation, editor: fixture.editor,
            quoteLoader: { _, _ in throw NSError(domain: "pricing-unavailable", code: 1) })
        try await GenerationPackageInputs.persist(package: package, snapshot: #require(generation.references), editor: fixture.editor)
        return package
    }

    private func present(_ package: GenerationPackageV1, editor: EditorViewModel, phase: String = "bible") throws -> GenerationBatch {
        let itemID = UUID().uuidString
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey,
            phase: phase, items: [.init(id: itemID, purpose: "Mara front", package: package)]))
        try editor.generationBatchCoordinator.present(batch, recoveries: [
            itemID: GenerationBatchRecovery(options: []) { _, _ in package },
        ])
        return batch
    }

    private func routedSelection(_ fixture: Fixture) throws -> PipelineProductionRouteSelection {
        let home = try #require(fixture.editor.workingRoot)
        let root = try #require(DataRootResolver.dataRoot(of: home))
        let path = "bible/characters/mara/Mara-front.png"
        let modelID = "bytedance/seedance-2.5/image-to-video"
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let candidate = try #require(catalog.productionRouteCandidates(activation: activation).first { $0.modelID == modelID })
        let target = try #require(candidate.target)
        let mode = try #require(candidate.candidate.inputSlots.first { $0.id == CoreReferenceInputSlotIDV1.firstFrame }?.modeIDs.first)
        let requirement = ProductionRequirementV1(modalityID: "video", modeIDs: [mode], visibleEntityCount: 1,
            requiresFirstFrame: true, duration: .init(preferredSeconds: 5, minimumSeconds: 5, maximumSeconds: 5),
            resolution: "720p", aspectRatio: "16:9", requiresOutputAudio: false)
        let projectID = "references", shotID = "s001"
        let asset = try AssetGraphContentAddressV1.reidentified(AssetGraphNodeV1(id: "pending", version: 1, path: path,
            sha256: try FileDigest.sha256(of: fixture.source), modality: .image, approval: .approved,
            provenance: .init(kindID: "fixture.import", recordedAt: "2026-10-18T00:00:00Z"),
            allowedUseIDs: [CoreReferenceSemanticJobIDV1.firstFrame]))
        let graph = AssetGraphV1(id: try AssetGraphContentAddressV1.graphID(projectID: projectID, assets: [asset]),
            projectID: projectID, assets: [asset])
        let demand = ReferenceDemandV1(id: "mara-anchor", assetID: asset.id, modality: .image,
            semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame, isRequired: true, priority: 0,
            inputSlotID: CoreReferenceInputSlotIDV1.firstFrame, modeID: mode)
        let demandSet = ReferenceDemandSetV1(id: "demands-\(shotID)", projectID: projectID, shotID: shotID,
            assetGraph: .init(id: graph.id, role: AssetGraphV1.artifactRole, path: PipelineLayout.assetGraphFile,
                sha256: FileDigest.sha256(of: try AssetGraphCanonicalCodecV1.encode(graph))), demands: [demand])
        try PipelineProductionInputsWriter.write(graph: graph, demandSets: [demandSet], templates: [
            .init(id: "inputs-\(shotID)", projectID: projectID, shotID: shotID,
                coreInputs: .init(firstFrameModeID: mode)),
        ], dataRoot: root)
        let matches = try ProductionRequirementResolverV1.matchingRoutes(requirement: requirement, demandSet: demandSet,
            assetGraph: graph, dataRoot: root, candidates: [candidate.candidate])
        let route = try #require(matches.first?.route)
        let result = try ReferencePlannerV2.plan(id: "reference-plan-\(shotID)", dataRoot: root, route: route,
            requirement: requirement, demandSet: demandSet, graph: graph, candidate: candidate.candidate)
        guard case .plan(let plan) = result else { throw ToolError("The fixture reference plan is not executable.") }
        return PipelineProductionRouteSelection(modelID: modelID, target: target, requirement: requirement,
            route: route, routeArtifactSHA256: FileDigest.sha256(of: try ReferencePlanCanonicalCodecV2.encode(route)), referencePlan: plan,
            referencePlanSHA256: FileDigest.sha256(of: try ReferencePlanCanonicalCodecV2.encode(plan)),
            orderedBindingsSHA256: FileDigest.sha256(of: try ReferencePlanCanonicalCodecV2.encode(plan.bindings)))
    }

    @Test func routedProjectInputsKeepExactPathsThroughArchivePreflightAndRenderRecord() async throws {
        let fixture = try fixture(kind: "pipeline")
        defer { fixture.cleanup() }
        let home = try #require(fixture.editor.workingRoot)
        let root = try #require(DataRootResolver.dataRoot(of: home))
        let original = try Data(contentsOf: fixture.source)
        let selection = try routedSelection(fixture)
        let shot = try Shot(id: selection.route.shotID, section: "verse", timeStart: 0, timeEnd: 5, durationS: 5,
            type: .performance, description: "Mara holds her pose.", visualPrompt: "Mara holds her opening pose.", mood: "calm")
        _ = try saveShotlist(Shotlist(schema_: shotlistSchemaVersion, mode: .beat, project: "references",
            song: Song(title: "Song", audioPath: "audio/song.wav", analysisPath: "analysis/song.json", bpm: 120, durationS: 5),
            generated: "2026-10-18", generator: "test", shots: [shot]), to: root)
        let executor = ToolExecutor(editor: fixture.editor, enforceHardGates: false)
        let inputs = try await executor.productionVideoInputs(selection: selection, editor: fixture.editor, dataRoot: root)
        let reference = try #require(inputs.assets.frames.first)
        #expect(reference.url.standardizedFileURL.resolvingSymlinksInPath()
            == fixture.source.standardizedFileURL.resolvingSymlinksInPath())
        #expect(reference.id == fixture.reference.id)
        #expect(fixture.editor.mediaAssets.isEmpty)
        #expect(inputs.routingProof.orderedBindings.first?.path == "bible/characters/mara/Mara-front.png")
        #expect(inputs.routingProof.orderedBindings.first?.sha256 == FileDigest.sha256(of: original))

        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries)
        let model = try #require(catalog.video.first(where: { $0.id == selection.modelID }))
        let shotFingerprint = try PromptCompiler.shotFingerprint(shot)
        let request = GenerationRequest(modality: .video, modelId: model.id, intent: "Mara holds her opening pose.", aspectRatio: "16:9",
            durationSeconds: 5, placement: .mediaLibrary(folderId: nil), origin: .panel, target: selection.target,
            submission: .video { prompt in
                var input = GenerationInput(prompt: prompt, model: model.id, duration: 5, aspectRatio: "16:9", resolution: "720p")
                input.videoDuration = .seconds(5)
                input.promptShotId = shot.id
                input.promptProjectKey = fixture.editor.projectId
                input.promptShotFingerprint = shotFingerprint
                input.productionRouting = inputs.routingProof
                return VideoGenerationSubmission.make(genInput: input, model: model,
                    offeringCapabilities: inputs.offeringCapabilities, inputAssets: inputs.assets,
                    placeholderDuration: 5, generateAudio: false)
            })
        let generation = try await GenerationController.prepare(request, editor: fixture.editor).get()
        let package = try await GenerationController.prepareReviewPackage(generation, editor: fixture.editor,
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        let snapshot = try #require(generation.references)
        try await GenerationPackageInputs.persist(package: package, snapshot: snapshot, editor: fixture.editor)
        let restored = try await GenerationPackageInputs.restore(package: package, editor: fixture.editor)
        #expect(restored.sources.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() }
            == [reference.url.standardizedFileURL.resolvingSymlinksInPath()])
        #expect(restored.receipts == package.payload.references)
        let archived = try #require(restored.urls.first)
        #expect(try Data(contentsOf: archived) == original)
        let batch = try present(package, editor: fixture.editor, phase: "render")
        let coordinator = fixture.editor.generationBatchCoordinator
        await coordinator.preflight(editor: fixture.editor, expectedBatchID: batch.id)
        try #require(coordinator.canApprovePending, "\(coordinator.preflightIssue ?? "")")

        let output = home.appendingPathComponent("rendered.mp4")
        try Data("fixture provider output".utf8).write(to: output)
        var recordedInput = package.payload.generationInput
        recordedInput.generationPackageID = package.id
        let rendered = MediaAsset(id: "rendered-video", url: output, type: .video, name: "Mara take", generationInput: recordedInput)
        fixture.editor.mediaAssets.append(rendered)
        func record() async -> ToolResult {
            await executor.execute(name: "record_render", args: ["project_dir": root.path, "phase": "preview",
                "shot_id": shot.id, "output": rendered.id])
        }
        let recorded = await record()
        try #require(!recorded.isError, "\(ToolHarness.textOf(recorded))")
        let proof = try loadRenderProofManifest(dataRoot: root, phase: "preview")
        #expect(proof.entries[shot.id]?.startFrame?.path == "pipeline/bible/characters/mara/Mara-front.png")
        #expect(proof.entries[shot.id]?.startFrame?.sha256 == FileDigest.sha256(of: original))
        let proofURL = root.appendingPathComponent(PipelineLayout.renderProofFile(phase: "preview"))
        let proofBytes = try Data(contentsOf: proofURL)

        let changedImage = try #require(NSBitmapImageRep(data: original))
        let changedPixels = try #require(changedImage.bitmapData)
        changedPixels.pointee ^= 0xff
        let changedBytes = try #require(changedImage.representation(using: .png, properties: [:]))
        #expect(FileDigest.sha256(of: changedBytes) != FileDigest.sha256(of: original))
        let held = fixture.source.appendingPathExtension("held")
        for removed in [false, true] {
            if removed { try FileManager.default.moveItem(at: fixture.source, to: held) }
            else { try changedBytes.write(to: fixture.source) }
            await #expect(throws: (any Error).self) {
                try await executor.productionVideoInputs(selection: selection, editor: fixture.editor, dataRoot: root)
            }
            await #expect(throws: (any Error).self) {
                try await GenerationPackageInputs.restore(package: package, editor: fixture.editor)
            }
            await coordinator.preflight(editor: fixture.editor, expectedBatchID: batch.id)
            #expect(!coordinator.canApprovePending)
            let rejected = await record()
            #expect(rejected.isError)
            #expect(try Data(contentsOf: proofURL) == proofBytes)
            if removed { try FileManager.default.moveItem(at: held, to: fixture.source) }
            else { try original.write(to: fixture.source) }
        }
        #expect(fixture.editor.mediaAssets.map(\.id) == [rendered.id])
        #expect(fixture.editor.generationLog.spendEvents.isEmpty)
    }

    @Test func projectAndFrameReferencesResolveWithoutInventingLibraryEntries() async throws {
        for kind in ["pipeline", "frame"] {
            let fixture = try fixture(kind: kind)
            defer { fixture.cleanup() }
            let package = try await package(fixture)
            #expect(fixture.editor.mediaAssets.isEmpty)
            let resolved = try GenerationPackageInputs.resolveReferences(package: package, editor: fixture.editor)
            #expect(resolved.map(\.url) == [fixture.source])
            #expect(NSImage(contentsOf: try #require(resolved.first).url) != nil)
            let restored = try await GenerationPackageInputs.restore(package: package, editor: fixture.editor)
            #expect(restored.receipts == package.payload.references)
            let batch = try present(package, editor: fixture.editor)
            await fixture.editor.generationBatchCoordinator.preflight(editor: fixture.editor, expectedBatchID: batch.id)
            #expect(fixture.editor.generationBatchCoordinator.canApprovePending)
            #expect(fixture.editor.generationBatchCoordinator.preflightIssue == nil)
            let authority = try GenerationExecutionAuthorityStore(root: fixture.project.appendingPathComponent("test-authority"), hostID: UUID().uuidString)
            let approved = try await GenerationBatchStore.approve(batch, editor: fixture.editor,
                approval: .acceptUnknownPrices, authority: authority)
            #expect(approved.authorityAvailable)
            #expect(approved.journal.executions.allSatisfy { $0.state == .queued })
            #expect(fixture.editor.generationLog.spendEvents.isEmpty)
        }
    }

    @Test func missingLibraryIdentityBlocksBothApprovalsAndRevisionsPreserveTheReferenceFailure() async throws {
        let fixture = try fixture(kind: "library")
        defer { fixture.cleanup() }
        let package = try await package(fixture)
        let batch = try present(package, editor: fixture.editor)
        fixture.editor.mediaAssets.removeAll()
        let coordinator = fixture.editor.generationBatchCoordinator
        coordinator.startsApprovedBatches = false
        await coordinator.preflight(editor: fixture.editor, expectedBatchID: batch.id)
        #expect(!coordinator.canApprovePending)
        #expect(coordinator.preflightIssue?.contains("Mara-front.png") == true)
        await coordinator.approve(editor: fixture.editor, expectedBatchID: batch.id, approval: .acceptUnknownPrices)
        await coordinator.approveForPhase(editor: fixture.editor, expectedBatchID: batch.id)
        #expect(coordinator.pending?.id == batch.id)
        #expect(fixture.editor.phaseSpendApproval.current == nil)
        #expect(fixture.editor.generationLog.spendEvents.isEmpty)
        #expect(coordinator.snapshots.isEmpty)
        let revision = coordinator.revisionMessage()
        #expect(revision.contains(try #require(coordinator.preflightIssue)))
        #expect(!revision.contains("Pricing diagnostics"))
        #expect(!revision.contains(try #require(package.payload.pricingFailure).detail))
        coordinator.requestRevision(editor: fixture.editor)
        fixture.editor.mediaAssets.append(fixture.reference)
        let revised = try present(try await self.package(fixture), editor: fixture.editor)
        #expect(revised.id != batch.id)
        await coordinator.preflight(editor: fixture.editor, expectedBatchID: revised.id)
        #expect(coordinator.canApprovePending)
        let restoredReference = try GenerationPackageInputs.resolveReference(package.payload.references[0], package: package, editor: fixture.editor)
        #expect(NSImage(contentsOf: restoredReference.url) != nil)
    }

    @Test func preparationRejectsAReferenceRemovedBeforeReview() async throws {
        let fixture = try fixture(kind: "library")
        defer { fixture.cleanup() }
        let generation = try await prepare(fixture)
        fixture.editor.mediaAssets.removeAll()
        await #expect(throws: (any Error).self) {
            try await GenerationController.prepareReviewPackage(generation, editor: fixture.editor,
                quoteLoader: { _, _ in GenerationPackageFixture.money() })
        }
        #expect(fixture.editor.generationBatchCoordinator.pending == nil)
        #expect(fixture.editor.generationLog.spendEvents.isEmpty)
    }

    @Test func singleSubmissionRejectsLibraryRemovalAfterReviewBeforeReservingOrDispatching() async throws {
        for removeDuringPricing in [false, true] {
            let fixture = try fixture(kind: "library")
            defer { fixture.cleanup() }
            let generation = try await prepare(fixture)
            let package = try await GenerationController.prepareReviewPackage(generation, editor: fixture.editor,
                quoteLoader: { _, _ in GenerationPackageFixture.money() })
            try await GenerationPackageInputs.persist(package: package, snapshot: #require(generation.references), editor: fixture.editor)
            if !removeDuringPricing { fixture.editor.mediaAssets.removeAll() }
            var quotes = 0
            let outcome = await GenerationController.submitPrepared(generation, editor: fixture.editor,
                quoteLoader: { _, _ in
                    quotes += 1
                    fixture.editor.mediaAssets.removeAll()
                    return GenerationPackageFixture.money()
                })
            guard case .failure(let error) = outcome else {
                Issue.record("A removed library reference reached submission")
                continue
            }
            #expect(error.localizedDescription.contains("no longer in the media library"))
            #expect(quotes == (removeDuringPricing ? 1 : 0))
            #expect(FileManager.default.fileExists(atPath: fixture.source.path))
            #expect(fixture.editor.mediaAssets.isEmpty)
            #expect(fixture.editor.generationLog.spendEvents.isEmpty)
        }
    }

    @Test func routedLibraryReferencesRetainTheirIdentityAndExactProjectPath() async throws {
        let fixture = try fixture(kind: "library")
        defer { fixture.cleanup() }
        let original = try await package(fixture)
        let receipt = try #require(original.payload.references.first)
        let proofFixture = try #require(PipelineProductionRoutingTests.generationInput(
            requirement: PipelineProductionRoutingTests.requirement(), modelID: original.payload.target.modelId).productionRouting)
        var proofJSON = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(proofFixture)) as? [String: Any])
        let binding = ProductionGenerationRoutingBindingV1(demandID: "identity", graphAssetID: "mara", graphAssetVersion: 1,
            mediaAssetID: receipt.assetID, path: "bible/characters/mara/Mara-front.png", sha256: receipt.sourceSHA256,
            modalityID: "image", semanticJobID: "identity", inputSlotID: "image", modeID: "image-to-video")
        proofJSON["ordered_bindings"] = [try JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(binding))]
        let proof = try JSONDecoder().decode(ProductionGenerationRoutingProofV1.self,
            from: JSONSerialization.data(withJSONObject: proofJSON))
        var input = original.payload.generationInput
        input.productionRouting = proof
        var payload = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(original.payload)) as? [String: Any])
        payload["routing"] = proofJSON
        payload["generationInput"] = try JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(input))
        payload["routeReceipt"] = try JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(
            GenerationRouteReceipt(target: original.payload.target, checks: [], capabilitySnapshot: proof.route.capabilitySnapshot)))
        let routed = try GenerationPackageV1(payload: JSONDecoder().decode(GenerationPackageV1.Payload.self,
            from: JSONSerialization.data(withJSONObject: payload)))
        #expect(try GenerationPackageInputs.resolveReference(receipt, package: routed, editor: fixture.editor) === fixture.reference)
        fixture.editor.mediaAssets.removeAll()
        #expect(throws: (any Error).self) {
            try GenerationPackageInputs.resolveReference(receipt, package: routed, editor: fixture.editor)
        }
        fixture.editor.mediaAssets.append(fixture.reference)
        let duplicate = fixture.source.deletingLastPathComponent().appendingPathComponent("duplicate.png")
        try FileManager.default.copyItem(at: fixture.source, to: duplicate)
        fixture.reference.url = duplicate
        #expect(throws: (any Error).self) {
            try GenerationPackageInputs.resolveReference(receipt, package: routed, editor: fixture.editor)
        }
    }

    @Test func archivedBytesNeverReplaceChangedCurrentProjectTruth() async throws {
        let fixture = try fixture(kind: "pipeline")
        defer { fixture.cleanup() }
        let package = try await package(fixture)
        try Data("changed project reference".utf8).write(to: fixture.source)
        await #expect(throws: (any Error).self) {
            try await GenerationPackageInputs.restore(package: package, editor: fixture.editor)
        }
        let batch = try present(package, editor: fixture.editor)
        await fixture.editor.generationBatchCoordinator.preflight(editor: fixture.editor, expectedBatchID: batch.id)
        #expect(!fixture.editor.generationBatchCoordinator.canApprovePending)
        #expect(fixture.editor.generationBatchCoordinator.preflightIssue?.contains("Mara-front.png") == true)
    }

    @Test func archivedBytesNeverAuthorizeASymlinkReplacingTheProjectReference() async throws {
        let fixture = try fixture(kind: "pipeline")
        defer { fixture.cleanup() }
        let package = try await package(fixture)
        let outsidePipeline = try #require(fixture.editor.workingRoot).appendingPathComponent("outside-pipeline.png")
        try FileManager.default.moveItem(at: fixture.source, to: outsidePipeline)
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: outsidePipeline)
        await #expect(throws: (any Error).self) {
            try await GenerationPackageInputs.validate(package: package, editor: fixture.editor)
        }
        #expect(fixture.editor.generationLog.spendEvents.isEmpty)
    }

    @Test func packagesFromThePreviousComposerPolicyRequireRecompilation() async throws {
        let fixture = try fixture(kind: "library")
        defer { fixture.cleanup() }
        let package = try await package(fixture)
        let home = try #require(fixture.editor.workingRoot)
        let root = try #require(DataRootResolver.dataRoot(of: home))
        struct PreviousInputs: Encodable {
            let artifactHashes: [String: String]
            let directives: [String]
            let locked: [String]
        }
        var hashes: [String: String] = [:]
        for path in [PipelineLayout.ledgerFile, PipelineLayout.briefFile] {
            hashes[path] = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
                ? try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: root)) : "absent"
        }
        let ledger = (try? YAMLArtifactStore(dataRoot: root).load(Ledger.self, at: PipelineLayout.ledgerFile)) ?? Ledger()
        #expect(ledger.objects.isEmpty)
        let oldFingerprint = FileDigest.sha256(of: try GenerationPackageV1.canonicalData(
            PreviousInputs(artifactHashes: hashes, directives: [], locked: [])))
        #expect(package.payload.compilerInputsSHA256 != oldFingerprint)
        var payload = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(package.payload)) as? [String: Any])
        var binding = try #require(payload["binding"] as? [String: Any])
        binding["compilerInputsSHA256"] = oldFingerprint
        payload["binding"] = binding
        payload["compilerInputsSHA256"] = oldFingerprint
        let old = try GenerationPackageV1(payload: JSONDecoder().decode(GenerationPackageV1.Payload.self,
            from: JSONSerialization.data(withJSONObject: payload)))
        await #expect(throws: (any Error).self) { try await old.requireCurrentContext(editor: fixture.editor) }
        #expect(fixture.editor.generationLog.spendEvents.isEmpty)
    }
}
