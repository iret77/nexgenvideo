import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionBlockoutRecoveryAcceptance {
    static func run(context: ProductionPlanningAcceptanceFixture.Context, shotID: String,
                    scale: Double, driver: ProductionVisualSourcesDriver, output: URL) async throws {
        let root = context.dataRoot, window = driver.window
        let directory = output.appendingPathComponent("blockout-recovery-\(Int(scale * 100))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = try await canonical(root)
        let before = initial.draft
        var snapshots: [String: [String: String]] = [:]
        func save(_ value: Canonical, as name: String) throws {
            try value.bytes.write(to: directory.appendingPathComponent(name + ".json"))
            try value.versionBytes.write(to: directory.appendingPathComponent(name + ".version.json"))
            snapshots[name] = ["sha256": value.sha256, "currentPath": ShotPlanningDraftV1.currentPath,
                "versionPath": ShotPlanningDraftV1.versionPath(value.draft.header.revision)]
        }
        guard let shot = before.shots.first(where: { $0.shotID == shotID }),
              let ref = shot.camera.blockingReference else { throw failed("The actual selected plan is missing.") }
        let bytes = try await Task.detached { try Data(contentsOf: ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: root)) }.value
        try bytes.write(to: directory.appendingPathComponent("original-receipt.json"))
        try save(initial, as: "before")
        var prior = initial
        for damage in ["missing", "tampered"] {
            guard try await canonical(root).bytes == prior.bytes else { throw failed("The recovery source changed before damage.") }
            let receiptURL = root.appendingPathComponent(ref.path)
            var restored = false
            defer { if !restored { try? bytes.write(to: receiptURL, options: .atomic) } }
            if damage == "missing" { try FileManager.default.moveItem(at: receiptURL, to: directory.appendingPathComponent("missing.quarantine")) }
            else { try Data("negative blockout receipt mutation".utf8).write(to: receiptURL, options: .atomic) }
            let damagedHash: Any
            if damage == "missing" { damagedHash = NSNull() }
            else {
                let damaged = try Data(contentsOf: receiptURL)
                damagedHash = FileDigest.sha256(of: damaged)
                try damaged.write(to: directory.appendingPathComponent("tampered-receipt.bin"))
            }
            try JSONSerialization.data(withJSONObject: ["path": ref.path, "expectedSHA256": ref.sha256,
                "actualSHA256": damagedHash, "state": damage, "shotID": shotID,
                "snapshotSHA256": prior.sha256], options: [.sortedKeys])
                .write(to: directory.appendingPathComponent(damage + "-damage.json"))
            await context.editor.refreshEngineState()
            try await driver.wait("native blockout recovery visible") {
                driver.state("shot-planning.blockout.recover", in: window) == true
                    && driver.text("shot-planning.blockout.recovery", in: window) != nil
            }
            let snapshot = try await Task.detached { try PipelineBlockoutRemovalSnapshot.load(dataRoot: root) }.value
            let damagedSnapshot = try await canonical(root, validateSources: false)
            guard damagedSnapshot.bytes == prior.bytes, snapshot.sha256 == prior.sha256 else { throw failed("Damage changed canonical Shot Planning.") }
            try save(damagedSnapshot, as: damage + "-snapshot")
            var staleError: String?
            do {
                _ = try await PipelineShotPlanningEditor.removeBlockouts(shotIDs: snapshot.shotIDs, in: snapshot.draft,
                    editor: context.editor, expectedSHA256: String(repeating: "0", count: 64))
            } catch is CancellationError { throw CancellationError() }
            catch let error as GateBlocked where error.message == "The blockout assignments changed. Reload Shot Planning before removing them." { staleError = error.message }
            guard staleError != nil, let home = context.editor.workingRoot, DataRootResolver.dataRoot(of: home) == root,
                  context.editor.openWorkingCopyKey != nil, !context.editor.agentService.isStreaming,
                  !context.editor.agentService.isComposerBlocked,
                  let lease = context.editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Negative blockout recovery lease") else {
                throw failed("A stale recovery snapshot was accepted or the negative lease could not be held.")
            }
            var leaseError: String?
            do {
                defer { context.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
                guard context.editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else {
                    throw failed("The competing native mutation lease was not held.")
                }
                _ = try await PipelineShotPlanningEditor.removeBlockouts(shotIDs: snapshot.shotIDs, in: snapshot.draft,
                    editor: context.editor, expectedSHA256: snapshot.sha256)
            } catch let error as GateBlocked where error.message == "Finish the current production action before changing this plan." { leaseError = error.message }
            let afterSHA = try FileDigest.sha256(of: ProjectLocalFile.resolve(ShotPlanningDraftV1.currentPath, dataRoot: root))
            guard leaseError != nil, snapshot.sha256 == afterSHA else {
                throw failed("A stale or concurrent recovery changed canonical Shot Planning.")
            }
            try JSONSerialization.data(withJSONObject: ["beforeSHA256": snapshot.sha256, "afterSHA256": afterSHA,
                "staleError": staleError ?? "", "leaseError": leaseError ?? ""], options: [.sortedKeys])
                .write(to: directory.appendingPathComponent(damage + "-refusals.json"))
            try await driver.reveal("shot-planning.blockout.recover", in: window)
            try driver.record("blockout recovery begin " + damage, fields: ["state": damage,
                "snapshotSHA256": snapshot.sha256, "receiptSHA256": ref.sha256])
            try driver.capture("blockout-recovery-" + damage, target: window)
            try await driver.click("shot-planning.blockout.recover", in: window)
            try await driver.wait("explicit blockout removal confirmation") {
                NSApp.windows.contains { $0.isVisible && $0.isKeyWindow
                    && AppNativeMenuAcceptance.buttons(in: $0).contains { $0.title == "Remove all assignments" && $0.enabled } }
            }
            guard let alert = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow
                && AppNativeMenuAcceptance.buttons(in: $0).contains { $0.title == "Remove all assignments" && $0.enabled } }) else { throw failed("The explicit removal dialog disappeared.") }
            try driver.capture("blockout-confirm-" + damage, target: alert)
            try AppNativeMenuAcceptance.accessibilityClick("Remove all assignments", in: alert, driver: driver)
            try await driver.wait("native removal published") {
                driver.state("shot-planning.blockout.recover", in: window) == nil
                    && WorkspaceUIAcceptance.probeFrame(identifier: "shot-planning.blockout.open." + shotID, in: window) != nil
            }
            let removed = try await canonical(root)
            let desired = try PipelineShotPlanningEditor.removingBlockouts(shotIDs: snapshot.shotIDs, from: prior.draft)
            guard removed.draft.shots == desired, removed.draft.header.revision == prior.draft.header.revision + 1,
                  removed.draft.storyboardRevision == prior.draft.storyboardRevision else { throw failed("Recovery did not remove exactly the displayed assignments.") }
            try save(removed, as: damage + "-removed")
            try bytes.write(to: receiptURL, options: .atomic); restored = true
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            let expectedUndo = try PlanningWriterIO.json(ShotPlanningDraftV1(header: .init(projectID: prior.draft.header.projectID,
                revision: removed.draft.header.revision + 1, origin: .userRevision, inputs: prior.draft.header.inputs),
                storyboardRevision: prior.draft.storyboardRevision, shots: prior.draft.shots))
            try await driver.wait("native Undo restored exact canonical bytes") {
                (try? Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningDraftV1.currentPath, dataRoot: root))) == expectedUndo
            }
            let undone = try await canonical(root)
            guard undone.bytes == expectedUndo else { throw failed("Native Undo did not publish the exact restored state in its next revision.") }
            try save(undone, as: damage + "-undo")
            try driver.record("blockout recovery complete " + damage, fields: ["state": damage,
                "snapshotSHA256": snapshot.sha256, "removedSHA256": removed.sha256, "undoSHA256": undone.sha256])
            prior = undone
        }
        try await open(shotID, driver: driver)
        let sheet = try await driver.sheet("shot.blockout.sheet")
        try await driver.wait("native single remove available") { driver.state("shot.blockout.remove", in: sheet) == true }
        try await driver.click("shot.blockout.remove", in: sheet)
        try await driver.wait("single removal closed") { window.attachedSheet == nil }
        let cleared = try await canonical(root)
        let expectedSingle = try PipelineShotPlanningEditor.removingBlockouts(shotIDs: [shotID], from: prior.draft)
        guard cleared.draft.shots == expectedSingle, cleared.draft.header.revision == prior.draft.header.revision + 1,
              cleared.draft.storyboardRevision == prior.draft.storyboardRevision else { throw failed("The native single removal changed another shot or state.") }
        try save(cleared, as: "cleared")
        try await open(shotID, driver: driver)
        let reattach = try await driver.sheet("shot.blockout.sheet")
        try await driver.wait("native plan can be reattached") { driver.state("shot.blockout.plan", in: reattach) == true }
        try await driver.click("shot.blockout.plan", in: reattach)
        try await driver.wait("real plan reattached", seconds: 120) { window.attachedSheet == nil }
        let after = try await canonical(root)
        guard let selected = after.draft.shots.first(where: { $0.shotID == shotID }), let replacement = selected.camera.blockingReference,
              replacement != ref, selected.camera.spatialState == shot.camera.spatialState else { throw failed("Reattachment did not preserve the confirmed state with a fresh actual receipt.") }
        guard try PipelineShotPlanningEditor.removingBlockouts(shotIDs: [shotID], from: after.draft) == cleared.draft.shots,
              after.draft.header.revision == cleared.draft.header.revision + 1,
              after.draft.storyboardRevision == cleared.draft.storyboardRevision else {
            throw failed("Reattachment changed another shot, pose, or revision.")
        }
        let outputEvidence = try await Task.detached { () async throws -> (String, String, Int64, Int32) in
            let references = try PipelineNativeBlockoutStore.references(replacement, shot: selected, dataRoot: root)
            let value = try PipelineNativeBlockoutStore.read(replacement, dataRoot: root)
            guard value.kind == .planElevation, value.original == nil, value.output.role == "host.plan-elevation-video" else {
                throw failed("Reattachment did not create an actual native plan.")
            }
            let media = "reattached.mov", closure = directory.appendingPathComponent(media + ".evidence")
            for reference in references {
                let target = closure.appendingPathComponent(reference.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try PipelineGeometryVideoExport.copyVerified(source: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root),
                        to: target, expectedSHA256: reference.sha256)
                }
                guard try FileDigest.sha256(of: target) == reference.sha256 else { throw failed("The reattachment evidence copy changed.") }
            }
            let source = try ProjectLocalFile.requireHash(value.output.sha256, at: value.output.path, dataRoot: root)
            let duration = try await AVURLAsset(url: source).load(.duration)
            guard duration.isNumeric, duration.value > 0 else { throw failed("The actual reattachment MOV has no duration.") }
            _ = try await AVAssetImageGenerator(asset: AVURLAsset(url: source)).image(at: .zero)
            try PipelineGeometryVideoExport.copyVerified(source: source, to: directory.appendingPathComponent(media), expectedSHA256: value.output.sha256)
            let receipt = try Data(contentsOf: ProjectLocalFile.requireHash(replacement.sha256, at: replacement.path, dataRoot: root))
            guard FileDigest.sha256(of: receipt) == replacement.sha256 else { throw failed("The reattachment receipt changed while reading it.") }
            try receipt.write(to: directory.appendingPathComponent("reattached-receipt.json"))
            return (media, value.output.sha256, duration.value, duration.timescale)
        }.value
        try save(after, as: "reattached")
        try driver.record("native blockout recovery", fields: ["directory": directory.lastPathComponent,
            "shotID": shotID, "receiptSHA256": ref.sha256, "reattachedSHA256": replacement.sha256,
            "canonicalSnapshots": snapshots, "reattachedOutput": ["media": outputEvidence.0, "outputSHA256": outputEvidence.1,
                "durationValue": outputEvidence.2, "durationTimescale": outputEvidence.3],
            "missingReceiptRecovery": true, "tamperedReceiptRecovery": true, "explicitConfirmation": true,
            "nativeSingleRemoval": true, "nativeReattachment": true, "nativeUndoAfterFileRestore": true,
            "staleSnapshotRejected": true, "competingLeaseRejected": true])
    }

    private static func open(_ shotID: String, driver: ProductionVisualSourcesDriver) async throws {
        if WorkspaceUIAcceptance.probeFrame(identifier: "shot-planning.reload." + shotID, in: driver.window) != nil {
            try await driver.click("shot-planning.reload." + shotID, in: driver.window)
        }
        try await driver.click("shot-planning.blockout.open." + shotID, in: driver.window)
    }

    private struct Canonical: Sendable {
        let draft: ShotPlanningDraftV1
        let bytes: Data
        let versionBytes: Data
        var sha256: String { FileDigest.sha256(of: bytes) }
    }

    private static func canonical(_ root: URL, validateSources: Bool = true) async throws -> Canonical {
        try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningDraftV1.currentPath, dataRoot: root))
            let draft = try JSONDecoder().decode(ShotPlanningDraftV1.self, from: bytes)
            if validateSources {
                guard draft == (try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: PlanningWriterIO.storyboard(dataRoot: root))) else {
                    throw failed("Canonical Shot Planning changed during validation.")
                }
            }
            let version = try Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningDraftV1.versionPath(draft.header.revision), dataRoot: root))
            guard bytes == version,
                  bytes == (try Data(contentsOf: ProjectLocalFile.resolve(ShotPlanningDraftV1.currentPath, dataRoot: root))) else {
                throw failed("Current and versioned Shot Planning bytes differ.")
            }
            return Canonical(draft: draft, bytes: bytes, versionBytes: version)
        }.value
    }

    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native blockout recovery: " + message) }
}
