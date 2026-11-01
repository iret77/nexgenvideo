import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum SpatialEvaluatedGeometryAcceptance {
    static func run(runtime: BpyRuntimeSession, runtimeRoot: URL, output: URL) async throws {
        try runtime.loadProjectCheckpoint(sceneRevision: nil, cancellation: .init())
        let script = try String(contentsOf: runtimeRoot.appendingPathComponent("scene_operations.py"), encoding: .utf8)
        let source = "import json\nngv_command = {'kind':'create'}\n" + script + "\n" + fixture
        let directory = output.appendingPathComponent("evaluated-deformation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: directory.appendingPathComponent("scene-program.py"), options: .atomic)
        let invalidFixtures = [
            ("second-scene", "bpy.data.scenes.new('Unposed foreign scene')"),
            ("second-view-layer", "bpy.context.scene.view_layers.new('Additional render layer')"),
            ("rest-outside-interval", "bpy.context.scene['ngv_rest_frame'] = 2")
        ]
        for (name, mutation) in invalidFixtures {
            let invalidSource = source + "\n" + mutation + "\n"
            try Data(invalidSource.utf8).write(to: directory.appendingPathComponent("negative-\(name).py"), options: .atomic)
            let rejected = try runtime.runJob(id: UUID(), expectedRevision: nil, source: invalidSource)
            defer { rejected.release() }
            try JSONEncoder().encode(rejected.response).write(to: directory.appendingPathComponent("negative-\(name).response.json"), options: .atomic)
            guard rejected.response.ok, rejected.response.state == .failed,
                  rejected.response.message == "verification rejected an invalid scene",
                  rejected.response.progress.contains(where: { $0.stage == "verification" }),
                  rejected.response.outputs.isEmpty, rejected.stagedOutputs.isEmpty else {
                throw SpatialSceneError.invalid("The invalid \(name) fixture did not return the expected verifier rejection: \(rejected.response.state?.rawValue ?? "unknown state"): \(rejected.response.message ?? "no message").")
            }
        }
        let result = try runtime.runJob(id: UUID(), expectedRevision: nil, source: source)
        defer { result.release() }
        try JSONEncoder().encode(result.response).write(to: directory.appendingPathComponent("scene-response.json"), options: .atomic)
        guard result.response.ok, result.response.state == .awaitingConfirmation else {
            throw SpatialSceneError.invalid("The deformation fixture failed: \(result.response.message ?? result.response.state?.rawValue ?? "unknown state").")
        }
        guard let preflightURL = result.stagedOutputs["simulation-preflight.json"],
              let preflightOutput = result.response.outputs.first(where: { $0.name == "simulation-preflight.json" }),
              let verificationURL = result.stagedOutputs["verification.json"] else { throw SpatialSceneError.changed }
        let preflight = try Data(contentsOf: preflightURL)
        try preflight.write(to: directory.appendingPathComponent("simulation-preflight.json"), options: .atomic)
        try Data(contentsOf: verificationURL).write(to: directory.appendingPathComponent("scene-verification.json"), options: .atomic)
        guard SpatialSceneStore.digest(preflight) == preflightOutput.sha256,
              let preflightValue = try JSONSerialization.jsonObject(with: preflight) as? [String: Any],
              preflightValue["isBaked"] as? Bool == false,
              (preflightValue["reason"] as? String)?.contains("Bake simulation caches") == true else { throw SpatialSceneError.changed }
        let revision = try SpatialSceneStore.prepare(result: result, sceneID: UUID(), name: "Deforming geometry acceptance",
            expectedHead: nil, runtimeLock: Data(contentsOf: runtimeRoot.appendingPathComponent("runtime-lock.json")),
            worker: Data(contentsOf: runtimeRoot.appendingPathComponent("worker.py")), resources: [], cancellation: .init()).revision
        defer { revision.scenePayload.releaseRuntimeSource() }
        try runtime.authenticateSpatialReceipt(revision, cancellation: .init())
        if let job = result.response.jobID { _ = try runtime.cancel(jobID: job) }
        guard let camera = revision.snapshot.cameras.first, let rig = revision.snapshot.objects.first(where: { $0.name == "RiggedMesh" }),
              let shape = revision.snapshot.objects.first(where: { $0.name == "ShapeMesh" }),
              let modifier = revision.snapshot.objects.first(where: { $0.name == "ModifierMesh" }),
              let curve = revision.snapshot.objects.first(where: { $0.name == "CurveGeometry" }) else { throw SpatialSceneError.changed }
        let state = SpatialClayState(sceneManifestSHA256: SpatialSceneStore.digest(revision.manifestData), cameraID: camera.id,
            frames: (0...1).map { frame in .init(frame: frame, objects: revision.snapshot.objects.map {
                .init(objectID: $0.id, matrixWorld: $0.matrixWorld)
            }, cameraVerticalFieldOfView: camera.verticalFieldOfView) })
        let candidate = try await SpatialEvaluatedGeometryRenderer.prepare(state: state, revision: revision,
            runtime: runtime, runtimeRoot: runtimeRoot)
        try candidate.geometry.validate(state: state, scene: revision)
        try candidate.geometry.validateFiles(candidate.files)
        try candidate.geometry.validateRecordedSources(candidate.files, state: state, scene: revision, runtimeRoot: runtimeRoot,
            scope: runtime.mediaReadScope(cancellation: .init()))
        guard let foreign = revision.snapshot.objects.first(where: { $0.name == "ForeignMesh" }),
              candidate.geometry.frames.allSatisfy({ $0.scene == "Deformation active" && $0.viewLayer == "ViewLayer"
                  && $0.sceneFrame == $0.frame && $0.meshes.allSatisfy { $0.objectID != foreign.id } }) else { throw SpatialSceneError.changed }
        func bounds(_ object: String, frame: Int) throws -> SpatialEvaluatedGeometryV1.Mesh {
            guard let value = candidate.geometry.frames[frame].meshes.first(where: { $0.objectID == object }) else { throw SpatialSceneError.changed }
            return value
        }
        let firstRig = try bounds(rig.id, frame: 0), lastRig = try bounds(rig.id, frame: 1)
        let firstShape = try bounds(shape.id, frame: 0), lastShape = try bounds(shape.id, frame: 1)
        let firstModifier = try bounds(modifier.id, frame: 0), lastModifier = try bounds(modifier.id, frame: 1)
        let curveBounds = try bounds(curve.id, frame: 0)
        guard abs(lastRig.minimum[0] - firstRig.minimum[0] - 4) < 0.0001,
              abs(lastShape.minimum[1] - firstShape.minimum[1] - 2) < 0.0001,
              curveBounds.maximum[0] - curveBounds.minimum[0] > 0.9,
              lastModifier.maximum[2] - lastModifier.minimum[2] > firstModifier.maximum[2] - firstModifier.minimum[2] + 1 else {
            throw SpatialSceneError.invalid("The evaluated plan lost bone, shape-key, modifier deformation or the native object-transform override.")
        }
        let request = SpatialClayRequest(owner: .shotPlanning, ownerArtifactSHA256: revision.manifest.sceneSHA256,
            ownerBindingSHA256: candidate.geometry.stateSHA256, cameraID: camera.id, startFrame: 0, endFrame: 1,
            width: 128, height: 128, samples: 1, stateSHA256: candidate.geometry.stateSHA256)
        let clay = try await SpatialClayRenderer.prepare(request: request, revision: revision, state: state,
            runtime: runtime, runtimeRoot: runtimeRoot, cancellation: .init())
        defer { clay.release() }
        try runtime.authenticateSpatialDerivation(clay, source: revision, cancellation: .init())
        guard let first = clay.files["clay-00000000.png"], let last = clay.files["clay-00000001.png"], first.sha256 != last.sha256 else {
            throw SpatialSceneError.invalid("Native deformation did not change the actual Clay pixels.")
        }
        for (name, bytes) in candidate.files { try bytes.write(to: directory.appendingPathComponent(name)) }
        for (name, file) in clay.files {
            try file.verify()
            try FileManager.default.copyItem(at: file.url, to: directory.appendingPathComponent(name))
        }
        try clay.proofData.write(to: directory.appendingPathComponent("clay-proof.v1.json"))
        let claySettings = try SpatialClayRenderer.renderSettings(request, state: state)
        let clayLiteral = try JSONEncoder().encode(String(decoding: claySettings, as: UTF8.self))
        let clayCommand = "import json\nngv_command = json.loads(\(String(decoding: clayLiteral, as: UTF8.self)))\n" + script
        try Data(clayCommand.utf8).write(to: directory.appendingPathComponent("clay-command.py"))
        try SpatialSceneStore.encode(state).write(to: directory.appendingPathComponent("state.v1.json"))
        try revision.manifestData.write(to: directory.appendingPathComponent("scene-manifest.v1.json"))
        try revision.scenePayload.export(to: directory.appendingPathComponent("scene.blend"), checking: {})
        try revision.snapshotData.write(to: directory.appendingPathComponent("snapshot.v1.json"))
        let plan = try NativeBlockoutPlanProjection(snapshot: revision.snapshot, snapshotData: revision.snapshotData, state: state,
            geometry: candidate.geometry, locationID: "deformation")
        try NativeBlockoutExporter.export(width: 640, height: 480, frameCount: 2,
            presentation: { CMTime(value: Int64($0), timescale: 24) }, duration: CMTime(value: 2, timescale: 24),
            to: directory.appendingPathComponent("plan.mov"), frame: plan.frame)
        let movie = directory.appendingPathComponent("plan.mov")
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard CMTimeCompare(duration, CMTime(value: 2, timescale: 24)) == 0, audioTracks.isEmpty else { throw SpatialSceneError.changed }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var pixels: [String] = []
        for index in 0...1 {
            let image = try await generator.image(at: CMTime(value: Int64(index), timescale: 24)).image
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw SpatialSceneError.changed }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw SpatialSceneError.changed }
            let bytes = data as Data
            try bytes.write(to: directory.appendingPathComponent("plan-frame-\(index).png"))
            pixels.append(SpatialSceneStore.digest(bytes))
        }
        guard pixels[0] != pixels[1] else { throw SpatialSceneError.invalid("Evaluated deformation did not change the decoded plan movie.") }
        let observed: [String: Any] = ["schema": "evaluated-geometry-acceptance/v1", "boneObjectID": rig.id,
            "shapeObjectID": shape.id, "modifierObjectID": modifier.id, "curveObjectID": curve.id, "foreignObjectID": foreign.id,
            "sourceProgramSHA256": SpatialSceneStore.digest(Data(source.utf8)), "sourceJobTimeoutSeconds": runtime.limits.timeoutSeconds,
            "simulationPreflightSHA256": SpatialSceneStore.digest(preflight),
            "clayCommandSHA256": SpatialSceneStore.digest(Data(clayCommand.utf8)),
            "geometrySHA256": SpatialSceneStore.digest(try SpatialSceneStore.encode(candidate.geometry)),
            "stateSHA256": candidate.geometry.stateSHA256, "sceneManifestSHA256": candidate.geometry.sceneManifestSHA256,
            "movieSHA256": SpatialSceneStore.digest(try Data(contentsOf: movie)), "durationValue": duration.value,
            "durationTimescale": duration.timescale, "audioTrackCount": audioTracks.count, "decodedFrameSHA256": pixels]
        try JSONSerialization.data(withJSONObject: observed, options: [.sortedKeys]).write(to: directory.appendingPathComponent("observations.v1.json"))
    }

    private static let fixture = #"""
bpy.ops.mesh.primitive_plane_add(size=1)
cache_probe = bpy.context.object
cloth_probe = cache_probe.modifiers.new('Unbaked cache probe', 'CLOTH')
cache_observation = {'isBaked':cloth_probe.point_cache.is_baked}
try:
    require_baked_cache(cloth_probe.point_cache, 0, 1)
except ValueError as error:
    cache_observation['reason'] = str(error)
else:
    raise ValueError('An actual unbaked Blender point cache was accepted')
(output_dir / 'simulation-preflight.json').write_text(json.dumps(cache_observation, sort_keys=True))
bpy.data.objects.remove(cache_probe, do_unlink=True)
bpy.ops.mesh.primitive_cube_add(size=1)
rig_mesh = bpy.context.object
rig_mesh.name = 'RiggedMesh'
armature = bpy.data.armatures.new('Rig')
rig = bpy.data.objects.new('Rig', armature)
bpy.context.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
rig.select_set(True)
bpy.ops.object.mode_set(mode='EDIT')
bone = armature.edit_bones.new('Root')
bone.head = (0,0,0)
bone.tail = (0,0,1)
bpy.ops.object.mode_set(mode='OBJECT')
group = rig_mesh.vertex_groups.new(name='Root')
group.add(list(range(len(rig_mesh.data.vertices))), 1, 'REPLACE')
modifier = rig_mesh.modifiers.new('Rig', 'ARMATURE')
modifier.object = rig
for frame, value in [(0,0), (1,4)]:
    rig.pose.bones['Root'].location.x = value
    rig.pose.bones['Root'].keyframe_insert(data_path='location', frame=frame)
    rig_mesh.location.x = value * 5
    rig_mesh.keyframe_insert(data_path='location', frame=frame)
bpy.ops.mesh.primitive_cube_add(size=1, location=(0,3,0))
shape_mesh = bpy.context.object
shape_mesh.name = 'ShapeMesh'
shape_mesh.shape_key_add(name='Basis')
key = shape_mesh.shape_key_add(name='Shift')
for vertex in key.data:
    vertex.co.y += 2
for frame, value in [(0,0), (1,1)]:
    key.value = value
    key.keyframe_insert(data_path='value', frame=frame)
bpy.ops.mesh.primitive_plane_add(size=1, location=(3,0,0))
depth_mesh = bpy.context.object
depth_mesh.name = 'ModifierMesh'
solidify = depth_mesh.modifiers.new('Depth', 'SOLIDIFY')
solidify.show_viewport = False
for frame, value in [(0,0.1), (1,2)]:
    solidify.thickness = value
    solidify.keyframe_insert(data_path='thickness', frame=frame)
curve_data = bpy.data.curves.new('Renderable curve', 'CURVE')
curve_data.dimensions = '3D'
curve_data.bevel_depth = 0.1
spline = curve_data.splines.new('POLY')
spline.points.add(1)
spline.points[0].co = (0,-2,0,1)
spline.points[1].co = (1,-2,0,1)
curve_object = bpy.data.objects.new('CurveGeometry', curve_data)
bpy.context.collection.objects.link(curve_object)
apply_command({'kind':'camera', 'name':'Plan Camera', 'matrixWorld':[[1,0,0,1],[0,0,-1,-12],[0,1,0,4],[0,0,0,1]],
               'verticalFieldOfView':1.1, 'near':0.01, 'far':100, 'width':128, 'height':128, 'frame':0, 'keyframe':False})
bpy.context.scene.name = 'Deformation active'
foreign_mesh = bpy.data.meshes.new('Foreign geometry')
foreign_mesh.from_pydata([(1000,0,0),(1001,0,0),(1000,1,0)], [], [(0,1,2)])
foreign_object = bpy.data.objects.new('ForeignMesh', foreign_mesh)
bpy.context.collection.objects.link(foreign_object)
foreign_object.hide_render = True
bpy.context.scene.frame_start = 0
bpy.context.scene.frame_end = 1
bpy.context.scene['ngv_rest_frame'] = 0
bpy.context.scene.frame_set(0)
"""#
}
