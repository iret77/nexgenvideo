import AppKit
import BpyRuntimeProtocol
import Foundation
import NexGenEngine

@MainActor
enum ProductionSpatialHashCancellationAcceptance {
    private struct Outcome: Sendable {
        let failure: String
        let clock: BpyClockReading?
        let taskCancelled: Bool
    }
    private final class Attempt: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Outcome?
        func finish(_ result: Outcome) { lock.withLock { self.result = result } }
        var outcome: Outcome? { lock.withLock { result } }
    }

    static func run(context: ProductionPlanningAcceptanceFixture.Context, output: URL) async throws -> [String: String] {
        guard let key = context.editor.openWorkingCopyKey else { throw SpatialSceneError.changed }
        let operation = try BpyRuntimeHost.shared.acquireOperation(document: context.document, documentID: key)
        defer { BpyRuntimeHost.shared.releaseOperation(operation) }
        let runtime = operation.session
        let authority = try PipelineSpatialSceneAuthority(editor: context.editor, runtime: runtime)
        let session = SpatialSceneSession(pipelineRoot: context.dataRoot, runtime: runtime, authority: authority)
        var scenes: [SpatialSceneRevision] = []
        for name in ["Hash cancellation A", "Hash cancellation B"] {
            await session.create(name: name)
            guard session.error == nil else { throw SpatialSceneError.changed }
            await session.editPython("padding = bpy.data.texts.new('NGV_HASH_CANCELLATION_PADDING')\npadding.write('x' * (256 * 1024 * 1024))\n")
            guard session.error == nil, let current = session.current, current.scenePayload.byteCount >= 256 * 1_024 * 1_024 else {
                throw GateBlocked("The native cancellation control did not produce a valid large saved scene.")
            }
            scenes.append(current)
        }
        var records: [[String: Any]] = []
        for (index, purpose) in ["checkpoint", "file-digest"].enumerated() {
            let scene = scenes[index], root = context.dataRoot
            let path = SpatialSceneStore.revisionPath(scene: scene.manifest.sceneID, revision: scene.manifest.revision) + "/scene.blend"
            let file = try ProjectLocalFile.resolve(path, dataRoot: root)
            let control = try await Task.detached {
                let began = try BpyRuntimeClock.awakeSeconds()
                let digest = try BpyRuntimeFile.digest(at: file)
                return (digest, try BpyRuntimeClock.awakeSeconds() - began)
            }.value
            guard control.0 == scene.manifest.sceneSHA256, control.1 > 0 else { throw SpatialSceneError.changed }
            let token = BpyOperationCancellation(), attempt = Attempt()
            let gate = try BpyNativeHashGate(file: file, operation: token.id, purpose: purpose)
            defer { token.cancel(); gate.release() }
            let before = try runtime.nativeCheckpointStamp(), releasesBefore = try BpyMemoryCoordinator.shared.selftestReleaseCount()
            let indexBefore = try SpatialSceneStore.digest(SpatialSceneStore.read(SpatialSceneStore.basePath + "/index.v1.json", in: root))
            let task = Task.detached {
                var failure = "unexpected-success"
                do {
                    if purpose == "checkpoint" { try runtime.loadProjectCheckpoint(sceneRevision: scene, cancellation: token) }
                    else {
                        try BpyMediaReadScope.withScope(dataRoot: root, cancellation: token) { scope in
                            try scope.withConsumer { _ in try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: root) }
                        }
                    }
                } catch let error as BpyAdmissionFailure { failure = error.rawValue }
                catch let error as BpyExecutionInterruption { failure = error.reason.rawValue }
                catch { failure = "unexpected-error" }
                attempt.finish(.init(failure: failure, clock: BpyRuntimeClock.read(), taskCancelled: Task.isCancelled))
            }
            do {
                let deadline = try BpyRuntimeClock.awakeSeconds() + 30
                while gate.sample == nil {
                    guard attempt.outcome == nil, try BpyRuntimeClock.awakeSeconds() < deadline else { throw SpatialSceneError.changed }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let sample = gate.sample, !sample.context.isCancelled(), let cancelledAt = BpyRuntimeClock.read() else { throw SpatialSceneError.changed }
                token.cancel(); gate.release()
                while attempt.outcome == nil {
                    guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
                    try await Task.sleep(for: .milliseconds(5))
                }
                await task.value
                guard let outcome = attempt.outcome, let ended = outcome.clock,
                      outcome.failure == "cancelled", !outcome.taskCancelled, sample.context.isCancelled(), !gate.timedOut,
                      gate.chunksAfterCancellation == 0,
                      ended.awake >= cancelledAt.awake, ended.awake - cancelledAt.awake <= 0.25,
                      ended.awake - cancelledAt.awake < control.1 / 2,
                      before == (try runtime.nativeCheckpointStamp()), releasesBefore == (try BpyMemoryCoordinator.shared.selftestReleaseCount()),
                      indexBefore == (try SpatialSceneStore.digest(SpatialSceneStore.read(SpatialSceneStore.basePath + "/index.v1.json", in: root))) else {
                    throw GateBlocked("The caller-only cancellation did not stop the active hash before upload or publication.")
                }
                records.append(["purpose": purpose, "operation": token.id.uuidString, "sceneID": scene.manifest.sceneID.uuidString,
                    "sceneBytes": sample.progress.bytes, "hashedBytes": sample.progress.hashedBytes,
                    "sceneCount": try SpatialSceneStore.index(in: root).scenes.count,
                    "device": sample.progress.device, "inode": sample.progress.inode,
                    "expectedDevice": gate.device, "expectedInode": gate.inode, "expectedBytes": gate.bytes,
                    "sceneSHA256": control.0, "controlSeconds": control.1, "cancelledAt": cancelledAt.awake,
                    "endedAt": ended.awake, "failure": outcome.failure, "taskCancelled": outcome.taskCancelled,
                    "callerCancelled": sample.context.isCancelled(), "checkpointBefore": before,
                    "chunksAfterCancellation": gate.chunksAfterCancellation,
                    "checkpointAfter": try runtime.nativeCheckpointStamp(), "releasesBefore": releasesBefore,
                    "releasesAfter": try BpyMemoryCoordinator.shared.selftestReleaseCount(), "indexBefore": indexBefore,
                    "indexAfter": try SpatialSceneStore.digest(SpatialSceneStore.read(SpatialSceneStore.basePath + "/index.v1.json", in: root))])
            } catch {
                token.cancel(); gate.release(); await task.value
                throw error
            }
        }
        let editor = try await editorCancellation(session: session, root: context.dataRoot)
        let evidence: [String: Any] = ["schema": "nexgenvideo/spatial-hash-cancellation/2", "hashes": records, "editor": editor]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), name = "production-spatial-hash-cancel.json"
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
        return ["file": name, "sha256": FileDigest.sha256(of: data)]
    }

    private static func editorCancellation(session: SpatialSceneSession, root: URL) async throws -> [[String: Any]] {
        guard let current = session.current else { throw SpatialSceneError.changed }
        let path = SpatialSceneStore.revisionPath(scene: current.manifest.sceneID, revision: current.manifest.revision) + "/scene.blend"
        let file = try ProjectLocalFile.resolve(path, dataRoot: root)
        var records: [[String: Any]] = []
        for route in ["user", "externalToken"] {
            let gate = try BpyNativeHashGate(file: file, purpose: route == "user" ? "file-digest" : "checkpoint")
            defer { gate.release() }
            let prior = current.manifest.revision, priorFrame = session.frame
            let releases = try BpyMemoryCoordinator.shared.selftestReleaseCount()
            let task = Task { await session.evaluate(frame: priorFrame + 1); return Task.isCancelled }
            do {
                let deadline = try BpyRuntimeClock.awakeSeconds() + 30
                while gate.sample == nil {
                    guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let sample = gate.sample, !sample.context.isCancelled() else { throw SpatialSceneError.changed }
                if route == "user" { session.cancel() } else { try session.nativeInvalidateActiveOperation() }
                guard sample.context.isCancelled() else { throw SpatialSceneError.changed }
                gate.release()
                while session.busy {
                    guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let taskCancelled = await task.value
                guard !gate.timedOut, !taskCancelled, !session.canCancel, gate.chunksAfterCancellation == 0,
                      session.current?.manifest.revision == prior, session.frame == priorFrame,
                      (route == "user" ? session.error == nil : session.error?.isEmpty == false),
                      releases == (try BpyMemoryCoordinator.shared.selftestReleaseCount()) else {
                    throw GateBlocked("Location cancellation changed the current scene or confused a user action with an external interruption.")
                }
                records.append(["route": route, "operation": sample.context.id.uuidString,
                    "purpose": sample.context.purpose, "device": sample.progress.device, "inode": sample.progress.inode,
                    "expectedDevice": gate.device, "expectedInode": gate.inode,
                    "sceneID": current.manifest.sceneID.uuidString, "revisionBefore": prior.uuidString,
                    "revisionAfter": session.current?.manifest.revision.uuidString ?? "", "frameBefore": priorFrame, "frameAfter": session.frame,
                    "sceneBytes": sample.progress.bytes, "hashedBytes": sample.progress.hashedBytes,
                    "chunksAfterCancellation": gate.chunksAfterCancellation, "callerCancelled": sample.context.isCancelled(),
                    "callingTaskCancelled": taskCancelled, "canCancel": session.canCancel, "error": session.error ?? "",
                    "releasesBefore": releases, "releasesAfter": try BpyMemoryCoordinator.shared.selftestReleaseCount()])
            } catch {
                session.cancel(); gate.release(); _ = await task.value
                throw error
            }
        }
        return records
    }
}
