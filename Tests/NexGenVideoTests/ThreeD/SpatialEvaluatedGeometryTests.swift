import Foundation
import Testing
@testable import NexGenVideo

@Suite("Evaluated geometry sidecar byte closure; format fixtures only")
struct SpatialEvaluatedGeometryTests {
    @Test func nativeChunkClosureRejectsMissingForeignAndSubstitutedFiles() throws {
        let job = UUID(), fingerprint = String(repeating: "a", count: 64)
        let matrix = [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let frame = SpatialEvaluatedGeometryV1.Frame(frame: 0,
            meshes: [.init(id: "mesh", objectID: "object", minimum: [0, 0, 0], maximum: [1, 1, 1])], cameraMatrix: matrix)
        let bounds = try SpatialSceneStore.encode([frame])
        let verification = try JSONSerialization.data(withJSONObject: ["jobID": job.uuidString,
            "fingerprint": fingerprint, "blenderBuildHash": "unit-format-only"], options: [.sortedKeys])
        let chunk = SpatialEvaluatedGeometryV1.Chunk(startFrame: 0, endFrame: 0, jobID: job, jobFingerprint: fingerprint,
            commandSHA256: fingerprint, verificationSHA256: SpatialSceneStore.digest(verification),
            filename: "evaluated-bounds-0.v1.json", sha256: SpatialSceneStore.digest(bounds))
        let geometry = SpatialEvaluatedGeometryV1(schema: "spatial-evaluated-geometry/v1", sceneManifestSHA256: fingerprint,
            sceneSHA256: fingerprint, stateSHA256: fingerprint, workerSHA256: fingerprint, scriptSHA256: fingerprint,
            runtimeLockSHA256: fingerprint, runtimeBinarySHA256: fingerprint, chunks: [chunk], frames: [frame])
        let files = [chunk.filename: bounds, "evaluated-verification-0.v1.json": verification,
                     "evaluated-geometry.v1.json": try SpatialSceneStore.encode(geometry)]
        try geometry.validateFiles(files)
        var missing = files
        missing.removeValue(forKey: chunk.filename)
        #expect(throws: (any Error).self) { try geometry.validateFiles(missing) }
        var foreign = files
        foreign["other-shot.v1.json"] = bounds
        #expect(throws: (any Error).self) { try geometry.validateFiles(foreign) }
        var changed = files
        changed[chunk.filename] = try SpatialSceneStore.encode([SpatialEvaluatedGeometryV1.Frame(frame: 0,
            meshes: [.init(id: "mesh", objectID: "object", minimum: [4, 0, 0], maximum: [5, 1, 1])], cameraMatrix: matrix)])
        #expect(throws: (any Error).self) { try geometry.validateFiles(changed) }
        let wrongVerification = try JSONSerialization.data(withJSONObject: ["jobID": UUID().uuidString,
            "fingerprint": fingerprint, "blenderBuildHash": "unit-format-only"], options: [.sortedKeys])
        let reboundChunk = SpatialEvaluatedGeometryV1.Chunk(startFrame: 0, endFrame: 0, jobID: job,
            jobFingerprint: fingerprint, commandSHA256: fingerprint, verificationSHA256: SpatialSceneStore.digest(wrongVerification),
            filename: chunk.filename, sha256: chunk.sha256)
        let rebound = SpatialEvaluatedGeometryV1(schema: geometry.schema, sceneManifestSHA256: fingerprint,
            sceneSHA256: fingerprint, stateSHA256: fingerprint, workerSHA256: fingerprint, scriptSHA256: fingerprint,
            runtimeLockSHA256: fingerprint, runtimeBinarySHA256: fingerprint, chunks: [reboundChunk], frames: [frame])
        let rehashed = [chunk.filename: bounds, "evaluated-verification-0.v1.json": wrongVerification,
                        "evaluated-geometry.v1.json": try SpatialSceneStore.encode(rebound)]
        #expect(throws: (any Error).self) { try rebound.validateFiles(rehashed) }
    }
}
