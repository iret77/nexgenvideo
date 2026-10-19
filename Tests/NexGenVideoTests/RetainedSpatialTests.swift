import AVFoundation
import BpyRuntimeProtocol
import NexGenEngine
import XCTest
@testable import NexGenVideo

final class RetainedSpatialTests: XCTestCase {
    func testPlanUsesEvaluatedBoundsAndTheSelectedCameraPose() throws {
        let snapshot = try snapshot()
        let first = pose(x: 0), moved = pose(x: 4)
        let state = SpatialClayState(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera",
            frames: [.init(frame: 0, objects: first, cameraVerticalFieldOfView: 60),
                     .init(frame: 1, objects: moved, cameraVerticalFieldOfView: 60)])
        let plan = try NativeBlockoutPlanProjection(snapshot: snapshot, snapshotData: SpatialSceneStore.encode(snapshot), state: state, geometry: geometry(state: state, centers: [0, 4]), locationID: "room")
        let start = try plan.frame(0), end = try plan.frame(1)
        XCTAssertEqual(end.shapes[0].center.x - start.shapes[0].center.x, 4, accuracy: 0.000001)
        XCTAssertEqual(end.cameras[0].position.x - start.cameras[0].position.x, 4, accuracy: 0.000001)
        let incomplete = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: "camera",
            frames: [.init(frame: 0, objects: [first[1]], cameraVerticalFieldOfView: 60)])
        XCTAssertThrowsError(try NativeBlockoutPlanProjection(snapshot: snapshot, snapshotData: SpatialSceneStore.encode(snapshot), state: incomplete,
            geometry: geometry(state: incomplete, centers: [0]), locationID: "room"))
    }

    func testPlanConsumesPerFrameDeformedBoundsWithAnUnchangedObjectMatrix() throws {
        let scene = try snapshot(), objects = pose(x: 0)
        let state = SpatialClayState(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera",
            frames: [.init(frame: 0, objects: objects, cameraVerticalFieldOfView: 1),
                     .init(frame: 1, objects: objects, cameraVerticalFieldOfView: 1)])
        let value = try NativeBlockoutPlanProjection(snapshot: scene, snapshotData: SpatialSceneStore.encode(scene), state: state,
            geometry: geometry(state: state, centers: [0, 5]), locationID: "room")
        XCTAssertEqual(try value.frame(1).shapes[0].center.x - value.frame(0).shapes[0].center.x, 5, accuracy: 0.000001)
        XCTAssertEqual(try value.frame(1).cameras[0].position, value.frame(0).cameras[0].position)
        XCTAssertEqual(value.layout.widthMeters, 7, accuracy: 0.000001)
        XCTAssertTrue(try value.frame(0).metric)
        let baseline = try geometry(state: state, centers: [0, 5])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SpatialSceneStore.encode(baseline)) as? [String: Any])
        json["stateSHA256"] = String(repeating: "f", count: 64)
        let bad = try JSONDecoder().decode(SpatialEvaluatedGeometryV1.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try NativeBlockoutPlanProjection(snapshot: scene, snapshotData: SpatialSceneStore.encode(scene), state: state, geometry: bad, locationID: "room"))
    }

    func testPlanRejectsForeignSnapshotDuplicateInstancesAndUnappliedNativeTransforms() throws {
        let scene = try snapshot(), objects = pose(x: 0)
        let bytes = try SpatialSceneStore.encode(scene)
        let state = SpatialClayState(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera",
            frames: [.init(frame: 0, objects: objects, cameraVerticalFieldOfView: 1)])
        let value = try geometry(state: state, centers: [0])
        _ = try NativeBlockoutPlanProjection(snapshot: scene, snapshotData: bytes, state: state, geometry: value, locationID: "room")
        for fault in ["camera", "object", "duplicate"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SpatialSceneStore.encode(value)) as? [String: Any])
            var frames = try XCTUnwrap(json["frames"] as? [[String: Any]])
            if fault == "camera" {
                var matrix = try XCTUnwrap(frames[0]["cameraMatrix"] as? [Double]); matrix[3] += 3
                frames[0]["cameraMatrix"] = matrix
            } else if fault == "object" {
                var poses = try XCTUnwrap(frames[0]["objects"] as? [[String: Any]])
                var matrix = try XCTUnwrap(poses[0]["matrixWorld"] as? [Double]); matrix[3] += 3
                poses[0]["matrixWorld"] = matrix; frames[0]["objects"] = poses
            } else {
                var meshes = try XCTUnwrap(frames[0]["meshes"] as? [[String: Any]])
                meshes.append(try XCTUnwrap(meshes.first)); frames[0]["meshes"] = meshes
            }
            json["frames"] = frames
            let changed = try JSONDecoder().decode(SpatialEvaluatedGeometryV1.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try NativeBlockoutPlanProjection(snapshot: scene, snapshotData: bytes, state: state,
                geometry: changed, locationID: "room"))
        }
        var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        altered["metersPerUnit"] = 0.25
        let alteredData = try JSONSerialization.data(withJSONObject: altered)
        XCTAssertThrowsError(try NativeBlockoutPlanProjection(snapshot: scene, snapshotData: alteredData, state: state,
            geometry: value, locationID: "room"))
    }

    func testPlanConvertsRawBlenderBoundsToMetersExactlyOnce() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SpatialSceneStore.encode(snapshot())) as? [String: Any])
        json["metersPerUnit"] = 0.25
        let scene = try JSONDecoder().decode(BpySpatialSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        let objects = pose(x: 0)
        let state = SpatialClayState(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera",
            frames: [.init(frame: 0, objects: objects, cameraVerticalFieldOfView: 1),
                     .init(frame: 1, objects: objects, cameraVerticalFieldOfView: 1)])
        let plan = try NativeBlockoutPlanProjection(snapshot: scene, snapshotData: SpatialSceneStore.encode(scene), state: state,
            geometry: geometry(state: state, centers: [0, 5], sourceSnapshot: scene), locationID: "room")
        XCTAssertEqual(try plan.frame(1).shapes[0].center.x - plan.frame(0).shapes[0].center.x, 1.25, accuracy: 0.000001)
        XCTAssertEqual(plan.layout.widthMeters, 1.75, accuracy: 0.000001)
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

    func testPanoramaSourceNameCannotCollideWithAViewAndNativePrefixIsExact() throws {
        XCTAssertNoThrow(try PipelinePanoramaStore.validate(specs: [.init(name: "panorama", yawDegrees: 0)]))
        let nested = try Location(id: "room", name: "Room", visualPrompt: "Room.", referenceImages: ["fixture.png"],
            scene3d: .init(panorama: "bible/native-panorama-x/sub/image.png"))
        XCTAssertFalse(PipelinePanoramaStore.hasNativeSelection(nested))
        XCTAssertTrue(try PipelinePanoramaStore.references(location: nested,
            dataRoot: FileManager.default.temporaryDirectory).isEmpty)
    }

    func testAllInvalidPanoramaLocationsAreCollectedInBibleOrder() throws {
        let locations = try ["first", "second"].map { id in
            try Location(id: id, name: id, visualPrompt: "Room.",
                attributes: [PipelinePanoramaStore.receiptPathKey: "bible/native-panorama-selections/" + id + ".v1.json"],
                referenceImages: ["fixture.png"])
        }
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture", locations: locations)
        XCTAssertEqual(try PipelinePanoramaStore.invalidSelections(in: bible,
            dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), locations)
    }

    func testBrokenPanoramaReceiptDoesNotBlockUnrelatedAppearanceButCannotLaunderCopiedGeometry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString.lowercased()
        let outputs = root.appendingPathComponent("bible/" + UUID().uuidString.lowercased() + "/native-panorama-" + id)
        let receipts = root.appendingPathComponent("bible/native-panorama-selections")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let geometry = Data("isolated protected-output fixture".utf8)
        try geometry.write(to: outputs.appendingPathComponent("source.panorama"))
        try Data("broken receipt".utf8).write(to: receipts.appendingPathComponent(id + ".v1.json"))
        XCTAssertThrowsError(try PipelinePanoramaStore.requirePurpose(sha256: FileDigest.sha256(of: geometry), geometry: false, dataRoot: root))
        XCTAssertNoThrow(try PipelinePanoramaStore.requirePurpose(sha256: FileDigest.sha256(of: Data("unrelated appearance".utf8)), geometry: false, dataRoot: root))
    }

    func testBibleEntityIDsAreGloballyUniqueBeforeProvenance() throws {
        let character = try Character(id: "room", name: "Person", visualPrompt: "Person.", sheets: ["front": "fixture.png"])
        let location = try Location(id: "room", name: "Room", visualPrompt: "Room.", referenceImages: ["fixture.png"])
        XCTAssertThrowsError(try Bible(project: "fixture", generated: "fixture", generator: "fixture",
            characters: [character], locations: [location]))
    }

    func testBibleGateRejectsOrphanPanoramaReceiptEvenWithoutPanoramaPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try YAMLArtifactStore(dataRoot: root).save(ProjectMeta(project: "fixture", mode: .generic), to: PipelineLayout.projectFile)
        try savePipelineAssetProof(.init(project: "fixture", scope: "bible"), dataRoot: root)
        let location = try Location(id: "room", name: "Room", visualPrompt: "A room.", referenceImages: ["fixture.png"])
        var bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture", locations: [location])
        XCTAssertNoThrow(try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root, validateVariants: false))
        bible.locations[0].attributes[PipelinePanoramaStore.receiptPathKey] = "bible/native-panorama-selections/missing.v1.json"
        XCTAssertThrowsError(try PipelineProductionAssetEvidence.requireBible(bible, dataRoot: root, validateVariants: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("panorama assignment"))
        }
    }

    func testAgentCannotCreateNativePanoramaWhenBibleIsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let location = try Location(id: "room", name: "Room", visualPrompt: "A room.",
            attributes: [PipelinePanoramaStore.receiptPathKey: "bible/native-panorama-selections/" + id + ".v1.json",
                         PipelinePanoramaStore.receiptHashKey: String(repeating: "a", count: 64)],
            referenceImages: ["fixture.png"], scene3d: .init(panorama: "bible/namespace/native-panorama-" + id + "/panorama.png", povs: [], provider: "native-import"))
        let candidate = try Bible(project: "fixture", generated: "fixture", generator: "fixture", look: .init(), locations: [location])
        XCTAssertThrowsError(try PipelinePanoramaStore.requireAgentPreservesNativeSelection(candidate, dataRoot: root))
        XCTAssertNoThrow(try PipelinePanoramaStore.requireAgentPreservesNativeSelection(
            try Bible(project: "fixture", generated: "fixture", generator: "fixture", look: .init()), dataRoot: root))
    }

    func testInvalidPanoramaOffersLocationSpecificRecoveryWithoutAcceptingItsReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let location = try Location(id: "room", name: "Pale room", visualPrompt: "A room.",
            attributes: [PipelinePanoramaStore.receiptPathKey: "bible/native-panorama-selections/missing.v1.json"])
        XCTAssertTrue(PipelinePanoramaStore.hasNativeSelection(location))
        XCTAssertThrowsError(try PipelinePanoramaStore.references(location: location, dataRoot: root)) { error in
            guard let error = error as? GateBlocked else { return XCTFail("Expected a native recovery error.") }
            XCTAssertTrue(error.message.contains("Pale room"))
            XCTAssertTrue(error.message.contains("bible/native-panorama-selections/missing.v1.json"))
            XCTAssertTrue(error.message.contains("remove the invalid assignment"))
        }
    }

    @MainActor
    func testBibleFixturePreservesNativeAttributesInTheRealToolSchema() throws {
        let location = try Location(id: "room", name: "Room", visualPrompt: "A room.",
            attributes: [PipelinePanoramaStore.receiptPathKey: "bible/native-panorama-selections/owner.v1.json",
                         PipelinePanoramaStore.receiptHashKey: String(repeating: "a", count: 64)],
            sheets: ["appearance": "bible/namespace/appearance.png"])
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture", locations: [location])
        let arguments = try ProductionBibleToolFixture.arguments(bible)
        let schema = try XCTUnwrap(ToolDefinitions.all.first(where: { $0.name == .writeBible })?.inputSchema)
        XCTAssertNoThrow(try validateToolInput(in: arguments, against: schema, path: "write_bible"))
        let encoded = try XCTUnwrap((arguments["locations"] as? [[String: Any]])?.first)
        let attributes = try XCTUnwrap(encoded["attributes"] as? [[String: String]])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: attributes.map { ($0["key"]!, $0["value"]!) }), location.attributes)
        XCTAssertEqual(encoded["sheets"] as? [[String: String]], [["view": "appearance", "path": "bible/namespace/appearance.png"]])
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
        let cameraObject: [String: Any] = ["id": "camera", "name": "Camera", "kind": "CAMERA", "matrixWorld": identity]
        let camera: [String: Any] = ["id": "camera", "name": "Camera", "matrixWorld": identity, "projection": identity,
            "verticalFieldOfView": 60, "near": 0.1, "far": 100, "width": 1280, "height": 720]
        let mesh: [String: Any] = ["id": "mesh", "objectID": "cube", "matrixWorld": identity,
            "positions": [[-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]], "triangles": [0, 1, 0]]
        return try JSONDecoder().decode(BpySpatialSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "schema": "bpy-spatial-snapshot/v1", "units": "meters", "metersPerUnit": 1,
            "frame": 0, "restFrame": 0, "framesPerSecond": 24, "timebaseNumerator": 24, "timebaseDenominator": 1,
            "objects": [object, cameraObject], "cameras": [camera], "meshes": [mesh], "externalPaths": []]))
    }

    private func pose(x: Double) -> [SpatialClayObjectPose] {
        let matrix = [1.0, 0, 0, x, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        return [.init(objectID: "cube", matrixWorld: matrix), .init(objectID: "camera", matrixWorld: matrix)]
    }

    private func geometry(state: SpatialClayState, centers: [Double], sourceSnapshot: BpySpatialSnapshot? = nil) throws -> SpatialEvaluatedGeometryV1 {
        let frames = try zip(state.frames, centers).map { pair in
            let camera = try XCTUnwrap(pair.0.objects.first { $0.objectID == "camera" })
            return SpatialEvaluatedGeometryV1.Frame(frame: pair.0.frame,
                meshes: [.init(id: "mesh", objectID: "cube", minimum: [pair.1 - 1, -1, -1], maximum: [pair.1 + 1, 1, 1])],
                cameraMatrix: camera.matrixWorld,
                metersPerUnit: sourceSnapshot?.metersPerUnit ?? 1, objects: pair.0.objects)
        }
        return .init(schema: "spatial-evaluated-geometry/v1", sceneManifestSHA256: state.sceneManifestSHA256,
            sceneSHA256: String(repeating: "b", count: 64), stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)),
            workerSHA256: "", scriptSHA256: "", runtimeLockSHA256: "", runtimeBinarySHA256: "", chunks: [], frames: frames,
            snapshotSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(sourceSnapshot ?? snapshot())))
    }
}
