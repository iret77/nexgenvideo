import AppKit
import BpyRuntimeProtocol
import Foundation
import Observation
import simd
import UniformTypeIdentifiers

@MainActor
protocol SpatialSceneAuthority: AnyObject {
    func requireReadableScene() async throws
    func readScene<Value: Sendable>(_ operation: @escaping @Sendable (URL) throws -> Value) async throws -> Value
    func commitSceneEdit(
        _ prepare: @escaping @Sendable () async throws -> SpatialSceneCandidate
    ) async throws -> SpatialSceneCommit
}

@MainActor @Observable
final class SpatialSceneSession {
    private(set) var locations: [SpatialSceneHead] = []
    private(set) var current: SpatialSceneRevision?
    private(set) var snapshot: BpySpatialSnapshot?
    private(set) var snapshotRevision = UUID()
    private(set) var busy = false
    private(set) var error: String?
    private(set) var cameraPreview: Data?
    var selectedObjectID: String?
    var selectedCameraID: String?
    var frame = 1
    var freeCameraPosition = SIMD3<Float>(6, -8, 5)
    var freeCameraTarget = SIMD3<Float>.zero
    var snap = true

    private let pipelineRoot: URL
    private let runtimeRoot: URL
    private let runtime: BpyRuntimeSession
    private let authority: any SpatialSceneAuthority
    private var undoRevisions: [SpatialSceneHead] = []
    private var redoRevisions: [SpatialSceneHead] = []
    private var activeJob: SpatialEditCancellation?
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(pipelineRoot: URL, runtime: BpyRuntimeSession, authority: any SpatialSceneAuthority) {
        self.pipelineRoot = pipelineRoot
        self.runtime = runtime
        self.authority = authority
        runtimeRoot = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BpyRuntime")
    }

    var selectedObject: BpySpatialObject? { snapshot?.objects.first { $0.id == selectedObjectID } }
    var selectedCamera: BpySpatialCamera? { snapshot?.cameras.first { $0.id == selectedCameraID } }
    var canUndo: Bool { !busy && !undoRevisions.isEmpty }
    var canRedo: Bool { !busy && !redoRevisions.isEmpty }

    func reload() {
        guard !busy else { return }
        busy = true
        refreshTask = Task {
            defer { busy = false; refreshTask = nil }
            do {
                let index = try await authority.readScene { try SpatialSceneStore.index(in: $0) }
                locations = index.scenes
                if let id = current?.manifest.sceneID, let head = locations.first(where: { $0.id == id }) {
                    if head.revision != current?.manifest.revision {
                        undoRevisions.removeAll()
                        redoRevisions.removeAll()
                    }
                    try await load(head)
                } else if current != nil {
                    current = nil
                    snapshot = nil
                    cameraPreview = nil
                    undoRevisions.removeAll()
                    redoRevisions.removeAll()
                }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func open(_ head: SpatialSceneHead) {
        guard !busy else { return }
        busy = true
        refreshTask = Task {
            defer { busy = false; refreshTask = nil }
            do {
                try await authority.requireReadableScene()
                try await load(head)
                undoRevisions.removeAll()
                redoRevisions.removeAll()
                selectedObjectID = nil
                selectedCameraID = nil
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func create(name: String) async {
        await edit(["kind": "create"], newName: name)
    }

    func addPrimitive(_ kind: String) async {
        await edit(["kind": "primitive", "primitive": kind, "name": kind.capitalized])
    }

    func removeSelected() async {
        guard let selectedObjectID else { return }
        await edit(["kind": "delete", "objectID": selectedObjectID])
    }

    func transformSelected(position: SIMD3<Double>, rotation: SIMD3<Double>, scale: SIMD3<Double>, keyframe: Bool) async {
        guard let selectedObjectID else { return }
        let angles = rotation * (.pi / 180)
        let orientation = simd_quatd(angle: angles.z, axis: [0, 0, 1])
            * simd_quatd(angle: angles.y, axis: [0, 1, 0])
            * simd_quatd(angle: angles.x, axis: [1, 0, 0])
        var matrix = simd_double4x4(orientation)
        matrix.columns.0 *= scale.x
        matrix.columns.1 *= scale.y
        matrix.columns.2 *= scale.z
        let step = snap ? 0.1 : 0
        let translation = step > 0 ? SIMD3<Double>((position.x / step).rounded(),
                                                  (position.y / step).rounded(),
                                                  (position.z / step).rounded()) * step : position
        matrix.columns.3 = [translation.x, translation.y, translation.z, 1]
        let rows = (0..<4).map { row in (0..<4).map { matrix[$0][row] } }
        await edit(["kind": "transform", "objectID": selectedObjectID,
                    "matrixWorld": rows, "keyframe": keyframe, "frame": frame])
    }

    func camera(name: String, fieldOfView: Double, width: Int, height: Int, keyframe: Bool) async {
        guard !busy else { return }
        do { _ = try SpatialClayRenderer.renderDimensions(width: width, height: height) }
        catch { self.error = error.localizedDescription; return }
        let world: [[Double]]
        if let selectedCamera {
            world = stride(from: 0, to: 16, by: 4).map { Array(selectedCamera.matrixWorld[$0..<$0 + 4]) }
        } else {
            let position = SIMD3<Double>(freeCameraPosition)
            let back = simd_normalize(position - SIMD3<Double>(freeCameraTarget))
            let right = simd_normalize(simd_cross(SIMD3<Double>(0, 0, 1), back))
            let up = simd_cross(back, right)
            world = [[right.x, up.x, back.x, position.x], [right.y, up.y, back.y, position.y],
                     [right.z, up.z, back.z, position.z], [0, 0, 0, 1]]
        }
        var command: [String: Any] = ["kind": "camera", "name": name, "matrixWorld": world,
                                     "verticalFieldOfView": fieldOfView * .pi / 180,
                                     "near": 0.01, "far": 10_000,
                                     "width": width, "height": height, "frame": frame, "keyframe": keyframe]
        if let selectedCamera { command["objectID"] = selectedCamera.id }
        await edit(command)
    }

    func importGLB() async {
        guard !busy, let importingScene = current?.manifest.revision else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "glb") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let data = try await Task.detached {
                try SpatialSceneStore.read(url.lastPathComponent, in: url.deletingLastPathComponent())
            }.value
            try Task.checkCancellation()
            guard !busy, current?.manifest.revision == importingScene else { throw SpatialSceneError.changed }
            guard data.starts(with: Data("glTF".utf8)) else {
                throw SpatialSceneError.invalid("Choose a binary glTF (.glb) file.")
            }
            let resource = SpatialSceneResource(id: UUID(), filename: url.lastPathComponent,
                                               sha256: SpatialSceneStore.digest(data), byteCount: data.count)
            await edit(["kind": "import_glb", "filename": "resource-" + resource.id.uuidString + ".glb"],
                       importedResource: (resource, data))
        } catch { self.error = error.localizedDescription }
    }

    func evaluate(frame: Int) async {
        guard !busy, let current else { return }
        busy = true
        defer { busy = false; activeJob = nil }
        do {
            try await requireCurrent(current)
            let source = try commandSource(["kind": "evaluate", "frame": frame])
            let runtime = runtime
            let job = SpatialEditCancellation(runtime: runtime)
            activeJob = job
            let root = runtimeRoot
            let result = try await Task.detached {
                try job.check()
                try runtime.loadProjectCheckpoint(scene: current.sceneData,
                                                  revision: current.manifest.revision.uuidString,
                                                  sha256: current.manifest.sceneSHA256)
                try job.check()
                defer { try? runtime.cancel(jobID: job.id) }
                let result = try runtime.runJob(id: job.id, expectedRevision: current.manifest.revision.uuidString, source: source)
                try job.check()
                return try SpatialSceneStore.prepare(
                    result: result, sceneID: current.manifest.sceneID, name: current.manifest.name,
                    expectedHead: nil, runtimeLock: Data(contentsOf: root.appendingPathComponent("runtime-lock.json")),
                    worker: Data(contentsOf: root.appendingPathComponent("worker.py")), resources: []
                ).revision.snapshot
            }.value
            try await requireCurrent(current)
            snapshot = result
            snapshotRevision = UUID()
            self.frame = frame
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func undo() async { await restore(undo: true) }
    func redo() async { await restore(undo: false) }

    func renderCamera() async {
        guard !busy, let current, let cameraID = selectedCameraID else { return }
        busy = true
        cameraPreview = nil
        defer { busy = false; activeJob = nil }
        do {
            try await requireCurrent(current)
            let job = SpatialEditCancellation(runtime: runtime)
            activeJob = job
            let result = try await SpatialClayRenderer.preview(
                revision: current, cameraID: cameraID, frame: frame, runtime: runtime, runtimeRoot: runtimeRoot,
                jobID: job.id, isCancelled: { job.isCancelled }
            )
            try await requireCurrent(current)
            cameraPreview = result
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func dismissCameraPreview() { cameraPreview = nil }

    func cancel() {
        refreshTask?.cancel()
        operationTask?.cancel()
        let job = activeJob
        Task.detached { job?.cancel() }
    }

    func editPython(_ source: String) async {
        await edit([:], python: source)
    }

    private func edit(_ command: [String: Any], newName: String? = nil,
                      importedResource: (SpatialSceneResource, Data)? = nil,
                      python: String? = nil) async {
        guard !busy, current != nil || newName != nil else {
            error = "Finish the current location action before applying this edit."
            return
        }
        busy = true
        let task = Task {
            await performEdit(command, newName: newName, importedResource: importedResource, python: python)
        }
        operationTask = task
        await task.value
        operationTask = nil
        busy = false
    }

    private func performEdit(_ command: [String: Any], newName: String?,
                             importedResource: (SpatialSceneResource, Data)?, python: String?) async {
        defer { activeJob = nil }
        let previous = newName == nil ? current : nil
        let head = previous.flatMap { value in locations.first { $0.id == value.manifest.sceneID } }
        do {
            let source = try python ?? commandSource(command)
            let root = runtimeRoot
            let runtime = runtime
            let sceneID = previous?.manifest.sceneID ?? UUID()
            let name = newName ?? previous!.manifest.name
            let job = SpatialEditCancellation(runtime: runtime)
            activeJob = job
            var resources = previous?.manifest.resources.compactMap { item in
                previous?.resources[item.id].map { (item, $0) }
            } ?? []
            if let importedResource { resources.append(importedResource) }
            let frozenResources = resources
            let committed = try await authority.commitSceneEdit {
                try await Task.detached {
                    try job.check()
                    try runtime.loadProjectCheckpoint(scene: previous?.sceneData,
                                                      revision: previous?.manifest.revision.uuidString,
                                                      sha256: previous?.manifest.sceneSHA256)
                    try job.check()
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let inputs = try frozenResources.map { item, data in
                        let filename = "resource-" + item.id.uuidString + ".glb"
                        try data.write(to: staging.appendingPathComponent(filename), options: .atomic)
                        return try BpyApprovedInputCopy(approvedDirectory: staging, filename: filename)
                    }
                    let result = try runtime.runJob(id: job.id, expectedRevision: previous?.manifest.revision.uuidString,
                                                    source: source, inputs: inputs)
                    try job.check()
                    return try SpatialSceneStore.prepare(
                        result: result, sceneID: sceneID, name: name, expectedHead: head,
                        runtimeLock: Data(contentsOf: root.appendingPathComponent("runtime-lock.json")),
                        worker: Data(contentsOf: root.appendingPathComponent("worker.py")), resources: frozenResources
                    )
                }.value
            }
            await Task.detached {
                _ = try? runtime.cancel(jobID: job.id)
            }.value
            if let head { undoRevisions.append(head) } else { undoRevisions.removeAll() }
            redoRevisions.removeAll()
            applyCommitted(committed)
        } catch {
            if let activeJob { await Task.detached { activeJob.cancel() }.value }
            self.error = error.localizedDescription
        }
    }

    private func restore(undo: Bool) async {
        guard !busy else { return }
        busy = true
        let task = Task { await performRestore(undo: undo) }
        operationTask = task
        await task.value
        operationTask = nil
        busy = false
    }

    private func performRestore(undo: Bool) async {
        guard let current, let prior = undo ? undoRevisions.last : redoRevisions.last,
              let head = locations.first(where: { $0.id == current.manifest.sceneID }) else { return }
        do {
            let root = pipelineRoot
            let committed = try await authority.commitSceneEdit {
                try await Task.detached {
                    let original = try SpatialSceneStore.load(prior, in: root)
                    return try SpatialSceneStore.restoration(original, replacing: head)
                }.value
            }
            if undo { undoRevisions.removeLast(); redoRevisions.append(head) }
            else { redoRevisions.removeLast(); undoRevisions.append(head) }
            applyCommitted(committed)
        } catch { self.error = error.localizedDescription }
    }

    private func load(_ head: SpatialSceneHead) async throws {
        let (loaded, index) = try await authority.readScene { root in
            let index = try SpatialSceneStore.index(in: root)
            guard index.scenes.first(where: { $0.id == head.id }) == head else { throw SpatialSceneError.changed }
            return (try SpatialSceneStore.load(head, in: root), index)
        }
        current = loaded
        locations = index.scenes
        snapshot = loaded.snapshot
        snapshotRevision = UUID()
        frame = loaded.snapshot.frame
        cameraPreview = nil
    }

    private func requireCurrent(_ revision: SpatialSceneRevision) async throws {
        try await authority.readScene { root in
            let index = try SpatialSceneStore.index(in: root)
            guard let head = index.scenes.first(where: { $0.id == revision.manifest.sceneID }),
                  head.revision == revision.manifest.revision,
                  head.manifestSHA256 == SpatialSceneStore.digest(revision.manifestData) else {
                throw SpatialSceneError.changed
            }
        }
    }

    private func applyCommitted(_ committed: SpatialSceneCommit) {
        current = committed.revision
        locations = committed.index.scenes
        snapshot = committed.revision.snapshot
        snapshotRevision = UUID()
        frame = committed.revision.snapshot.frame
        cameraPreview = nil
        error = nil
    }

    private func commandSource(_ command: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        let literal = try JSONEncoder().encode(String(decoding: data, as: UTF8.self))
        return "import json\nngv_command = json.loads(\(String(decoding: literal, as: UTF8.self)))\n"
            + (try String(contentsOf: runtimeRoot.appendingPathComponent("scene_operations.py"), encoding: .utf8))
    }
}

private final class SpatialEditCancellation: @unchecked Sendable {
    let id = UUID()
    private let runtime: BpyRuntimeSession
    private let lock = NSLock()
    private var cancelled = false

    init(runtime: BpyRuntimeSession) { self.runtime = runtime }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        _ = try? runtime.cancel(jobID: id)
    }
}
