import AppKit
import AVKit
import NexGenEngine

@MainActor
enum ProductionV2TakeAcceptance {
    enum RangePlacement: String { case withHandles, endingAtSourceEnd }

    static func run(takeID: String, context: ProductionPlanningAcceptanceFixture.Context,
                    driver: ProductionVisualSourcesDriver,
                    rangePlacement: RangePlacement = .withHandles,
                    nextUnrenderedShotID: String? = nil,
                    expectedPreviewTakeID: String = "") async throws -> ReviewedTakeRange.Stored {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard let home = editor.workingRoot else { throw failed("The take project closed.") }
        let snapshot = try await TakeReview.capture(takeID: takeID, home: home)
        let initial = try await Task.detached {
            (try PipelineRenderTakeStore.load(dataRoot: root, project: snapshot.take.project, phase: snapshot.take.phase),
             try TakeReview.load(take: snapshot.take, dataRoot: root))
        }.value
        guard initial.0.selected[snapshot.take.shotID] == nil, initial.1 == nil else {
            throw failed("A take was already selected or reviewed before native input.")
        }
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        try await driver.click("take.open", in: window)
        let sheet = try await driver.sheet("take.picker")
        guard driver.text("take.picker", in: sheet) == expectedPreviewTakeID else { throw failed("Take review did not preserve the explicit preview choice.") }
        let title = try await pickerTitle(takeID: takeID, context: context)
        try await driver.picker("take.picker", title: title, expected: takeID, in: sheet)
        try await driver.wait("unreviewed take controls") {
            driver.text("take.pass", in: sheet) == TakeReview.Pass.identity.rawValue
                && driver.state("take.use", in: sheet) == false && driver.state("take.record-pass", in: sheet) == false
        }
        try await requireReviewBeforeIteration(snapshot: snapshot, context: context, driver: driver, sheet: sheet)
        try await ProductionNativePlayerAcceptance.playWholeTake(duration: snapshot.durationSeconds, driver: driver, sheet: sheet)
        try await driver.picker("take.verdict", title: "Reject", expected: TakeReview.Verdict.rejected.rawValue, in: sheet)
        let rejection = "Native acceptance rejection: the complete candidate is not approved before the separate review."
        try await finding(rejection, start: 0, end: snapshot.durationSeconds, driver: driver, sheet: sheet)
        try await driver.click("take.record-pass", in: sheet)
        try await driver.wait("rejected pass can be saved") { driver.text("take.save", in: sheet) == "1" }
        try await driver.click("take.save", in: sheet)
        try await driver.wait("rejection persisted", seconds: 30) {
            guard let review = try? TakeReview.load(take: snapshot.take, dataRoot: root) else { return false }
            return review.findings.count == 1 && review.findings[0].verdict == .rejected && review.findings[0].observation == rejection
        }
        guard driver.state("take.use", in: sheet) == false,
              try PipelineRenderTakeStore.load(dataRoot: root, project: snapshot.take.project, phase: snapshot.take.phase).selected[snapshot.take.shotID] == nil else {
            throw failed("A saved rejected take became selectable or selected.")
        }
        try driver.capture("take-rejected", target: sheet)
        try await ProductionTakeRepairAcceptance.run(snapshot: snapshot, context: context, driver: driver, sheet: sheet)
        try await driver.click("take.review-again", in: sheet)
        try await driver.wait("review restarted") { driver.text("take.pass", in: sheet) == TakeReview.Pass.identity.rawValue }
        var findings: [TakeReview.Finding] = []
        for (index, pass) in TakeReview.Pass.allCases.enumerated() {
            guard driver.text("take.pass", in: sheet) == pass.rawValue else { throw failed("Take review skipped a pass.") }
            let verdict: TakeReview.Verdict = pass == .identity ? .conforms : .acceptedDeviation
            let label = pass == .identity ? "Meets the approved plan" : "Accept deviation — explain"
            try await driver.picker("take.verdict", title: label, expected: verdict.rawValue, in: sheet)
            let observation = "Native acceptance \(pass.rawValue): the moving synthetic source is an intentional test composition."
            try await finding(observation, start: 0, end: snapshot.durationSeconds, driver: driver, sheet: sheet)
            findings.append(.init(pass: pass, verdict: verdict, observation: observation, startSeconds: 0, endSeconds: snapshot.durationSeconds))
            try await driver.click("take.record-pass", in: sheet)
            try await driver.wait("recorded take pass \(index + 1)") {
                driver.text(index + 1 == TakeReview.Pass.allCases.count ? "take.save" : "take.record-pass", in: sheet) == String(index + 1)
            }
        }
        try driver.capture("take-six-passes", target: sheet)
        try await driver.click("take.save", in: sheet)
        try await driver.wait("accepted take review persisted", seconds: 30) {
            (try? TakeReview.load(take: snapshot.take, dataRoot: root)?.findings) == findings && driver.state("take.use", in: sheet) == true
        }
        let updatedReviewSHA = try await Task.detached {
            try FileDigest.sha256(of: ProjectLocalFile.resolve(TakeReview.path(takeID: takeID), dataRoot: root))
        }.value
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: true, driver: driver, in: sheet)
        try await driver.wait("repair continuation binds the new review") {
            driver.text("take.repair.continue", in: sheet) == updatedReviewSHA
                && driver.state("take.repair.continue", in: sheet) == false
        }
        do {
            _ = try await TakeRepairPlan.requireForGeneration(input: snapshot.take.generationInput, home: home)
            throw failed("Reviewing the take cleared the explicit rescue decision.")
        } catch {
            guard error.localizedDescription.contains("Generation is paused by the recorded decision") else { throw error }
        }
        try driver.record("native repair superseded review", fields: ["takeID": takeID, "reviewSHA256": updatedReviewSHA,
            "continueEnabled": driver.state("take.repair.continue", in: sheet) == true, "rescueStillPausesGeneration": true])
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: false, driver: driver, in: sheet)
        try await driver.click("take.use", in: sheet)
        try await driver.wait("native V2 take selection", seconds: 30) {
            (try? PipelineProductionRenderWriter.requireSelected(shotID: snapshot.take.shotID, dataRoot: root).selection.takeID) == takeID
        }
        let wholeSelection = try await Task.detached { try PipelineProductionRenderWriter.requireSelected(shotID: snapshot.take.shotID, dataRoot: root) }.value
        try await requireNextShot(nextUnrenderedShotID, driver: driver, sheet: sheet)
        guard wholeSelection.selection.nativeRange == nil, wholeSelection.record.output.sha256 == snapshot.take.output.sha256 else {
            throw failed("Whole-take selection is bound to different output or a range that was never chosen.")
        }
        try driver.record("native whole-take selection", fields: ["takeID": takeID,
            "reviewSHA256": wholeSelection.selection.review.sha256, "selectionSHA256": wholeSelection.reference.sha256,
            "rejectedSelectionBlocked": true, "passes": findings.map { $0.pass.rawValue }])
        let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        guard let timing = projection.timing(for: snapshot.take.shotID), editor.timeline.fps > 0 else { throw failed("The selected take has no canonical planned duration.") }
        let count = projection.timebase.seconds(for: timing.durationTicks) * Double(editor.timeline.fps)
        guard count.isFinite, count > 0, abs(count - count.rounded()) < 0.000001, count < Double(Int.max / 2) else {
            throw failed("The planned take range is not an exact timeline frame count.")
        }
        let firstFrame: Int
        switch rangePlacement {
        case .withHandles: firstFrame = editor.timeline.fps
        case .endingAtSourceEnd:
            let sourceFrames = snapshot.durationSeconds * Double(editor.timeline.fps)
            guard sourceFrames.isFinite, sourceFrames < Double(Int.max / 2), sourceFrames > count,
                  abs(sourceFrames - sourceFrames.rounded()) < 0.000001 else {
                throw failed("The real source endpoint is not an exact frame after a usable leading handle.")
            }
            firstFrame = Int(sourceFrames.rounded()) - Int(count.rounded())
        }
        let endFrame = firstFrame + Int(count.rounded())
        let endSeconds = Double(endFrame) / Double(editor.timeline.fps)
        switch rangePlacement {
        case .withHandles:
            guard endSeconds < snapshot.durationSeconds else {
                throw failed("The generated candidate needs real leading and trailing media outside the selected range.")
            }
        case .endingAtSourceEnd:
            guard firstFrame > 0, abs(endSeconds - snapshot.durationSeconds) < 0.000001 else {
                throw failed("The native predecessor range does not end at the actual source endpoint.")
            }
        }
        let previousRanges = try await ReviewedTakeRange.saved(takeID: takeID, home: home)
        try await ProductionNativeDisclosureAcceptance.toggle("take.range.open", content: "take.range.start", expanded: true, driver: driver, in: sheet)
        try await driver.fill("take.range.start", value: String(firstFrame), in: sheet)
        try await driver.fill("take.range.end", value: String(endFrame), in: sheet)
        guard driver.state("take.range.record-pass", in: sheet) == false else { throw failed("An unplayed empty range finding is actionable.") }
        try await driver.click("take.range.play", in: sheet)
        try await driver.wait("range player started") {
            guard let player = ProductionNativePlaybackAcceptance.player("take.range.player", in: sheet) else { return false }
            return player.currentItem?.status == .readyToPlay
                && player.currentTime().seconds >= Double(firstFrame) / Double(editor.timeline.fps) && player.rate > 0
        }
        guard let player = ProductionNativePlaybackAcceptance.player("take.range.player", in: sheet) else { throw failed("The actual range player disappeared.") }
        try await driver.wait("entire selected source range played", seconds: Double(endFrame - firstFrame) / Double(editor.timeline.fps) + 5) {
            player.currentTime().seconds >= Double(endFrame - 1) / Double(editor.timeline.fps)
        }
        var rangeFindings: [TakeReview.Finding] = []
        for (index, pass) in TakeReview.Pass.allCases.enumerated() {
            guard driver.text("take.range.pass", in: sheet) == pass.rawValue else { throw failed("Range review skipped a pass.") }
            let observation = "Native range \(pass.rawValue): inspected the complete chosen source frames \(firstFrame)–\(endFrame)."
            try await driver.fill("take.range.observation", value: observation, in: sheet)
            rangeFindings.append(.init(pass: pass, verdict: .conforms, observation: observation,
                startSeconds: 0, endSeconds: Double(endFrame - firstFrame) / Double(editor.timeline.fps)))
            try await driver.click("take.range.record-pass", in: sheet)
            try await driver.wait("recorded range pass \(index + 1)") {
                index + 1 == TakeReview.Pass.allCases.count ? driver.state("take.range.save", in: sheet) == true
                    : driver.text("take.range.pass", in: sheet) == TakeReview.Pass.allCases[index + 1].rawValue
            }
        }
        try driver.capture("range-six-passes", target: sheet)
        try await driver.click("take.range.save", in: sheet)
        try await driver.wait("range saved", seconds: 30) { driver.state("take.range.audio", in: sheet) != nil }
        let saved = try await ReviewedTakeRange.saved(takeID: takeID, home: home)
        let new = saved.filter { candidate in !previousRanges.contains { $0.id == candidate.id } }
        guard new.count == 1, let range = new.first, range.review.range.startFrame == firstFrame,
              range.review.range.endFrame == endFrame, range.review.findings == rangeFindings,
              range.review.source == snapshot.take.output else { throw failed("The saved native range differs from its actual source and findings.") }
        try await driver.click("take.range.audio", in: sheet, enabled: false)
        try await driver.wait("include source audio selected") { driver.state("take.range.audio", in: sheet) == true }
        try await driver.click("take.range.use." + range.id, in: sheet)
        try await driver.wait("native range selected for shot", seconds: 30) {
            (try? PipelineProductionRenderWriter.requireSelected(shotID: snapshot.take.shotID, dataRoot: root).selection.nativeRange?.id) == range.id
        }
        try await requireNextShot(nextUnrenderedShotID, driver: driver, sheet: sheet)
        let timelineBeforeInsert = editor.timeline
        try await driver.click("take.range.add", in: sheet)
        try await driver.wait("reviewed range inserted", seconds: 30) { editor.timeline != timelineBeforeInsert }
        let oldIDs = Set(timelineBeforeInsert.tracks.flatMap(\.clips).map(\.id))
        let added = editor.timeline.tracks.flatMap(\.clips).filter { !oldIDs.contains($0.id) }
        guard let picture = added.first(where: { $0.mediaType == .video }),
              picture.trimStartFrame == firstFrame, picture.durationFrames == endFrame - firstFrame,
              let mediaURL = editor.mediaResolver.resolveURL(for: picture.mediaRef),
              try FileDigest.sha256(of: mediaURL) == snapshot.take.output.sha256 else {
            throw failed("Native range insertion changed the source or its exact frame interval.")
        }
        let hasAudio = try await AVURLAsset(url: snapshot.mediaURL).loadTracks(withMediaType: .audio).isEmpty == false
        guard !hasAudio || added.contains(where: { $0.mediaType == .audio && $0.mediaRef == picture.mediaRef
            && $0.trimStartFrame == firstFrame && $0.durationFrames == picture.durationFrames }) else {
            throw failed("The explicit source-audio choice did not add its matching audio range.")
        }
        try driver.capture("range-inserted", target: sheet)
        try await driver.click("take.close", in: sheet)
        try await driver.wait("take sheet closed") { window.attachedSheet == nil && window.isKeyWindow }
        try await driver.click("pipeline.overview.select.render", in: window, enabled: false)
        try await driver.wait("document receives inserted-range Undo") { !(window.firstResponder is NSTextView) }
        guard editor.undoManager?.canUndo == true else { throw failed("The native reviewed-range insertion has no Undo.") }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("undo incidental range insertion") { editor.timeline == timelineBeforeInsert }
        let selected = try await Task.detached { try PipelineProductionRenderWriter.requireSelected(shotID: snapshot.take.shotID, dataRoot: root) }.value
        guard selected.selection.nativeRange?.id == range.id else { throw failed("Timeline Undo changed the explicitly selected production range.") }
        try driver.record("native reviewed range selected and inserted", fields: ["takeID": takeID, "reviewID": range.id,
            "firstFrame": firstFrame, "endFrame": endFrame, "fps": editor.timeline.fps,
            "rangePlacement": rangePlacement.rawValue, "sourceDurationSeconds": snapshot.durationSeconds,
            "sourceSHA256": range.review.source.sha256, "includedAvailableAudio": hasAudio,
            "insertUndoPreservedSelection": true, "selectionSHA256": selected.reference.sha256])
        return range
    }

    static func nextShot(firstTakeID: String, nextTakeID: String,
                         context: ProductionPlanningAcceptanceFixture.Context,
                         driver: ProductionVisualSourcesDriver) async throws {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        guard let home = editor.workingRoot else { throw failed("The next-shot project closed.") }
        let first = try await TakeReview.capture(takeID: firstTakeID, home: home)
        let next = try await TakeReview.capture(takeID: nextTakeID, home: home)
        let initial = try await Task.detached {
            try PipelineRenderTakeStore.load(dataRoot: root, project: first.take.project, phase: "final")
        }.value
        guard first.take.phase == "final", next.take.phase == "final",
              first.take.shotID != next.take.shotID, initial.selected[first.take.shotID] == firstTakeID,
              initial.selected[next.take.shotID] == nil else { throw failed("Next-shot navigation needs a selected predecessor and an unselected successor.") }
        let reviewBefore = try await Task.detached { try TakeReview.load(take: first.take, dataRoot: root) }.value
        let selectionBefore = try await Task.detached {
            try PipelineProductionRenderWriter.requireSelected(shotID: first.take.shotID, dataRoot: root).reference
        }.value
        let nextReviewBefore = try await Task.detached { try TakeReview.load(take: next.take, dataRoot: root) }.value
        guard reviewBefore != nil, nextReviewBefore == nil else {
            throw failed("Next-shot navigation needs an existing first review and a genuinely unreviewed successor.")
        }
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        try await driver.click("take.open", in: window)
        let sheet = try await driver.sheet("take.picker")
        let title = try await pickerTitle(takeID: firstTakeID, context: context)
        try await driver.picker("take.picker", title: title, expected: firstTakeID, in: sheet)
        try await driver.wait("next available take in the review sheet") {
            driver.state("take.next", in: sheet) == true && driver.text("take.next", in: sheet) == next.take.shotID
        }
        try await driver.reveal("take.next", in: sheet)
        try driver.visible(["take.next"], in: sheet)
        try driver.capture("next-shot-sheet-before", target: sheet)
        try await driver.click("take.next", in: sheet)
        try await driver.reveal("take.picker", in: sheet)
        try await driver.wait("next unreviewed take opened without approval") {
            driver.text("take.picker", in: sheet) == nextTakeID
                && driver.text("take.pass", in: sheet) == TakeReview.Pass.identity.rawValue
                && driver.state("take.use", in: sheet) == false
        }
        try driver.capture("next-shot-sheet-after", target: sheet)
        try await driver.click("take.close", in: sheet)
        try await driver.wait("next-shot sheet closed") { window.attachedSheet == nil && window.isKeyWindow }
        try await driver.click("take.workspace.select.\(firstTakeID)", in: window)
        try await driver.wait("selected predecessor preview and next action") {
            driver.text("take.workspace.player", in: window) == firstTakeID
                && driver.state("take.next", in: window) == true
                && driver.text("take.next", in: window) == next.take.shotID
        }
        try await driver.reveal("take.next", in: window)
        try driver.visible(["take.next"], in: window)
        try driver.capture("next-shot-workspace-before", target: window)
        try await driver.click("take.next", in: window)
        try await driver.reveal("take.workspace.player", in: window)
        try await driver.wait("workspace opens the next exact take") {
            driver.text("take.workspace.player", in: window) == nextTakeID
                && driver.state("take.next", in: window) == nil
        }
        try driver.capture("next-shot-workspace-after", target: window)
        let final = try await Task.detached {
            (try PipelineRenderTakeStore.load(dataRoot: root, project: first.take.project, phase: "final"),
             try TakeReview.load(take: first.take, dataRoot: root), try TakeReview.load(take: next.take, dataRoot: root))
        }.value
        let selectionAfter = try await Task.detached {
            try PipelineProductionRenderWriter.requireSelected(shotID: first.take.shotID, dataRoot: root).reference
        }.value
        guard final.0 == initial, final.1 == reviewBefore, final.2 == nil, selectionAfter == selectionBefore else {
            throw failed("Next-shot navigation changed a take selection or review.")
        }
        try driver.record("native next open shot in sheet and workspace", fields: ["firstTakeID": firstTakeID,
            "nextTakeID": nextTakeID, "nextShotID": next.take.shotID, "selectionAndReviewUnchanged": true,
            "selectionSHA256Before": selectionBefore.sha256, "selectionSHA256After": selectionAfter.sha256])
    }

    private static func requireNextShot(_ unrenderedShotID: String?, driver: ProductionVisualSourcesDriver,
                                        sheet: NSWindow) async throws {
        try await driver.wait("selected take exposes the next open shot or completed queue", seconds: 30) {
            if let unrenderedShotID {
                return driver.text("take.next.missing", in: sheet) == unrenderedShotID
                    && driver.state("take.queue.complete", in: sheet) == nil
            }
            return driver.state("take.queue.complete", in: sheet) != nil
                && driver.state("take.next.missing", in: sheet) == nil
        }
    }

    private static func finding(_ text: String, start: Double, end: Double,
                                driver: ProductionVisualSourcesDriver, sheet: NSWindow) async throws {
        try await driver.fill("take.observation", value: text, in: sheet)
        try await driver.fill("take.start", value: String(start), in: sheet)
        try await driver.fill("take.end", value: String(end), in: sheet)
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native V2 take acceptance: " + message) }
}

@MainActor
enum ProductionNativePlaybackAcceptance {
    static func player(_ identifier: String, in window: NSWindow) -> AVPlayer? {
        guard let root = window.contentView, let frame = WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: window) else { return nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let candidates = descendants(root).compactMap { $0 as? AVPlayerView }.filter { view in
            let actual = view.convert(view.bounds, to: root)
            return !view.isHiddenOrHasHiddenAncestor && actual.width > 0 && actual.height > 0
                && frame.insetBy(dx: -1, dy: -1).contains(actual)
        }
        return candidates.count == 1 ? candidates[0].player : nil
    }
}

extension ProductionV2TakeAcceptance {
    private static func requireReviewBeforeIteration(snapshot: TakeReview.Snapshot,
        context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver, sheet: NSWindow) async throws {
        let reason = "Inspect and review this candidate before recording the next iteration."
        try TakeIterationPolicyV1().validate()
        guard try TakeReview.load(take: snapshot.take, dataRoot: context.dataRoot) == nil else {
            throw failed("The iteration prerequisite fixture already has a saved take review.")
        }
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: true, driver: driver, in: sheet)
        try await driver.fill("take.repair.reason", value: reason, in: sheet, requireFocusExit: true)
        try await driver.reveal("take.repair.prerequisite", in: sheet)
        try driver.visible(["take.repair.prerequisite", "take.repair.save"], in: sheet)
        let instruction = "Complete and save the take review before recording an iteration decision."
        guard let root = sheet.contentView else { throw failed("The native take review sheet disappeared.") }
        let viewport = sheet.convertToScreen(root.convert(root.visibleRect, to: nil))
        var pending: [any NSAccessibilityProtocol] = [root], visited = Set<ObjectIdentifier>()
        var instructionFrame: NSRect?
        while let element = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let frame = element.accessibilityFrame()
            if element.accessibilityRole() == .staticText, frame.width > 0, frame.height > 0, viewport.contains(frame),
               [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityValue() as? String].contains(instruction) {
                instructionFrame = frame; break
            }
            pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        guard let instructionFrame, driver.text("take.repair.reason", in: sheet) == reason,
              driver.state("take.repair.save", in: sheet) == false,
              try TakeReview.load(take: snapshot.take, dataRoot: context.dataRoot) == nil else {
            throw failed("An unreviewed take needs a visible review prerequisite and disabled iteration Save with a valid reason.")
        }
        try driver.capture("take-repair-review-required", target: sheet)
        try driver.record("native take review prerequisite", fields: ["takeID": snapshot.take.id, "reviewExists": false,
            "reason": reason, "saveEnabled": driver.state("take.repair.save", in: sheet) == true,
            "instruction": instruction, "instructionFrame": [instructionFrame.minX, instructionFrame.minY, instructionFrame.width, instructionFrame.height],
            "window": sheet.windowNumber])
        try await driver.fill("take.repair.reason", value: "", in: sheet, requireFocusExit: true)
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: false, driver: driver, in: sheet)
    }

    static func pickerTitle(takeID: String, context: ProductionPlanningAcceptanceFixture.Context) async throws -> String {
        let root = context.dataRoot, productionV2 = context.editor.usesProductionPlanningV2
        return try await Task.detached {
            let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile).project
            let projection = productionV2 ? try ProductionPlanningLineageV2.projection(dataRoot: root) : nil
            let takes = try ["preview", "final"].flatMap { phase in
                try PipelineRenderTakeStore.load(dataRoot: root, project: project, phase: phase).takeIDs.map {
                    try PipelineRenderTakeStore.take(id: $0, dataRoot: root)
                }
            }.sorted { $0.recordedAt > $1.recordedAt }
            guard let index = takes.firstIndex(where: { $0.id == takeID }) else {
                throw GateBlocked("The native take picker candidate is unavailable.")
            }
            let take = takes[index]
            let number = projection?.shots.firstIndex { $0.id == take.shotID }
            let shot = number.map { String(localized: "Shot \($0 + 1)") }
                ?? (productionV2 ? String(localized: "Previous plan shot") : take.shotID)
            let phase = take.phase == "preview" ? String(localized: "Draft") : String(localized: "Production")
            return "\(shot) · \(phase) · Take \(index + 1) · \(take.recordedAt)"
        }.value
    }
}
