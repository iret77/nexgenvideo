import AppKit
import Foundation
import NexGenEngine

@MainActor
enum FilmFlowOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let scenario = Scenario(output: output, scale: scale)
        do {
            try FileManager.default.createDirectory(at: scenario.directory, withIntermediateDirectories: true)
            let image = scenario.directory.appendingPathComponent("source.png")
            try FullflowAcceptanceFixture.writeReference(to: image)
            FilmFlowAcceptanceHTTP.install(image: try Data(contentsOf: image))
            let context = try await ProductionPlanningAcceptanceFixture.makeScript(beforeBriefApproval: { try await scenario.brief($0) })
            defer { context.document.close() }
            try await scenario.script(context)
            try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
            _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
            try await scenario.storyboard(context)
            try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
            _ = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: context)
            try await scenario.camera(context)
            return try await scenario.saveAndReopen(context)
        } catch { scenario.driver?.failure(error); throw error }
    }

    private final class Scenario {
        let output: URL
        let scale: Double
        let name: String
        let directory: URL
        var driver: ProductionVisualSourcesDriver?
        var retained: FilmFlowSnapshotStore.Retained?
        let shotObject = "get_shotlist#/scenes/0/shots/0"
        let characterObject = "list_entities#/0"
        let missingPointer = "list_entities#/1/referenceImageUrl"

        init(output: URL, scale: Double) {
            self.output = output; self.scale = scale
            name = "filmflow-owner-\(Int(scale * 100))"
            directory = output.appendingPathComponent(name, isDirectory: true)
        }

        func brief(_ context: ProductionPlanningAcceptanceFixture.Context) async throws {
            NSDocumentController.shared.addDocument(context.document)
            context.document.makeWindowControllers(); context.document.showWindows()
            guard let window = context.document.windowControllers.first?.window else { throw failed("The actual document window is missing.") }
            window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); NSApp.mainMenu = MainMenuBuilder.buildMenu()
            let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
            self.driver = driver
            let connection = FilmFlowAcceptanceHTTP.connection()
            try FilmFlowImportPresenter.setAcceptanceConfiguration(.init(isolated: true, connect: { connection },
                makeReader: { FilmFlowAcceptanceHTTP.reader(connection: $0) }), editor: context.editor)
            try await context.editor.refreshEngineState()
            let before = try PipelineStorySourceWriter.selectionState(dataRoot: context.dataRoot)
            let gates = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile))
            try gates.write(to: directory.appendingPathComponent("gates-before.yaml"), options: .atomic)
            let lineage = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.lineageFile))
            try lineage.write(to: directory.appendingPathComponent("lineage-before.json"), options: .atomic)
            let sheet = try await open(editor: context.editor, window: window, driver: driver)
            try await driver.click("filmflow.connect", in: sheet)
            try await driver.wait("actual isolated MCP project list") { driver.state("filmflow.project", in: sheet) == true }
            try await selectProject(sheet, driver: driver)
            FilmFlowAcceptanceHTTP.holdNextProjectRead()
            try await driver.click("filmflow.download", in: sheet)
            try await driver.wait("actual pending MCP read") { FilmFlowAcceptanceHTTP.heldReadCount() == 1 }
            guard driver.state("filmflow.done", in: sheet) == false else { throw failed("Done can discard an active FilmFlow import.") }
            try await driver.click("filmflow.cancel-operation", in: sheet)
            try await driver.wait("native cancellation reaches the actual transport") {
                FilmFlowAcceptanceHTTP.cancelledReadCount() == 1 && driver.text("filmflow.message", in: sheet) == "Operation cancelled."
            }
            guard try FilmFlowSnapshotStore.list(dataRoot: context.dataRoot).isEmpty else { throw failed("Cancel retained a snapshot.") }
            try driver.capture("cancelled-read", target: sheet)
            try driver.record("FilmFlow transport cancellation", fields: ["heldReads": 1, "cancelledReads": 1, "retainedCount": 0])
            try await driver.click("filmflow.projects.read", in: sheet)
            try await driver.wait("reconnect actual MCP after cancellation") { driver.state("filmflow.project", in: sheet) == true }
            try await selectProject(sheet, driver: driver)
            try await driver.click("filmflow.download", in: sheet)
            try await driver.wait("portable snapshot awaiting explicit omission", seconds: 30) { driver.state("filmflow.accept", in: sheet) == false }
            try await selectSource(shotObject, title: "3. EXT. HARBOUR — NIGHT · 1A.1", sheet: sheet, driver: driver)
            let imageSHA = try FileDigest.sha256(of: directory.appendingPathComponent("source.png"))
            try await driver.reveal("production.input.image.open." + imageSHA, in: sheet)
            try await driver.inspect("production.input.image.open." + imageSHA, in: sheet)
            try await driver.reveal("filmflow.accept", in: sheet)
            try driver.visible(["filmflow.accept", "filmflow.done"], in: sheet)
            try driver.capture("missing-image-blocks-accept", target: sheet)
            try await driver.reveal("filmflow.omit." + missingPointer, in: sheet)
            try await driver.click("filmflow.omit." + missingPointer, in: sheet)
            try await driver.wait("explicit image omission enables accept") { driver.state("filmflow.accept", in: sheet) == true }
            try await driver.click("filmflow.accept", in: sheet)
            try await driver.wait("snapshot accepted without approving Brief", seconds: 30) {
                driver.text("filmflow.message", in: sheet)?.hasPrefix("Snapshot retained.") == true
                    && driver.state("filmflow.targets.reload", in: sheet) == true
            }
            let snapshots = try await Task.detached { try FilmFlowSnapshotStore.list(dataRoot: context.dataRoot) }.value
            guard snapshots.count == 1, let retained = snapshots.first,
                  try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile)) == gates,
                  try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.lineageFile)) == lineage else {
                throw failed("Snapshot acceptance changed phase approvals or retained more than one snapshot.")
            }
            self.retained = retained
            try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.gatesFile))
                .write(to: directory.appendingPathComponent("gates-after.yaml"), options: .atomic)
            try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.lineageFile))
                .write(to: directory.appendingPathComponent("lineage-after.json"), options: .atomic)
            try FileManager.default.copyItem(at: retained.directory, to: directory.appendingPathComponent("snapshot"))
            try driver.record("FilmFlow snapshot accepted", fields: ["snapshotID": retained.id.uuidString.lowercased(),
                "snapshotSHA256": retained.sha256, "liveOAuth": false, "provider": "isolated SDK read-only transport",
                "sourceImageSHA256": imageSHA, "omitted": [missingPointer]])
            try await driver.reveal("filmflow.notes.open", in: sheet); try await driver.click("filmflow.notes.open", in: sheet)
            try await driver.reveal("filmflow.notes." + shotObject, in: sheet); try await driver.click("filmflow.notes." + shotObject, in: sheet)
            try await driver.reveal("filmflow.notes.apply", in: sheet)
            try driver.capture("planning-notes-before-accept", target: sheet)
            try await driver.click("filmflow.notes.apply", in: sheet)
            try await driver.wait("native planning notes selected", seconds: 30) { driver.text("filmflow.message", in: sheet)?.hasPrefix("Planning notes selected.") == true }
            let applied = try PipelineStorySourceWriter.selectionState(dataRoot: context.dataRoot)
            guard applied != before, let source = applied.source, String(decoding: source, as: UTF8.self).contains("A lantern crosses the empty doorway.") else {
                throw failed("The actual Brief source does not contain the chosen planning description.")
            }
            try saveSelection(before, label: "notes-before"); try saveSelection(applied, label: "notes-applied")
            try await close(sheet, parent: window, driver: driver)
            try await selectionUndoRedo(context, before: before, applied: applied, driver: driver)
            let identityBefore = try ConfirmedIdentityAssetStoreV1.load(dataRoot: context.dataRoot)
            try copyOptional(PipelineLayout.confirmedIdentityAssetsFile, root: context.dataRoot, label: "identity-before")
            let identitySheet = try await open(editor: context.editor, window: window, driver: driver)
            try await openRetained(identitySheet, driver: driver)
            try await selectSource(characterObject, title: "4. CHARACTER · Harbour keeper", sheet: identitySheet, driver: driver)
            try await driver.reveal("filmflow.identity.name", in: identitySheet)
            try await driver.fill("filmflow.identity.name", value: "Prepared Harbour Keeper", in: identitySheet)
            guard driver.state("filmflow.identity.apply", in: identitySheet) == false else { throw failed("Upstream isConfirmed silently confirmed the local identity.") }
            try await driver.reveal("filmflow.identity.confirm", in: identitySheet); try await driver.click("filmflow.identity.confirm", in: identitySheet)
            try await driver.reveal("filmflow.identity.apply", in: identitySheet)
            try driver.capture("explicit-native-identity", target: identitySheet)
            try await driver.click("filmflow.identity.apply", in: identitySheet)
            try await appliedMessage(identitySheet, driver: driver)
            let identityAfter = try ConfirmedIdentityAssetStoreV1.load(dataRoot: context.dataRoot)
            guard identityAfter != identityBefore else { throw failed("Native identity confirmation did not publish.") }
            try copyCurrent(PipelineLayout.confirmedIdentityAssetsFile, root: context.dataRoot, label: "identity-applied")
            try await close(identitySheet, parent: window, driver: driver)
            try await undo(window, redo: false, driver: driver)
            try await driver.wait("native identity Undo", seconds: 30) { (try? ConfirmedIdentityAssetStoreV1.load(dataRoot: context.dataRoot)) == identityBefore }
            try copyOptional(PipelineLayout.confirmedIdentityAssetsFile, root: context.dataRoot, label: "identity-undo")
            try await undo(window, redo: true, driver: driver)
            try await driver.wait("native identity Redo", seconds: 30) { (try? ConfirmedIdentityAssetStoreV1.load(dataRoot: context.dataRoot)) == identityAfter }
            try copyCurrent(PipelineLayout.confirmedIdentityAssetsFile, root: context.dataRoot, label: "identity-redo")
            try await undo(window, redo: false, driver: driver)
            try await driver.wait("original Brief identity state restored", seconds: 30) { (try? ConfirmedIdentityAssetStoreV1.load(dataRoot: context.dataRoot)) == identityBefore }
            guard try PipelineStorySourceWriter.selectionState(dataRoot: context.dataRoot) == before,
                  context.editor.projectState?.nextPhaseName == "brief" else { throw failed("Fixture setup was not restored before its normal Brief approval.") }
        }

        func script(_ context: ProductionPlanningAcceptanceFixture.Context) async throws {
            let driver = try requireDriver(), window = driver.window
            let original = try PlanningWriterIO.script(dataRoot: context.dataRoot)
            try copyCurrent(ScriptV1.currentPath, root: context.dataRoot, label: "script-before")
            guard let scene = original.scenes.first, let event = scene.events.first else { throw failed("The genuine Script draft is empty.") }
            let sheet = try await open(editor: context.editor, window: window, driver: driver)
            try await openRetained(sheet, driver: driver)
            try await selectSource(shotObject, title: "3. EXT. HARBOUR — NIGHT · 1A.1", sheet: sheet, driver: driver)
            try await driver.reveal("filmflow.target.scene", in: sheet)
            try await driver.picker("filmflow.target.scene", title: scene.title, expected: scene.id, in: sheet)
            try await driver.reveal("filmflow.target.event", in: sheet)
            try await driver.picker("filmflow.target.event", title: event.action, expected: event.id, in: sheet)
            try await driver.reveal("filmflow.script.apply", in: sheet); try driver.capture("script-mapping", target: sheet)
            try await driver.click("filmflow.script.apply", in: sheet); try await appliedMessage(sheet, driver: driver)
            let applied = try PlanningWriterIO.script(dataRoot: context.dataRoot)
            guard applied.scenes[0].events[0].id == event.id, applied.scenes[0].events[0].treatmentBeatIDs == event.treatmentBeatIDs,
                  applied.scenes[0].events[0].action.contains("A lantern crosses the empty doorway.") else { throw failed("Native Script mapping changed identity/beat bindings or lost the description.") }
            try copyCurrent(ScriptV1.currentPath, root: context.dataRoot, label: "script-applied")
            try await close(sheet, parent: window, driver: driver)
            try await undo(window, redo: false, driver: driver)
            try await driver.wait("native Script Undo") { (try? PlanningWriterIO.script(dataRoot: context.dataRoot).scenes) == original.scenes }
            try copyCurrent(ScriptV1.currentPath, root: context.dataRoot, label: "script-undo")
            try await undo(window, redo: true, driver: driver)
            try await driver.wait("native Script Redo") { (try? PlanningWriterIO.script(dataRoot: context.dataRoot).scenes) == applied.scenes }
            try copyCurrent(ScriptV1.currentPath, root: context.dataRoot, label: "script-redo")
            try await undo(window, redo: false, driver: driver)
            try await driver.wait("fixture Script actions restored") { (try? PlanningWriterIO.script(dataRoot: context.dataRoot).scenes) == original.scenes }
        }

        func storyboard(_ context: ProductionPlanningAcceptanceFixture.Context) async throws {
            let driver = try requireDriver(), window = driver.window
            let before = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
            try copyCurrent(StoryboardTimingV1.currentPath, root: context.dataRoot, label: "timing-before")
            guard let shot = before.timing.shots.first, let moment = shot.moments.first else { throw failed("The actual Storyboard is empty.") }
            let sheet = try await open(editor: context.editor, window: window, driver: driver)
            try await openRetained(sheet, driver: driver)
            try await selectSource(shotObject, title: "3. EXT. HARBOUR — NIGHT · 1A.1", sheet: sheet, driver: driver)
            try await driver.reveal("filmflow.target.shot", in: sheet)
            try await driver.picker("filmflow.target.shot", title: "Shot 1", expected: shot.id, in: sheet)
            try await driver.reveal("filmflow.target.moment", in: sheet)
            try await driver.picker("filmflow.target.moment", title: moment.intent, expected: moment.id, in: sheet)
            try await driver.reveal("filmflow.duration.apply", in: sheet); try await driver.click("filmflow.duration.apply", in: sheet)
            try await driver.wait("out-of-range source duration refused") { driver.text("filmflow.error", in: sheet)?.contains("selected playback range") == true }
            guard try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false).fingerprint == before.fingerprint else { throw failed("Imported duration changed the actual playback range.") }
            try driver.capture("duration-refused", target: sheet)
            try await driver.reveal("filmflow.sketch.apply", in: sheet); try driver.capture("sketch-mapping", target: sheet)
            try await driver.click("filmflow.sketch.apply", in: sheet); try await appliedMessage(sheet, driver: driver)
            let after = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
            guard let image = after.timing.shots.first?.moments.first?.asset?.image,
                  image.sha256 == FileDigest.sha256(of: try Data(contentsOf: directory.appendingPathComponent("source.png"))),
                  after.timing.rangeStartTicks == before.timing.rangeStartTicks,
                  after.timing.rangeDurationTicks == before.timing.rangeDurationTicks else { throw failed("Sketch mapping changed timing or used other image bytes.") }
            try copyCurrent(StoryboardTimingV1.currentPath, root: context.dataRoot, label: "timing-applied")
            try await close(sheet, parent: window, driver: driver)
            guard context.editor.productionSelectedPhase == "storyboard", context.editor.workspaceFocus == .production,
                  context.editor.focusedPanel == .project else { throw failed("Native FilmFlow adoption did not retain Storyboard Undo focus.") }
            try await undo(window, redo: false, driver: driver)
            _ = try await PipelineStoryboardEditor.waitForPendingRestore(editor: context.editor)
            let undone = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
            guard undone.timing.shots.first?.moments.first?.asset == nil else { throw failed("Sketch Undo did not remove the selected image.") }
            try copyCurrent(StoryboardTimingV1.currentPath, root: context.dataRoot, label: "timing-undo")
            try await undo(window, redo: true, driver: driver)
            _ = try await PipelineStoryboardEditor.waitForPendingRestore(editor: context.editor)
            var current = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
            guard current.timing.shots.first?.moments.first?.asset?.image.sha256 == image.sha256 else { throw failed("Sketch Redo changed its image.") }
            try copyCurrent(StoryboardTimingV1.currentPath, root: context.dataRoot, label: "timing-redo")
            for target in current.timing.shots {
                for remaining in target.moments where remaining.asset == nil {
                    current = try await PipelineStoryboardEditor.attachImage(from: directory.appendingPathComponent("source.png"),
                        shotID: target.id, momentID: remaining.id, expectedFingerprint: current.fingerprint, editor: context.editor)
                }
            }
        }

        func camera(_ context: ProductionPlanningAcceptanceFixture.Context) async throws {
            let driver = try requireDriver(), window = driver.window
            let before = try readPlan(context.dataRoot)
            try copyCurrent(ShotPlanningDraftV1.currentPath, root: context.dataRoot, label: "planning-before")
            guard let shot = before.shots.first else { throw failed("The actual planning draft is empty.") }
            let sheet = try await open(editor: context.editor, window: window, driver: driver)
            try await openRetained(sheet, driver: driver)
            try await selectSource(shotObject, title: "3. EXT. HARBOUR — NIGHT · 1A.1", sheet: sheet, driver: driver)
            try await driver.reveal("filmflow.target.shot", in: sheet)
            try await driver.picker("filmflow.target.shot", title: "Shot 1", expected: shot.shotID, in: sheet)
            try await driver.reveal("filmflow.camera.movement", in: sheet)
            try await driver.picker("filmflow.camera.movement", title: "pan", expected: "pan", in: sheet)
            guard let retained else { throw failed("The retained snapshot is missing.") }
            let sourceURL = retained.directory.appendingPathComponent("dto/get_shotlist.json")
            let originalBytes = try Data(contentsOf: sourceURL)
            let altered = Data("{\"changed\":\"after native preview\"}".utf8)
            try altered.write(to: sourceURL, options: .atomic)
            try altered.write(to: directory.appendingPathComponent("stale-source.json"), options: .atomic)
            do {
                try await driver.click("filmflow.camera.apply", in: sheet)
                try await driver.wait("changed source bytes refused") { driver.text("filmflow.error", in: sheet)?.isEmpty == false }
                guard try readPlan(context.dataRoot) == before else { throw failed("A stale imported source changed the canonical plan.") }
                try driver.capture("stale-source-refused", target: sheet)
                try driver.record("FilmFlow stale source refused", fields: ["sourcePath": "dto/get_shotlist.json",
                    "originalSHA256": FileDigest.sha256(of: originalBytes), "changedSHA256": FileDigest.sha256(of: altered),
                    "message": driver.text("filmflow.error", in: sheet) ?? ""])
            } catch { try originalBytes.write(to: sourceURL, options: .atomic); throw error }
            try originalBytes.write(to: sourceURL, options: .atomic)
            try await driver.click("filmflow.targets.reload", in: sheet)
            try await driver.wait("original retained source restored") { driver.state("filmflow.targets.reload", in: sheet) == true }
            try await driver.reveal("filmflow.camera.apply", in: sheet); try driver.capture("camera-mapping", target: sheet)
            try await driver.click("filmflow.camera.apply", in: sheet); try await appliedMessage(sheet, driver: driver)
            let after = try readPlan(context.dataRoot)
            guard after.shots[0].camera.movement == .pan, after.shots[0].sourceMode == shot.sourceMode,
                  after.shots[0].camera.movementDetail?.contains("Track the harbour light") == true,
                  Array(after.shots.dropFirst()) == Array(before.shots.dropFirst()) else { throw failed("Camera mapping changed another shot or lost source notes.") }
            try copyCurrent(ShotPlanningDraftV1.currentPath, root: context.dataRoot, label: "planning-applied")
            try await close(sheet, parent: window, driver: driver)
            try await undo(window, redo: false, driver: driver)
            try await driver.wait("native camera Undo", seconds: 30) { (try? readPlan(context.dataRoot).shots) == before.shots }
            try copyCurrent(ShotPlanningDraftV1.currentPath, root: context.dataRoot, label: "planning-undo")
            try await undo(window, redo: true, driver: driver)
            try await driver.wait("native camera Redo", seconds: 30) { (try? readPlan(context.dataRoot).shots) == after.shots }
            try copyCurrent(ShotPlanningDraftV1.currentPath, root: context.dataRoot, label: "planning-redo")
        }

        func saveAndReopen(_ context: ProductionPlanningAcceptanceFixture.Context) async throws -> [String: Any] {
            let driver = try requireDriver(), window = driver.window
            guard let retained, let viewport = window.contentView?.bounds.size, viewport == NSSize(width: 960, height: 640),
                  AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else {
                throw failed("The measured native viewport or interface scale is wrong.")
            }
            let plan = try readPlan(context.dataRoot)
            try FileManager.default.copyItem(at: context.dataRoot.appendingPathComponent("import/filmflow-adoptions"), to: directory.appendingPathComponent("adoptions"))
            let closure = try copyAdoptionOutputs(root: context.dataRoot)
            try await AppNativeMenuAcceptance.choose(["File", "Save"], in: window, driver: driver)
            try await driver.wait("native saved FilmFlow project", seconds: 30) { !context.document.isDocumentEdited }
            guard let savedRoot = DataRootResolver.dataRoot(of: context.packageURL) else { throw failed("The saved package has no pipeline directory.") }
            let persisted = try copyPersistence(root: savedRoot, label: "saved", closure: closure)
            context.document.close()
            let document = try await VideoProject.load(from: context.packageURL)
            defer { document.close() }
            NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
            guard let reopenedWindow = document.windowControllers.first?.window, let home = document.editorViewModel.workingRoot,
                  let root = DataRootResolver.dataRoot(of: home) else { throw failed("The saved project did not reopen.") }
            reopenedWindow.setContentSize(NSSize(width: 960, height: 640)); reopenedWindow.makeKeyAndOrderFront(nil)
            await document.editorViewModel.refreshEngineState()
            let beforeCalls = FilmFlowAcceptanceHTTP.calls().count
            let sheet = try await open(editor: document.editorViewModel, window: reopenedWindow, driver: driver)
            try await openRetained(sheet, driver: driver)
            try await selectSource(shotObject, title: "3. EXT. HARBOUR — NIGHT · 1A.1", sheet: sheet, driver: driver)
            let loaded = try await Task.detached { try FilmFlowSnapshotStore.list(dataRoot: root) }.value
            guard loaded.count == 1, loaded[0].sha256 == retained.sha256,
                  try readPlan(root).shots == plan.shots,
                  FilmFlowAcceptanceHTTP.calls().count == beforeCalls else { throw failed("Offline reopen changed the archive or contacted FilmFlow.") }
            try driver.capture("offline-reopened", target: sheet)
            try await close(sheet, parent: reopenedWindow, driver: driver)
            let reopened = try copyPersistence(root: root, label: "reopened", closure: closure)
            guard persisted == reopened else { throw failed("The persisted FilmFlow closure changed during reopen.") }
            let files = try fileInventory(directory)
            let value: [String: Any] = ["schema": "ngv.filmflow-owner.v1", "scale": scale,
                "effectiveScale": AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)),
                "viewport": ["width": viewport.width, "height": viewport.height], "backingScale": window.backingScaleFactor,
                "snapshotSHA256": retained.sha256, "snapshotID": retained.id.uuidString.lowercased(),
                "liveOAuth": false, "isolatedSDKTransport": true, "calls": FilmFlowAcceptanceHTTP.calls(),
                "native": driver.result(), "reopenedSnapshotSHA256": loaded[0].sha256,
                "offlineReadCallCountBefore": beforeCalls, "offlineReadCallCountAfter": FilmFlowAcceptanceHTTP.calls().count,
                "adoptionOutputs": closure, "persistedFiles": persisted, "files": files]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
            return value
        }

        private func selectionUndoRedo(_ context: ProductionPlanningAcceptanceFixture.Context,
            before: PipelineStorySourceWriter.SelectionState, applied: PipelineStorySourceWriter.SelectionState,
            driver: ProductionVisualSourcesDriver) async throws {
            for (redo, expected, label) in [(false, before, "notes-undo"), (true, applied, "notes-redo"), (false, before, "notes-restored")] {
                try await undo(driver.window, redo: redo, driver: driver)
                try await driver.wait(label, seconds: 30) { (try? PipelineStorySourceWriter.selectionState(dataRoot: context.dataRoot)) == expected }
                try saveSelection(try PipelineStorySourceWriter.selectionState(dataRoot: context.dataRoot), label: label)
            }
        }
        private func open(editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
            await editor.refreshEngineState()
            try await AppNativeMenuAcceptance.choose(["File", "Import from FilmFlow…"], in: window, driver: driver)
            let sheet = try await driver.sheet("filmflow.sheet", parent: window)
            try await driver.wait("FilmFlow targets loaded", seconds: 30) { driver.state("filmflow.targets.reload", in: sheet) == true }
            return sheet
        }
        private func openRetained(_ sheet: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
            guard let retained else { throw failed("No retained snapshot was captured.") }
            let title = retained.snapshot.project.title + " · " + retained.snapshot.finishedAt.formatted()
            try await driver.reveal("filmflow.snapshot", in: sheet)
            try await driver.picker("filmflow.snapshot", title: title, expected: retained.id.uuidString, in: sheet)
            try await driver.click("filmflow.open-retained", in: sheet)
            try await driver.wait("offline retained material loaded") { driver.state("filmflow.source", in: sheet) == true }
        }
        private func close(_ sheet: NSWindow, parent: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
            try await driver.click("filmflow.done", in: sheet)
            try await driver.wait("FilmFlow sheet closed") { parent.attachedSheet == nil && parent.isKeyWindow }
        }
        private func selectProject(_ sheet: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
            try await driver.picker("filmflow.project", title: FilmFlowAcceptanceHTTP.title + " · OWNER", expected: FilmFlowAcceptanceHTTP.projectID, in: sheet)
        }
        private func selectSource(_ id: String, title: String, sheet: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
            try await driver.reveal("filmflow.source", in: sheet)
            try await driver.picker("filmflow.source", title: title, expected: id, in: sheet)
        }
        private func appliedMessage(_ sheet: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
            try await driver.wait("native FilmFlow material published", seconds: 30) { driver.text("filmflow.message", in: sheet)?.hasPrefix("Material adopted.") == true && driver.state("filmflow.targets.reload", in: sheet) == true }
        }
        private func undo(_ window: NSWindow, redo: Bool, driver: ProductionVisualSourcesDriver) async throws {
            try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: window)
        }
        private func copyOptional(_ path: String, root: URL, label: String) throws {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { try copyCurrent(path, root: root, label: label) }
            else { try Data("absent".utf8).write(to: directory.appendingPathComponent(label + ".absent"), options: .atomic) }
        }
        private func saveSelection(_ value: PipelineStorySourceWriter.SelectionState, label: String) throws {
            try value.selection?.write(to: directory.appendingPathComponent(label + ".json"), options: .atomic)
            try value.source?.write(to: directory.appendingPathComponent(label + ".md"), options: .atomic)
        }
        private func copyCurrent(_ path: String, root: URL, label: String) throws {
            try FileManager.default.copyItem(at: ProjectLocalFile.resolve(path, dataRoot: root), to: directory.appendingPathComponent(label + ".json"))
        }
        private func copyAdoptionOutputs(root: URL) throws -> [String: String] {
            let base = root.appendingPathComponent("import/filmflow-adoptions")
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw failed("The actual adoption receipts are missing.")
            }
            var outputs: [String: String] = [:]
            for case let file as URL in files where file.pathExtension == "json" {
                let bytes = try Data(contentsOf: file)
                guard let receipt = try? FilmFlowSnapshot.decode(FilmFlowAdoption.Receipt.self, from: bytes),
                      receipt.schema == "ngv.filmflow-adoption.v1" else { continue }
                var references = receipt.outputs
                for reference in receipt.outputs {
                    let source = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                    if let timing = try? JSONDecoder().decode(StoryboardTimingV1.self, from: Data(contentsOf: source)) {
                        for asset in timing.shots.flatMap(\.moments).compactMap(\.asset) {
                            references += [asset.image, asset.proof]
                            let proofURL = try ProjectLocalFile.requireHash(asset.proof.sha256, at: asset.proof.path, dataRoot: root)
                            let proof = try JSONDecoder().decode(StoryboardSketchProofV1.self, from: Data(contentsOf: proofURL))
                            references += try proof.currentByteReferences(dataRoot: root)
                        }
                    }
                }
                for reference in references {
                    if let previous = outputs[reference.path], previous != reference.sha256 {
                        throw failed("Two historical adoptions overwrite the same output path.")
                    }
                    let source = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                    if outputs[reference.path] == nil {
                        let target = directory.appendingPathComponent("adoption-outputs/" + reference.path)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: source, to: target)
                    }
                    outputs[reference.path] = reference.sha256
                }
            }
            guard !outputs.isEmpty else { throw failed("No historical adoption output was retained.") }
            return outputs
        }
        private func copyPersistence(root: URL, label: String, closure: [String: String]) throws -> [String: String] {
            guard let retained else { throw failed("No snapshot was accepted.") }
            var paths = Set(closure.keys)
            let archive = FilmFlowSnapshotStore.path(retained.id)
            paths.formUnion(try fileInventory(root.appendingPathComponent(archive)).keys.map { archive + "/" + $0 })
            let adoptions = "import/filmflow-adoptions"
            paths.formUnion(try fileInventory(root.appendingPathComponent(adoptions)).keys.map { adoptions + "/" + $0 })
            paths.insert(ShotPlanningDraftV1.currentPath)
            var copied: [String: String] = [:]
            for path in paths.sorted() {
                let source = try ProjectLocalFile.resolve(path, dataRoot: root)
                let target = directory.appendingPathComponent(label + "/" + path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                copied[path] = try FileDigest.sha256(of: source)
            }
            return copied
        }
        private func fileInventory(_ root: URL) throws -> [String: String] {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw failed("The evidence directory is missing.")
            }
            var files: [String: String] = [:]
            for case let file as URL in entries {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isSymbolicLink != true else { throw failed("Evidence must not contain symlinks.") }
                if properties.isRegularFile == true {
                    files[String(file.path.dropFirst(root.path.count + 1))] = try FileDigest.sha256(of: file)
                }
            }
            return files
        }
        private func readPlan(_ root: URL) throws -> ShotPlanningDraftV1 {
            try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root))
        }
        private func requireDriver() throws -> ProductionVisualSourcesDriver {
            guard let driver else { throw failed("The real document window has not been opened.") }; return driver
        }
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native FilmFlow import: " + message) }
}
