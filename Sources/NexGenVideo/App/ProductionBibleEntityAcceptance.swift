import AppKit
import NexGenEngine

@MainActor
enum ProductionBibleEntityAcceptance {
    static let performerID = "owner_performer"
    static let ensembleID = "owner_ensemble"
    static let propID = "owner_prop"

    static func prepareAndInspect(context: ProductionPlanningAcceptanceFixture.Context,
                                  generation: ProductionV2GenerationAcceptance,
                                  driver: ProductionVisualSourcesDriver) async throws {
        let editor = context.editor, root = context.dataRoot, window = driver.window, output = driver.output
        guard editor.projectState?.nextPhaseName == "bible", let home = editor.workingRoot,
              let session = editor.agentService.currentSessionId,
              let projectKey = editor.projectId, !projectKey.isEmpty else { throw failed("The actual Bible phase and conversation must be current.") }
        let original = try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
            try bytes.write(to: output.appendingPathComponent("bible-typed-before.yaml"))
            return try decodedBible(bytes)
        }.value
        let sheet = try await generateSheet(context: context, generation: generation, driver: driver, session: session)
        var assigned: [String: CanonicalArtifactReferenceV1] = [:]
        for id in [performerID, ensembleID, propID] {
            let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "bible", leaf: "typed-" + id + ".png", dataRoot: root)
            try await ProductionPlanningAcceptanceFixture.run("copy_project_file", args: ["media": sheet.id, "to": path], in: context)
            assigned[id] = .init(id: sheet.id, role: sheet.role, path: path, sha256: sheet.sha256)
        }
        guard let performer = assigned[performerID], let ensemble = assigned[ensembleID], let prop = assigned[propID] else {
            throw failed("The actual typed source assignments are missing.")
        }
        var candidate = original
        candidate.characters.append(try NexGenEngine.Character(id: performerID, name: "Reference performer",
            visualPrompt: "Controlled geometric stand-in for typed reference navigation, not a human identity-quality claim.",
            attributes: ["fixture": "geometric stand-in"], referenceImages: [performer.path], sheets: ["front": performer.path]))
        candidate.ensembles.append(try Ensemble(id: ensembleID, name: "Reference ensemble",
            visualPrompt: "Two controlled geometric stand-ins sharing the same reference palette.", memberCount: 2,
            membersDescription: "Two explicit fixture members.", referenceImages: [ensemble.path], sheets: ["group_wide": ensemble.path]))
        candidate.props.append(try Prop(id: propID, name: "Reference prop",
            visualPrompt: "Controlled geometric reference prop for typed source navigation.",
            referenceImages: [prop.path], sheets: ["front": prop.path]))
        try await ProductionPlanningAcceptanceFixture.run("write_bible", args: ProductionBibleToolFixture.arguments(candidate), in: context)
        let stored = try await Task.detached {
            let value = try decodedBible(Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)))
            try PipelineProductionAssetEvidence.requireBible(value, dataRoot: root)
            return value
        }.value
        guard stored.characters == candidate.characters, stored.ensembles == candidate.ensembles,
              stored.props == candidate.props, stored.locations == original.locations,
              stored.look == original.look, stored.notes == original.notes else { throw failed("The canonical writer changed typed entities or the existing Look.") }
        try await ProductionV2PlanningAcceptance.selectPhase("bible", context: context, driver: driver)
        var entities: [[String: Any]] = []
        for (section, kind, id, view) in [("Characters", BibleEntityKind.character, performerID, "front"),
                                         ("Ensembles", .ensemble, ensembleID, "group_wide"),
                                         ("Props", .prop, propID, "front")] {
            try await driver.segment("bible.section", title: section, titles: BiblePanelView.Section.allCases.map(\.rawValue), in: window)
            if editor.inspectorPanelVisible { try await AppNativeMenuAcceptance.choose(["View", "Inspector"], in: window, driver: driver) }
            try await driver.wait("Inspector hidden before typed selection") { !editor.inspectorPanelVisible }
            guard let sheet = assigned[id] else { throw failed("The typed sheet has no canonical assignment.") }
            let ref = BibleEntityRef(kind: kind, id: id)
            try await driver.click("bible.entity.select." + kind.rawValue + "." + id, in: window)
            try await driver.wait("typed Bible entity inspected") { editor.inspectedObject == .entity(ref) && editor.inspectorPanelVisible && editor.bible?.entity(ref) != nil }
            let probe = "bible.sheet." + kind.rawValue + "." + id + "." + view
            try await driver.reveal(probe, in: window)
            guard driver.text(probe, in: window) == sheet.path else { throw failed("The visible sheet points at a different canonical image.") }
            try await driver.click(probe, in: window)
            try await driver.wait("actual typed source image presented") {
                guard case .referenceImage(let image) = editor.activePreviewTab else { return false }
                return image.entity == ref && image.path == sheet.path && image.projectHome == home
                    && driver.state("preview.reference.image", in: window) == true
                    && driver.text("preview.reference.image", in: window) == sheet.path
            }
            try driver.visible(["preview.reference.image"], in: window)
            try driver.capture("typed-bible-" + kind.rawValue, target: window)
            guard editor.inspectedObject == .entity(ref) else { throw failed("Source traversal lost the typed originating entity.") }
            let retainedImage = "bible-typed-source-" + kind.rawValue + ".png"
            try await Task.detached {
                try Data(contentsOf: ProjectLocalFile.requireHash(sheet.sha256, at: sheet.path, dataRoot: root))
                    .write(to: output.appendingPathComponent(retainedImage), options: .atomic)
            }.value
            entities.append(["retainedImage": retainedImage, "kind": kind.rawValue, "id": id, "view": view, "path": sheet.path, "sha256": sheet.sha256,
                "previewID": editor.activePreviewTab.id, "inspectorOpenedFromHidden": true])
        }
        try await driver.segment("bible.section", title: "Look", titles: BiblePanelView.Section.allCases.map(\.rawValue), in: window)
        if editor.inspectorPanelVisible { try await AppNativeMenuAcceptance.choose(["View", "Inspector"], in: window, driver: driver) }
        try await driver.wait("Inspector hidden before Look selection") { !editor.inspectorPanelVisible }
        try await driver.click("bible.look.select", in: window)
        try await driver.wait("Look selection opens its actual Inspector") { editor.inspectedObject == .look && editor.inspectorPanelVisible }
        try driver.capture("typed-bible-look", target: window)
        let bibleBytes = try await Task.detached { try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) }.value
        let evidence: [String: Any] = ["schema": "nexgenvideo/bible-typed-native-evidence/1", "status": "source-only-pending", "entities": entities,
            "bibleSHA256": FileDigest.sha256(of: bibleBytes), "bibleFile": "bible-typed-source.yaml",
            "beforeSHA256": try FileDigest.sha256(of: output.appendingPathComponent("bible-typed-before.yaml")),
            "look": try ProductionPlanningAcceptanceFixture.object(stored.look), "lookInspectorOpenedFromHidden": true,
            "referenceImage": "bible-typed-reference.png", "provider": "isolated HTTP through real compile/package/output receipt",
            "humanIdentityQualityClaim": false, "projectKey": projectKey]
        try bibleBytes.write(to: driver.output.appendingPathComponent("bible-typed-source.yaml"))
        try await Task.detached {
            try Data(contentsOf: ProjectLocalFile.requireHash(sheet.sha256, at: sheet.path, dataRoot: root))
                .write(to: output.appendingPathComponent("bible-typed-reference.png"))
        }.value
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: driver.output.appendingPathComponent("bible-typed-evidence.json"))
        try driver.record("native typed Bible entities and source traversal", fields: evidence)
    }

    private static func generateSheet(context: ProductionPlanningAcceptanceFixture.Context,
        generation: ProductionV2GenerationAcceptance, driver: ProductionVisualSourcesDriver, session: UUID) async throws -> CanonicalArtifactReferenceV1 {
        let editor = context.editor, root = context.dataRoot, output = driver.output
        guard let home = editor.workingRoot else { throw failed("The source project closed.") }
        try await generation.discoverImages(driver: driver)
        let model = "fal-ai/flux/schnell"
        let bytes = try await Task.detached {
            let design = try YAMLArtifactStore(dataRoot: root).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
            guard let ref = design.refs.first else { throw failed("The controlled image fixture is missing.") }
            return try Data(contentsOf: ProjectLocalFile.resolve(ref.path, dataRoot: root))
        }.value
        guard bytes.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) else { throw failed("The controlled image fixture must be an actual PNG.") }
        try MusicvideoGenerationHTTP.installCover(endpoint: model, output: bytes)
        let compiled = try await ProductionStoryboardGenerationAcceptance.object("compile_prompt", args: ["intent":
            "A controlled red geometric shape reference on a pale plane; typed-navigation fixture, not a human identity.",
            "shotId": "none", "model": model], context: context, session: session)
        guard let prompt = compiled["compiledPrompt"] as? String, let token = compiled["compileToken"] as? String else { throw failed("The actual image compiler returned no token.") }
        _ = try await ProductionStoryboardGenerationAcceptance.result("prepare_generation_batch", args: ["requestID": UUID().uuidString,
            "items": [["tool": "generate_image", "purpose": "Create a controlled Bible reference sheet",
                "request": ["prompt": prompt, "compileToken": token, "shotId": "none", "model": model,
                    "aspectRatio": "16:9", "numImages": 1, "name": "Typed Bible reference fixture"]]]], context: context, session: session)
        guard let batch = editor.generationBatchCoordinator.pending, batch.payload.phase == "bible",
              batch.payload.items.count == 1, MusicvideoGenerationHTTP.requests.isEmpty else { throw failed("The Bible image submitted before native approval.") }
        try await driver.wait("Bible image native approval") { driver.state("generation-batch.approve", in: driver.window) == true }
        try await driver.reveal("generation-batch.approve", in: driver.window)
        try driver.visible(["generation-batch.decline", "generation-batch.approve", "generation-batch.cost"], in: driver.window)
        try driver.capture("typed-bible-generation-approval", target: driver.window)
        try await driver.click("generation-batch.approve", in: driver.window)
        try await driver.wait("Bible image actual completion", seconds: 60) {
            guard let execution = try? GenerationBatchStore.load(id: batch.id, home: home).journal.executions.first else { return false }
            return [.complete, .blocked, .failed, .canceled].contains(execution.state)
                && editor.generationBatchCoordinator.activeBatchID == nil && !editor.agentService.isStreaming
        }
        let loaded = try GenerationBatchStore.load(id: batch.id, home: home)
        guard loaded.journal.executions.first?.state == .complete,
              let id = loaded.journal.executions.first?.outputAssetIDs.first,
              MusicvideoGenerationHTTP.submittedPrompt == prompt, MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else { throw failed("The approved image did not complete through its actual adapter.") }
        let receipt = try GenerationOutputReceipt.load(assetID: id, home: home)
        guard receipt.package.id == batch.payload.items.first?.package.id, receipt.output.sha256 == FileDigest.sha256(of: bytes) else { throw failed("The Bible image lacks its actual package/output binding.") }
        let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "bible", leaf: "typed-reference.png", dataRoot: root)
        try await ProductionPlanningAcceptanceFixture.run("copy_project_file", args: ["media": id, "to": path], in: context)
        try await Task.detached {
            try FileManager.default.copyItem(at: ProjectLocalFile.resolve(GenerationOutputReceipt.path(assetID: id), dataRoot: home),
                to: output.appendingPathComponent("bible-typed-generation-receipt.json"))
            try FileManager.default.copyItem(at: ProjectLocalFile.requireHash(receipt.package.sha256, at: receipt.package.path, dataRoot: home),
                to: output.appendingPathComponent("bible-typed-generation-package.json"))
            try PlanningWriterIO.json(loaded.batch).write(to: output.appendingPathComponent("bible-typed-generation-batch.json"))
            try PlanningWriterIO.json(loaded.journal).write(to: output.appendingPathComponent("bible-typed-generation-journal.json"))
        }.value
        let requests = MusicvideoGenerationHTTP.requests.map { ["method": $0.method, "url": $0.url, "bodyBase64": $0.body.base64EncodedString()] }
        try JSONSerialization.data(withJSONObject: requests, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("bible-typed-http.json"))
        try driver.record("actual generated Bible reference", fields: ["assetID": id, "batchID": batch.id,
            "packageID": receipt.package.id, "imageSHA256": receipt.output.sha256, "path": path, "nativeApproval": true, "liveProvider": false])
        return .init(id: id, role: "bible.reference", path: path, sha256: receipt.output.sha256)
    }

    static func captureBeforeSave(editor: EditorViewModel, output: URL) async throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let projectKey = editor.projectId, !projectKey.isEmpty else { throw failed("The Bible has no current data root and identity before Save.") }
        try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
            let inspected = try decodedBible(Data(contentsOf: output.appendingPathComponent("bible-typed-source.yaml")))
            let current = try decodedBible(bytes)
            guard sameTypedContent(current, inspected) else { throw failed("The inspected typed Bible changed before Save. Inspect the current assignments again.") }
            try bytes.write(to: output.appendingPathComponent("bible-typed-pre-save.yaml"))
            try JSONSerialization.data(withJSONObject: ["projectKey": projectKey, "bibleSHA256": FileDigest.sha256(of: bytes)], options: [.sortedKeys])
                .write(to: output.appendingPathComponent("bible-typed-pre-save.json"))
        }.value
    }

    static func requireReopened(editor: EditorViewModel, output: URL) async throws {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let projectKey = editor.projectId, !projectKey.isEmpty else { throw failed("The reopened Bible has no actual data root and project identity.") }
        let references = [BibleEntityRef(kind: .character, id: performerID),
                          .init(kind: .ensemble, id: ensembleID), .init(kind: .prop, id: propID)]
        let bytes = try await Task.detached {
            let before = try Data(contentsOf: output.appendingPathComponent("bible-typed-pre-save.yaml"))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("bible-typed-pre-save.json"))) as? [String: String]
            guard expected?["projectKey"] == projectKey, expected?["bibleSHA256"] == FileDigest.sha256(of: before) else { throw failed("The exact pre-Save project/Bible binding changed.") }
            let after = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
            guard after == before else { throw failed("Save and reopen changed the typed canonical Bible.") }
            let bible = try decodedBible(after)
            try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root)
            let inspected = try decodedBible(Data(contentsOf: output.appendingPathComponent("bible-typed-source.yaml")))
            guard sameTypedContent(bible, inspected) else { throw failed("The reopened Bible differs from the inspected typed assignments.") }
            let imageSHA = try FileDigest.sha256(of: output.appendingPathComponent("bible-typed-reference.png"))
            for reference in references {
                let sheets: [String: String]
                switch (reference.kind, bible.lookupId(reference.id)) {
                case (.character, .character(let value)?): sheets = value.sheets
                case (.ensemble, .ensemble(let value)?): sheets = value.sheets
                case (.prop, .prop(let value)?): sheets = value.sheets
                default: throw failed("The reopened Bible lost a typed entity.")
                }
                guard !sheets.isEmpty else { throw failed("The reopened typed entity lost its sheet.") }
                for path in sheets.values { _ = try ProjectLocalFile.requireHash(imageSHA, at: path, dataRoot: root) }
            }
            try after.write(to: output.appendingPathComponent("bible-typed-reopened.yaml"))
            return after
        }.value
        try JSONSerialization.data(withJSONObject: ["projectKey": projectKey, "bibleSHA256": FileDigest.sha256(of: bytes),
            "file": "bible-typed-reopened.yaml"], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("bible-typed-reopened.json"))
    }

    nonisolated private static func decodedBible(_ bytes: Data) throws -> Bible {
        guard let yaml = String(data: bytes, encoding: .utf8) else { throw failed("The retained Bible is not UTF-8 YAML.") }
        return try YAMLCoding.decode(Bible.self, from: yaml)
    }

    nonisolated private static func sameTypedContent(_ value: Bible, _ expected: Bible) -> Bool {
        value.characters == expected.characters && value.ensembles == expected.ensembles && value.props == expected.props
            && value.locations == expected.locations && value.look == expected.look && value.notes == expected.notes
    }

    nonisolated private static func failed(_ text: String) -> GateBlocked { GateBlocked("Typed Bible acceptance: " + text) }
}
