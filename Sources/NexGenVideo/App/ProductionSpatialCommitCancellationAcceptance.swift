import AppKit
import Foundation
import NexGenEngine

@MainActor
enum ProductionSpatialCommitCancellationAcceptance {
    @MainActor private final class Observer {
        weak var session: SpatialSceneSession?
        var armed = false
        var called = false
        var couldCancel: Bool?
        var taskCancelled: Bool?
        func progress(_ progress: SpatialSceneCommitProgress) {
            guard armed, progress == .committed, let session else { return }
            called = true
            couldCancel = session.canCancel
            session.cancel()
            taskCancelled = Task.isCancelled
        }
    }

    static func run(context: ProductionPlanningAcceptanceFixture.Context, output: URL) async throws -> [String: String] {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let key = context.editor.openWorkingCopyKey else { throw SpatialSceneError.changed }
        let operation = try BpyRuntimeHost.shared.acquireOperation(document: context.document, documentID: key)
        defer { BpyRuntimeHost.shared.releaseOperation(operation) }
        let authority = try PipelineSpatialSceneAuthority(editor: context.editor, runtime: operation.session)
        let observer = Observer()
        let session = SpatialSceneSession(pipelineRoot: context.dataRoot, runtime: operation.session,
            authority: authority, commitObserver: observer.progress)
        observer.session = session
        await session.create(name: "Commit cancellation control")
        guard session.error == nil, let prior = session.current else { throw SpatialSceneError.changed }
        observer.armed = true
        await session.addPrimitive("cube")
        let index = try SpatialSceneStore.index(in: context.dataRoot)
        guard observer.called, observer.couldCancel == false, observer.taskCancelled == false,
              session.error == nil, session.canUndo, let current = session.current,
              current.manifest.revision != prior.manifest.revision,
              let head = index.scenes.first(where: { $0.id == prior.manifest.sceneID }),
              head.revision == current.manifest.revision, current.snapshot.objects.count == 1 else {
            throw GateBlocked("Cancel after the location commit lost the saved revision or its Undo step.")
        }
        let root = context.dataRoot, payload = current.scenePayload
        let readback = try await Task.detached {
            let loaded = try SpatialSceneStore.load(head, in: root)
            let verified = try payload.verify(checking: {})
            guard verified == loaded.manifest.sceneSHA256 else { throw SpatialSceneError.changed }
            return loaded.manifest.sceneSHA256
        }.value
        let record: [String: Any] = ["schema": "nexgenvideo/spatial-commit-cancellation/1",
            "sceneID": head.id.uuidString, "priorRevision": prior.manifest.revision.uuidString,
            "committedRevision": head.revision.uuidString, "currentRevision": current.manifest.revision.uuidString,
            "cancelAfterCommitObserved": observer.called, "cancelEnabledAtCommit": observer.couldCancel ?? true,
            "taskCancelledAfterLateCancel": observer.taskCancelled ?? true, "canUndo": session.canUndo,
            "error": session.error ?? "", "objects": current.snapshot.objects.count,
            "committedSceneSHA256": current.manifest.sceneSHA256, "readbackSceneSHA256": readback,
            "payloadVerified": readback == current.manifest.sceneSHA256]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), name = "production-spatial-commit-cancel.json"
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
        return ["file": name, "sha256": FileDigest.sha256(of: data)]
    }
}
