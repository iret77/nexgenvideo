import AppKit
import NexGenEngine
import SwiftUI

@MainActor
enum ProductionSpatialHistoryAcceptance {
    @MainActor private final class HistoryRejectionObserver {
        weak var session: SpatialSceneSession?
        var armed = false
        var rejected: SpatialSceneHistoryIntent?

        func progress(_ progress: SpatialSceneCommitProgress) {
            guard armed, progress == .committed, let session else { return }
            armed = false
            _ = session.requestRedo()
            rejected = session.historyIntent
        }
    }

    @MainActor private final class HistoryAdmissionObserver {
        weak var session: SpatialSceneSession?
        let action: SpatialSceneHistoryIntent.Action
        let oldID: UUID?
        let sourceRevision: UUID
        let priorRevision: UUID
        let createdUptime = ProcessInfo.processInfo.systemUptime
        private(set) var admitted: SpatialSceneHistoryIntent?
        private(set) var rejected: SpatialSceneHistoryIntent?
        private(set) var attemptedAt: TimeInterval?
        private(set) var busyBeforeReload = false
        private(set) var busyAfterReload = false
        private(set) var errorAfterRejection: String?
        private(set) var callbacks = 0
        private(set) var failure: String?

        init(session: SpatialSceneSession, action: SpatialSceneHistoryIntent.Action,
             sourceRevision: UUID, priorRevision: UUID) {
            self.session = session
            self.action = action
            oldID = session.historyIntent?.id
            self.sourceRevision = sourceRevision
            self.priorRevision = priorRevision
        }

        func observe(_ intent: SpatialSceneHistoryIntent) {
            guard let session else { return }
            callbacks += 1
            admitted = intent
            guard intent.id != oldID, intent.action == action, intent.origin == .userInterface,
                  intent.status == .admitted, !intent.busyAtRequest,
                  intent.sourceRevision == sourceRevision, intent.priorRevision == priorRevision,
                  session.busy else {
                failure = "The actual UI callback admitted an unexpected history request."
                return
            }
            attemptedAt = ProcessInfo.processInfo.systemUptime
            busyBeforeReload = session.busy
            session.reload()
            busyAfterReload = session.busy
            if action == .undo { _ = session.requestRedo() } else { _ = session.requestUndo() }
            rejected = session.historyIntent
            errorAfterRejection = session.error
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
        let observer = HistoryRejectionObserver()
        let session = SpatialSceneSession(pipelineRoot: context.dataRoot, runtime: operation.session,
            authority: authority, commitObserver: observer.progress)
        observer.session = session
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SpatialSceneView(session: session))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "spatial-history-admission")
        do {
            try await driver.wait("real history control ready", seconds: 90) {
                !session.busy && session.canUndo && driver.state("spatial.undo", in: window) == true
            }
            let beforeReload = try await read(session: session, root: context.dataRoot)
            session.reload()
            guard session.busy, session.requestUndo() == nil,
                  session.historyIntent?.status == .rejectedBusy, session.error == nil else { throw SpatialSceneError.changed }
            let busyRejection = session.historyIntent
            try await driver.wait("history retry notice after real reload", seconds: 90) {
                !session.busy && session.canUndo && driver.state("spatial.undo", in: window) == true
                    && driver.text("spatial.history.notice", in: window) == "Undo was not applied. Try again."
            }
            let afterReload = try await read(session: session, root: context.dataRoot)
            guard afterReload.0.manifestData == beforeReload.0.manifestData, afterReload.1 == beforeReload.1,
                  session.historyIntent?.id == busyRejection?.id, session.error == nil else {
                throw failed("The rejected history request or same-head reload changed canonical history.")
            }
            try driver.record("busy history reload rejection", fields: ["rejected": try receipt(busyRejection),
                "notice": driver.text("spatial.history.notice", in: window) as Any? ?? NSNull(),
                "canonicalRevision": afterReload.0.manifest.revision.uuidString, "revisionCount": afterReload.1])
            try driver.capture("history-retry-notice", target: window)
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
            let awaitedRedo = try await restored(session: session, expected: redone, previous: awaitedUndo,
                beforeCount: beforeCancel.1 + 1, root: context.dataRoot)
            guard session.historyIntent?.origin == .awaitedCall, session.historyIntent?.status == .committed,
                  session.canUndo, !session.canRedo, !session.historyTrace.overflow else { throw SpatialSceneError.changed }
            await session.undo()
            let beforeEdit = try await restored(session: session, expected: awaitedUndo, previous: awaitedRedo,
                beforeCount: beforeCancel.1 + 2, root: context.dataRoot)
            guard session.canRedo else { throw SpatialSceneError.changed }
            observer.armed = true
            await session.addPrimitive("sphere")
            let afterEdit = try await read(session: session, root: context.dataRoot)
            guard !observer.armed, let rejected = observer.rejected, rejected.action == .redo,
                  rejected.status == .rejectedBusy, rejected.busyAtRequest,
                  rejected.sourceRevision == beforeEdit.manifest.revision,
                  session.historyIntent?.id == rejected.id, session.error == nil,
                  !session.canRedo, session.canUndo, afterEdit.1 == beforeCancel.1 + 4,
                  afterEdit.0.manifest.parentRevision == beforeEdit.manifest.revision,
                  afterEdit.0.manifest.restoredFromRevision == nil, afterEdit.0.snapshot.objects.count == 2,
                  afterEdit.0.snapshot.objects.first(where: { $0.id == cube.id })?.matrixWorld == cube.matrixWorld else {
                throw failed("A new scene edit did not invalidate the previous Redo without replaying it.")
            }
            try await driver.wait("unavailable history notice after actual edit") {
                driver.state("spatial.redo", in: window) == false
                    && driver.text("spatial.history.notice", in: window) == "Redo is no longer available."
            }
            try driver.record("busy Redo rejected before actual edit invalidates Redo", fields: [
                "rejected": try receipt(rejected), "canonicalRevision": afterEdit.0.manifest.revision.uuidString,
                "notice": driver.text("spatial.history.notice", in: window) as Any? ?? NSNull(), "canRedo": session.canRedo])
            try driver.capture("history-no-redo-after-edit", target: window)
            try driver.record("history admission regression complete", fields: [
                "schema": "nexgenvideo/spatial-history-admission/1", "sceneID": edited.manifest.sceneID.uuidString,
                "priorRevision": prior.manifest.revision.uuidString, "editedRevision": edited.manifest.revision.uuidString,
                "undoRevision": undone.manifest.revision.uuidString, "redoRevision": redone.manifest.revision.uuidString,
                "emptyRejected": true, "busyReloadRejectedWithRetryNotice": true,
                "invalidatedRedoRejectedWithoutRetryInstruction": true,
                "cancelledBeforeWork": true, "awaitedCompletionVerified": true,
                "historyTrace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.historyTrace))])
            return driver.result()
        } catch {
            try? session.observeHistoryAdmissionForAcceptance(nil)
            driver.failure(error)
            window.contentView = nil
            window.close()
            await session.cancelAndWait()
            do {
                let record: [String: Any] = ["schema": "nexgenvideo/spatial-history-failure/1",
                    "error": error.localizedDescription, "busyAfterCleanup": session.busy,
                    "historyIntent": try receipt(session.historyIntent),
                    "historyTrace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.historyTrace))]
                try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    .write(to: output.appendingPathComponent("spatial-history-failure.json"), options: .atomic)
            } catch { FileHandle.standardError.write(Data(("HISTORY_TRACE_EVIDENCE_FAIL " + error.localizedDescription + "\n").utf8)) }
            throw error
        }
    }

    static func retainProject(context: ProductionPlanningAcceptanceFixture.Context, output: URL,
                              outcome: String, error: (any Error)? = nil,
                              name: String = "spatial-history-project") throws -> [String: String] {
        guard let source = context.editor.workingRoot else { throw SpatialSceneError.changed }
        let package = name + ".ngv", target = output.appendingPathComponent(package, isDirectory: true)
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
        let record: [String: Any] = ["schema": "nexgenvideo/spatial-history-project/1", "project": package,
            "outcome": outcome, "error": error?.localizedDescription as Any? ?? NSNull(),
            "files": closure.sorted { ($0["path"] as! String) < ($1["path"] as! String) }]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let manifest = name + "-files.json"
        try data.write(to: output.appendingPathComponent(manifest), options: .atomic)
        return ["project": package, "manifest": manifest, "sha256": FileDigest.sha256(of: data)]
    }

    private static func clickHistory(undo: Bool, session: SpatialSceneSession, window: NSWindow,
                                     driver: ProductionVisualSourcesDriver, expected: SpatialSceneRevision,
                                     previous: SpatialSceneRevision, root: URL) async throws -> SpatialSceneRevision {
        let before = try await read(session: session, root: root)
        let action: SpatialSceneHistoryIntent.Action = undo ? .undo : .redo
        let oldID = session.historyIntent?.id
        let observer = HistoryAdmissionObserver(session: session, action: action,
            sourceRevision: previous.manifest.revision, priorRevision: expected.manifest.revision)
        try session.observeHistoryAdmissionForAcceptance(observer.observe)
        defer { try? session.observeHistoryAdmissionForAcceptance(nil) }
        do {
            try await driver.clickButton(undo ? "spatial.undo" : "spatial.redo", title: undo ? "Undo" : "Redo", in: window)
            try await driver.wait("real history callback and restoration", seconds: 90) {
                observer.callbacks == 1 && !session.busy
            }
        } catch {
            let failure = error
            do { try driver.record("actual history callback failure", fields: admissionReceipt(observer, session: session)) }
            catch { FileHandle.standardError.write(Data(("HISTORY_ADMISSION_EVIDENCE_FAIL " + error.localizedDescription + "\n").utf8)) }
            throw failure
        }
        try driver.record("actual history callback reload order", fields: admissionReceipt(observer, session: session))
        guard observer.callbacks == 1, observer.failure == nil,
              let admitted = observer.admitted, admitted.id != oldID, admitted.action == action, admitted.origin == .userInterface,
              admitted.status == .admitted, !admitted.busyAtRequest,
              admitted.sourceRevision == previous.manifest.revision,
              admitted.priorRevision == expected.manifest.revision,
              admitted.observedUptime >= observer.createdUptime,
              let attemptedAt = observer.attemptedAt, admitted.observedUptime <= attemptedAt,
              observer.busyBeforeReload, observer.busyAfterReload,
              observer.rejected?.status == .rejectedBusy, observer.rejected?.busyAtRequest == true,
              observer.errorAfterRejection == nil,
              session.historyIntent?.id == admitted.id, session.historyIntent?.status == .committed,
              !session.historyTrace.overflow else {
            throw failed("The genuine ready history callback did not claim its restoration before the reload attempt.")
        }
        let events = session.historyTrace.events.filter { $0.id == admitted.id }
        guard events.map(\.status) == [.admitted, .committed],
              events.allSatisfy({ $0.action == action && $0.sourceRevision == previous.manifest.revision
                  && $0.priorRevision == expected.manifest.revision }),
              events[0].observedUptime <= events[1].observedUptime else {
            throw failed("The actual history intent trace lost or duplicated its admitted restoration.")
        }
        let result = try await restored(session: session, expected: expected, previous: previous,
            beforeCount: before.1, root: root)
        guard session.canUndo, session.canRedo == undo else { throw SpatialSceneError.changed }
        try driver.capture(action.rawValue + "-restored", target: window)
        return result
    }

    private static func admissionReceipt(_ observer: HistoryAdmissionObserver, session: SpatialSceneSession) throws -> [String: Any] {
        ["action": observer.action.rawValue, "expectedSourceRevision": observer.sourceRevision.uuidString,
            "expectedPriorRevision": observer.priorRevision.uuidString,
            "observerCreatedUptime": observer.createdUptime,
            "reloadAttemptUptime": observer.attemptedAt as Any? ?? NSNull(),
            "admissionCallbacks": observer.callbacks, "admissionFailure": observer.failure as Any? ?? NSNull(),
            "busyBeforeReload": observer.busyBeforeReload, "busyAfterReload": observer.busyAfterReload,
            "errorAfterRejection": observer.errorAfterRejection as Any? ?? NSNull(),
            "admitted": try receipt(observer.admitted), "concurrentRejection": try receipt(observer.rejected),
            "completed": try receipt(session.historyIntent)]
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
