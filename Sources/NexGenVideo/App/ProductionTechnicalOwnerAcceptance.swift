import AppKit
import NexGenEngine

@MainActor
enum ProductionTechnicalOwnerAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context,
                    driver: ProductionVisualSourcesDriver) async throws {
        let editor = context.editor, root = context.dataRoot, window = driver.window
        let projection = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        guard let shot = projection.shots.first, shot.sourceMode == .generated,
              context.editor.projectState?.nextPhaseName == "shotlist" else { throw failed("The actual generated Shot List must still await approval.") }
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
        let initial = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shot.id, editor: editor)
        let desired = try changedSettings(initial)
        try driver.record("native technical begin", fields: ["shotID": shot.id, "fingerprint": initial.fingerprint])
        let before = try await export(initial, label: "before", root: root, driver: driver)
        var sheet = try await open(shot.id, driver: driver)
        try await driver.wait("actual technical settings loaded", seconds: 30) {
            driver.text("production.technical.model", in: sheet) == initial.currentChange.candidateID
                && driver.state("production.technical.apply", in: sheet) == false
        }
        let invalid = [("duration", "-1"), ("duration", "not a time"), ("trim", "999")]
        for (field, value) in invalid {
            try await enter(initial.currentChange, snapshot: initial, sheet: sheet, driver: driver)
            try await driver.fill("production.technical." + field, value: value, in: sheet, requireFocusExit: true)
            try await invalidSettings(field + " " + value, sheet: sheet, driver: driver)
        }
        try await enter(initial.currentChange, snapshot: initial, sheet: sheet, driver: driver)
        try await driver.picker("production.technical.model", title: "Choose model", expected: "", in: sheet)
        try await invalidSettings("missing model", sheet: sheet, driver: driver)
        try await enter(initial.currentChange, snapshot: initial, sheet: sheet, driver: driver)
        try await driver.picker("production.technical.mode", title: "Choose mode", expected: "", in: sheet)
        try await invalidSettings("missing mode", sheet: sheet, driver: driver)
        try await enter(desired, snapshot: initial, sheet: sheet, driver: driver)
        try await driver.wait("changed settings may be applied") { driver.state("production.technical.apply", in: sheet) == true }
        _ = try capture("technical-cancel-dirty", target: sheet, driver: driver)
        try await driver.click("production.technical.cancel", in: sheet)
        try await driver.wait("native technical cancel") { window.attachedSheet == nil && window.isKeyWindow }
        let cancelled = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shot.id, editor: editor)
        guard cancelled.fingerprint == initial.fingerprint, cancelled.proposal == initial.proposal else {
            throw failed("Cancel changed the current Shot List or its source closure.")
        }
        let afterCancel = try await export(cancelled, label: "cancelled", root: root, driver: driver)
        sheet = try await open(shot.id, driver: driver)
        try await driver.wait("reopened production settings") { driver.text("production.technical.model", in: sheet) == initial.currentChange.candidateID }
        try await enter(desired, snapshot: initial, sheet: sheet, driver: driver)
        try await driver.wait("native technical Apply enabled") { driver.state("production.technical.apply", in: sheet) == true }
        try driver.visible(["production.technical.apply", "production.technical.cancel"], in: sheet)
        _ = try capture("technical-before-apply", target: sheet, driver: driver)
        try await driver.click("production.technical.apply", in: sheet)
        try await driver.wait("native technical publication", seconds: 30) { window.attachedSheet == nil && window.isKeyWindow }
        let applied = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shot.id, editor: editor)
        guard let originalShot = initial.proposal.shots.first(where: { $0.execution.id == shot.id }),
              let appliedShot = applied.proposal.shots.first(where: { $0.execution.id == shot.id }),
              applied.currentChange == desired,
              applied.projection.header.revision > initial.projection.header.revision,
              applied.draft == initial.draft, applied.timing == initial.timing,
              applied.proposal.shots.filter({ $0.execution.id != shot.id }) == initial.proposal.shots.filter({ $0.execution.id != shot.id }),
              applied.proposal.musicvideoPlan == initial.proposal.musicvideoPlan,
              appliedShot.referenceDemands.map(\.assetID) == originalShot.referenceDemands.map(\.assetID),
              editor.projectState?.nextPhaseName == "shotlist" else { throw failed("Native technical changes altered editorial timing, another shot or its actual references.") }
        let afterApply = try await export(applied, label: "applied", root: root, driver: driver)
        let undo = try await restore(redo: false, expected: initial.proposal, shotID: shot.id, context: context, driver: driver)
        let afterUndo = try await export(undo, label: "undo", root: root, driver: driver)
        let redo = try await restore(redo: true, expected: applied.proposal, shotID: shot.id, context: context, driver: driver)
        let afterRedo = try await export(redo, label: "redo", root: root, driver: driver)
        let restored = try await restore(redo: false, expected: initial.proposal, shotID: shot.id, context: context, driver: driver)
        let afterRestore = try await export(restored, label: "restored", root: root, driver: driver)
        _ = try capture("technical-original-restored", target: window, driver: driver)
        try driver.record("native technical Shot settings", fields: ["shotID": shot.id,
            "before": before, "cancelled": afterCancel, "applied": afterApply,
            "undo": afterUndo, "redo": afterRedo, "restored": afterRestore,
            "modelChanged": initial.currentChange.candidateID != desired.candidateID,
            "conditioningBefore": initial.currentChange.conditioning.rawValue,
            "conditioningAfter": desired.conditioning.rawValue,
            "actualProvider": "isolated existing Fal catalog; no generation dispatched by technical editing"])
    }

    private static func changedSettings(_ snapshot: PipelineProductionPlanWriter.CandidateSnapshot) throws -> PipelineProductionPlanWriter.TechnicalChange {
        let old = snapshot.currentChange, ticks = snapshot.projection.timebase.ticksPerSecond
        guard let duration = old.nativeDurationTicks, let mode = old.modeID, duration <= Int64.max - ticks,
              old.sourceInTicks <= Int64.max - ticks,
              let original = snapshot.candidates.first(where: { $0.id == old.candidateID }) else { throw failed("The current executable video settings are unavailable.") }
        let conditioning: PipelineProductionPlanWriter.Conditioning = old.conditioning == .startEnd ? .start : old.conditioning
        let candidates = snapshot.candidates.filter { $0.id != original.id } + [original]
        for candidate in candidates where candidate.modeIDs.contains(mode) {
            for resolution in candidate.resolutions where resolution != old.resolution {
                for seconds in [1, 2] {
                    let addition = ticks.multipliedReportingOverflow(by: Int64(seconds))
                    let end = duration.addingReportingOverflow(addition.partialValue)
                    guard !addition.overflow, !end.overflow else { continue }
                    let change = PipelineProductionPlanWriter.TechnicalChange(delivery: old.delivery,
                        candidateID: candidate.id, modeID: mode, conditioning: conditioning,
                        nativeDurationTicks: end.partialValue, sourceInTicks: old.sourceInTicks + ticks, resolution: resolution, endFrameBoundary: old.endFrameBoundary)
                    if PipelineProductionPlanWriter.evaluateNative(change, snapshot: snapshot).canApply { return change }
                }
            }
        }
        throw failed("The actual catalog has no valid alternate duration, output range and resolution for this fixture; no capabilities may be invented.")
    }

    private static func open(_ shotID: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.click("production.plan.edit." + shotID, in: driver.window)
        return try await driver.sheet("production.technical.delivery")
    }

    private static func enter(_ change: PipelineProductionPlanWriter.TechnicalChange,
                              snapshot: PipelineProductionPlanWriter.CandidateSnapshot,
                              sheet: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let model = snapshot.candidates.first(where: { $0.id == change.candidateID }),
              let mode = change.modeID, let duration = change.nativeDurationTicks else { throw failed("Expected native technical fields are incomplete.") }
        try await driver.picker("production.technical.model", title: model.displayName + " · " + model.offering.providerID,
            expected: model.id, in: sheet)
        try await driver.picker("production.technical.mode", title: mode.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized,
            expected: mode, in: sheet)
        let titles: [PipelineProductionPlanWriter.Conditioning: String] = [.none: "Text and references", .start: "Start frame", .end: "End frame", .startEnd: "Start and end frames"]
        guard let title = titles[change.conditioning] else { throw failed("This native test requires an independent generated shot.") }
        try await driver.picker("production.technical.conditioning", title: title, expected: change.conditioning.rawValue, in: sheet)
        try await driver.picker("production.technical.resolution", title: change.resolution ?? "Provider default", expected: change.resolution ?? "", in: sheet)
        try await driver.fill("production.technical.duration", value: ProductionTimeEntry.seconds(duration, timebase: snapshot.projection.timebase), in: sheet, requireFocusExit: true)
        try await driver.fill("production.technical.trim", value: ProductionTimeEntry.seconds(change.sourceInTicks, timebase: snapshot.projection.timebase), in: sheet, requireFocusExit: true)
    }

    private static func invalidSettings(_ label: String, sheet: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("native invalid settings " + label) {
            driver.state("production.technical.apply", in: sheet) == false && driver.text("production.technical.validation", in: sheet)?.isEmpty == false
        }
        try await driver.reveal("production.technical.validation", in: sheet)
        try driver.visible(["production.technical.validation", "production.technical.apply", "production.technical.cancel"], in: sheet)
        let image = try capture("technical-invalid-" + label.replacingOccurrences(of: " ", with: "-"), target: sheet, driver: driver)
        try driver.record("native technical refusal", fields: ["input": label,
            "message": driver.text("production.technical.validation", in: sheet) ?? "", "applyEnabled": driver.state("production.technical.apply", in: sheet) == true, "screenshot": image])
    }

    private static func restore(redo: Bool, expected: PipelineProductionPlanWriter.Proposal, shotID: String,
                                context: ProductionPlanningAcceptanceFixture.Context, driver: ProductionVisualSourcesDriver) async throws -> PipelineProductionPlanWriter.CandidateSnapshot {
        let editor = context.editor, before = editor.engineStateRevision
        try await driver.click("pipeline.overview.select.shotlist", in: driver.window, enabled: false)
        if driver.window.firstResponder is NSTextView { try driver.pressKey(48, characters: "\t", in: driver.window) }
        guard !(driver.window.firstResponder is NSTextView),
              (redo ? editor.undoManager?.redoActionName : editor.undoManager?.undoActionName) == "Edit Shot List" else {
            throw failed("Technical Undo does not target the actual document revision.")
        }
        try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: driver.window)
        try await driver.wait("actual technical history restore", seconds: 30) { editor.engineStateRevision > before }
        _ = try await PipelineProductionPlanWriter.waitForPendingNativeRestore(editor: editor)
        let restored = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shotID, editor: editor)
        guard restored.proposal == expected else { throw failed("Technical Undo/Redo restored different source, timing or route settings.") }
        return restored
    }

    private static func export(_ snapshot: PipelineProductionPlanWriter.CandidateSnapshot, label: String,
                               root: URL, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let directory = "technical-" + label, output = driver.output.appendingPathComponent(directory)
        let hashes = try await Task.detached {
            let promotion = try PipelineShotPlanningPromotionStore.requireCurrent(projection: snapshot.projection, dataRoot: root)
            // requireCurrent already validates reference shape and rejects conflicting path hashes.
            var seenPaths = Set<String>()
            let references = promotion.artifactReferences.filter { seenPaths.insert($0.path).inserted }
                .sorted { $0.path < $1.path }
            var files: [String: Data] = [:]
            for reference in references {
                let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                files[reference.path] = try Data(contentsOf: url)
            }
            files[ShotPlanningPromotionV1.currentPath] = try Data(contentsOf: root.appendingPathComponent(ShotPlanningPromotionV1.currentPath))
            files[PipelineLayout.gatesFile] = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
            files["decoded-proposal.json"] = try PlanningWriterIO.json(snapshot.proposal)
            files["decoded-projection.json"] = try PlanningWriterIO.json(snapshot.projection)
            files["actual-candidates.json"] = try PlanningWriterIO.json(snapshot.candidates)
            var result: [String: String] = [:]
            for (path, bytes) in files {
                let destination = output.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination, options: .atomic)
                result[directory + "/" + path] = FileDigest.sha256(of: bytes)
            }
            return result
        }.value
        let evidence: [String: Any] = ["directory": directory, "files": hashes, "fingerprint": snapshot.fingerprint,
            "revision": snapshot.projection.header.revision, "projection": directory + "/" + ProductionPlanProjectionV1.versionPath(snapshot.projection.header.revision),
            "promotion": directory + "/" + ShotPlanningPromotionV1.currentPath,
            "proposal": directory + "/decoded-proposal.json", "decodedProjection": directory + "/decoded-projection.json"]
        try driver.record("native technical snapshot", fields: ["label": label, "snapshot": evidence])
        return evidence
    }

    private static func capture(_ label: String, target: NSWindow, driver: ProductionVisualSourcesDriver) throws -> [String: String] {
        try driver.capture(label, target: target)
        guard let path = driver.screenshots.last else { throw failed("The actual technical screenshot is missing.") }
        let image = ["path": path, "sha256": try FileDigest.sha256(of: driver.output.appendingPathComponent(path))]
        try driver.record("native technical capture", fields: ["label": label, "screenshot": image])
        return image
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native technical settings: " + message) }
}
