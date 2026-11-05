import AppKit
import NexGenEngine
import SwiftUI

@MainActor
enum ProductionSpatialHistoryAcceptance {
    private final class HistoryWindow: NSWindow {
        var afterMouseUp: (() -> Void)?

        override func sendEvent(_ event: NSEvent) {
            super.sendEvent(event)
            if event.type == .leftMouseUp, let action = afterMouseUp {
                afterMouseUp = nil
                action()
            }
        }
    }

    static func run(context: ProductionPlanningAcceptanceFixture.Context, output: URL) async throws -> [String: Any] {
        do {
            let result = try await exercise(context: context, output: output)
            let project = try retainProject(context: context, output: output, outcome: "completed")
            return result.merging(["canonicalProject": project]) { _, new in new }
        } catch {
            do { _ = try retainProject(context: context, output: output, outcome: "failed", error: error) }
            catch { FileHandle.standardError.write(Data(("HISTORY_EVIDENCE_FAIL " + error.localizedDescription + "\n").utf8)) }
            throw error
        }
    }

    private static func exercise(context: ProductionPlanningAcceptanceFixture.Context, output: URL) async throws -> [String: Any] {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let key = context.editor.openWorkingCopyKey else { throw SpatialSceneError.changed }
        let operation = try BpyRuntimeHost.shared.acquireOperation(document: context.document, documentID: key)
        defer { BpyRuntimeHost.shared.releaseOperation(operation) }
        let authority = try PipelineSpatialSceneAuthority(editor: context.editor, runtime: operation.session)
        let session = SpatialSceneSession(pipelineRoot: context.dataRoot, runtime: operation.session, authority: authority)
        await session.create(name: "History admission control")
        guard session.error == nil, let empty = session.current, !session.canUndo,
              session.requestUndo() == nil, session.historyIntent?.status == .rejectedHistory,
              session.current?.manifest.revision == empty.manifest.revision else { throw SpatialSceneError.changed }
        await session.addPrimitive("cube")
        guard session.error == nil, let prior = session.current, let cube = prior.snapshot.objects.first,
              prior.snapshot.objects.count == 1 else { throw SpatialSceneError.changed }
        session.selectedObjectID = cube.id
        await session.transformSelected(position: SIMD3<Double>(0.5, 0, 0), rotation: .zero,
                                        scale: SIMD3<Double>(repeating: 1), keyframe: false)
        guard session.error == nil, let edited = session.current,
              edited.snapshot.objects.first?.matrixWorld != cube.matrixWorld else { throw SpatialSceneError.changed }
        let window = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SpatialSceneView(session: session))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.afterMouseUp = nil; window.contentView = nil; window.close() }
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "spatial-history-admission")
        do {
            try await driver.wait("real history control ready", seconds: 90) {
                !session.busy && session.canUndo && driver.state("spatial.undo", in: window) == true
            }
            let undone = try await clickHistory(undo: true, session: session, window: window, driver: driver,
                expected: prior, previous: edited, root: context.dataRoot)
            let redone = try await clickHistory(undo: false, session: session, window: window, driver: driver,
                expected: edited, previous: undone, root: context.dataRoot)
            let beforeCancel = try await read(session: session, root: context.dataRoot)
            let cancelledID = session.requestUndo()
            session.cancel()
            try await driver.wait("cancelled history releases ownership", seconds: 90) { !session.busy }
            guard let cancelledID, session.historyIntent?.id == cancelledID,
                  session.historyIntent?.status == .failed, session.error == nil,
                  session.canUndo, !session.canRedo else {
                throw failed("Cancellation before restoration changed canonical history.")
            }
            let afterCancel = try await read(session: session, root: context.dataRoot)
            guard afterCancel.0.manifestData == beforeCancel.0.manifestData, afterCancel.1 == beforeCancel.1 else {
                throw failed("Cancellation before restoration changed canonical history.")
            }
            await session.undo()
            let awaitedUndo = try await restored(session: session, expected: undone, previous: redone,
                beforeCount: beforeCancel.1, root: context.dataRoot)
            guard session.historyIntent?.origin == .awaitedCall, session.historyIntent?.status == .committed else {
                throw failed("The awaited Undo returned before its actual restoration completed.")
            }
            await session.redo()
            _ = try await restored(session: session, expected: redone, previous: awaitedUndo,
                beforeCount: beforeCancel.1 + 1, root: context.dataRoot)
            guard session.historyIntent?.origin == .awaitedCall, session.historyIntent?.status == .committed,
                  session.canUndo, !session.canRedo else { throw SpatialSceneError.changed }
            try driver.record("history admission regression complete", fields: [
                "schema": "nexgenvideo/spatial-history-admission/1", "sceneID": edited.manifest.sceneID.uuidString,
                "priorRevision": prior.manifest.revision.uuidString, "editedRevision": edited.manifest.revision.uuidString,
                "undoRevision": undone.manifest.revision.uuidString, "redoRevision": redone.manifest.revision.uuidString,
                "emptyRejected": true, "cancelledBeforeWork": true, "awaitedCompletionVerified": true])
            return driver.result()
        } catch {
            window.afterMouseUp = nil
            driver.failure(error)
            window.contentView = nil
            window.close()
            await session.cancelAndWait()
            throw error
        }
    }

    private static func retainProject(context: ProductionPlanningAcceptanceFixture.Context, output: URL,
                                      outcome: String, error: (any Error)? = nil) throws -> [String: String] {
        guard let source = context.editor.workingRoot else { throw SpatialSceneError.changed }
        let name = "spatial-history-project.ngv", target = output.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: target)
        guard let files = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw SpatialSceneError.changed
        }
        var closure: [[String: Any]] = []
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SpatialSceneError.changed }
            guard values.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(target.path.count + 1))
            let data = try Data(contentsOf: file)
            closure.append(["path": relative, "bytes": data.count, "sha256": FileDigest.sha256(of: data)])
        }
        guard !closure.isEmpty else { throw SpatialSceneError.changed }
        let record: [String: Any] = ["schema": "nexgenvideo/spatial-history-project/1", "project": name,
            "outcome": outcome, "error": error?.localizedDescription as Any? ?? NSNull(),
            "files": closure.sorted { ($0["path"] as! String) < ($1["path"] as! String) }]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let manifest = "spatial-history-project-files.json"
        try data.write(to: output.appendingPathComponent(manifest), options: .atomic)
        return ["project": name, "manifest": manifest, "sha256": FileDigest.sha256(of: data)]
    }

    private static func clickHistory(undo: Bool, session: SpatialSceneSession, window: HistoryWindow,
                                     driver: ProductionVisualSourcesDriver, expected: SpatialSceneRevision,
                                     previous: SpatialSceneRevision, root: URL) async throws -> SpatialSceneRevision {
        let before = try await read(session: session, root: root)
        let action: SpatialSceneHistoryIntent.Action = undo ? .undo : .redo
        let oldID = session.historyIntent?.id
        var admitted: SpatialSceneHistoryIntent?
        var rejected: SpatialSceneHistoryIntent?
        var attemptedAt: TimeInterval?
        var busyBeforeReload = false
        var busyAfterReload = false
        var errorAfterRejection: String?
        window.afterMouseUp = {
            attemptedAt = ProcessInfo.processInfo.systemUptime
            admitted = session.historyIntent
            busyBeforeReload = session.busy
            session.reload()
            busyAfterReload = session.busy
            if undo { _ = session.requestRedo() } else { _ = session.requestUndo() }
            rejected = session.historyIntent
            errorAfterRejection = session.error
        }
        try await driver.click(undo ? "spatial.undo" : "spatial.redo", in: window)
        try await driver.wait("real history callback and restoration", seconds: 90) {
            attemptedAt != nil && !session.busy
        }
        let record: [String: Any] = ["action": action.rawValue, "reloadAttemptUptime": attemptedAt as Any? ?? NSNull(),
            "busyBeforeReload": busyBeforeReload, "busyAfterReload": busyAfterReload,
            "errorAfterRejection": errorAfterRejection as Any? ?? NSNull(),
            "admitted": try receipt(admitted), "concurrentRejection": try receipt(rejected),
            "completed": try receipt(session.historyIntent)]
        try driver.record("actual history callback reload order", fields: record)
        guard let admitted, admitted.id != oldID, admitted.action == action, admitted.origin == .userInterface,
              admitted.status == .admitted, !admitted.busyAtRequest,
              admitted.sourceRevision == previous.manifest.revision,
              admitted.priorRevision == expected.manifest.revision,
              let attemptedAt, admitted.observedUptime <= attemptedAt, busyBeforeReload, busyAfterReload,
              rejected?.status == .rejectedBusy, rejected?.busyAtRequest == true,
              errorAfterRejection == nil,
              session.historyIntent?.id == admitted.id, session.historyIntent?.status == .committed else {
            throw failed("The genuine ready history callback did not claim its restoration before the reload attempt.")
        }
        let result = try await restored(session: session, expected: expected, previous: previous,
            beforeCount: before.1, root: root)
        guard session.canUndo, session.canRedo == undo else { throw SpatialSceneError.changed }
        try driver.capture(action.rawValue + "-restored", target: window)
        return result
    }

    private static func restored(session: SpatialSceneSession, expected: SpatialSceneRevision,
                                 previous: SpatialSceneRevision, beforeCount: Int, root: URL) async throws -> SpatialSceneRevision {
        let (loaded, count) = try await read(session: session, root: root)
        guard !session.busy, session.error == nil, count == beforeCount + 1,
              loaded.manifest.revision != previous.manifest.revision,
              loaded.manifest.revision != expected.manifest.revision,
              loaded.manifest.parentRevision == previous.manifest.revision,
              loaded.manifest.restoredFromRevision == expected.manifest.revision,
              loaded.snapshotData == expected.snapshotData, loaded.resources == expected.resources,
              loaded.manifest.sceneSHA256 == expected.manifest.sceneSHA256,
              session.current?.manifest.revision == loaded.manifest.revision else {
            throw failed("History did not publish exactly one canonical revision with the original scene bytes.")
        }
        return loaded
    }

    private static func read(session: SpatialSceneSession, root: URL) async throws -> (SpatialSceneRevision, Int) {
        guard let scene = session.current?.manifest.sceneID else { throw SpatialSceneError.changed }
        return try await Task.detached {
            try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root)
            guard let head = try SpatialSceneStore.index(in: root).scenes.first(where: { $0.id == scene }) else {
                throw SpatialSceneError.changed
            }
            let loaded = try SpatialSceneStore.load(head, in: root)
            guard try loaded.scenePayload.verify(checking: {}) == loaded.manifest.sceneSHA256 else {
                throw SpatialSceneError.changed
            }
            let directory = root.appendingPathComponent(SpatialSceneStore.revisionPath(scene: scene, revision: head.revision))
                .deletingLastPathComponent()
            let count = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
            return (loaded, count)
        }.value
    }

    private static func receipt(_ intent: SpatialSceneHistoryIntent?) throws -> Any {
        guard let intent else { return NSNull() }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent))
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("History acceptance: " + message) }
}
