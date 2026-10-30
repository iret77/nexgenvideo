import BpyRuntimeProtocol
import Foundation
import NexGenEngine

enum SpatialEvaluatedGeometryRenderer {
    struct Candidate: Sendable {
        let geometry: SpatialEvaluatedGeometryV1
        let files: [String: Data]
        fileprivate init(geometry: SpatialEvaluatedGeometryV1, files: [String: Data]) {
            self.geometry = geometry; self.files = files
        }
    }

    static func requireEvidence(references: [CanonicalArtifactReferenceV1], stateReference: CanonicalArtifactReferenceV1,
                                cameraID: String, sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                directory: String, dataRoot: URL) throws {
        try BpyMediaReadScope.withScope(dataRoot: dataRoot) { scope in
            try scope.withConsumer { _ in
                try requireEvidence(references: references, stateReference: stateReference, cameraID: cameraID,
                    sceneReference: sceneReference, shotID: shotID, directory: directory, dataRoot: dataRoot, scope: scope)
            }
        }
    }

    private static func requireEvidence(references: [CanonicalArtifactReferenceV1], stateReference: CanonicalArtifactReferenceV1,
                                        cameraID: String, sceneReference: CanonicalArtifactReferenceV1, shotID: String,
                                        directory: String, dataRoot: URL, scope: BpyMediaReadScope) throws {
        try scope.check()
        let refs = references.filter { $0.role == "host.evaluated-geometry" }
        guard Set(refs.map(\.path)).count == refs.count,
              refs.contains(where: { $0.path == directory + "/evaluated-geometry.v1.json" }) else { throw SpatialSceneError.changed }
        var files: [String: Data] = [:]
        for ref in refs {
            try scope.check()
            guard (ref.path as NSString).deletingLastPathComponent == directory else { throw SpatialSceneError.changed }
            files[(ref.path as NSString).lastPathComponent] = try scope.verifiedData(
                at: ProjectLocalFile.resolve(ref.path, dataRoot: dataRoot), expectedSHA256: ref.sha256,
                maximum: BpyRuntimeLimits.maximumOutputBytes)
        }
        guard let data = files["evaluated-geometry.v1.json"],
              let head = try SpatialSceneStore.index(in: dataRoot).scenes.first(where: {
                  SpatialSceneStore.revisionPath(scene: $0.id, revision: $0.revision) + "/scene.blend" == sceneReference.path
              }) else { throw SpatialSceneError.changed }
        let scene = try SpatialSceneStore.load(head, in: dataRoot)
        guard scene.manifest.sceneSHA256 == sceneReference.sha256 else { throw SpatialSceneError.changed }
        let state = try PipelineSpatialDerivationWriter.requirePlanningState(reference: stateReference, cameraID: cameraID,
            sceneReference: sceneReference, shotID: shotID, dataRoot: dataRoot)
        let geometry = try JSONDecoder().decode(SpatialEvaluatedGeometryV1.self, from: data)
        try geometry.validate(state: state, scene: scene)
        try geometry.validateFiles(files)
        try geometry.validateRecordedSources(files, state: state, scene: scene,
            runtimeRoot: BpyRuntimeBundleLayout(app: Bundle.main.bundleURL, serviceName: bpyRuntimeServiceNames[0]).runtime, scope: scope)
    }

    static func prepare(state: SpatialClayState, revision: SpatialSceneRevision,
                        runtime: BpyRuntimeSession, runtimeRoot: URL) async throws -> Candidate {
        let cancellation = BpyOperationCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try await prepareOffMain(state: state, revision: revision, runtime: runtime, runtimeRoot: runtimeRoot,
                cancellation: cancellation)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            cancellation.cancel(); task.cancel()
        }
    }

    private static func prepareOffMain(state: SpatialClayState, revision: SpatialSceneRevision,
                                       runtime: BpyRuntimeSession, runtimeRoot: URL,
                                       cancellation: BpyOperationCancellation) async throws -> Candidate {
        guard !state.frames.isEmpty else { throw SpatialSceneError.changed }
        let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: revision.manifest.sceneSHA256,
            ownerBindingSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)), cameraID: state.cameraID,
            startFrame: 0, endFrame: state.frames.count - 1, width: 64, height: 64, samples: 1,
            stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)))
        try SpatialClayRenderer.validateSequenceState(state, request: request, revision: revision)
        let script = try Data(contentsOf: runtimeRoot.appendingPathComponent("scene_operations.py"))
        let worker = try Data(contentsOf: runtimeRoot.appendingPathComponent("worker.py"))
        let runtimeLock = try Data(contentsOf: runtimeRoot.appendingPathComponent("runtime-lock.json"))
        let binarySHA256 = try runtime.digestRuntimeFile(at: runtimeRoot.appendingPathComponent("site-packages/bpy/__init__.so"), cancellation: cancellation)
        var frames: [SpatialEvaluatedGeometryV1.Frame] = []
        var chunks: [SpatialEvaluatedGeometryV1.Chunk] = []
        let record = try Data(contentsOf: runtimeRoot.appendingPathComponent("site-packages/bpy-5.2.2.dist-info/RECORD"))
        var files: [String: Data] = ["evaluated-scene-operations.py": script, "evaluated-worker.py": worker,
            "evaluated-runtime-lock.json": runtimeLock, "evaluated-runtime-record.csv": record]
        for start in stride(from: 0, to: state.frames.count, by: 120) {
            try Task.checkCancellation()
            let end = min(start + 119, state.frames.count - 1)
            let part = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: state.cameraID,
                                       frames: Array(state.frames[start...end]))
            let source = try SpatialEvaluatedGeometryV1.command(state: part, script: script)
            let job = UUID()
            let operation = Task.detached {
                try Task.checkCancellation()
                try runtime.loadProjectCheckpoint(sceneRevision: revision, cancellation: cancellation)
                try Task.checkCancellation()
                return try runtime.runJob(id: job, expectedRevision: revision.manifest.revision.uuidString, source: source, cancellation: cancellation)
            }
            let result = try await withTaskCancellationHandler { try await operation.value } onCancel: {
                cancellation.cancel(); operation.cancel()
            }
            defer { result.release() }
            try Task.checkCancellation()
            let evidence = try runtime.authenticateEvaluatedGeometry(jobID: job, source: source, revision: revision,
                result: result, cancellation: cancellation)
            let values = try JSONDecoder().decode([SpatialEvaluatedGeometryV1.Frame].self, from: evidence.bounds)
            guard values.map(\.frame) == Array(start...end) else { throw SpatialSceneError.changed }
            let filename = "evaluated-bounds-\(start).v1.json"
            files[filename] = evidence.bounds
            files["evaluated-command-\(start).py"] = Data(source.utf8)
            files["evaluated-verification-\(start).v1.json"] = evidence.verification
            chunks.append(.init(startFrame: start, endFrame: end, jobID: job, jobFingerprint: evidence.fingerprint,
                commandSHA256: SpatialSceneStore.digest(Data(source.utf8)), verificationSHA256: SpatialSceneStore.digest(evidence.verification),
                filename: filename, sha256: SpatialSceneStore.digest(evidence.bounds)))
            frames += values
        }
        let geometry = SpatialEvaluatedGeometryV1(schema: "spatial-evaluated-geometry/v1",
            sceneManifestSHA256: SpatialSceneStore.digest(revision.manifestData), sceneSHA256: revision.manifest.sceneSHA256,
            stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)), workerSHA256: SpatialSceneStore.digest(worker),
            scriptSHA256: SpatialSceneStore.digest(script), runtimeLockSHA256: SpatialSceneStore.digest(runtimeLock),
            runtimeBinarySHA256: binarySHA256, chunks: chunks, frames: frames,
            snapshotSHA256: revision.manifest.snapshotSHA256, runtimeRecordSHA256: SpatialSceneStore.digest(record),
            sceneRevision: revision.manifest.revision, effectiveTimeoutSeconds: runtime.limits.timeoutSeconds)
        try geometry.validate(state: state, scene: revision)
        files["evaluated-geometry.v1.json"] = try SpatialSceneStore.encode(geometry)
        try geometry.validateFiles(files)
        try geometry.validateRecordedSources(files, state: state, scene: revision, runtimeRoot: runtimeRoot,
            scope: runtime.mediaReadScope(cancellation: cancellation))
        try Task.checkCancellation()
        return Candidate(geometry: geometry, files: files)
    }
}
