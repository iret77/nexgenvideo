import BpyRuntimeProtocol
import Foundation
import simd

struct SpatialEvaluatedGeometryV1: Codable, Sendable, Equatable {
    struct Mesh: Codable, Sendable, Equatable {
        let id: String
        let objectID: String
        let minimum: [Double]
        let maximum: [Double]
    }
    struct Frame: Codable, Sendable, Equatable {
        let frame: Int
        let meshes: [Mesh]
        let cameraMatrix: [Double]
        let sceneFrame: Int
        let scene: String
        let viewLayer: String
        let metersPerUnit: Double
        let objects: [SpatialClayObjectPose]

        init(frame: Int, meshes: [Mesh], cameraMatrix: [Double], sceneFrame: Int? = nil,
             scene: String = "unit-scene", viewLayer: String = "unit-layer", metersPerUnit: Double = 1,
             objects: [SpatialClayObjectPose] = []) {
            self.frame = frame; self.meshes = meshes; self.cameraMatrix = cameraMatrix
            self.sceneFrame = sceneFrame ?? frame; self.scene = scene; self.viewLayer = viewLayer
            self.metersPerUnit = metersPerUnit; self.objects = objects
        }
    }
    struct Chunk: Codable, Sendable, Equatable {
        let startFrame: Int
        let endFrame: Int
        let jobID: UUID
        let jobFingerprint: String
        let commandSHA256: String
        let verificationSHA256: String
        let filename: String
        let sha256: String
    }
    let schema: String
    let sceneManifestSHA256: String
    let sceneSHA256: String
    let stateSHA256: String
    let workerSHA256: String
    let scriptSHA256: String
    let runtimeLockSHA256: String
    let runtimeBinarySHA256: String
    let chunks: [Chunk]
    let frames: [Frame]
    var snapshotSHA256 = ""
    var sceneFrameOrigin = 0
    var runtimeRecordSHA256 = ""
    var sceneRevision: UUID?
    var effectiveTimeoutSeconds = 0

    func validate(state: SpatialClayState, scene: SpatialSceneRevision) throws {
        guard schema == "spatial-evaluated-geometry/v1",
              sceneManifestSHA256 == SpatialSceneStore.digest(scene.manifestData),
              sceneSHA256 == scene.manifest.sceneSHA256, snapshotSHA256 == scene.manifest.snapshotSHA256,
              snapshotSHA256 == SpatialSceneStore.digest(scene.snapshotData),
              sceneFrameOrigin == 0, sceneRevision == scene.manifest.revision, effectiveTimeoutSeconds > 0,
              Self.hash(runtimeRecordSHA256),
              stateSHA256 == SpatialSceneStore.digest(try SpatialSceneStore.encode(state)),
              !state.frames.isEmpty, frames.map(\.frame) == state.frames.map(\.frame),
              state.frames.map(\.frame) == Array(state.frames.indices),
              !chunks.isEmpty, Set(chunks.map(\.jobID)).count == chunks.count,
              Set(chunks.map(\.filename)).count == chunks.count,
              [workerSHA256, scriptSHA256, runtimeLockSHA256, runtimeBinarySHA256].allSatisfy(Self.hash) else { throw SpatialSceneError.changed }
        var next = 0
        for chunk in chunks {
            guard chunk.startFrame == next, chunk.endFrame >= next,
                  chunk.endFrame - next < 120, chunk.endFrame < frames.count,
                  chunk.filename == "evaluated-bounds-\(chunk.startFrame).v1.json",
                  [chunk.jobFingerprint, chunk.commandSHA256, chunk.verificationSHA256, chunk.sha256].allSatisfy(Self.hash) else { throw SpatialSceneError.changed }
            next = chunk.endFrame + 1
        }
        guard next == frames.count else { throw SpatialSceneError.changed }
        let objects = Set(scene.snapshot.objects.map(\.id))
        guard Set(frames.map(\.scene)).count == 1, Set(frames.map(\.viewLayer)).count == 1 else { throw SpatialSceneError.changed }
        for (index, frame) in frames.enumerated() {
            guard frame.sceneFrame == frame.frame, !frame.scene.isEmpty, !frame.viewLayer.isEmpty,
                  frame.metersPerUnit == scene.snapshot.metersPerUnit,
                  Set(state.frames[index].objects.map(\.objectID)) == objects,
                  state.frames[index].objects.count == objects.count,
                  Set(frame.objects.map(\.objectID)) == objects, frame.objects.count == objects.count,
                  Set(frame.meshes.map(\.id)).count == frame.meshes.count,
                  let nativeCamera = state.frames[index].objects.first(where: { $0.objectID == state.cameraID }) else { throw SpatialSceneError.changed }
            let expectedObjects = Dictionary(uniqueKeysWithValues: state.frames[index].objects.map { ($0.objectID, $0.matrixWorld) })
            for pose in frame.objects {
                guard let expected = expectedObjects[pose.objectID], try Self.sameMatrix(pose.matrixWorld, expected) else { throw SpatialSceneError.changed }
            }
            let actual = try SpatialShotPoseTimeline.matrix(frame.cameraMatrix)
            let expected = try SpatialShotPoseTimeline.matrix(nativeCamera.matrixWorld)
            guard zip(SpatialShotPoseTimeline.rows(actual), SpatialShotPoseTimeline.rows(expected))
                .allSatisfy({ abs($0.0 - $0.1) <= 0.000001 * max(1, abs($0.1)) }) else { throw SpatialSceneError.changed }
            for mesh in frame.meshes {
                guard !mesh.id.isEmpty, objects.contains(mesh.objectID), mesh.minimum.count == 3, mesh.maximum.count == 3,
                      (mesh.minimum + mesh.maximum).allSatisfy(\.isFinite),
                      zip(mesh.minimum, mesh.maximum).allSatisfy({ $0.0 <= $0.1 }) else { throw SpatialSceneError.changed }
            }
        }
    }

    func validateFiles(_ files: [String: Data]) throws {
        struct Verification: Decodable { let jobID: UUID; let fingerprint: String; let blenderBuildHash: String }
        var actual: [Frame] = []
        var names = Set(["evaluated-geometry.v1.json"])
        if !runtimeRecordSHA256.isEmpty {
            names.formUnion(["evaluated-scene-operations.py", "evaluated-worker.py", "evaluated-runtime-lock.json", "evaluated-runtime-record.csv"])
            names.formUnion(chunks.map { "evaluated-command-\($0.startFrame).py" })
        }
        for chunk in chunks {
            let name = "evaluated-verification-\(chunk.startFrame).v1.json"
            names.formUnion([chunk.filename, name])
            guard let bounds = files[chunk.filename], SpatialSceneStore.digest(bounds) == chunk.sha256,
                  let verification = files[name], SpatialSceneStore.digest(verification) == chunk.verificationSHA256 else { throw SpatialSceneError.changed }
            let values = try JSONDecoder().decode([Frame].self, from: bounds)
            guard values.map(\.frame) == Array(chunk.startFrame...chunk.endFrame) else { throw SpatialSceneError.changed }
            let evidence = try JSONDecoder().decode(Verification.self, from: verification)
            guard evidence.jobID == chunk.jobID, evidence.fingerprint == chunk.jobFingerprint,
                  !evidence.blenderBuildHash.isEmpty else { throw SpatialSceneError.changed }
            actual += values
        }
        guard actual == frames, Set(files.keys) == names,
              let encoded = files["evaluated-geometry.v1.json"],
              try JSONDecoder().decode(Self.self, from: encoded) == self else { throw SpatialSceneError.changed }
    }

    static func command(state: SpatialClayState, script: Data) throws -> String {
        let settings = try JSONSerialization.data(withJSONObject: ["kind": "evaluate_bounds", "cameraID": state.cameraID,
            "state": JSONSerialization.jsonObject(with: SpatialSceneStore.encode(state))], options: [.sortedKeys])
        let literal = try JSONEncoder().encode(String(decoding: settings, as: UTF8.self))
        return "import json\nngv_command = json.loads(\(String(decoding: literal, as: UTF8.self)))\n" + String(decoding: script, as: UTF8.self)
    }

    func validateRecordedSources(_ files: [String: Data], state: SpatialClayState, scene: SpatialSceneRevision,
                                 runtimeRoot: URL, scope: BpyMediaReadScope) throws {
        try scope.check()
        guard let script = files["evaluated-scene-operations.py"], SpatialSceneStore.digest(script) == scriptSHA256,
              let worker = files["evaluated-worker.py"], SpatialSceneStore.digest(worker) == workerSHA256,
              let lock = files["evaluated-runtime-lock.json"], SpatialSceneStore.digest(lock) == runtimeLockSHA256,
              let record = files["evaluated-runtime-record.csv"], SpatialSceneStore.digest(record) == runtimeRecordSHA256,
              let json = try JSONSerialization.jsonObject(with: lock) as? [String: Any],
              let wheel = json["bpyWheelLayout"] as? [String: Any],
              let binary = wheel["expectedRuntimeBinaryEvidence"] as? [String: Any],
              let build = binary["buildHash"] as? String, !build.isEmpty else { throw SpatialSceneError.changed }
        guard script == (try Data(contentsOf: runtimeRoot.appendingPathComponent("scene_operations.py"))),
              worker == (try Data(contentsOf: runtimeRoot.appendingPathComponent("worker.py"))),
              lock == (try Data(contentsOf: runtimeRoot.appendingPathComponent("runtime-lock.json"))),
              record == (try Data(contentsOf: runtimeRoot.appendingPathComponent("site-packages/bpy-5.2.2.dist-info/RECORD"))),
              try scope.digest(at: runtimeRoot.appendingPathComponent("site-packages/bpy/__init__.so")) == runtimeBinarySHA256 else { throw SpatialSceneError.changed }
        for chunk in chunks {
            try scope.check()
            guard state.frames.indices.contains(chunk.startFrame), state.frames.indices.contains(chunk.endFrame),
                  chunk.startFrame <= chunk.endFrame else { throw SpatialSceneError.changed }
            let part = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: state.cameraID,
                frames: Array(state.frames[chunk.startFrame...chunk.endFrame]))
            let expected = try Self.command(state: part, script: script)
            guard let source = files["evaluated-command-\(chunk.startFrame).py"], source == Data(expected.utf8),
                  SpatialSceneStore.digest(source) == chunk.commandSHA256,
                  BpyRuntimeSession.evaluatedGeometryFingerprint(revision: scene.manifest.revision, source: expected,
                    timeoutSeconds: effectiveTimeoutSeconds) == chunk.jobFingerprint,
                  let verification = files["evaluated-verification-\(chunk.startFrame).v1.json"],
                  let value = try JSONSerialization.jsonObject(with: verification) as? [String: Any],
                  value["blenderBuildHash"] as? String == build else { throw SpatialSceneError.changed }
        }
    }

    static func sameMatrix(_ a: [Double], _ b: [Double]) throws -> Bool {
        _ = try SpatialShotPoseTimeline.matrix(a); _ = try SpatialShotPoseTimeline.matrix(b)
        return zip(a, b).allSatisfy { abs($0.0 - $0.1) <= 0.000001 * max(1, abs($0.1)) }
    }

    private static func hash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
}
