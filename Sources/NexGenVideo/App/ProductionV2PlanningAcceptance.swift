import AppKit
import NexGenEngine

@MainActor
enum ProductionV2PlanningAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, sourceVideo: URL,
                    driver: ProductionVisualSourcesDriver, generatedFirstShot: Bool,
                    sketchGeneration: ProductionV2GenerationAcceptance? = nil,
                    beforeShotPlanningApproval: (@MainActor (ProductionPlanningAcceptanceFixture.Context, ProductionVisualSourcesDriver) async throws -> Void)? = nil) async throws -> ShotPlanningDraftV1 {
        let editor = context.editor, window = driver.window, root = context.dataRoot
        try await selectPhase("script", context: context, driver: driver)
        let scriptBefore = try await Task.detached { try PlanningWriterIO.script(dataRoot: root) }.value
        guard let scene = scriptBefore.scenes.first else { throw failed("Script has no scene.") }
        try await driver.click("script.scene.edit." + scene.id, in: window)
        let sheet = try await driver.sheet("script.scene.title")
        let title = scene.title + " — native revision"
        try await driver.fill("script.scene.title", value: title, in: sheet)
        try driver.visible(["script.scene.cancel", "script.scene.apply"], in: sheet)
        try driver.capture("script-edit", target: sheet)
        try await driver.click("script.scene.apply", in: sheet)
        try await driver.wait("Script edit committed") { window.attachedSheet == nil }
        let scriptAfter = try await Task.detached { try PlanningWriterIO.script(dataRoot: root) }.value
        guard scriptAfter.header.revision > scriptBefore.header.revision,
              scriptAfter.scenes.first?.title == title, scriptAfter.events == scriptBefore.events else {
            throw failed("Native Script edit did not preserve its events and publish the typed title.")
        }
        try driver.record("native Script revision", fields: ["before": scriptBefore.header.revision,
            "after": scriptAfter.header.revision, "title": title])
        try await approve("script", artifact: ScriptV1.currentPath, next: "storyboard", context: context, driver: driver)

        let initial = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        try await selectPhase("storyboard", context: context, driver: driver)
        guard let first = initial.timing.shots.first, first.durationTicks > 1 else { throw failed("Storyboard has no usable shot.") }
        let clock = initial.timing.timebase
        try clock.validate()
        let frameTicks = clock.ticksPerSecond * clock.fpsDenominator / clock.fpsNumerator
        let offset = first.durationTicks / 2 / frameTicks * frameTicks
        guard offset > 0, offset < first.durationTicks else { throw failed("The planned shot has no distinct interior source frame.") }
        let seconds = ProductionTimeEntry.seconds(offset, timebase: initial.timing.timebase)
        try await driver.click("storyboard.moment.add." + first.id, in: window)
        let momentSheet = try await driver.sheet("storyboard.edit.sheet")
        try await driver.fill("storyboard.edit.first", value: seconds, in: momentSheet)
        let intent = "The same action reaches its second visible position."
        try await driver.fill("storyboard.edit.second", value: intent, in: momentSheet)
        try driver.visible(["storyboard.edit.cancel", "storyboard.edit.apply"], in: momentSheet)
        try driver.capture("add-moment", target: momentSheet)
        try await driver.click("storyboard.edit.apply", in: momentSheet)
        try await driver.wait("second moment committed") { window.attachedSheet == nil }
        let added = try await board(context, requireVisuals: false)
        guard added.timing.shots.map(\.id) == initial.timing.shots.map(\.id),
              added.timing.shots.map(\.startTicks) == initial.timing.shots.map(\.startTicks),
              added.timing.shots.map(\.durationTicks) == initial.timing.shots.map(\.durationTicks),
              let changed = added.timing.shots.first, changed.moments.count == first.moments.count + 1,
              changed.moments.contains(where: { $0.offsetTicks == offset && $0.intent == intent }) else {
            throw failed("Adding a sketch moment changed shot identity/timing or failed to preserve the typed moment.")
        }
        let beforeUndo = editor.engineStateRevision
        try await driver.click("storyboard.undo", in: window)
        try await driver.wait("Storyboard Undo committed", seconds: 30) { editor.engineStateRevision > beforeUndo && !busy(editor) }
        let undone = try await board(context, requireVisuals: false)
        guard sameBoardContents(undone, initial), undone.storyboard.header.revision > added.storyboard.header.revision else {
            throw failed("Native Storyboard Undo did not restore the preceding moments and timing.")
        }
        let beforeRedo = editor.engineStateRevision
        try await driver.click("storyboard.redo", in: window)
        try await driver.wait("Storyboard Redo committed", seconds: 30) { editor.engineStateRevision > beforeRedo && !busy(editor) }
        let restored = try await board(context, requireVisuals: false)
        guard sameBoardContents(restored, added), restored.storyboard.header.revision > undone.storyboard.header.revision else {
            throw failed("Native Storyboard Redo did not restore the additional moment.")
        }
        try driver.record("multiple moments with native Undo and Redo", fields: ["shotID": first.id,
            "momentIDs": restored.timing.shots.first!.moments.map(\.id), "offsetTicks": offset,
            "shotCount": restored.timing.shots.count, "durationTicks": first.durationTicks])
        try await requestApproval("storyboard", artifact: StoryboardV2.currentPath, context: context)
        try await driver.wait("missing sketches block approval") {
            driver.state("agent.gate.approve", in: window) == false
                && driver.text("agent.gate.approve", in: window) != "Checking the current phase…"
        }
        try driver.capture("missing-sketches-block-approval", target: window)
        let beforeDecline = Set(editor.agentService.messages.map(\.id))
        try await driver.click("agent.gate.decline", in: window)
        try await driver.wait("missing-sketch decision and actual follow-up settled") {
            editor.agentService.pendingGateApproval == nil && !editor.agentService.isStreaming
                && editor.agentService.messages.contains { message in
                    !beforeDecline.contains(message.id) && message.role == .assistant && message.blocks.contains {
                        if case .text(let value) = $0 { return value == "Acceptance transport received storyboard." }
                        return false
                    }
                }
        }
        try await assignSketches(context: context, sourceVideo: sourceVideo, driver: driver)
        if let sketchGeneration {
            try await ProductionStoryboardGenerationAcceptance.run(context: context, generation: sketchGeneration, driver: driver)
        }
        let visual = try await board(context)
        try await playMoments(visual, driver: driver)
        try await approve("storyboard", artifact: StoryboardV2.currentPath, next: "shot_planning", context: context, driver: driver)

        let draft = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: context)
        if generatedFirstShot {
            let proposal = draft.shots.enumerated().map { index, shot in
                ShotPlanningDraftV1.ShotIntent(shotID: shot.shotID, sourceMode: shot.sourceMode, camera: shot.camera,
                    obligations: index == 0 ? [.init(id: "look", kind: .look, subject: "Approved side lighting",
                        requirement: "Use the actual approved Production Design reference.", required: true)] : [])
            }
            try await ProductionPlanningAcceptanceFixture.run("write_shot_planning_draft", args: [
                "origin": "agentRevision", "shots": try ProductionPlanningAcceptanceFixture.object(proposal)], in: context)
        }
        try await selectPhase("shot_planning", context: context, driver: driver)
        for (index, shot) in draft.shots.enumerated() where index != 0 || !generatedFirstShot {
            try await driver.picker("shot-planning.source-mode." + shot.shotID, title: "Imported footage",
                expected: SourceMode.imported.rawValue, in: window)
            let before = try await readDraft(context)
            try await driver.chooseFile(nil, in: window, trigger: "shot-planning.choose-source." + shot.shotID)
            guard try await readDraft(context) == before else { throw failed("Cancelling source selection changed Shot Planning.") }
            try await driver.chooseFile(sourceVideo, in: window, trigger: "shot-planning.choose-source." + shot.shotID)
            try await driver.wait("native source attached", seconds: 30) {
                driver.text("shot-planning.source-end." + shot.shotID, in: window) != nil
                    && !self.busy(editor)
            }
            let imported = try await readDraft(context)
            guard let selected = imported.shots.first(where: { $0.shotID == shot.shotID }),
                  selected.sourceMode == .imported, let source = selected.source,
                  let timing = visual.timing.shots.first(where: { $0.id == shot.shotID }) else {
                throw failed("The native source picker did not bind its selected video.")
            }
            let originalHash = try await Task.detached { try FileDigest.sha256(of: sourceVideo) }.value
            guard source.sha256 == originalHash else { throw failed("The native source picker bound different video bytes.") }
            let end = ProductionTimeEntry.seconds(timing.durationTicks, timebase: visual.timing.timebase)
            try await driver.fill("shot-planning.source-start." + shot.shotID, value: "0", in: window)
            try await driver.fill("shot-planning.source-end." + shot.shotID, value: end, in: window)
            try await applyShot(shot.shotID, context: context, driver: driver)
            let trimmed = try await readDraft(context)
            guard let range = trimmed.shots.first(where: { $0.shotID == shot.shotID })?.sourceInputRange,
                  range.startTicks == 0, range.timebase.representsSameTime(range.durationTicks,
                    as: timing.durationTicks, timebase: visual.timing.timebase) else {
                throw failed("The typed source range differs from the planned shot duration.")
            }
            try driver.record("native source range", fields: ["shotID": shot.shotID, "sha256": source.sha256,
                "startTicks": range.startTicks, "durationTicks": range.durationTicks])
        }
        try await editShotAndUndo(context: context, shotID: draft.shots[0].shotID, driver: driver)
        try await beforeShotPlanningApproval?(context, driver)
        let final = try await readDraft(context)
        try driver.capture("shot-planning-reviewed", target: window)
        try await approve("shot_planning", artifact: ShotPlanningDraftV1.currentPath, next: "bible", context: context, driver: driver)
        return final
    }

    static func selectPhase(_ phase: String, context: ProductionPlanningAcceptanceFixture.Context,
                            driver: ProductionVisualSourcesDriver) async throws {
        try await driver.click("pipeline.overview.select." + phase, in: driver.window, enabled: false)
        try await driver.wait("selected phase " + phase) { context.editor.productionSelectedPhase == phase }
    }

    static func approve(_ phase: String, artifact: String, next: String?, context: ProductionPlanningAcceptanceFixture.Context,
                        driver: ProductionVisualSourcesDriver) async throws {
        if context.editor.declaredPluginBinding?.id == "musicvideo" {
            let evidence = try await MusicvideoNativeAcceptance.approve(phase, editor: context.editor, evidenceURL: driver.output)
            guard evidence.nextPhase == (next ?? "complete") else { throw failed("The native gate advanced to the wrong V2 phase.") }
            guard let row = try ProductionPlanningAcceptanceFixture.object(evidence) as? [String: Any] else {
                throw failed("Native gate evidence is not an object.")
            }
            try driver.record("native approval " + phase, fields: row)
            return
        }
        let root = context.dataRoot
        try await driver.wait("native gate runtime idle") { !context.editor.agentService.isStreaming }
        let priorMessages = Set(context.editor.agentService.messages.map(\.id))
        let before = try await Task.detached { try FileDigest.sha256(of: root.appendingPathComponent(PipelineLayout.gatesFile)) }.value
        try await requestApproval(phase, artifact: artifact, context: context)
        try await driver.wait("ready native approval " + phase) { driver.state("agent.gate.approve", in: driver.window) == true }
        try await driver.reveal("agent.gate.approve", in: driver.window)
        try driver.visible(["agent.gate.decline", "agent.gate.approve"], in: driver.window)
        try driver.capture("approve-" + phase, target: driver.window)
        try await driver.click("agent.gate.approve", in: driver.window)
        try await driver.wait("approved " + phase) {
            context.editor.agentService.pendingGateApproval == nil
                && context.editor.projectState?.phases.first(where: { $0.phase == phase })?.approved == true
                && (next == nil || context.editor.projectState?.nextPhaseName == next)
        }
        try await driver.wait("Core native approval handoff " + phase, seconds: 30) {
            !context.editor.agentService.isStreaming && context.editor.agentService.messages.contains {
                !priorMessages.contains($0.id) && $0.role == .assistant && $0.blocks.contains {
                    if case .text(let value) = $0 { return value == "Acceptance transport received " + (next ?? "complete") + "." }
                    return false
                }
            }
        }
        guard context.editor.agentService.messages.last(where: { $0.role == .user }).map({ $0.hidden && $0.userPresentation == nil }) == true else {
            throw failed("The Core phase handoff was shown as an authored user turn.")
        }
        let gate = try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile).get(phase) }.value
        guard gate.approved else { throw failed("The native approval did not persist its phase.") }
        let after = try await Task.detached { try FileDigest.sha256(of: root.appendingPathComponent(PipelineLayout.gatesFile)) }.value
        guard before != after else { throw failed("Native approval left the persisted gates unchanged.") }
        try driver.record("native approval " + phase, fields: ["phase": phase, "nextPhase": next ?? "complete",
            "approvedPersisted": gate.approved, "handoffHidden": true, "gatesBeforeSHA256": before, "gatesAfterSHA256": after])
    }

    private static func requestApproval(_ phase: String, artifact: String, context: ProductionPlanningAcceptanceFixture.Context) async throws {
        let root = context.dataRoot
        guard let sessionID = context.editor.agentService.currentSessionId else {
            throw failed("The native gate request has no actual recording-runtime session.")
        }
        let fingerprint = try await Task.detached { GateArtifactFingerprint(path: artifact,
            sha256: try FileDigest.sha256(of: root.appendingPathComponent(artifact)),
            lineageSHA256: try FileDigest.sha256(of: root.appendingPathComponent(PipelineLayout.lineageFile)), phase: phase) }.value
        _ = try context.editor.agentService.requestGateApproval(.init(phase: phase, dataRoot: root,
            declaredPack: context.editor.declaredPluginName, declaredBinding: context.editor.declaredPluginBinding,
            declaredProductionContract: context.editor.declaredProductionContract,
            sessionId: sessionID, artifactFingerprint: fingerprint), origin: .inAppChat(sessionID: sessionID))
    }

    private static func assignSketches(context: ProductionPlanningAcceptanceFixture.Context, sourceVideo: URL,
                                      driver: ProductionVisualSourcesDriver) async throws {
        let current = try await board(context, requireVisuals: false)
        let sourceHash = try await Task.detached { try FileDigest.sha256(of: sourceVideo) }.value
        for shot in current.timing.shots {
            for moment in shot.moments {
                try await driver.menu("storyboard.sketch.sources." + moment.id, title: "Capture source video frame…", in: driver.window)
                let sheet = try await driver.sheet("storyboard.native-sketch.sheet")
                guard driver.state("storyboard.native-sketch.confirm", in: sheet) == false else { throw failed("An unprepared sketch is assignable.") }
                try await driver.chooseFile(sourceVideo, in: sheet)
                let time = ProductionTimeEntry.seconds(moment.offsetTicks, timebase: current.timing.timebase)
                try await driver.fill("storyboard.native-sketch.source-seconds", value: time, in: sheet)
                try await driver.click("storyboard.native-sketch.preview-frame", in: sheet)
                try await driver.wait("actual decoded sketch preview", seconds: 30) {
                    driver.state("storyboard.native-sketch.confirm", in: sheet) == true
                        && driver.text("storyboard.native-sketch.image", in: sheet)?.count == 64
                }
                let imageHash = driver.text("storyboard.native-sketch.image", in: sheet)
                try await driver.reveal("storyboard.native-sketch.image", in: sheet)
                try driver.visible(["storyboard.native-sketch.image", "storyboard.native-sketch.cancel", "storyboard.native-sketch.confirm"], in: sheet)
                try driver.capture("sketch-preview-" + moment.id, target: sheet)
                try await driver.click("storyboard.native-sketch.confirm", in: sheet)
                try await driver.wait("native sketch assignment") { driver.window.attachedSheet == nil }
                let saved = try await board(context, requireVisuals: false)
                guard let assigned = saved.timing.shots.first(where: { $0.id == shot.id })?.moments.first(where: { $0.id == moment.id })?.asset else {
                    throw failed("The native sketch assignment has no canonical asset proof.")
                }
                let root = context.dataRoot
                let proof = try await Task.detached {
                    _ = try ProjectLocalFile.requireHash(assigned.proof.sha256, at: assigned.proof.path, dataRoot: root)
                    let proof = try PlanningWriterIO.read(StoryboardSketchProofV1.self, at: assigned.proof.path, dataRoot: root)
                    try PipelineStoryboardNativeMedia.requireCurrent(proof, dataRoot: root)
                    return proof
                }.value
                guard assigned.image.sha256 == imageHash, proof.image == assigned.image,
                      case .sourceFrame(let video, let clock, let ticks, _, _) = proof.source,
                      video.sha256 == sourceHash, clock.ticksPerSecond > 0, clock.ticksPerSecond <= Int64(Int32.max),
                      current.timing.timebase.ticksPerSecond > 0, current.timing.timebase.ticksPerSecond <= Int64(Int32.max),
                      ticks / clock.ticksPerSecond == moment.offsetTicks / current.timing.timebase.ticksPerSecond,
                      (ticks % clock.ticksPerSecond) * current.timing.timebase.ticksPerSecond
                        == (moment.offsetTicks % current.timing.timebase.ticksPerSecond) * clock.ticksPerSecond else {
                    throw failed("The assigned sketch differs from its preview, source bytes or chosen moment time.")
                }
                try driver.record("native sketch assignment", fields: ["shotID": shot.id, "momentID": moment.id,
                    "imageSHA256": assigned.image.sha256, "sourceSHA256": sourceHash, "sourceTime": time])
            }
        }
    }

    private static func playMoments(_ board: StoryboardBundleSnapshot, driver: ProductionVisualSourcesDriver) async throws {
        guard let shot = board.timing.shots.first, shot.moments.count >= 2,
              let first = shot.moments.first, let second = shot.moments.dropFirst().first,
              let firstImage = first.asset?.image, let secondImage = second.asset?.image,
              firstImage.sha256 != secondImage.sha256 else { throw failed("The two actual source moments need distinct decoded images.") }
        try await driver.click("storyboard.animatic." + shot.id, in: driver.window)
        try await driver.wait("first Animatic moment") { driver.text("animatic.image", in: driver.window) == first.id + ":" + firstImage.sha256 }
        try driver.capture("animatic-first-moment", target: driver.window)
        try await driver.click("animatic.play", in: driver.window)
        try await driver.wait("playback reaches second real sketch", seconds: board.timing.timebase.seconds(for: shot.durationTicks) + 5) {
            driver.text("animatic.image", in: driver.window) == second.id + ":" + secondImage.sha256
        }
        try await driver.click("animatic.play", in: driver.window)
        try driver.capture("animatic-second-moment", target: driver.window)
        try driver.record("two moments within one shot", fields: ["shotID": shot.id,
            "firstImageSHA256": firstImage.sha256, "secondImageSHA256": secondImage.sha256, "cutUnchanged": true])
        try await driver.click("storyboard.view", in: driver.window, enabled: false, fraction: NSPoint(x: 0.25, y: 0.5))
        try await driver.wait("return to Storyboard") { driver.state("storyboard.view", in: driver.window) == false }
    }

    private static func editShotAndUndo(context: ProductionPlanningAcceptanceFixture.Context, shotID: String,
                                       driver: ProductionVisualSourcesDriver) async throws {
        let window = driver.window, editor = context.editor
        let before = try await readDraft(context)
        try await ProductionNativeDisclosureAcceptance.toggle("shot-planning.camera.disclosure." + shotID,
            content: "shot-planning.blocking." + shotID, expanded: true, driver: driver, in: window)
        let text = "Move the same subject across the pale background without changing the cut."
        try await driver.fill("shot-planning.blocking." + shotID, value: text, in: window)
        try await applyShot(shotID, context: context, driver: driver)
        let applied = try await readDraft(context)
        guard applied.header.revision > before.header.revision,
              applied.shots.first(where: { $0.shotID == shotID })?.camera.blocking == [text] else {
            throw failed("The native Shot Planning edit did not publish its exact blocking direction.")
        }
        try await ProductionNativeDisclosureAcceptance.toggle("shot-planning.camera.disclosure." + shotID,
            content: "shot-planning.blocking." + shotID, expanded: false, driver: driver, in: window)
        try await driver.wait("document receives Shot Planning Undo") { !(window.firstResponder is NSTextView) }
        guard !(window.firstResponder is NSTextView), editor.undoManager?.canUndo == true else {
            throw failed("Native Shot Planning Undo still targets a text editor or has no document revision.")
        }
        let revision = editor.engineStateRevision
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("native Shot Planning Undo", seconds: 30) { editor.engineStateRevision > revision && !busy(editor) }
        let undone = try await readDraft(context)
        guard undone.shots == before.shots, undone.header.revision > applied.header.revision,
              editor.undoManager?.canRedo == true else { throw failed("Native document Undo did not publish the preceding shot choices.") }
        let undoRevision = editor.engineStateRevision
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("native Shot Planning Redo", seconds: 30) { editor.engineStateRevision > undoRevision && !busy(editor) }
        let redone = try await readDraft(context)
        guard redone.shots == applied.shots, redone.header.revision > undone.header.revision else {
            throw failed("Native document Redo did not restore the edited shot choices.")
        }
        try driver.record("native Shot Planning Undo and Redo", fields: ["shotID": shotID,
            "before": before.header.revision, "applied": applied.header.revision,
            "undone": undone.header.revision, "redone": redone.header.revision])
    }

    private static func applyShot(_ id: String, context: ProductionPlanningAcceptanceFixture.Context,
                                  driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("shot changes enabled") { driver.state("shot-planning.apply." + id, in: driver.window) == true }
        let revision = context.editor.engineStateRevision
        try await driver.click("shot-planning.apply." + id, in: driver.window)
        try await driver.wait("shot changes committed", seconds: 30) {
            context.editor.engineStateRevision > revision && !busy(context.editor)
                && driver.state("shot-planning.apply." + id, in: driver.window) == false
        }
    }

    private static func busy(_ editor: EditorViewModel) -> Bool {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return true }
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil
    }

    private static func sameBoardContents(_ lhs: StoryboardBundleSnapshot, _ rhs: StoryboardBundleSnapshot) -> Bool {
        lhs.storyboard.header.projectID == rhs.storyboard.header.projectID
            && lhs.storyboard.summary == rhs.storyboard.summary && lhs.storyboard.steps == rhs.storyboard.steps
            && lhs.causality.bindings == rhs.causality.bindings && lhs.timing.timebase == rhs.timing.timebase
            && lhs.timing.mode == rhs.timing.mode && lhs.timing.audio == rhs.timing.audio
            && lhs.timing.rangeStartTicks == rhs.timing.rangeStartTicks && lhs.timing.rangeDurationTicks == rhs.timing.rangeDurationTicks
            && lhs.timing.shots == rhs.timing.shots
    }

    private static func board(_ context: ProductionPlanningAcceptanceFixture.Context, requireVisuals: Bool = true) async throws -> StoryboardBundleSnapshot {
        let root = context.dataRoot
        return try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: requireVisuals) }.value
    }

    private static func readDraft(_ context: ProductionPlanningAcceptanceFixture.Context) async throws -> ShotPlanningDraftV1 {
        let root = context.dataRoot
        return try await Task.detached { try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root,
            storyboard: PlanningWriterIO.storyboard(dataRoot: root)) }.value
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native V2 owner path: " + message) }
}
