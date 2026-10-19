import AppKit
import AVFoundation
import ImageIO
import NexGenEngine
import UniformTypeIdentifiers

@MainActor
enum ProductionFramesOwnerAcceptance {
    private static let imageModel = "fal-ai/gemini-25-flash-image/edit"

    static func run(output: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw failed("Explicit native acceptance is required.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let generation = try ProductionV2GenerationAcceptance(modelID: "bytedance/seedance-2.5/image-to-video")
        defer { generation.close() }
        let runtime = ProductionV2RecordingRuntime()
        let original = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: runtime.service())
        let editor = original.editor
        generation.configure(editor: editor)
        let context = ProductionPlanningAcceptanceFixture.Context(document: original.document, packageURL: original.packageURL,
            dataRoot: original.dataRoot, executor: generation.executor(editor: editor))
        if !NSDocumentController.shared.documents.contains(where: { $0 === context.document }) {
            NSDocumentController.shared.addDocument(context.document)
        }
        context.document.makeWindowControllers()
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else { throw failed("No actual document window.") }
        window.setContentSize(AppTheme.Window.projectMin); window.appearance = NSAppearance(named: .darkAqua)
        context.document.showWindows(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "native-frames")
        var originalOpen = true
        defer { if originalOpen { context.document.close() } }
        do {
            await editor.refreshEngineState()
            guard editor.agentService.send(text: "Acceptance transport: retain this Core phase context.", mentions: [], hidden: true) else { throw failed("No actual recording session.") }
            try await driver.wait("Frames owner session") { !editor.agentService.isStreaming && editor.agentService.currentSessionId != nil }
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            let source = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
            _ = try await ProductionV2PlanningAcceptance.run(context: context, sourceVideo: source, driver: driver,
                generatedFirstShot: true, sketchGeneration: generation)
            try await ProductionV2PreRenderAcceptance.references(context: context, driver: driver)
            let generated = try await generation.proposal(context: context, frameBoundaries: true)
            _ = try await ProductionPlanningAcceptanceFixture.promoteImported(in: context, generatedShots: [generated])
            try await ProductionTechnicalOwnerAcceptance.run(context: context, driver: driver)
            let technicalRoot = context.dataRoot
            let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: technicalRoot) }.value
            guard let shot = projection.shots.first, projection.requiredFrameRoles(for: shot.id) == ["start", "end"],
                  projection.shots.dropFirst().allSatisfy({ projection.requiredFrameRoles(for: $0.id).isEmpty }) else { throw failed("The real plan does not require exactly the two generated boundary roles.") }
            try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
            try await ProductionV2PlanningAcceptance.approve("shotlist", artifact: ProductionPlanProjectionV1.versionPath(projection.header.revision), next: "sanity", context: context, driver: driver)
            try await ProductionPlanningAcceptanceFixture.prepareImportedSanity(in: context)
            try await ProductionV2PlanningAcceptance.selectPhase("sanity", context: context, driver: driver)
            try await ProductionV2PlanningAcceptance.approve("sanity", artifact: PipelineLayout.sanityReportFile, next: "frames", context: context, driver: driver)
            try await ProductionPlanningAcceptanceFixture.run("run_phase", args: ["phase": "frames"], in: context)
            try await ProductionV2PlanningAcceptance.selectPhase("frames", context: context, driver: driver)
            let images = try await fixtureImages(source: source, output: output)
            let first = try await GenerationBatchBusyOwnerAcceptance.generateFrame(shotID: shot.id, role: "start", image: images[0], context: context, generation: generation, driver: driver)
            let end = try await generate(shotID: shot.id, role: "end", image: images[3], context: context, generation: generation, driver: driver)
            let evidenceRoot = context.dataRoot
            let negativeEvidence = try await Task.detached {
                try changedEvidence(first, projection: projection, root: evidenceRoot)
            }.value
            try driver.record("changed frame producer evidence rejected", fields: negativeEvidence)
            try await select(first, context: context, driver: driver)
            try await select(end, context: context, driver: driver)
            try await audit(first, context: context, driver: driver)
            try await audit(end, context: context, driver: driver)
            try await requireFrames(projection, root: context.dataRoot)
            let stale = try await snapshot(shotID: shot.id, role: "start", context: context)
            try await iteration(.redo, items: [first], context: context, driver: driver)
            let second = try await generate(shotID: shot.id, role: "start", image: images[1], context: context, generation: generation, driver: driver)
            let afterRedo = try await snapshot(shotID: shot.id, role: "start", context: context)
            guard afterRedo.index.active == first.id, afterRedo.items.count == 2 else { throw failed("Redo replaced the current selection or lost its first candidate.") }
            let indexBefore = try PlanningWriterIO.json(afterRedo.index)
            var staleRejected = false
            do { try await PipelineProductionFrameCandidates.select(candidateID: first.id, snapshot: stale, editor: editor) }
            catch { staleRejected = true }
            let afterStale = try await snapshot(shotID: shot.id, role: "start", context: context)
            guard staleRejected, try PlanningWriterIO.json(afterStale.index) == indexBefore else {
                throw failed("A stale native selection changed candidate history.")
            }
            try await select(second, context: context, driver: driver)
            let oldAuditRejected = await framesRejected(projection, root: context.dataRoot)
            guard oldAuditRejected else { throw failed("The preceding image's accepted audit authorized another image.") }
            try await audit(second, context: context, driver: driver)
            try await requireFrames(projection, root: context.dataRoot)
            try await iteration(.remix, items: [first, second], context: context, driver: driver)
            let remix = try await generate(shotID: shot.id, role: "start", image: images[2], context: context, generation: generation, driver: driver)
            let beforeUse = try await snapshot(shotID: shot.id, role: "start", context: context)
            guard beforeUse.index.active == second.id, beforeUse.items.count == 3 else { throw failed("Remix changed selection before Use.") }
            try await select(remix, context: context, driver: driver)
            guard await framesRejected(projection, root: context.dataRoot) else { throw failed("Remix inherited an earlier audit.") }
            try await audit(remix, context: context, driver: driver)
            try await requireFrames(projection, root: context.dataRoot)
            try await ProductionV2PlanningAcceptance.approve("frames", artifact: PipelineLayout.framesManifestFile, next: "render_review", context: context, driver: driver)
            try driver.capture("frames-approved-exact-selection", target: window)
            let final = try await snapshot(shotID: shot.id, role: "start", context: context)
            guard final.index.active == remix.id, final.index.decisions.map(\.candidateID) == [first.id, second.id, remix.id] else { throw failed("The actual native selection history is incomplete.") }
            let root = context.dataRoot
            let roleFrames = try await Task.detached { try loadFramesManifest(dataRoot: root) }.value
            let finalEnd = try await snapshot(shotID: shot.id, role: "end", context: context)
            let files = try await Task.detached {
                try exportEvidence(snapshots: [final, finalEnd], root: root, output: output)
            }.value
            let measuredViewport = try viewport(window)
            guard context.document.isDocumentEdited else { throw failed("The frame history has no unsaved document mutation before Save.") }
            NSApp.mainMenu = MainMenuBuilder.buildMenu()
            try await AppNativeMenuAcceptance.choose(["File", "Save"], in: window, driver: driver)
            try await driver.wait("native Save commits frame history", seconds: 30) { !context.document.isDocumentEdited }
            context.document.close(); originalOpen = false
            let reopened = try await VideoProject.load(from: context.packageURL, agentService: ProductionV2RecordingRuntime().service())
            defer { reopened.close() }
            guard let reopenedHome = reopened.editorViewModel.workingRoot,
                  let reopenedRoot = DataRootResolver.dataRoot(of: reopenedHome) else { throw failed("The saved project did not reopen.") }
            await reopened.editorViewModel.refreshEngineState()
            let restored = try await PipelineProductionFrameCandidates.capture(home: reopenedHome)
            guard let restoredStart = restored.first(where: { $0.shotID == shot.id && $0.role == "start" }),
                  let restoredEnd = restored.first(where: { $0.shotID == shot.id && $0.role == "end" }),
                  restoredStart.index == final.index, restoredEnd.index == finalEnd.index,
                  restored.allSatisfy({ $0.items.allSatisfy { $0.unavailable == nil } }) else {
                throw failed("Reopen changed the candidate history, exact selection or generation evidence.")
            }
            try await requireFrames(projection, root: reopenedRoot)
            let persistence: [String: Any] = ["nativeSave": true, "reopenMethod": "VideoProject.load",
                "candidateHistoryPreserved": true, "selectedFrameAndAuditsCurrent": true, "files": files]
            try driver.record("saved frame history revalidated after reopen", fields: persistence)
            let evidence: [String: Any] = ["shotID": shot.id, "roles": ["start", "end"],
                "candidateIDs": final.items.map(\.id), "selectedID": remix.id, "endCandidateID": end.id,
                "selectionHistory": final.index.decisions.map(\.candidateID), "staleSelectionRejected": staleRejected,
                "oldAuditRejected": oldAuditRejected, "redoPreservedSelection": true, "remixPreservedSelection": true,
                "changedEvidence": negativeEvidence,
                "frameManifestSHA256": FileDigest.sha256(of: try PlanningWriterIO.json(roleFrames)),
                "provider": "isolated Fal HTTP through actual catalog, image adapter and receipt writer", "liveProvider": false]
            try driver.record("native frame candidate lifecycle", fields: evidence)
            let result: [String: Any] = ["workflow": "core", "viewport": measuredViewport,
                "frames": evidence, "persistence": persistence, "nativeEvidence": driver.result(),
                "framesApproved": reopened.editorViewModel.projectState?.phases.first(where: { $0.phase == "frames" })?.approved == true]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("frames-result.json"), options: .atomic)
            return result
        } catch { driver.failure(error); throw error }
    }

    static func generate(shotID: String, role: String, image: Data,
        context: ProductionPlanningAcceptanceFixture.Context, generation: ProductionV2GenerationAcceptance,
        driver: ProductionVisualSourcesDriver,
        afterBatchApproval: (@MainActor (String) async throws -> Void)? = nil,
        beforeBatchApproval: (@MainActor (String) async throws -> Void)? = nil) async throws -> PipelineProductionFrameCandidates.Item {
        let editor = context.editor, root = context.dataRoot
        guard let home = editor.workingRoot, let session = editor.agentService.currentSessionId else { throw failed("No current generation session.") }
        let pending = try await tool("next_render_shot", args: ["phase": "frames"], context: context)
        guard pending["shot_id"] as? String == shotID, pending["role"] as? String == role,
              let intent = pending["visual_prompt"] as? String else { throw failed("The actual frame runner requested a different boundary.") }
        let compiled = try await tool("compile_prompt", args: ["intent": intent, "shotId": shotID, "model": imageModel, "frameRole": role], context: context)
        guard let prompt = compiled["compiledPrompt"] as? String, let token = compiled["compileToken"] as? String else { throw failed("No actual compiled frame prompt.") }
        let plan = try await PipelineProductionPromptCompiler.framePlan(shotID: shotID, modelID: imageModel, dataRoot: root, catalog: generation.catalog, frameRole: role)
        let referenceBytes = try await Task.detached { try plan.bindings.map { try Data(contentsOf: ProjectLocalFile.requireHash($0.sha256, at: $0.path, dataRoot: root)) } }.value
        try MusicvideoGenerationHTTP.installFrameImage(endpoint: imageModel, output: image, referenceCount: referenceBytes.count)
        _ = try await tool("prepare_generation_batch", args: ["requestID": UUID().uuidString,
            "items": [["tool": "generate_image", "purpose": "Generate the exact planned " + role + " frame",
                "request": ["prompt": prompt, "compileToken": token, "shotId": shotID, "model": imageModel,
                    "aspectRatio": "16:9", "numImages": 1, "name": "Isolated provider · " + role + " frame"]]]], context: context)
        guard let batch = editor.generationBatchCoordinator.pending, let item = batch.payload.items.first,
              batch.payload.phase == "frames", batch.payload.items.count == 1,
              item.package.payload.generationInput.frameReferencePlan == plan,
              MusicvideoGenerationHTTP.requests.isEmpty else { throw failed("The package did not retain the canonical frame inputs or submitted before approval.") }
        try await driver.wait("Frames native budget approval") { driver.state("generation-batch.approve", in: driver.window) == true }
        try await driver.reveal("generation-batch.approve", in: driver.window)
        try driver.visible(["generation-batch.decline", "generation-batch.approve", "generation-batch.cost"], in: driver.window)
        try driver.capture("frame-approval-" + role, target: driver.window)
        try await beforeBatchApproval?(batch.id)
        try await driver.click("generation-batch.approve", in: driver.window)
        try await afterBatchApproval?(batch.id)
        try await driver.wait("Frames actual image response", seconds: 60) {
            guard let state = try? GenerationBatchStore.load(id: batch.id, home: home).journal.executions.first?.state else { return false }
            return [.complete, .blocked, .failed, .canceled].contains(state) && editor.generationBatchCoordinator.activeBatchID == nil && !editor.agentService.isStreaming
        }
        let stored = try GenerationBatchStore.load(id: batch.id, home: home)
        let puts = MusicvideoGenerationHTTP.requests.filter { $0.method == "PUT" }
        guard stored.authorityAvailable, stored.journal.executions.first?.state == .complete,
              stored.journal.pricingOverrideItemIDs == [item.id], let id = stored.journal.executions.first?.outputAssetIDs.first,
              let asset = editor.mediaAssets.first(where: { $0.id == id }), try FileDigest.sha256(of: asset.url) == FileDigest.sha256(of: image),
              puts.map(\.body) == referenceBytes, MusicvideoGenerationHTTP.submittedPrompt == prompt,
              MusicvideoGenerationHTTP.unexpectedRequests.isEmpty,
              let body = MusicvideoGenerationHTTP.requests.first(where: { $0.method == "POST" && $0.url == "https://queue.fal.run/" + imageModel })?.body,
              let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              request["image_urls"] as? [String] == referenceBytes.indices.map({ "https://media.invalid/frame-input-\($0).png" }) else {
            throw failed(stored.journal.executions.first?.detail ?? "The actual provider upload or result differs from the reviewed package.")
        }
        _ = try await ProductionStoryboardGenerationAcceptance.result("record_render", args: ["phase": "frames", "shot_id": shotID,
            "role": role, "status": "rendered", "output": id], context: context, session: session)
        let after = try await snapshot(shotID: shotID, role: role, context: context)
        guard let value = after.items.first(where: { $0.candidate.receipt.generation.assetID == id }), value.unavailable == nil else { throw failed("The actual completed image has no verifiable candidate.") }
        try driver.record("actual generated frame", fields: ["shotID": shotID, "role": role, "candidateID": value.id,
            "assetID": id, "packageSHA256": item.package.id, "imageSHA256": value.candidate.usage.outputSHA256,
            "planSHA256": plan.fingerprint, "promptSHA256": FileDigest.sha256(of: Data(prompt.utf8)),
            "referenceSHA256": plan.bindings.map(\.sha256), "uploadedSHA256": puts.map { FileDigest.sha256(of: $0.body) },
            "providerRequestID": MusicvideoGenerationHTTP.requestID, "modelEndpoint": item.package.payload.target.endpoint,
            "nativeSpendApproval": true, "liveProvider": false])
        return value
    }

    static func select(_ item: PipelineProductionFrameCandidates.Item,
        context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let shot = item.candidate.receipt.shotID, role = item.candidate.receipt.role
        try await reveal(item, context: context, driver: driver)
        try await driver.wait("actual candidate shown") { driver.state("frames.use." + item.id, in: driver.window) == true }
        try await driver.inspect("production.input.image.open." + item.id, in: driver.window)
        try await driver.click("frames.use." + item.id, in: driver.window)
        try await driver.wait("candidate selection published") { driver.text("frames.current.\(shot).\(role)", in: driver.window) == item.id && !busy(context.editor) }
        let selected = try await snapshot(shotID: shot, role: role, context: context)
        guard selected.index.active == item.id, selected.index.decisions.last?.candidateID == item.id else { throw failed("Use did not persist this exact candidate.") }
        try driver.capture("selected-" + role + "-" + String(selected.index.decisions.count), target: driver.window)
    }

    private static func iteration(_ kind: PipelineProductionFrameCandidates.IterationKind,
        items: [PipelineProductionFrameCandidates.Item], context: ProductionPlanningAcceptanceFixture.Context,
        driver: ProductionVisualSourcesDriver) async throws {
        guard let first = items.first else { throw failed("No source candidates.") }
        let shotID = first.candidate.receipt.shotID, role = first.candidate.receipt.role
        if kind == .redo {
            try await reveal(first, context: context, driver: driver)
            try await driver.click("frames.redo." + first.id, in: driver.window)
        }
        else {
            for item in items {
                try await reveal(item, context: context, driver: driver)
                try await driver.click("frames.pick." + item.id, in: driver.window)
            }
            try await driver.click("frames.remix.\(shotID).\(role)", in: driver.window)
        }
        let sheet = try await driver.sheet("frames.iteration.sheet")
        guard driver.state("frames.iteration.submit", in: sheet) == false else { throw failed("An iteration can submit without per-source intent.") }
        try await driver.picker("frames.iteration.reason", title: "Composition", expected: "Composition", in: sheet)
        for (index, item) in items.enumerated() {
            let aspect = index == 0 ? "Composition" : "Lighting"
            try await driver.picker("frames.iteration.aspect." + item.id, title: aspect, expected: aspect, in: sheet)
        }
        try await driver.fill("frames.iteration.note", value: "Keep the pale plane and compare the visible red circle positions.", in: sheet)
        try await driver.reveal("frames.iteration.submit", in: sheet)
        try driver.visible(["frames.iteration.cancel", "frames.iteration.submit"], in: sheet)
        try driver.capture("frame-" + kind.rawValue + "-sources", target: sheet)
        try await driver.click("frames.iteration.submit", in: sheet)
        try await driver.wait("native iteration persisted and agent handoff settled", seconds: 30) { driver.window.attachedSheet == nil && !context.editor.agentService.isStreaming && !busy(context.editor) }
        let root = context.dataRoot
        let value = try await Task.detached {
            try PipelineProductionFrameCandidates.currentIteration(shotID: shotID, role: role, dataRoot: root)
        }.value
        guard let value, value.kind == kind, Set(value.sources.map { $0.candidate.id }) == Set(items.map(\.id)),
              value.sources.allSatisfy({ !$0.aspects.isEmpty }) else { throw failed("The native iteration lost its exact source choices.") }
        try driver.record("native frame " + kind.rawValue, fields: ["candidateIDs": value.sources.map { $0.candidate.id },
            "sourceSHA256": value.sources.map { $0.image.sha256 }, "iterationSHA256": try PipelineProductionFrameCandidates.iterationReference(value).sha256])
    }

    static func audit(_ item: PipelineProductionFrameCandidates.Item,
        context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let receipt = item.candidate.receipt, root = context.dataRoot
        let expected = try await tool("get_frame_audit", args: ["shot_id": receipt.shotID, "role": receipt.role], context: context)
        let observed = try await tool("inspect_media", args: ["mediaRef": receipt.generation.assetID], context: context)
        guard let keys = expected["current_expected"] as? [String: String], !keys.isEmpty,
              let observation = observed["observationReceipt"] as? String else { throw failed("The actual image inspection returned no current audit context.") }
        var checks: [String: Any] = [:]
        for key in keys.keys {
            let noPeople = ["character_position", "gaze"].contains(key)
            let simple = ["character_count", "forbidden_elements"].contains(key)
            checks[key] = ["status": noPeople ? "n/a" : simple ? "clean" : "minor",
                "observed": "The decoded fixture shows one red circle on a pale flat plane, without people or lettering.",
                "note": noPeople ? "There is no person, body pose or gaze in this deterministic test image."
                    : simple ? "The known moving-shape source has no characters or text." : "A flat geometric test image does not demonstrate the requested cinematic camera, scene geometry or lighting; this deviation requires explicit native acceptance."]
        }
        _ = try await tool("save_frame_audit", args: ["shot_id": receipt.shotID, "role": receipt.role,
            "auditor": "isolated deterministic shape observer", "overall": "minor", "checks": checks,
            "observation_receipt": observation], context: context)
        await context.editor.refreshEngineState()
        let prefix = receipt.shotID + "." + receipt.role
        try await driver.click("frames.audit.open." + prefix, in: driver.window)
        try await driver.wait("actual frame deviation form") { driver.text("frames.audit.reason." + prefix, in: driver.window) != nil }
        guard driver.state("frames.audit.accept." + prefix, in: driver.window) == false else { throw failed("A deviation can be accepted without a reason.") }
        try await driver.fill("frames.audit.reason." + prefix, value: "Accept the visible red-circle fixture deviation for this isolated UI acceptance; it is not a claim of production image quality.", in: driver.window)
        try await driver.click("frames.audit.accept." + prefix, in: driver.window)
        try await driver.wait("exact frame deviations accepted", seconds: 30) {
            guard let audit = try? loadFrameAudit(dataRoot: root, shotId: receipt.shotID, role: receipt.role) else { return false }
            return (try? FrameAuditAcceptanceStoreV1.requireResolved(audit: audit, dataRoot: root)) != nil && !busy(context.editor)
        }
        let audit = try await Task.detached { try loadFrameAudit(dataRoot: root, shotId: receipt.shotID, role: receipt.role) }.value
        guard let audit, audit.renderSha256 == receipt.generation.output.sha256, audit.overall == .minor else { throw failed("The audit was not bound to the inspected selected image.") }
        try driver.record("native frame deviations accepted", fields: ["shotID": receipt.shotID, "role": receipt.role,
            "imageSHA256": audit.renderSha256, "overall": audit.overall.rawValue, "checks": audit.checks.keys.sorted(),
            "observationReceipt": observation, "qualityClaim": false])
    }

    private static func snapshot(shotID: String, role: String, context: ProductionPlanningAcceptanceFixture.Context) async throws -> PipelineProductionFrameCandidates.Snapshot {
        guard let home = context.editor.workingRoot,
              let value = try await PipelineProductionFrameCandidates.capture(home: home).first(where: { $0.shotID == shotID && $0.role == role }) else { throw failed("No current frame role.") }
        return value
    }

    private static func reveal(_ item: PipelineProductionFrameCandidates.Item,
        context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws {
        let shot = item.candidate.receipt.shotID, role = item.candidate.receipt.role
        let current = try await snapshot(shotID: shot, role: role, context: context)
        let header = "frames.role.\(shot).\(role)", target = "frames.use." + item.id
        try await driver.wait("current candidate count visible") {
            driver.text(header, in: driver.window) == String(current.items.count)
        }
        try await driver.reveal(header, in: driver.window)
        guard let root = driver.window.contentView,
              let heading = WorkspaceUIAcceptance.findProbe(in: root, identifier: header),
              let screen = NSScreen.screens.first else { throw failed("The candidate role has no actual native scroll surface.") }
        var parent = heading.superview
        var scroll: NSScrollView?
        while let view = parent {
            if let value = view as? NSScrollView { scroll = value; break }
            parent = view.superview
        }
        guard let scroll else { throw failed("The frame gallery is not in its native scroll view.") }
        for _ in 0..<30 {
            root.layoutSubtreeIfNeeded()
            if WorkspaceUIAcceptance.findProbe(in: root, identifier: target) != nil {
                try await driver.reveal(target, in: driver.window)
                return
            }
            let before = scroll.contentView.bounds.origin
            let local = NSPoint(x: scroll.visibleRect.midX, y: scroll.visibleRect.midY)
            guard driver.window.isKeyWindow, scroll.window === driver.window, !scroll.isHiddenOrHasHiddenAncestor,
                  !scroll.visibleRect.isEmpty, let hit = root.hitTest(scroll.convert(local, to: root.superview)),
                  hit === scroll || hit.isDescendant(of: scroll) else { throw failed("The actual gallery wheel target is clipped or covered.") }
            let point = driver.window.convertPoint(toScreen: scroll.convert(local, to: nil))
            let location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
            try await ProductionNativeReadingAcceptance.movePointer(to: location, window: driver.window, driver: driver)
            let events = try HangDiagnosticReplay.scrollGestureEvents(delta: scroll.contentView.isFlipped ? -100 : 100,
                location: location)
            for event in events {
                guard let cg = event.cgEvent else { throw failed("The native gallery wheel event is unavailable.") }
                cg.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await driver.wait("actual gallery wheel delivery") { scroll.contentView.bounds.origin != before }
            let after = scroll.contentView.bounds.origin
            try driver.record("native frame candidate wheel", fields: ["candidateID": item.id,
                "before": [before.x, before.y], "after": [after.x, after.y]])
            guard before != after else { throw failed("The gallery reached its native scroll boundary without the actual candidate.") }
        }
        throw failed("The actual candidate could not be reached with native wheel input.")
    }

    private static func tool(_ name: String, args: [String: Any], context: ProductionPlanningAcceptanceFixture.Context) async throws -> [String: Any] {
        guard let session = context.editor.agentService.currentSessionId else { throw failed("No actual tool session.") }
        return try await ProductionStoryboardGenerationAcceptance.object(name, args: args, context: context, session: session)
    }

    private static func requireFrames(_ projection: ProductionPlanProjectionV1, root: URL) async throws {
        try await Task.detached { _ = try ProductionPlanFramesV1.requireCurrent(projection: projection, dataRoot: root) }.value
    }

    private static func framesRejected(_ projection: ProductionPlanProjectionV1, root: URL) async -> Bool {
        do { try await requireFrames(projection, root: root); return false } catch { return true }
    }

    private static func busy(_ editor: EditorViewModel) -> Bool {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else { return true }
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil
    }

    private static func fixtureImages(source: URL, output: URL) async throws -> [Data] {
        try await Task.detached {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var images: [Data] = []
            for second in 0..<4 {
                let result = try await generator.image(at: CMTime(value: Int64(second), timescale: 1))
                guard CMTimeCompare(result.actualTime, CMTime(value: Int64(second), timescale: 1)) == 0 else { throw failed("The source decoder returned another frame.") }
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw failed("No PNG encoder.") }
                CGImageDestinationAddImage(destination, result.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw failed("The source frame could not be encoded.") }
                try (bytes as Data).write(to: output.appendingPathComponent("frame-provider-source-\(second).png"), options: .atomic)
                images.append(bytes as Data)
            }
            guard Set(images.map { FileDigest.sha256(of: $0) }).count == 4 else { throw failed("The actual moving source did not produce four distinct fixture images.") }
            return images
        }.value
    }

    private static func viewport(_ window: NSWindow) throws -> [String: Double] {
        guard let view = window.contentView else { throw failed("No native viewport.") }
        view.layoutSubtreeIfNeeded()
        let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        guard abs(view.bounds.width - AppTheme.Window.projectMin.width) < 0.5,
              abs(view.bounds.height - AppTheme.Window.projectMin.height) < 0.5 else { throw failed("The native viewport is not the actual minimum window size.") }
        return ["width": view.bounds.width, "height": view.bounds.height, "textScale": scale, "backingScale": window.backingScaleFactor]
    }

    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native Frames: " + message) }

    nonisolated private static func changedEvidence(_ item: PipelineProductionFrameCandidates.Item,
        projection: ProductionPlanProjectionV1, root: URL) throws -> [String: Bool] {
        let original = item.candidate.receipt.generation.output
        let mirror = PipelineGenerationEvidenceSnapshot.reference(mirroring: original, area: .frames)
        guard item.candidate.receipt.inputs.contains(mirror) else { throw failed("The new candidate has no exact pipeline evidence copy.") }
        let home = FrameInventory.projectHome(of: root)
        let urls = [try PipelineGenerationEvidenceSnapshot.requireExact(mirror.sha256, path: mirror.path, root: root),
            try PipelineGenerationEvidenceSnapshot.requireExact(original.sha256, path: original.path, root: home)]
        for url in urls {
            let bytes = try Data(contentsOf: url)
            do {
                defer { try? bytes.write(to: url, options: .atomic) }
                try Data("deliberately replaced fixture image".utf8).write(to: url, options: .atomic)
                var rejected = false
                do {
                    _ = try PipelineProductionFramesWriter.requireEvidence(receipt: item.candidate.receipt,
                        usage: item.candidate.usage, projection: projection, dataRoot: root)
                } catch { rejected = true }
                guard rejected else { throw failed("Changed producer evidence still authorized the candidate.") }
            }
            guard try Data(contentsOf: url) == bytes else { throw failed("The exact negative-test source was not restored.") }
            _ = try PipelineProductionFramesWriter.requireEvidence(receipt: item.candidate.receipt,
                usage: item.candidate.usage, projection: projection, dataRoot: root)
        }
        return ["changedPipelineCopyRejected": true, "changedHomeSourceRejected": true, "restoredExactEvidence": true]
    }

    nonisolated private static func exportEvidence(snapshots: [PipelineProductionFrameCandidates.Snapshot],
        root: URL, output: URL) throws -> [String: String] {
        var exported: [String: String] = [:]
        let destination = output.appendingPathComponent("frame-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        func copy(_ path: String, _ name: String) throws {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
            try bytes.write(to: destination.appendingPathComponent(name), options: .atomic)
            exported["frame-evidence/" + name] = FileDigest.sha256(of: bytes)
        }
        for snapshot in snapshots {
            try copy(PipelineProductionFrameCandidates.indexPath(shotID: snapshot.shotID, role: snapshot.role), snapshot.role + "-index.json")
            guard let audit = try loadFrameAudit(dataRoot: root, shotId: snapshot.shotID, role: snapshot.role) else { throw failed("The selected frame has no actual saved audit.") }
            let bytes = try PlanningWriterIO.json(audit)
            let auditName = snapshot.role + "-audit.json"
            try bytes.write(to: destination.appendingPathComponent(auditName), options: .atomic)
            exported["frame-evidence/" + auditName] = FileDigest.sha256(of: bytes)
            try copy("frames/\(snapshot.shotID)-\(snapshot.role).audit.yaml", snapshot.role + "-audit.yaml")
            try copy("frames/\(snapshot.shotID)-\(snapshot.role).acceptance.json", snapshot.role + "-acceptance.json")
            for item in snapshot.items {
                let reference = try PipelineProductionFrameCandidates.reference(item.candidate)
                try copy(reference.path, item.id + ".json")
                try copy(item.candidate.receipt.frame.path, item.id + ".png")
                try copy(item.candidate.receipt.generation.package.path, item.id + "-package.json")
                try copy(GenerationOutputReceipt.path(assetID: item.candidate.receipt.generation.assetID), item.id + "-output.json")
                for input in item.candidate.receipt.inputs where input.role == "host.frame-iteration" {
                    try copy(input.path, input.sha256 + "-iteration.json")
                }
            }
        }
        try copy(PipelineLayout.framesManifestFile, "manifest.yaml")
        return exported
    }
}
