import AVFoundation
import BpyRuntimeProtocol
import CoreGraphics
import ImageIO
import Foundation

nonisolated enum SpatialSceneRuntimeAcceptance {
    static func run(serviceName: String, output: URL) async throws -> [String: Bool] {
        try await Task.detached {
            let runtime = BpyRuntimeSession(documentID: "spatial-native-acceptance", serviceName: serviceName)
            defer { runtime.close() }
            let root = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BpyRuntime")
            let operations = try String(contentsOf: root.appendingPathComponent("scene_operations.py"), encoding: .utf8)
            let lock = try Data(contentsOf: root.appendingPathComponent("runtime-lock.json"))
            let worker = try Data(contentsOf: root.appendingPathComponent("worker.py"))
            let create = "import json\nngv_command = {'kind': 'create'}\n" + operations
            let exported = try runtime.runJob(id: UUID(), expectedRevision: nil, source: create + "\n" + exportFixture)
            guard let json = exported.stagedOutputs["fixture.json"],
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: String],
                  let text = value["glb"], let bytes = Data(base64Encoded: text) else {
                throw SpatialSceneError.invalid("The native GLB fixture could not be exported.")
            }
            if let id = exported.response.jobID { _ = try runtime.cancel(jobID: id) }
            let resource = SpatialSceneResource(id: UUID(), filename: "fixture.glb", sha256: SpatialSceneStore.digest(bytes), byteCount: bytes.count)
            let staging = output.appendingPathComponent("spatial-input")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let filename = "resource-" + resource.id.uuidString + ".glb"
            try bytes.write(to: staging.appendingPathComponent(filename))
            let source = create + "\nngv_fixture_filename = '" + filename + "'\n" + authoringFixture
            let result = try runtime.runJob(id: UUID(), expectedRevision: nil, source: source,
                                           inputs: [try .init(approvedDirectory: staging, filename: filename)])
            let revision = try SpatialSceneStore.prepare(result: result, sceneID: UUID(), name: "Native location",
                expectedHead: nil, runtimeLock: lock, worker: worker, resources: [(resource, bytes)]).revision
            try runtime.authenticateSpatialReceipt(revision)
            guard let camera = revision.snapshot.cameras.first(where: { $0.name == "Camera A" }),
                  let second = revision.snapshot.cameras.first(where: { $0.name == "Camera B" }),
                  camera.width == 128, camera.height == 128, second.width == 256, second.height == 128,
                  revision.snapshot.frame == 2, revision.snapshot.restFrame == 1,
                  revision.snapshot.timebaseNumerator == 24_000, revision.snapshot.timebaseDenominator == 1_001,
                  let cube = revision.snapshot.objects.first(where: { $0.name == "ImportedBox" }) else {
                throw SpatialSceneError.invalid("Native camera, frame, or GLB authoring did not persist.")
            }
            if let id = result.response.jobID { _ = try runtime.cancel(jobID: id) }
            let frames = (1...2).map { frame in
                SpatialClayStateFrame(frame: frame, objects: revision.snapshot.objects.map { object in
                    var matrix = object.matrixWorld
                    if object.id == cube.id { matrix[3] = frame == 1 ? 4 : 0; matrix[7] = 0; matrix[11] = 0 }
                    return SpatialClayObjectPose(objectID: object.id, matrixWorld: matrix)
                }, cameraVerticalFieldOfView: camera.verticalFieldOfView)
            }
            let state = SpatialClayState(sceneManifestSHA256: SpatialSceneStore.digest(revision.manifestData), cameraID: camera.id, frames: frames)
            let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: String(repeating: "a", count: 64),
                ownerBindingSHA256: String(repeating: "b", count: 64), cameraID: camera.id, startFrame: 1, endFrame: 2,
                width: 128, height: 128, samples: 8, stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)))
            let candidate = try await SpatialClayRenderer.prepare(request: request, revision: revision, state: state,
                                                                   runtime: runtime, runtimeRoot: root)
            try runtime.authenticateSpatialDerivation(candidate, source: revision)
            guard let first = candidate.files["clay-00000001.png"], let secondFrame = candidate.files["clay-00000002.png"],
                  candidate.files["clay.mov"] != nil else { throw SpatialSceneError.invalid("Native Clay output is incomplete.") }
            let animatedFirst = try await SpatialClayRenderer.preview(revision: revision, cameraID: camera.id, frame: 1,
                runtime: runtime, runtimeRoot: root, jobID: UUID(), isCancelled: { false })
            let animatedSecond = try await SpatialClayRenderer.preview(revision: revision, cameraID: camera.id, frame: 2,
                runtime: runtime, runtimeRoot: root, jobID: UUID(), isCancelled: { false })
            let firstCenter = try centerLuminance(first), secondCenter = try centerLuminance(secondFrame)
            guard abs(firstCenter - (try centerLuminance(animatedFirst))) > 12,
                  abs(secondCenter - (try centerLuminance(animatedSecond))) > 12,
                  abs(firstCenter - secondCenter) > 12 else {
                throw SpatialSceneError.invalid("Resolved shot state did not change rendered pixels from the animated scene.")
            }
            for (name, data) in candidate.files { try data.write(to: output.appendingPathComponent(name)) }
            try candidate.proofData.write(to: output.appendingPathComponent("spatial-proof.json"))
            try await verifyCompleteShot(revision: revision, cameraID: camera.id, fieldOfView: camera.verticalFieldOfView,
                cubeID: cube.id, runtime: runtime, runtimeRoot: root, output: output)
            try await SpatialEvaluatedGeometryAcceptance.run(runtime: runtime, runtimeRoot: root, output: output)
            guard runtime.close() else { throw SpatialSceneError.invalid("Native scene cleanup failed.") }
            return ["glbImport": true, "quaternionKeyframes": true, "viewedFrameEdit": true,
                    "cameraDimensions": true, "stableRestFrame": true, "resourceReceipt": true,
                    "resolvedStatePixels": true, "fractionalTimebaseMovie": true, "derivationAuthentication": true,
                    "completeShotSequence": true, "partialLastFrame": true, "sequenceTamperingRejected": true,
                    "sequenceDiscardRevokes": true, "sequenceExtraChunkRejected": true, "evaluatedDeformationBounds": true]
        }.value
    }

    private static func verifyCompleteShot(revision: SpatialSceneRevision, cameraID: String, fieldOfView: Double,
                                          cubeID: String, runtime: BpyRuntimeSession, runtimeRoot: URL, output: URL) async throws {
        let state = SpatialClayState(sceneManifestSHA256: SpatialSceneStore.digest(revision.manifestData), cameraID: cameraID,
            frames: (0...240).map { frame in
                .init(frame: frame, objects: revision.snapshot.objects.map { object in
                    var matrix = object.matrixWorld
                    if object.id == cubeID { matrix[3] = frame.isMultiple(of: 2) ? 0 : 4; matrix[7] = 0; matrix[11] = 0 }
                    return .init(objectID: object.id, matrixWorld: matrix)
                }, cameraVerticalFieldOfView: fieldOfView)
            })
        let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: String(repeating: "c", count: 64),
            ownerBindingSHA256: String(repeating: "d", count: 64), cameraID: cameraID, startFrame: 0, endFrame: 240,
            width: 384, height: 384, samples: 1, stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)))
        let candidate = try await SpatialClayRenderer.prepareSequence(request: request, revision: revision, state: state,
            timing: .init(numerator: 240_741, denominator: 24_000), runtime: runtime, runtimeRoot: runtimeRoot)
        defer { candidate.discard() }
        try runtime.authenticateSpatialSequence(candidate, source: revision)
        guard candidate.proof.chunks.count > 1, candidate.proof.chunks.first?.startFrame == 0,
              candidate.proof.chunks.last?.endFrame == 240, let movie = candidate.files["clay.mov"],
              let first = candidate.files["clay-00000000.png"], let second = candidate.files["clay-00000001.png"],
              abs(try centerLuminance(Data(contentsOf: first)) - centerLuminance(Data(contentsOf: second))) > 12 else {
            throw SpatialSceneError.invalid("The native full-shot sequence lost its resolved state or frame range.")
        }
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              CMTimeCompare(try await asset.load(.duration), CMTime(value: 240_741, timescale: 24_000)) == 0 else {
            throw SpatialSceneError.invalid("The native full shot was rounded to whole scene frames.")
        }
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(samples) else { throw SpatialSceneError.changed }
        reader.add(samples)
        guard reader.startReading() else { throw SpatialSceneError.changed }
        defer { if reader.status == .reading { reader.cancelReading() } }
        for index in 0...240 {
            guard let sample = samples.copyNextSampleBuffer(),
                  CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(index) * 1_001, timescale: 24_000)) == 0,
                  CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: index == 240 ? 501 : 1_001, timescale: 24_000)) == 0 else {
                throw SpatialSceneError.invalid("The native full shot changed a frame timestamp or its partial last sample.")
            }
        }
        guard samples.copyNextSampleBuffer() == nil, reader.status == .completed else { throw SpatialSceneError.changed }
        let proof = candidate.proof
        let extraName = "chunk-00000241.json"
        let extraURL = first.deletingLastPathComponent().appendingPathComponent(extraName)
        let extraID = UUID()
        guard let originalProofURL = candidate.files[proof.chunks[0].proofFilename],
              var json = try JSONSerialization.jsonObject(with: Data(contentsOf: originalProofURL)) as? [String: Any],
              var extraRequest = json["request"] as? [String: Any],
              var extraState = json["state"] as? [String: Any] else { throw SpatialSceneError.changed }
        extraRequest["startFrame"] = 241; extraRequest["endFrame"] = 240
        extraState["frames"] = [] as [Any]
        json["request"] = extraRequest; json["state"] = extraState; json["jobID"] = extraID.uuidString
        let extraProof = try JSONDecoder().decode(SpatialDerivationProof.self, from: JSONSerialization.data(withJSONObject: json))
        let extraData = try SpatialSceneStore.encode(extraProof)
        try extraData.write(to: extraURL)
        let extra = SpatialClaySequenceChunk(proofFilename: extraName, proofSHA256: SpatialSceneStore.digest(extraData),
            movieFilename: nil, startFrame: 241, endFrame: 240, jobID: extraID, jobFingerprint: extraProof.jobFingerprint)
        var malformedFiles = candidate.files
        malformedFiles[extraName] = extraURL
        let metadata = SpatialClayOutput(filename: extraName, sha256: extra.proofSHA256, byteCount: extraData.count,
                                         width: 0, height: 0, frameCount: 0, mediaKind: "application/json")
        let malformed = SpatialClaySequenceProof(id: proof.id, request: proof.request, state: proof.state, scene: proof.scene,
            timing: proof.timing, timebaseNumerator: proof.timebaseNumerator, timebaseDenominator: proof.timebaseDenominator,
            chunks: proof.chunks + [extra], outputs: proof.outputs + [metadata])
        var extraRejected = false
        do {
            try SpatialClayRenderer.validateSequence(proofData: SpatialSceneStore.encode(malformed),
                                                      files: malformedFiles, against: revision)
        } catch { extraRejected = true }
        guard extraRejected else { throw SpatialSceneError.invalid("An extra out-of-range Clay chunk was accepted.") }
        let original = try Data(contentsOf: first)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path)
        try Data(contentsOf: second).write(to: first)
        var rejected = false
        do { try runtime.authenticateSpatialSequence(candidate, source: revision) } catch { rejected = true }
        try original.write(to: first)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: first.path)
        guard rejected else { throw SpatialSceneError.invalid("A substituted sequence frame retained its host authentication.") }
        try runtime.authenticateSpatialSequence(candidate, source: revision)
        let evidence = output.appendingPathComponent("complete-shot")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
        for (name, file) in candidate.files { try FileManager.default.copyItem(at: file, to: evidence.appendingPathComponent(name)) }
        try candidate.proofData.write(to: evidence.appendingPathComponent("proof.json"))
        candidate.discard()
        rejected = false
        do { try runtime.authenticateSpatialSequence(candidate, source: revision) } catch { rejected = true }
        guard rejected, !candidate.isAvailable else { throw SpatialSceneError.invalid("Discard did not revoke the sequence receipt.") }
    }

    private static func centerLuminance(_ data: Data) throws -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let crop = image.cropping(to: CGRect(x: CGFloat(image.width / 2 - 4), y: CGFloat(image.height / 2 - 4), width: 8, height: 8)) else {
            throw SpatialSceneError.invalid("The native render comparison image is unreadable.")
        }
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw SpatialSceneError.invalid("The native render comparison surface is unavailable.")
            }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return Double(stride(from: 0, to: pixels.count, by: 4).reduce(0) {
            $0 + Int(pixels[$1]) + Int(pixels[$1 + 1]) + Int(pixels[$1 + 2])
        }) / Double(8 * 8 * 3)
    }

    private static let exportFixture = #"""
import base64
bpy.ops.mesh.primitive_cube_add(size=1)
bpy.context.object.name = "ImportedBox"
path = output_dir / "fixture.glb"
bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB")
(output_dir / "fixture.json").write_text(json.dumps({"glb": base64.b64encode(path.read_bytes()).decode()}))
path.unlink()
"""#

    private static let authoringFixture = #"""
apply_command({"kind": "import_glb", "filename": ngv_fixture_filename})
box = bpy.data.objects.get("ImportedBox")
assert box and box.rotation_mode == 'QUATERNION'
box['ngv_object_id'] = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
identity = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
rotated = [[0,-1,0,4],[1,0,0,0],[0,0,1,0],[0,0,0,1]]
for frame, matrix in [(1, identity), (2, rotated)]:
    apply_command({"kind":"transform", "objectID":box['ngv_object_id'], "matrixWorld":matrix, "frame":frame, "keyframe":True})
bpy.context.scene.frame_set(1)
assert abs(box.matrix_world[0][0] - 1) < 1e-5
bpy.context.scene.frame_set(2)
assert abs(box.matrix_world[0][0]) < 1e-5 and abs(box.matrix_world[0][3] - 4) < 1e-5
try:
    apply_command({"kind":"transform", "objectID":box['ngv_object_id'], "matrixWorld":identity, "frame":2, "keyframe":False})
    raise AssertionError('animated pose edit silently accepted')
except ValueError:
    pass
child = bpy.data.objects.new('Child', None)
bpy.context.scene.collection.objects.link(child)
child.parent = box
child['ngv_object_id'] = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
bpy.context.scene.frame_set(1)
apply_command({"kind":"transform", "objectID":child['ngv_object_id'], "matrixWorld":identity, "frame":2, "keyframe":False})
bpy.context.view_layer.update()
assert bpy.context.scene.frame_current == 2 and abs(child.matrix_world[0][3]) < 1e-5
world = [[1,0,0,0],[0,0,-1,-6],[0,1,0,0],[0,0,0,1]]
for name, width in [('Camera A', 128), ('Camera B', 256)]:
    apply_command({"kind":"camera", "name":name, "matrixWorld":world, "verticalFieldOfView":math.pi/3,
                   "near":0.01, "far":100, "width":width, "height":128, "frame":2, "keyframe":False})
bpy.context.scene.render.fps = 24
bpy.context.scene.render.fps_base = 1.001
"""#
}
