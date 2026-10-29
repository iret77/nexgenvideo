import AVFoundation
import BpyRuntimeProtocol
import NexGenEngine
import XCTest
@testable import NexGenVideo

final class RetainedSpatialTests: XCTestCase {
    func testPlanUsesEachEvaluatedPoseAndDoesNotFallBackToRestPose() throws {
        let snapshot = try snapshot()
        let first = pose(x: 0), moved = pose(x: 4)
        let state = SpatialClayState(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera",
            frames: [.init(frame: 0, objects: first, cameraVerticalFieldOfView: 60),
                     .init(frame: 1, objects: moved, cameraVerticalFieldOfView: 60)])
        let plan = try NativeBlockoutPlanProjection(snapshot: snapshot, state: state, locationID: "room")
        let start = try plan.frame(0), end = try plan.frame(1)
        XCTAssertEqual(end.shapes[0].center.x - start.shapes[0].center.x, 4, accuracy: 0.000001)
        XCTAssertEqual(end.cameras[0].position.x - start.cameras[0].position.x, 4, accuracy: 0.000001)
        let incomplete = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: "camera",
            frames: [.init(frame: 0, objects: [first[1]], cameraVerticalFieldOfView: 60)])
        XCTAssertThrowsError(try NativeBlockoutPlanProjection(snapshot: snapshot, state: incomplete, locationID: "room"))
    }

    func testPanoramaCameraContractRejectsPathNamesDuplicateViewsAndInvalidFOV() throws {
        XCTAssertNoThrow(try PipelinePanoramaStore.validate(specs: defaultFourWallPovs))
        for invalid in [PovSpec(name: "../escape", yawDegrees: 0), .init(name: "front", yawDegrees: .nan),
                        .init(name: "front", yawDegrees: 0, fovHorizontalDegrees: 180),
                        .init(name: "front", yawDegrees: 0, pitchDegrees: 91)] {
            XCTAssertThrowsError(try PipelinePanoramaStore.validate(specs: [invalid]))
        }
        XCTAssertThrowsError(try PipelinePanoramaStore.validate(specs: [defaultFourWallPovs[0], defaultFourWallPovs[0]]))
    }

    @MainActor
    func testAgentStagingCannotForgeNativePanoramaOrBlockoutBytes() throws {
        for prefix in ["", "pipeline/"] {
            for path in ["shot-planning/native-blockouts/owner.v1.json", "bible/native-panorama-selections/owner.v1.json",
                         "bible/namespace/native-panorama-owner/wide_front.png", "execution/blockout/namespace/native-owner/blockout.mov"] {
                XCTAssertThrowsError(try ToolExecutor.requirePipelineAssetCopyPath(prefix + path, source: false))
                XCTAssertThrowsError(try ToolExecutor.requirePipelineAssetCopyPath(prefix + path, source: true))
            }
        }
        XCTAssertNoThrow(try ToolExecutor.requirePipelineAssetCopyPath("bible/refs/candidate.png", source: false))
    }

    func testMOVExportCannotWriteInsideWorkingCopyOrSavedPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let working = root.appendingPathComponent("working"), saved = root.appendingPathComponent("Saved.ngv")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for target in [working.appendingPathComponent("pipeline/frames/paid.mov"), saved.appendingPathComponent("media/paid.mov")] {
            XCTAssertThrowsError(try PipelineNativeBlockoutStore.requireExportDestination(target, protectedRoots: [working, saved]))
        }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: saved)
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.requireExportDestination(alias.appendingPathComponent("paid.mov"), protectedRoots: [working, saved]))
        XCTAssertNoThrow(try PipelineNativeBlockoutStore.requireExportDestination(root.appendingPathComponent("Export.mov"), protectedRoots: [working, saved]))
    }

    @MainActor
    func testImportedBlockoutExportsActualIntervalAndRejectsMissingTrackCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mov")
        try await FullflowAcceptanceFixture.writeVideo(to: original, duration: 3, fps: 24, warm: false)
        let before = try FileDigest.sha256(of: original)
        let target = directory.appendingPathComponent("selected.mov")
        let range = CMTimeRange(start: CMTime(value: 12, timescale: 24), duration: CMTime(value: 24, timescale: 24))
        let measured = try await PipelineProductionInputMedia.exportRange(source: original, range: range, modality: .video, to: target)
        XCTAssertEqual(CMTimeCompare(measured, range.duration), 0)
        XCTAssertEqual(try FileDigest.sha256(of: original), before)
        _ = try await AVAssetImageGenerator(asset: AVURLAsset(url: target)).image(at: .zero)
        do {
            _ = try await PipelineProductionInputMedia.exportRange(source: original,
                range: CMTimeRange(start: CMTime(value: 5, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
                modality: .video, to: directory.appendingPathComponent("outside.mov"))
            XCTFail("An interval beyond the actual video track must fail.")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside.mov").path)) }
    }

    private func snapshot() throws -> BpySpatialSnapshot {
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let object: [String: Any] = ["id": "cube", "name": "Cube", "kind": "MESH", "matrixWorld": identity]
        let camera: [String: Any] = ["id": "camera", "name": "Camera", "matrixWorld": identity, "projection": identity,
            "verticalFieldOfView": 60, "near": 0.1, "far": 100, "width": 1280, "height": 720]
        let mesh: [String: Any] = ["id": "mesh", "objectID": "cube", "matrixWorld": identity,
            "positions": [[-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]], "triangles": [0, 1, 0]]
        return try JSONDecoder().decode(BpySpatialSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "schema": "bpy-spatial-snapshot/v1", "units": "METRIC", "metersPerUnit": 1,
            "frame": 0, "restFrame": 0, "framesPerSecond": 24, "timebaseNumerator": 24, "timebaseDenominator": 1,
            "objects": [object], "cameras": [camera], "meshes": [mesh], "externalPaths": []]))
    }

    private func pose(x: Double) -> [SpatialClayObjectPose] {
        let matrix = [1.0, 0, 0, x, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        return [.init(objectID: "cube", matrixWorld: matrix), .init(objectID: "camera", matrixWorld: matrix)]
    }
}
