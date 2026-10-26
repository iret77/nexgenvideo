import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionSourceVideoOwnerAcceptance {
    static func run(kind: ProductionSourceModesOwnerAcceptance.Kind, output: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested, kind != .animatedStill else {
            throw GateBlocked("Source-video acceptance requires its isolated native process and actual video recipe.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let runtime = ProductionV2RecordingRuntime()
        let original = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: runtime.service())
        let editor = original.editor
        defer { editor.agentService.cancel(); original.document.close() }
        NSDocumentController.shared.addDocument(original.document)
        if original.document.windowControllers.isEmpty { original.document.makeWindowControllers() }
        guard let window = original.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw GateBlocked("The source-video document has no actual editor window.")
        }
        window.setContentSize(AppTheme.Window.projectMin)
        original.document.showWindows(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "source-owner-" + kind.rawValue)
        let generation = try await ProductionSourceModeGenerationAcceptance(kind: kind, driver: driver)
        defer { generation.close() }
        generation.first.configure(editor: editor)
        let context = ProductionPlanningAcceptanceFixture.Context(document: original.document, packageURL: original.packageURL,
            dataRoot: original.dataRoot, executor: generation.executor(editor: editor))
        let root = context.dataRoot
        do {
            await editor.refreshEngineState()
            guard editor.agentService.send(text: "Acceptance transport: retain this actual Core source-recipe context.", mentions: [], hidden: true) else {
                throw GateBlocked("The actual source-recipe recording runtime could not start.")
            }
            try await driver.wait("source-recipe recording context") { !editor.agentService.isStreaming && editor.agentService.currentSessionId != nil }
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            let source = try await ProductionSourceModeFixture.makeMovingVideo()
            defer { try? FileManager.default.removeItem(at: source) }
            _ = try await ProductionV2PlanningAcceptance.run(context: context, sourceVideo: source, driver: driver,
                generatedFirstShot: kind != .aiEnhanced, sketchGeneration: generation.first,
                beforeShotPlanningApproval: { current, native in
                    try await ProductionSourceModesOwnerAcceptance.assignDraft(kind, context: current, sourceVideo: source, driver: native)
                })
            if kind == .aiEnhanced { try await prepareSourceOnlyReferences(context: context, driver: driver) }
            else { try await ProductionV2PreRenderAcceptance.references(context: context, driver: driver) }
            let draft = try await readDraft(root)
            guard draft.shots.count == 2 else { throw GateBlocked("The actual source-recipe plan no longer has two shots.") }
            let proposals: [PipelineProductionPlanWriter.ShotProposal]
            if kind == .aiEnhanced {
                proposals = [try await generation.proposal(shotID: draft.shots[0].shotID, context: context)]
            } else {
                proposals = [try await generation.first.proposal(context: context),
                    try await generation.proposal(shotID: draft.shots[1].shotID, context: context)]
            }
            generation.configure(editor: editor)
            _ = try await ProductionPlanningAcceptanceFixture.promoteImported(in: context, generatedShots: proposals)
            try await ProductionV2PreRenderAcceptance.review(context: context, driver: driver)
            var selected: [[String: Any]] = []
            let negative: [String: Any]
            if kind == .aiEnhanced {
                guard let reference = draft.shots[0].source else { throw GateBlocked("The actual AI source disappeared.") }
                let local = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                negative = try await rejectChangedBytes(local: local, shotID: draft.shots[0].shotID,
                    label: "native-original-source", context: context, generation: generation, driver: driver, output: output)
                let transformed = try await VideoTrimExtractor.extract(.init(sourceURL: source,
                    trimStartFrame: 30, trimEndFrame: 30, sourceFramesConsumed: 180, fps: 30))
                defer { try? FileManager.default.removeItem(at: transformed) }
                let take = try await generation.render(shotID: draft.shots[0].shotID, context: context,
                    outputVideo: transformed, driver: driver, output: output)
                let range = try await ProductionV2TakeAcceptance.run(takeID: take, context: context, driver: driver)
                selected.append(["shotID": draft.shots[0].shotID, "takeID": take, "rangeID": range.id])
            } else {
                generation.first.configure(editor: editor)
                let firstContext = ProductionPlanningAcceptanceFixture.Context(document: context.document, packageURL: context.packageURL,
                    dataRoot: root, executor: generation.first.executor(editor: editor))
                let take = try await generation.first.render(context: firstContext, sourceVideo: source, driver: driver)
                let range = try await ProductionV2TakeAcceptance.run(takeID: take, context: context, driver: driver,
                    rangePlacement: .endingAtSourceEnd, nextUnrenderedShotID: draft.shots[1].shotID)
                selected.append(["shotID": draft.shots[0].shotID, "takeID": take, "rangeID": range.id])
                guard let home = editor.workingRoot else { throw GateBlocked("The selected predecessor has no working copy.") }
                let predecessor = try await TakeReview.capture(takeID: take, home: home)
                let local = try ProjectLocalFile.requireHash(predecessor.take.output.sha256,
                    at: predecessor.take.output.path, dataRoot: root)
                negative = try await rejectChangedBytes(local: local, shotID: draft.shots[1].shotID,
                    label: "selected-predecessor-output", context: context, generation: generation, driver: driver, output: output)
                let second = try await generation.render(shotID: draft.shots[1].shotID, context: context,
                    outputVideo: source, driver: driver, output: output)
                try await ProductionV2TakeAcceptance.nextShot(firstTakeID: take, nextTakeID: second,
                    context: context, driver: driver)
                let secondRange = try await ProductionV2TakeAcceptance.run(takeID: second, context: context, driver: driver,
                    expectedPreviewTakeID: second)
                selected.append(["shotID": draft.shots[1].shotID, "takeID": second, "rangeID": secondRange.id])
            }
            let film = try await ProductionV2FilmAcceptance.run(context: context, driver: driver, output: output,
                requiresReviewedTake: true, requiresImportedPlacement: kind == .aiEnhanced)
            let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
            let proof = try await Task.detached { try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: root) }.value
            guard projection.shots.map(\.id) == draft.shots.map(\.shotID),
                  proof.placements.map(\.shotID) == projection.shots.map(\.id) else {
                throw GateBlocked("The actual source-video film changed stable planned shot identities.")
            }
            let files = try await Task.detached {
                try preserve(projection: projection, proof: proof, dataRoot: root, output: output)
            }.value
            let result = film.merging(["kind": kind.rawValue, "nativeDraftChoice": true, "nativePreRenderInspection": true,
                "nativeGenerationApproval": true, "nativeTakeRanges": selected, "staleInput": negative,
                "shotIDs": projection.shots.map(\.id), "canonicalFiles": files, "liveProvider": false,
                "nativeEvidence": driver.result(),
                "actualAccountEntitlementClaim": false, "semanticGenerationQualityClaim": false,
                "offGridSongEndClaim": false] as [String: Any]) { _, new in new }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("result.json"))
            return result
        } catch {
            driver.failure(error)
            throw error
        }
    }

    private static func prepareSourceOnlyReferences(context: ProductionPlanningAcceptanceFixture.Context,
                                                     driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot
        let draft = try await readDraft(root)
        guard draft.shots.allSatisfy({ $0.sourceMode != .generated && $0.obligations.isEmpty }),
              draft.shots.contains(where: { $0.sourceMode == .aiEnhanced }),
              draft.shots.allSatisfy({ $0.source != nil && $0.sourceInputRange != nil }) else {
            throw GateBlocked("Only actual source-only AI/imported shots without image obligations may omit native image selection.")
        }
        try await ProductionPlanningAcceptanceFixture.writeBible(in: context)
        let sources = Set(draft.shots.compactMap { $0.source?.path }).sorted()
        try await ProductionPlanningAcceptanceFixture.run("prepare_production_assets", args: ["assets": sources.map {
            ["path": $0, "modality": "video", "allowed_use_ids": []] as [String: Any]
        }], in: context)
        try await ProductionV2PlanningAcceptance.selectPhase("bible", context: context, driver: driver)
        try driver.capture("actual-source-only-bible", target: driver.window)
        try driver.record("native source-only reference contract", fields: ["shotIDs": draft.shots.map(\.shotID),
            "sourcePaths": sources, "requiredImageObligations": [], "nativeImageAssignmentClaim": false])
        try await ProductionV2PlanningAcceptance.approve("bible", artifact: PipelineLayout.bibleFile,
            next: "shotlist", context: context, driver: driver)
    }

    private static func rejectChangedBytes(local: URL, shotID: String, label: String,
                                          context: ProductionPlanningAcceptanceFixture.Context,
                                          generation: ProductionSourceModeGenerationAcceptance,
                                          driver: ProductionVisualSourcesDriver, output: URL) async throws -> [String: Any] {
        generation.configure(editor: context.editor)
        let access = try PipelineNativeEditAccess(editor: context.editor, label: "Verify exact source input")
        defer { access.end(editor: context.editor) }
        try access.requireCurrent(editor: context.editor)
        let original = try await Task.detached { try Data(contentsOf: local) }.value
        let before = context.editor.generationLog.spendEvents
        let requestsBefore = [MusicvideoGenerationHTTP.requests.count, ProductionRunwaySourceHTTP.requests.count,
            ManualVideoModesHTTP.snapshot.requests.count]
        let wrong = Data(original.reversed())
        guard wrong != original else { throw GateBlocked("The isolated changed-source fixture did not actually change its bytes.") }
        try await Task.detached { try wrong.write(to: output.appendingPathComponent("stale-input-changed.bin")) }.value
        try await Task.detached { try wrong.write(to: local, options: .atomic) }.value
        do {
            var refusal: Error?
            do {
                _ = try await PipelineProductionInputMaterializer.prepare(shotID: shotID, editor: context.editor,
                    catalog: generation.catalog)
            } catch { refusal = error }
            let requestsAfter = [MusicvideoGenerationHTTP.requests.count, ProductionRunwaySourceHTTP.requests.count,
                ManualVideoModesHTTP.snapshot.requests.count]
            guard let refusal, context.editor.generationLog.spendEvents == before, requestsBefore == requestsAfter else {
                throw GateBlocked("The canonical preparation accepted changed exact source bytes or spent before approval.")
            }
            try await Task.detached { try original.write(to: local, options: .atomic) }.value
            guard try await Task.detached(operation: { try Data(contentsOf: local) }).value == original else {
                throw GateBlocked("The controlled stale-source test did not restore the exact original bytes.")
            }
            try access.requireCurrent(editor: context.editor)
            let restored = try await PipelineProductionInputMaterializer.prepare(shotID: shotID, editor: context.editor,
                catalog: generation.catalog)
            guard restored.receipt.shotID == shotID, context.editor.generationLog.spendEvents == before,
                  [MusicvideoGenerationHTTP.requests.count, ProductionRunwaySourceHTTP.requests.count,
                   ManualVideoModesHTTP.snapshot.requests.count] == requestsBefore else {
                throw GateBlocked("The exact restored source did not pass the same canonical preparation.")
            }
            let evidence = ["target": label, "shotID": shotID, "originalSHA256": FileDigest.sha256(of: original),
                "changedSHA256": FileDigest.sha256(of: wrong), "restoredSHA256": FileDigest.sha256(of: original),
                "actualPreparationRefused": true, "generateRequested": false, "spendEventsUnchanged": true,
                "preparationBoundary": "PipelineProductionInputMaterializer.prepare", "restoredPreparationAccepted": true,
                "requestCountsBefore": requestsBefore, "requestCountsAfter": requestsAfter,
                "reason": refusal.localizedDescription] as [String: Any]
            try driver.record("changed exact source rejected before generation", fields: evidence)
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("stale-input.json"))
            return evidence
        } catch {
            try? await Task.detached { try original.write(to: local, options: .atomic) }.value
            throw error
        }
    }

    private static func readDraft(_ root: URL) async throws -> ShotPlanningDraftV1 {
        try await Task.detached { try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root,
            storyboard: PlanningWriterIO.storyboard(dataRoot: root)) }.value
    }

    private nonisolated static func preserve(projection: ProductionPlanProjectionV1, proof: ProductionPlanAssemblyProofV1,
                                              dataRoot: URL, output: URL) throws -> [String: String] {
        let evidence = output.appendingPathComponent("canonical", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let paths = [ProductionPlanProjectionV1.versionPath(projection.header.revision), ShotPlanningDraftV1.currentPath,
            StoryboardTimingV1.currentPath, RenderReviewV1.currentPath, ProductionPlanAssemblyProofV1.relativePath]
        var files: [String: String] = [:]
        for (index, path) in paths.enumerated() {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
            let name = "\(index)-" + URL(fileURLWithPath: path).lastPathComponent
            try bytes.write(to: evidence.appendingPathComponent(name))
            files[name] = FileDigest.sha256(of: bytes)
        }
        let projectionJSON = try JSONEncoder().encode(projection)
        try projectionJSON.write(to: evidence.appendingPathComponent("projection.json"))
        files["projection.json"] = FileDigest.sha256(of: projectionJSON)
        let assemblyJSON = try JSONEncoder().encode(proof)
        try assemblyJSON.write(to: evidence.appendingPathComponent("assembly.json"))
        files["assembly.json"] = FileDigest.sha256(of: assemblyJSON)
        var references = proof.artifactReferences + projection.header.inputs + projection.sourceBindings
        for shot in projection.shots where shot.sourceMode != .imported {
            let selected = try PipelineProductionRenderWriter.requireSelected(shotID: shot.id, dataRoot: dataRoot)
            references += [selected.reference, selected.selection.record, selected.selection.review,
                selected.record.projection, selected.record.generation, selected.record.submission, selected.record.output]
                + [selected.selection.nativeRange].compactMap { $0 }
            let submission = try PlanningWriterIO.read(RenderSubmissionBindingV1.self, at: selected.record.submission.path, dataRoot: dataRoot)
            references += [submission.review, submission.compiledPrompt, submission.route] + submission.inputs
            if let predecessor = submission.predecessor {
                references += [predecessor.selectionReceipt, predecessor.outputVideo] + [predecessor.lastFrame].compactMap { $0 }
            }
            let generated = try PlanningWriterIO.read(GenerationOutputReceipt.self, at: selected.record.generation.path, dataRoot: dataRoot)
            references += [generated.package]
            let package = try PlanningWriterIO.read(GenerationPackageV1.self, at: generated.package.path, dataRoot: dataRoot)
            if let materialization = package.payload.routing?.productionMaterialization {
                references.append(materialization)
                let materialized = try PlanningWriterIO.read(PipelineProductionInputMaterializer.Receipt.self,
                    at: materialization.path, dataRoot: dataRoot)
                references += [materialized.projection, materialized.promotion, materialized.plannedRoute, materialized.graph,
                    materialized.demands, materialized.route, materialized.referencePlan] + materialized.inputs + materialized.sourceMedia
                for media in materialized.sourceMedia {
                    let extracted = try PlanningWriterIO.read(PipelineProductionInputMedia.Receipt.self, at: media.path, dataRoot: dataRoot)
                    references += [extracted.selection.source, extracted.output]
                }
            }
        }
        var seen = Set<String>(), inventory: [[String: String]] = []
        for reference in references where seen.insert(reference.path + ":" + reference.sha256).inserted {
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
            let name = "ref-\(inventory.count)-" + URL(fileURLWithPath: reference.path).lastPathComponent
            try bytes.write(to: evidence.appendingPathComponent(name))
            files[name] = reference.sha256
            inventory.append(["path": reference.path, "sha256": reference.sha256, "file": name])
        }
        let inventoryBytes = try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys])
        try inventoryBytes.write(to: evidence.appendingPathComponent("references.json"))
        files["references.json"] = FileDigest.sha256(of: inventoryBytes)
        return files
    }
}
