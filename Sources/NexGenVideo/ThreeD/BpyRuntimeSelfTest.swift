import BpyRuntimeProtocol
import Darwin
import Foundation

private final class BpySelfTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<BpyRuntimeJobResult, Error>?

    func store(_ result: Result<BpyRuntimeJobResult, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> Result<BpyRuntimeJobResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum BpyRuntimeSelfTest {
    static func runIfRequested() {
        guard let outputPath = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"],
              !outputPath.isEmpty else { return }
        do {
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let evidence = try run(output: output)
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
            FileHandle.standardOutput.write(Data("SELFTEST_BPY_OK\n".utf8))
            Darwin.exit(0)
        } catch {
            let message = "SELFTEST_BPY_FAIL \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(1)
        }
    }

    private static func run(output: URL) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let deniedPaths = try deniedPathList(environment)
        let deniedJSON = try JSONSerialization.data(withJSONObject: deniedPaths)
        let deniedLiteral = String(decoding: deniedJSON, as: UTF8.self)
        guard let approvedPath = environment["NGV_BPY_APPROVED_INPUT_DIR"] else {
            throw BpyRuntimeError.invalidInput("NGV_BPY_APPROVED_INPUT_DIR is required.")
        }
        let approvedDirectory = URL(fileURLWithPath: approvedPath, isDirectory: true)
        let approvedInput = try BpyApprovedInputCopy(
            approvedDirectory: approvedDirectory,
            filename: "fixture.json"
        )
        let sessionA = BpyRuntimeSession(
            documentID: "acceptance-document-a",
            serviceName: bpyRuntimeServiceNames[0]
        )
        let sessionB = BpyRuntimeSession(
            documentID: "acceptance-document-b",
            serviceName: bpyRuntimeServiceNames[1]
        )
        defer {
            sessionA.close()
            sessionB.close()
        }
        let readyA = try sessionA.ready()
        let readyB = try sessionB.ready()
        guard readyA.runtime?.processIdentifier != readyB.runtime?.processIdentifier else {
            throw BpyRuntimeError.invalidOutput("Two documents shared one bpy process.")
        }

        let warmID = UUID()
        let warmStarted = Date()
        let warm = try sessionA.runJob(
            id: warmID,
            expectedRevision: nil,
            source: "metrics['warm_probe'] = 1.0"
        )
        let warmJobSeconds = Date().timeIntervalSince(warmStarted)
        guard warm.response.state == .awaitingConfirmation else {
            throw BpyRuntimeError.invalidOutput("The warm worker probe did not complete.")
        }
        _ = try sessionA.confirm(jobID: warmID, revision: "warm-probe")

        let firstID = UUID()
        let first = try sessionA.runJob(
            id: firstID,
            expectedRevision: "warm-probe",
            source: acceptanceSceneSource(deniedPaths: deniedLiteral),
            inputs: [approvedInput],
            timeoutSeconds: 120
        )
        guard first.response.state == .awaitingConfirmation,
              first.stagedOutputs["scene.blend"] != nil,
              let render = first.stagedOutputs["render.png"],
              let runtimeEvidence = first.stagedOutputs["evidence.json"] else {
            throw BpyRuntimeError.invalidOutput("The acceptance scene did not produce its real outputs.")
        }
        try FileManager.default.copyItem(
            at: render,
            to: output.appendingPathComponent("perspective.png")
        )
        try FileManager.default.copyItem(
            at: runtimeEvidence,
            to: output.appendingPathComponent("worker-evidence.json")
        )
        let workerEvidence = try JSONSerialization.jsonObject(
            with: Data(contentsOf: runtimeEvidence)
        )
        guard let workerEvidenceObject = workerEvidence as? [String: Any],
              let firstSessionRoot = workerEvidenceObject["session_root"] as? String else {
            throw BpyRuntimeError.invalidOutput("The worker omitted its sandbox session identity.")
        }
        let firstSessionRootLiteral = String(
            decoding: try JSONEncoder().encode(firstSessionRoot),
            as: UTF8.self
        )
        _ = try sessionA.confirm(jobID: firstID, revision: "revision-a")

        let duplicate = try sessionA.runJob(
            id: firstID,
            expectedRevision: nil,
            source: "raise RuntimeError('duplicate job executed')"
        )
        guard duplicate.response.state == .confirmed,
              duplicate.response.joinedExistingJob else {
            throw BpyRuntimeError.invalidOutput("A duplicate Job ID was not joined.")
        }

        for unsafeName in ["symlink.json", "hardlink.json"] {
            let unsafeInput = try BpyApprovedInputCopy(
                approvedDirectory: approvedDirectory,
                filename: unsafeName
            )
            do {
                _ = try sessionB.runJob(
                    id: UUID(),
                    expectedRevision: nil,
                    source: "pass",
                    inputs: [unsafeInput]
                )
                throw BpyRuntimeError.invalidOutput("Unsafe input \(unsafeName) crossed the boundary.")
            } catch let error as BpyRuntimeError {
                guard case .invalidInput(_) = error else { throw error }
            }
        }

        let secondDocumentID = UUID()
        let secondDocument = try sessionB.runJob(
            id: secondDocumentID,
            expectedRevision: nil,
            source: """
            import json
            import os
            mesh = bpy.data.meshes.new('DocumentBMesh')
            obj = bpy.data.objects.new('DocumentBOnly', mesh)
            bpy.context.scene.collection.objects.link(obj)
            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1.0)
            bm.to_mesh(mesh)
            bm.free()
            try:
                os.listdir(\(firstSessionRootLiteral))
                cross_session_denied = False
            except OSError as error:
                cross_session_denied = {'denied': True, 'errno': error.errno}
            (output_dir / 'cross-session.json').write_text(
                json.dumps({'cross_session_denied': cross_session_denied})
            )
            """
        )
        guard secondDocument.response.state == .awaitingConfirmation,
              let crossSessionURL = secondDocument.stagedOutputs["cross-session.json"],
              let crossSessionEvidence = try JSONSerialization.jsonObject(
                with: Data(contentsOf: crossSessionURL)
              ) as? [String: Any],
              let denied = crossSessionEvidence["cross_session_denied"] as? [String: Any],
              denied["denied"] as? Bool == true,
              let denialErrno = denied["errno"] as? Int,
              [Int(EPERM), Int(EACCES)].contains(denialErrno) else {
            throw BpyRuntimeError.invalidOutput("The second document did not execute independently.")
        }
        _ = try sessionB.confirm(jobID: secondDocumentID, revision: "document-b-revision")

        let timeoutID = UUID()
        let timedOut = try sessionA.runJob(
            id: timeoutID,
            expectedRevision: "revision-a",
            source: "while True: pass",
            timeoutSeconds: 2
        )
        guard timedOut.response.state == .timedOut else {
            throw BpyRuntimeError.invalidOutput("The infinite job did not time out.")
        }

        let afterTimeoutID = UUID()
        let afterTimeout = try sessionA.runJob(
            id: afterTimeoutID,
            expectedRevision: "revision-a",
            source: inspectionSource(label: "after-timeout")
        )
        try assertRecovered(afterTimeout, label: "timeout")
        _ = try sessionA.confirm(jobID: afterTimeoutID, revision: "revision-b")

        let cancelID = UUID()
        let cancelBox = BpySelfTestBox()
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            cancelBox.store(Result {
                try sessionA.runJob(
                    id: cancelID,
                    expectedRevision: "revision-b",
                    source: "while True: pass",
                    timeoutSeconds: 30
                )
            })
            cancelled.signal()
        }
        let cancelDeadline = Date().addingTimeInterval(10)
        while Date() < cancelDeadline {
            if (try? sessionA.status(jobID: cancelID).state) == .running { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = try sessionA.cancel(jobID: cancelID)
        guard cancelled.wait(timeout: .now() + 10) == .success,
              let cancelOutcome = cancelBox.load(),
              case .success(let cancelResult) = cancelOutcome,
              cancelResult.response.state == .cancelled else {
            throw BpyRuntimeError.invalidOutput("Cancellation did not stop the active job.")
        }

        let crashID = UUID()
        let crashed = try sessionA.runJob(
            id: crashID,
            expectedRevision: "revision-b",
            source: "import os; os._exit(91)"
        )
        guard crashed.response.state == .crashed else {
            throw BpyRuntimeError.invalidOutput("The worker crash was not reported.")
        }

        let afterCrashID = UUID()
        let afterCrash = try sessionA.runJob(
            id: afterCrashID,
            expectedRevision: "revision-b",
            source: inspectionSource(label: "after-crash")
        )
        try assertRecovered(afterCrash, label: "crash")

        sessionA.close()
        sessionB.close()
        return [
            "schema": "nexgenvideo/bpy-runtime-acceptance/1",
            "python": readyA.runtime?.pythonVersion ?? "",
            "bpy": readyA.runtime?.bpyVersion ?? "",
            "sandboxed": readyA.runtime?.sandboxed ?? false,
            "workerA": readyA.runtime?.processIdentifier ?? -1,
            "workerB": readyB.runtime?.processIdentifier ?? -1,
            "coldStartSeconds": readyA.metrics["cold_start_seconds"] ?? -1,
            "warmJobSeconds": warmJobSeconds,
            "jobMetrics": first.response.metrics,
            "timeoutState": timedOut.response.state?.rawValue ?? "",
            "cancelState": cancelResult.response.state?.rawValue ?? "",
            "crashState": crashed.response.state?.rawValue ?? "",
            "duplicateJoined": duplicate.response.joinedExistingJob,
            "sessionsClosed": true,
            "crossSessionDenied": true,
            "workerEvidence": workerEvidence,
        ]
    }

    private static func deniedPathList(_ environment: [String: String]) throws -> [String] {
        guard let raw = environment["NGV_BPY_DENIED_PATHS"],
              let data = raw.data(using: .utf8),
              let paths = try JSONSerialization.jsonObject(with: data) as? [String],
              paths.count >= 3 else {
            throw BpyRuntimeError.invalidInput("NGV_BPY_DENIED_PATHS requires secret, canonical, and foreign paths.")
        }
        return paths
    }

    private static func acceptanceSceneSource(deniedPaths: String) -> String {
        """
        import json
        import os
        import socket
        import time

        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = bpy.context.scene
        mesh = bpy.data.meshes.new('NGV_RoomMesh')
        room = bpy.data.objects.new('NGV_Room', mesh)
        scene.collection.objects.link(room)
        bm = bmesh.new()
        created = bmesh.ops.create_cube(bm, size=4.0)
        bmesh.ops.bevel(
            bm,
            geom=[edge for edge in bm.edges],
            offset=0.12,
            segments=3,
            affect='EDGES',
        )
        bm.to_mesh(mesh)
        bm.free()
        room.scale = (1.8, 1.2, 0.75)
        modifier = room.modifiers.new(name='NGV_BevelModifier', type='BEVEL')
        modifier.width = 0.04
        modifier.segments = 2

        for index in range(6):
            bpy.ops.mesh.primitive_cube_add(location=(-1.8 + index * 0.45, -0.4, -1.25 + index * 0.22))
            step = bpy.context.object
            step.name = f'NGV_Stair_{index:02d}'
            step.scale = (0.22, 0.8, 0.11)
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, location=(1.15, 0.55, -0.55))
        bpy.context.object.name = 'NGV_AsymmetricProp'

        clay = bpy.data.materials.new('NGV_Clay')
        clay.diffuse_color = (0.55, 0.58, 0.62, 1.0)
        for obj in scene.objects:
            if obj.type == 'MESH':
                obj.data.materials.append(clay)

        camera_data = bpy.data.cameras.new('NGV_PerspectiveCamera')
        camera = bpy.data.objects.new('NGV_PerspectiveCamera', camera_data)
        scene.collection.objects.link(camera)
        camera.location = (8.5, -9.0, 6.2)
        direction = mathutils.Vector((0.0, 0.0, -0.4)) - camera.location
        camera.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        camera_data.lens = 42
        scene.camera = camera

        light_data = bpy.data.lights.new('NGV_Key', type='AREA')
        light_data.energy = 1300
        light_data.shape = 'DISK'
        light_data.size = 5
        light = bpy.data.objects.new('NGV_Key', light_data)
        scene.collection.objects.link(light)
        light.location = (2.0, -3.0, 7.0)
        scene.world.color = (0.04, 0.04, 0.04)

        scene.render.resolution_x = 640
        scene.render.resolution_y = 360
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = 'PNG'
        scene.render.filepath = str(output_dir / 'render.png')
        renderer = {'requested': 'CYCLES_METAL', 'selected': '', 'devices': [], 'fallback': None}
        render_started = time.monotonic()
        try:
            cycles = bpy.context.preferences.addons['cycles'].preferences
            cycles.compute_device_type = 'METAL'
            cycles.get_devices()
            renderer['devices'] = [
                {'name': item.name, 'type': item.type} for item in cycles.devices
            ]
            metal = [item for item in cycles.devices if item.type == 'METAL']
            if not metal:
                raise RuntimeError('no Metal Cycles device')
            for item in cycles.devices:
                item.use = item in metal
            scene.render.engine = 'CYCLES'
            scene.cycles.device = 'GPU'
            scene.cycles.samples = 8
            renderer['selected'] = 'CYCLES_METAL'
            bpy.ops.render.render(write_still=True)
        except Exception as error:
            renderer['fallback'] = f'{type(error).__name__}: {error}'
            scene.render.engine = 'CYCLES'
            scene.cycles.device = 'CPU'
            scene.cycles.samples = 8
            renderer['selected'] = 'CYCLES_CPU'
            bpy.ops.render.render(write_still=True)
        metrics['render_seconds'] = time.monotonic() - render_started

        denied = {}
        for path in \(deniedPaths):
            try:
                with open(path, 'rb') as handle:
                    handle.read(1)
                denied[path] = False
            except OSError as error:
                denied[path] = {'denied': True, 'errno': error.errno}
        try:
            connection = socket.create_connection(('1.1.1.1', 443), timeout=1)
            connection.close()
            network_denied = False
        except OSError as error:
            network_denied = {'denied': True, 'errno': error.errno}

        autorun = bpy.data.texts.new('NGV_AutorunProbe.py')
        autorun.write("import bpy\\nbpy.data.objects.new('AUTORUN_RAN', None)\\n")
        autorun.use_module = True
        evidence = {
            'renderer': renderer,
            'denied_paths': denied,
            'network_denied': network_denied,
            'secret_environment_absent': all(
                name not in os.environ
                for name in ('RUNWAY_API_KEY', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'NGV_TEST_SECRET')
            ),
            'python_executable': os.path.realpath(os.sys.executable),
            'bpy_module': os.path.realpath(bpy.__file__),
            'session_root': str(session_root),
            'blender_user_config': os.environ.get('BLENDER_USER_CONFIG'),
            'objects': sorted(obj.name for obj in scene.objects),
            'modifiers': {
                obj.name: [modifier.type for modifier in obj.modifiers]
                for obj in scene.objects if obj.modifiers
            },
            'approved_input': json.loads((input_dir / 'fixture.json').read_text()),
        }
        (output_dir / 'evidence.json').write_text(json.dumps(evidence, sort_keys=True))
        """
    }

    private static func inspectionSource(label: String) -> String {
        """
        import json
        names = sorted(obj.name for obj in bpy.context.scene.objects)
        if 'NGV_Room' not in names or 'DocumentBOnly' in names or 'AUTORUN_RAN' in names:
            raise RuntimeError(f'confirmed scene isolation failed: {names}')
        (output_dir / '\(label).json').write_text(json.dumps({'objects': names}))
        """
    }

    private static func assertRecovered(_ result: BpyRuntimeJobResult, label: String) throws {
        let expectedName = label == "timeout" ? "after-timeout.json" : "after-crash.json"
        guard result.response.state == .awaitingConfirmation,
              result.stagedOutputs[expectedName] != nil else {
            throw BpyRuntimeError.invalidOutput("The worker did not restore the confirmed scene after \(label).")
        }
    }
}
