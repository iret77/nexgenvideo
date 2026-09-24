import AppKit
import BpyRuntimeProtocol
import Darwin
import Foundation

private final class BpySelfTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<BpyRuntimeJobResult, Error>?

    func store(_ value: Result<BpyRuntimeJobResult, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() -> Result<BpyRuntimeJobResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class BpyBoundaryReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: Data?
    private var error: Error?

    func store(response: Data) {
        lock.lock()
        self.response = response
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func load() -> (Data?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (response, error)
    }
}

@MainActor
enum BpyRuntimeSelfTest {
    private static var pendingResult: [String: Any]?
    private static var outputDirectory: URL?
    private static var retainedProjects: [VideoProject] = []

    static func scheduleIfRequested() {
        if let outputPath = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY_BOUNDARY"],
           !outputPath.isEmpty {
            DispatchQueue.main.async {
                do {
                    try runBoundaryProbe(outputPath: outputPath)
                    FileHandle.standardOutput.write(Data("SELFTEST_BPY_BOUNDARY_OK\n".utf8))
                    Darwin.exit(0)
                } catch {
                    FileHandle.standardError.write(
                        Data("SELFTEST_BPY_BOUNDARY_FAIL \(error.localizedDescription)\n".utf8)
                    )
                    Darwin.exit(1)
                }
            }
            return
        }
        if let mode = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY_HOST_CRASH"],
           ["before-authorization", "after-authorization"].contains(mode) {
            DispatchQueue.main.async {
                do {
                    try runHostCrashProbe(mode: mode)
                } catch {
                    FileHandle.standardError.write(
                        Data("SELFTEST_BPY_HOST_CRASH_FAIL \(error.localizedDescription)\n".utf8)
                    )
                    Darwin.exit(1)
                }
            }
            return
        }
        guard let outputPath = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"],
              !outputPath.isEmpty else {
            return
        }
        DispatchQueue.main.async {
            do {
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                outputDirectory = output
                pendingResult = try run(output: output)
                NSApp.terminate(nil)
            } catch {
                let message = "SELFTEST_BPY_FAIL \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                Darwin.exit(1)
            }
        }
    }

    private static func runBoundaryProbe(outputPath: String) throws {
        let connection = NSXPCConnection(serviceName: bpyRuntimeServiceNames[0])
        connection.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        let box = BpyBoundaryReplyBox()
        let finished = DispatchSemaphore(value: 0)
        connection.resume()
        defer { connection.invalidate() }
        guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
            box.store(error: error)
            finished.signal()
        }) as? BpyRuntimeServiceProtocol else {
            throw BpyRuntimeError.unavailable("The boundary XPC service is unavailable.")
        }
        let nonce = UUID()
        service.runBoundaryProbe(
            try JSONEncoder().encode(BpyBoundaryProbeRequest(nonce: nonce))
        ) { response in
            box.store(response: response)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 20) == .success else {
            throw BpyRuntimeError.timedOut
        }
        let value = box.load()
        if let error = value.1 { throw error }
        guard let data = value.0 else {
            throw BpyRuntimeError.invalidOutput("The boundary probe returned no result.")
        }
        let result = try JSONDecoder().decode(BpyBoundaryProbeResult.self, from: data)
        let permissionErrors = [Int32(EPERM), Int32(EACCES)]
        guard result.schema == "nexgenvideo/bpy-boundary-probe/1",
              result.nonce == nonce,
              result.serviceProcessIdentifier > 1,
              result.supervisorProcessIdentifier > 1,
              result.childProcessIdentifier > 1,
              Set([
                result.serviceProcessIdentifier,
                result.supervisorProcessIdentifier,
              result.childProcessIdentifier,
              ]).count == 3,
              result.serviceStartAbsoluteTime > 0,
              result.supervisorParentProcessIdentifier == result.serviceProcessIdentifier,
              result.supervisorStartAbsoluteTime > 0,
              result.childStartAbsoluteTime > 0,
              result.childParentProcessIdentifier == result.supervisorProcessIdentifier,
              result.allowedWriteSucceeded,
              permissionErrors.contains(result.outsideWriteDeniedErrno),
              [Int32(EPERM), Int32(EAGAIN)].contains(result.forkDeniedErrno),
              permissionErrors.contains(result.networkDeniedErrno),
              result.signalDeniedErrnos.count == 3,
              result.signalDeniedErrnos.allSatisfy({ permissionErrors.contains($0) }),
              result.unlinkedBytesObserved >= 1_024 * 1_024,
              result.unlinkedLimitReason == "disk",
              result.cleanupSupervisorGone,
              result.cleanupChildGone,
              result.healthyFollowupSucceeded else {
            throw BpyRuntimeError.invalidOutput("The signed boundary probe did not prove every denial and cleanup invariant.")
        }
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static func runHostCrashProbe(mode: String) throws {
        let project = VideoProject()
        retainedProjects = [project]
        project.makeWindowControllers()
        guard let session = BpyRuntimeHost.shared.session(for: project) else {
            throw BpyRuntimeError.unavailable("The crash probe could not reserve a runtime slot.")
        }
        _ = try session.ready()
        let jobID = UUID()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? session.runJob(
                id: jobID,
                expectedRevision: nil,
                source: """
                import os
                import sys
                os.execv(sys.executable, [sys.executable, '-I', '-c', 'import time; time.sleep(120)'])
                """,
                timeoutSeconds: 120,
                diagnosticDeferExecutionAuthorization: mode == "before-authorization"
            )
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let response = try? session.status(jobID: jobID),
               response.state == .running,
               response.activeProcessIdentifier.map({ $0 > 1 }) == true {
                if mode == "before-authorization",
                   response.activeProcessAuthorizationID != nil,
                   response.activeWorkerProcessIdentifier == nil {
                    _ = Darwin.kill(getpid(), SIGKILL)
                }
                if mode == "after-authorization",
                   response.activeProcessAuthorizationID == nil,
                   response.activeWorkerProcessIdentifier.map({ $0 > 1 }) == true {
                    _ = Darwin.kill(getpid(), SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw BpyRuntimeError.timedOut
    }

    static func applicationWillTerminate() {
        guard var result = pendingResult, let outputDirectory else { return }
        result["appDelegateShutdown"] = true
        result["hostPeakMemoryBytes"] = hostPeakMemoryBytes()
        do {
            let data = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(
                to: outputDirectory.appendingPathComponent("result.json"),
                options: .atomic
            )
            FileHandle.standardOutput.write(Data("SELFTEST_BPY_OK\n".utf8))
        } catch {
            let message = "SELFTEST_BPY_FAIL \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    private static func run(output: URL) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let deniedPaths = try deniedPathList(environment)
        let positiveControls = try deniedPaths.map {
            let data = try Data(contentsOf: URL(fileURLWithPath: $0))
            guard !data.isEmpty else {
                throw BpyRuntimeError.invalidInput("A denied-path positive control is empty.")
            }
            return ["path": $0, "bytes": data.count] as [String: Any]
        }
        guard let approvedPath = environment["NGV_BPY_APPROVED_INPUT_DIR"] else {
            throw BpyRuntimeError.invalidInput("NGV_BPY_APPROVED_INPUT_DIR is required.")
        }
        let approvedDirectory = URL(fileURLWithPath: approvedPath, isDirectory: true)
        let approvedInput = try BpyApprovedInputCopy(
            approvedDirectory: approvedDirectory,
            filename: "fixture.json"
        )
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: approvedDirectory.appendingPathComponent("fixture.json"))
        ) as? [String: Bool]
        guard fixture?["approved"] == true else {
            throw BpyRuntimeError.invalidInput("The approved-input positive control is invalid.")
        }

        let earlyCloseProject = VideoProject()
        earlyCloseProject.makeWindowControllers()
        guard let earlyCloseSession = BpyRuntimeHost.shared.session(for: earlyCloseProject) else {
            throw BpyRuntimeError.invalidOutput("The close-before-open lifecycle could not reserve a slot.")
        }
        let earlyCloseBox = BpySelfTestBox()
        let earlyCloseFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            earlyCloseBox.store(Result {
                let response = try earlyCloseSession.ready()
                return BpyRuntimeJobResult(response: response, stagedOutputs: [:])
            })
            earlyCloseFinished.signal()
        }
        Thread.sleep(forTimeInterval: 0.01)
        earlyCloseProject.close()
        guard earlyCloseFinished.wait(timeout: .now() + 10) == .success,
              earlyCloseBox.load() != nil else {
            throw BpyRuntimeError.invalidOutput("Close-before-open did not settle the client call.")
        }

        let failedProject = VideoProject()
        failedProject.makeWindowControllers()
        guard let failedOpen = BpyRuntimeHost.shared.session(
            for: failedProject,
            diagnosticOpenFailure: true
        ) else {
            throw BpyRuntimeError.invalidOutput("The failed-open lifecycle could not reserve a slot.")
        }
        do {
            _ = try failedOpen.ready()
            throw BpyRuntimeError.invalidOutput("The failed-open probe unexpectedly became ready.")
        } catch let error as BpyRuntimeError {
            guard case .unavailable(_) = error else { throw error }
        }

        let projectA = VideoProject()
        let projectB = VideoProject()
        let projectC = VideoProject()
        retainedProjects = [earlyCloseProject, failedProject, projectA, projectB, projectC]
        projectA.makeWindowControllers()
        projectB.makeWindowControllers()
        projectC.makeWindowControllers()
        guard !projectA.windowControllers.isEmpty,
              !projectB.windowControllers.isEmpty,
              !projectC.windowControllers.isEmpty,
              let sessionA = BpyRuntimeHost.shared.session(for: projectA),
              let sessionB = BpyRuntimeHost.shared.session(for: projectB),
              BpyRuntimeHost.shared.session(for: projectC) == nil else {
            throw BpyRuntimeError.invalidOutput("The real document lifecycle did not enforce two slots.")
        }
        failedProject.close()

        let coldStarted = Date()
        let readyA = try sessionA.ready()
        let coldStartSeconds = Date().timeIntervalSince(coldStarted)
        let readyB = try sessionB.ready()
        guard readyA.runtime?.processIdentifier != readyB.runtime?.processIdentifier,
              readyA.runtime?.serviceProcessIdentifier != readyB.runtime?.serviceProcessIdentifier else {
            throw BpyRuntimeError.invalidOutput("Two documents shared a bpy service identity.")
        }

        let warmID = UUID()
        let warmStarted = Date()
        let warm = try sessionA.runJob(
            id: warmID,
            expectedRevision: nil,
            source: "pass"
        )
        let warmJobSeconds = Date().timeIntervalSince(warmStarted)
        guard warm.response.state == .awaitingConfirmation else {
            throw BpyRuntimeError.invalidOutput("The warm filesystem-cache probe did not complete.")
        }
        _ = try sessionA.confirm(jobID: warmID, revision: "warm-probe")

        let firstID = UUID()
        let firstSource = acceptanceSceneSource()
        let firstStarted = Date()
        let first = try sessionA.runJob(
            id: firstID,
            expectedRevision: "warm-probe",
            source: firstSource,
            inputs: [approvedInput],
            timeoutSeconds: 120,
            diagnosticDeniedPaths: deniedPaths,
            diagnosticAutoexecPositiveControl: true
        )
        let hostJobSeconds = Date().timeIntervalSince(firstStarted)
        guard first.response.state == .awaitingConfirmation,
              first.stagedOutputs["scene.blend"] != nil,
              let render = first.stagedOutputs["render.png"],
              let verificationURL = first.stagedOutputs["verification.json"] else {
            throw BpyRuntimeError.invalidOutput("The acceptance scene did not produce verified outputs.")
        }
        let verification = try verificationObject(verificationURL)
        try assertVerification(
            verification,
            deniedPaths: deniedPaths,
            expectedObject: "NGV_Room"
        )
        try FileManager.default.copyItem(
            at: render,
            to: output.appendingPathComponent("perspective.png")
        )
        try FileManager.default.copyItem(
            at: verificationURL,
            to: output.appendingPathComponent("trusted-verification.json")
        )
        guard let firstSessionRoot = verification["sessionRoot"] as? String else {
            throw BpyRuntimeError.invalidOutput("Trusted verification omitted the session root.")
        }
        _ = try sessionA.confirm(jobID: firstID, revision: "revision-a")

        let duplicate = try sessionA.runJob(
            id: firstID,
            expectedRevision: "warm-probe",
            source: firstSource,
            inputs: [approvedInput],
            timeoutSeconds: 120,
            diagnosticDeniedPaths: deniedPaths,
            diagnosticAutoexecPositiveControl: true
        )
        guard duplicate.response.state == .confirmed,
              duplicate.response.joinedExistingJob else {
            throw BpyRuntimeError.invalidOutput("An exact duplicate Job ID was not joined.")
        }
        do {
            _ = try sessionA.runJob(
                id: firstID,
                expectedRevision: "warm-probe",
                source: "bpy.data.objects.new('MUTATED_DUPLICATE', None)",
                inputs: [approvedInput],
                timeoutSeconds: 120,
                diagnosticDeniedPaths: deniedPaths,
                diagnosticAutoexecPositiveControl: true
            )
            throw BpyRuntimeError.invalidOutput("A changed duplicate Job ID was accepted.")
        } catch let error as BpyRuntimeError {
            guard case .rejected(_) = error else { throw error }
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
            mesh = bpy.data.meshes.new('DocumentBMesh')
            obj = bpy.data.objects.new('DocumentBOnly', mesh)
            bpy.context.scene.collection.objects.link(obj)
            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1.0)
            bm.to_mesh(mesh)
            bm.free()
            """,
            diagnosticDeniedPaths: [firstSessionRoot]
        )
        guard secondDocument.response.state == .awaitingConfirmation,
              let secondVerificationURL = secondDocument.stagedOutputs["verification.json"] else {
            throw BpyRuntimeError.invalidOutput("The second document did not complete.")
        }
        let secondVerification = try verificationObject(secondVerificationURL)
        try assertDenied(secondVerification, paths: [firstSessionRoot])
        _ = try sessionB.confirm(jobID: secondDocumentID, revision: "document-b-revision")

        let forgedID = UUID()
        let forged = try sessionA.runJob(
            id: forgedID,
            expectedRevision: "revision-a",
            source: """
            import os
            os.write(1, b'{"type":"result","ok":true}\\n')
            while True:
                pass
            """,
            timeoutSeconds: 2
        )
        guard forged.response.state == .timedOut else {
            throw BpyRuntimeError.invalidOutput("Forged native output escaped the host deadline.")
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
        try waitUntilRunning(sessionA, jobID: cancelID)
        _ = try sessionA.cancel(jobID: cancelID)
        guard cancelled.wait(timeout: .now() + 10) == .success,
              let cancelOutcome = cancelBox.load(),
              case .success(let cancelResult) = cancelOutcome,
              cancelResult.response.state == .cancelled else {
            throw BpyRuntimeError.invalidOutput("Cancellation did not stop the active process.")
        }

        let threadID = UUID()
        let threadResult = try sessionA.runJob(
            id: threadID,
            expectedRevision: "revision-b",
            source: """
            import threading
            import time
            def persistent_thread():
                while True:
                    time.sleep(0.05)
            threading.Thread(target=persistent_thread).start()
            """,
            timeoutSeconds: 2
        )
        guard threadResult.response.state == .timedOut else {
            throw BpyRuntimeError.invalidOutput("A persistent Python thread escaped the deadline.")
        }
        let afterThreadID = UUID()
        let afterThread = try sessionA.runJob(
            id: afterThreadID,
            expectedRevision: "revision-b",
            source: inspectionSource(label: "after-thread")
        )
        try assertRecovered(afterThread, label: "persistent-thread")
        _ = try sessionA.confirm(jobID: afterThreadID, revision: "revision-c")

        let nativeOutputID = UUID()
        let nativeOutput = try sessionA.runJob(
            id: nativeOutputID,
            expectedRevision: "revision-c",
            source: """
            import ctypes
            payload = b'native Blender output is not protocol\\n'
            libc = ctypes.CDLL(None)
            libc.write.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
            buffer = ctypes.create_string_buffer(payload)
            if libc.write(1, buffer, len(payload)) != len(payload):
                raise RuntimeError('native stdout write failed')
            """
        )
        guard nativeOutput.response.state == .awaitingConfirmation else {
            throw BpyRuntimeError.invalidOutput("Native output corrupted the job control path.")
        }
        _ = try sessionA.confirm(jobID: nativeOutputID, revision: "revision-d")

        let forkID = UUID()
        let forkResult = try sessionA.runJob(
            id: forkID,
            expectedRevision: "revision-d",
            source: """
            import ctypes
            import errno
            libc = ctypes.CDLL(None, use_errno=True)
            child = libc.fork()
            if child != -1 or ctypes.get_errno() not in (errno.EAGAIN, errno.EPERM):
                raise RuntimeError(f'fork was not kernel-blocked: child={child}, errno={ctypes.get_errno()}')
            bpy.data.objects.new('FORK_BLOCKED', None)
            """
        )
        guard forkResult.response.state == .awaitingConfirmation,
              forkResult.response.metrics["descendant_peak_count"] == 0 else {
            throw BpyRuntimeError.invalidOutput("The kernel process limit did not block fork.")
        }
        _ = try sessionA.confirm(jobID: forkID, revision: "revision-e")

        let memoryID = UUID()
        let memory = try sessionA.runJob(
            id: memoryID,
            expectedRevision: "revision-e",
            source: """
            try:
                payload = bytearray(7 * 1024 * 1024 * 1024)
            except MemoryError:
                bpy.data.objects.new('RLIMIT_AS_ALLOCATION_DENIED', None)
            else:
                raise RuntimeError('7 GiB allocation bypassed the 6 GiB address-space limit')
            """,
            timeoutSeconds: 30
        )
        guard memory.response.state == .awaitingConfirmation,
              let memoryVerificationURL = memory.stagedOutputs["verification.json"],
              let memoryNames = try verificationObject(memoryVerificationURL)["objectNames"] as? [String],
              memoryNames.contains("RLIMIT_AS_ALLOCATION_DENIED") else {
            throw BpyRuntimeError.invalidOutput("The Darwin RLIMIT_AS probe did not deny the allocation.")
        }
        _ = try sessionA.cancel(jobID: memoryID)

        let outOfMemory = try sessionA.runJob(
            id: UUID(),
            expectedRevision: "revision-e",
            source: "payload = bytearray(7 * 1024 * 1024 * 1024)",
            timeoutSeconds: 30
        )
        guard outOfMemory.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Address-space exhaustion was not resource-limited.")
        }

        let crashID = UUID()
        let crashed = try sessionA.runJob(
            id: crashID,
            expectedRevision: "revision-e",
            source: "import os; os._exit(91)"
        )
        guard crashed.response.state == .crashed else {
            throw BpyRuntimeError.invalidOutput("The worker crash was not reported.")
        }

        let identityWriteFailure = try sessionA.runJob(
            id: UUID(),
            expectedRevision: "revision-e",
            source: "import time; time.sleep(120)",
            timeoutSeconds: 30,
            diagnosticSupervisorIdentityWriteFailure: true
        )
        guard identityWriteFailure.response.state == .failed else {
            throw BpyRuntimeError.invalidOutput(
                "The injected supervisor identity-write failure was not reported."
            )
        }
        let afterIdentityWriteFailureID = UUID()
        let afterIdentityWriteFailure = try sessionA.runJob(
            id: afterIdentityWriteFailureID,
            expectedRevision: "revision-e",
            source: inspectionSource(
                label: "after-supervisor-identity-write-failure",
                requiredObject: "FORK_BLOCKED"
            )
        )
        try assertRecovered(afterIdentityWriteFailure, label: "supervisor identity-write failure")
        _ = try sessionA.cancel(jobID: afterIdentityWriteFailureID)

        let identityCaptureFailure = try sessionA.runJob(
            id: UUID(),
            expectedRevision: "revision-e",
            source: "import time; time.sleep(120)",
            timeoutSeconds: 30,
            diagnosticSupervisorIdentityCaptureFailure: true
        )
        guard identityCaptureFailure.response.state == .failed else {
            throw BpyRuntimeError.invalidOutput(
                "The injected supervisor identity-capture failure was not reported."
            )
        }
        let afterIdentityCaptureFailureID = UUID()
        let afterIdentityCaptureFailure = try sessionA.runJob(
            id: afterIdentityCaptureFailureID,
            expectedRevision: "revision-e",
            source: inspectionSource(
                label: "after-supervisor-identity-capture-failure",
                requiredObject: "FORK_BLOCKED"
            )
        )
        try assertRecovered(afterIdentityCaptureFailure, label: "supervisor identity-capture failure")
        _ = try sessionA.cancel(jobID: afterIdentityCaptureFailureID)

        let parentDeathID = UUID()
        let parentDeathSource = """
        import os
        import sys
        os.execv(sys.executable, [sys.executable, '-I', '-c', 'import time; time.sleep(120)'])
        """
        let parentDeathBox = BpySelfTestBox()
        let parentDeathFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            parentDeathBox.store(Result {
                try sessionA.runJob(
                    id: parentDeathID,
                    expectedRevision: "revision-e",
                    source: parentDeathSource,
                    timeoutSeconds: 30
                )
            })
            parentDeathFinished.signal()
        }
        try waitUntilRunning(sessionA, jobID: parentDeathID)
        guard let servicePID = readyA.runtime?.serviceProcessIdentifier,
              servicePID > 1, Darwin.kill(servicePID, SIGKILL) == 0,
              parentDeathFinished.wait(timeout: .now() + 10) == .success,
              let parentDeathOutcome = parentDeathBox.load(),
              case .failure = parentDeathOutcome else {
            throw BpyRuntimeError.invalidOutput("The service-kill recovery probe could not start.")
        }
        Thread.sleep(forTimeInterval: 0.5)
        let reopened = try sessionA.ready()
        guard reopened.confirmedRevision == "revision-e",
              reopened.runtime?.serviceProcessIdentifier != servicePID else {
            throw BpyRuntimeError.invalidOutput("The host checkpoint was not restored after service death.")
        }
        do {
            _ = try sessionA.runJob(
                id: parentDeathID,
                expectedRevision: "revision-e",
                source: parentDeathSource,
                timeoutSeconds: 30
            )
            throw BpyRuntimeError.invalidOutput("An uncertain pre-recovery Job ID ran again.")
        } catch let error as BpyRuntimeError {
            guard case .rejected(_) = error else { throw error }
        }
        let afterServiceKillID = UUID()
        let afterServiceKill = try sessionA.runJob(
            id: afterServiceKillID,
            expectedRevision: "revision-e",
            source: inspectionSource(
                label: "after-service-kill",
                requiredObject: "FORK_BLOCKED"
            )
        )
        try assertRecovered(afterServiceKill, label: "service-kill")

        let originalSlot = sessionA.serviceName
        projectA.close()

        let constrained = BpyRuntimeSession(
            documentID: "acceptance-resource-limits",
            limits: BpyRuntimeLimits(
                timeoutSeconds: 30,
                memoryBytes: 6 * 1_024 * 1_024 * 1_024,
                inputBytes: 1_024 * 1_024,
                outputBytes: 2 * 1_024 * 1_024,
                stdoutBytes: 65_536,
                objects: 1,
                vertices: 8,
                polygons: 8,
                diskBytes: 2 * 1_024 * 1_024,
                files: 64,
                renderWidth: 128,
                renderHeight: 128,
                renderPixels: 16_384
            ),
            serviceName: originalSlot
        )
        _ = try constrained.ready()
        let containerScope = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            import errno
            import os
            import signal
            sibling = session_root.parent / 'hostile-container-sibling'
            try:
                sibling.write_bytes(b'escaped')
            except OSError as error:
                if error.errno not in (errno.EPERM, errno.EACCES):
                    raise
            else:
                raise RuntimeError('worker wrote outside its per-process Seatbelt root')
            for attempted_signal in (0, signal.SIGSTOP, signal.SIGKILL):
                try:
                    os.kill(os.getppid(), attempted_signal)
                except OSError as error:
                    if error.errno not in (errno.EPERM, errno.EACCES):
                        raise
                else:
                    raise RuntimeError(
                        f'worker signalled its native supervisor with {attempted_signal}'
                    )
            bpy.data.objects.new('CONTAINER_SIBLING_AND_SIGNAL_BLOCKED', None)
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard containerScope.response.state == .awaitingConfirmation,
              let containerVerificationURL = containerScope.stagedOutputs["verification.json"],
              let containerNames = try verificationObject(containerVerificationURL)["objectNames"] as? [String],
              containerNames.contains("CONTAINER_SIBLING_AND_SIGNAL_BLOCKED") else {
            throw BpyRuntimeError.invalidOutput("The per-process OS write scope was not enforced.")
        }
        guard let containerScopeID = containerScope.response.jobID else {
            throw BpyRuntimeError.invalidOutput("The OS-boundary probe omitted its Job ID.")
        }
        _ = try constrained.cancel(jobID: containerScopeID)
        let signalRecovery = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard signalRecovery.response.state == .awaitingConfirmation,
              let signalRecoveryID = signalRecovery.response.jobID else {
            throw BpyRuntimeError.invalidOutput(
                "The supervisor did not recover after the signal-denial probe."
            )
        }
        _ = try constrained.cancel(jobID: signalRecoveryID)
        let structuralLimit = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            bpy.ops.mesh.primitive_cube_add(location=(0, 0, 0))
            bpy.ops.mesh.primitive_cube_add(location=(2, 0, 0))
            bpy.context.scene.render.resolution_x = 256
            bpy.context.scene.render.resolution_y = 256
            """
        )
        guard structuralLimit.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Evaluated geometry/render limits were not terminal.")
        }
        let renderOnlyGeometry = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            bpy.ops.mesh.primitive_plane_add()
            target = bpy.context.object
            target.hide_viewport = True
            modifier = target.modifiers.new('NGV_RENDER_ONLY_ARRAY', 'ARRAY')
            modifier.count = 3
            modifier.show_viewport = False
            modifier.show_render = True
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard renderOnlyGeometry.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Render-only hidden geometry escaped verification.")
        }
        let secondarySceneGeometry = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            scene = bpy.data.scenes.new('NGV_SECONDARY_RENDER_SCENE')
            mesh = bpy.data.meshes.new('NGV_SECONDARY_RENDER_MESH')
            mesh.from_pydata([(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)], [], [(0, 1, 2, 3)])
            target = bpy.data.objects.new('NGV_SECONDARY_RENDER_OBJECT', mesh)
            scene.collection.objects.link(target)
            modifier = target.modifiers.new('NGV_SECONDARY_ARRAY', 'ARRAY')
            modifier.count = 3
            scene.render.resolution_x = 64
            scene.render.resolution_y = 64
            """
        )
        guard secondarySceneGeometry.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Secondary-scene geometry escaped verification.")
        }
        let storageLimit = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            package = output_dir / 'HostileFixture.app' / 'Contents' / 'Resources'
            package.mkdir(parents=True)
            for index in range(70):
                (package / f'overflow-{index:02d}.json').write_bytes(b'x')
            """
        )
        guard storageLimit.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Aggregate disk/file limits were not terminal.")
        }
        let aggregateBytes = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            import os
            home = Path(os.environ['HOME'])
            (home / 'large.bin').write_bytes(b'x' * 1800000)
            (home / 'aggregate.bin').write_bytes(b'x' * 500000)
            """
        )
        guard aggregateBytes.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Aggregate bytes outside outputs were not terminal.")
        }
        let unlinkedStorage = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            import os
            handles = []
            for index in range(2):
                path = Path(os.environ['HOME']) / f'unlinked-{index}.bin'
                handle = open(path, 'wb')
                os.unlink(path)
                handle.write(b'x' * 1400000)
                handle.flush()
                os.fsync(handle.fileno())
                handles.append(handle)
            while True:
                pass
            """,
            timeoutSeconds: 5
        )
        guard unlinkedStorage.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Open unlinked vnodes escaped the disk limit.")
        }
        let healthyChurn = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            import os
            import threading
            import time
            home = Path(os.environ['HOME'])
            def churn():
                deadline = time.monotonic() + 0.5
                index = 0
                while time.monotonic() < deadline:
                    source = home / f'churn-{index % 2}.part'
                    destination = home / f'churn-{index % 2}.tmp'
                    source.write_bytes(b'x' * 4096)
                    os.replace(source, destination)
                    destination.unlink()
                    index += 1
            thread = threading.Thread(target=churn)
            thread.start()
            thread.join()
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard healthyChurn.response.state == .awaitingConfirmation,
              let healthyChurnID = healthyChurn.response.jobID else {
            throw BpyRuntimeError.invalidOutput("Legitimate rename/delete churn failed the resource scan.")
        }
        _ = try constrained.cancel(jobID: healthyChurnID)
        let scanError = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            import os
            blocked = Path(os.environ['HOME']) / 'unreadable'
            blocked.mkdir()
            (blocked / 'payload').write_bytes(b'x')
            blocked.chmod(0)
            while True:
                pass
            """,
            timeoutSeconds: 5
        )
        guard scanError.response.state == .crashed else {
            throw BpyRuntimeError.invalidOutput("A resource-scan error did not fail closed.")
        }
        let afterResourceFailure = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard afterResourceFailure.response.state == .awaitingConfirmation else {
            throw BpyRuntimeError.invalidOutput("The resource supervisor did not recover for a healthy job.")
        }
        guard let recoveredJobID = afterResourceFailure.response.jobID else {
            throw BpyRuntimeError.invalidOutput("The healthy resource probe omitted its Job ID.")
        }
        _ = try constrained.cancel(jobID: recoveredJobID)
        constrained.close()

        guard let reusedSession = BpyRuntimeHost.shared.session(for: projectC),
              reusedSession.serviceName == originalSlot else {
            throw BpyRuntimeError.invalidOutput("Closing a real document did not release its slot.")
        }
        _ = try reusedSession.ready()
        projectC.close()

        let shutdownJobID = UUID()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? sessionB.runJob(
                id: shutdownJobID,
                expectedRevision: "document-b-revision",
                source: "while True: pass",
                timeoutSeconds: 120
            )
        }
        try waitUntilRunning(sessionB, jobID: shutdownJobID)

        return [
            "schema": "nexgenvideo/bpy-runtime-acceptance/2",
            "python": readyA.runtime?.pythonVersion ?? "",
            "bpy": readyA.runtime?.bpyVersion ?? "",
            "probeA": readyA.runtime?.processIdentifier ?? -1,
            "probeB": readyB.runtime?.processIdentifier ?? -1,
            "serviceA": readyA.runtime?.serviceProcessIdentifier ?? -1,
            "serviceB": readyB.runtime?.serviceProcessIdentifier ?? -1,
            "coldStartSeconds": coldStartSeconds,
            "serviceColdStartSeconds": readyA.metrics["cold_start_seconds"] ?? -1,
            "warmJobSeconds": warmJobSeconds,
            "hostJobSeconds": hostJobSeconds,
            "jobMetrics": first.response.metrics,
            "trustedVerification": verification,
            "deniedPositiveControls": positiveControls,
            "forgedResultState": forged.response.state?.rawValue ?? "",
            "cancelState": cancelResult.response.state?.rawValue ?? "",
            "rlimitASAllocationDenied": true,
            "outOfMemoryState": outOfMemory.response.state?.rawValue ?? "",
            "structuralLimitState": structuralLimit.response.state?.rawValue ?? "",
            "renderOnlyGeometryState": renderOnlyGeometry.response.state?.rawValue ?? "",
            "secondarySceneGeometryState": secondarySceneGeometry.response.state?.rawValue ?? "",
            "storageLimitState": storageLimit.response.state?.rawValue ?? "",
            "aggregateByteLimitState": aggregateBytes.response.state?.rawValue ?? "",
            "unlinkedStorageLimitState": unlinkedStorage.response.state?.rawValue ?? "",
            "healthyResourceChurnState": healthyChurn.response.state?.rawValue ?? "",
            "resourceScanErrorState": scanError.response.state?.rawValue ?? "",
            "containerSiblingWriteDenied": true,
            "supervisorSignalDenied": true,
            "supervisorSignalRecovered": true,
            "supervisorIdentityWriteFailureState": identityWriteFailure.response.state?.rawValue ?? "",
            "supervisorIdentityWriteFailureRecovered": true,
            "supervisorIdentityCaptureFailureState": identityCaptureFailure.response.state?.rawValue ?? "",
            "supervisorIdentityCaptureFailureRecovered": true,
            "resourceSupervisorRecovered": true,
            "crashState": crashed.response.state?.rawValue ?? "",
            "duplicateJoined": duplicate.response.joinedExistingJob,
            "changedDuplicateRejected": true,
            "failedOpenReleased": true,
            "closeBeforeOpenReleased": true,
            "serviceRecoveryRevision": reopened.confirmedRevision ?? "",
            "parentDeathJobFailedClosed": true,
            "execveOrphanReaped": true,
            "threeRealDocuments": true,
            "thirdDocumentInitiallyDenied": true,
            "slotReusedAfterClose": true,
            "appTerminationJobStarted": true,
        ]
    }

    private static func deniedPathList(_ environment: [String: String]) throws -> [String] {
        guard let raw = environment["NGV_BPY_DENIED_PATHS"],
              let data = raw.data(using: .utf8),
              let paths = try JSONSerialization.jsonObject(with: data) as? [String],
              paths.count >= 3 else {
            throw BpyRuntimeError.invalidInput(
                "NGV_BPY_DENIED_PATHS requires secret, canonical, and foreign paths."
            )
        }
        return paths
    }

    private static func verificationObject(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any] else {
            throw BpyRuntimeError.invalidOutput("Trusted verification is not an object.")
        }
        return value
    }

    private static func assertVerification(
        _ verification: [String: Any],
        deniedPaths: [String],
        expectedObject: String
    ) throws {
        guard verification["schema"] as? String == "nexgenvideo/bpy-verification/1",
              verification["autorunTextPresent"] as? Bool == true,
              verification["autorunMarkerAbsent"] as? Bool == true,
              verification["secretEnvironmentAbsent"] as? Bool == true,
              let names = verification["objectNames"] as? [String],
              names.contains(expectedObject),
              let modifiers = verification["modifiers"] as? [String: [String]],
              modifiers["NGV_Room"]?.contains("BEVEL") == true,
              let bpyModule = verification["bpyModule"] as? String,
              bpyModule.hasSuffix("/bpy/__init__.so") else {
            throw BpyRuntimeError.invalidOutput("The fresh verifier rejected scene identity.")
        }
        try assertDenied(verification, paths: deniedPaths)
        guard let network = verification["networkDenied"] as? [String: Any],
              network["denied"] as? Bool == true,
              let value = network["errno"] as? Int,
              [Int(EPERM), Int(EACCES)].contains(value) else {
            throw BpyRuntimeError.invalidOutput("The trusted network denial probe failed.")
        }
    }

    private static func assertDenied(_ verification: [String: Any], paths: [String]) throws {
        guard let denied = verification["deniedPaths"] as? [String: [String: Any]] else {
            throw BpyRuntimeError.invalidOutput("Trusted file-denial evidence is missing.")
        }
        for path in paths {
            guard denied[path]?["denied"] as? Bool == true,
                  let value = denied[path]?["errno"] as? Int,
                  [Int(EPERM), Int(EACCES)].contains(value) else {
                throw BpyRuntimeError.invalidOutput("The trusted file-denial probe failed.")
            }
        }
    }

    private static func acceptanceSceneSource() -> String {
        """
        import json
        import time

        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = bpy.context.scene
        mesh = bpy.data.meshes.new('NGV_RoomMesh')
        room = bpy.data.objects.new('NGV_Room', mesh)
        scene.collection.objects.link(room)
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=4.0)
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
            bpy.ops.mesh.primitive_cube_add(
                location=(-1.8 + index * 0.45, -0.4, -1.25 + index * 0.22)
            )
            step = bpy.context.object
            step.name = f'NGV_Stair_{index:02d}'
            step.scale = (0.22, 0.8, 0.11)
        bpy.ops.mesh.primitive_uv_sphere_add(
            segments=24,
            ring_count=12,
            location=(1.15, 0.55, -0.55),
        )
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
        try:
            cycles = bpy.context.preferences.addons['cycles'].preferences
            cycles.compute_device_type = 'METAL'
            cycles.get_devices()
            metal = [item for item in cycles.devices if item.type == 'METAL']
            if not metal:
                raise RuntimeError('no Metal Cycles device')
            for item in cycles.devices:
                item.use = item in metal
            scene.render.engine = 'CYCLES'
            scene.cycles.device = 'GPU'
            scene.cycles.samples = 8
            bpy.ops.render.render(write_still=True)
        except Exception:
            scene.render.engine = 'CYCLES'
            scene.cycles.device = 'CPU'
            scene.cycles.samples = 8
            bpy.ops.render.render(write_still=True)

        approved = json.loads((input_dir / 'fixture.json').read_text())
        if approved != {'approved': True}:
            raise RuntimeError('approved input bytes changed')
        autorun = bpy.data.texts.new('NGV_AutorunProbe.py')
        autorun.write("import bpy\\nbpy.data.objects.new('AUTORUN_RAN', None)\\n")
        autorun.use_module = True
        """
    }

    private static func inspectionSource(
        label: String,
        requiredObject: String? = nil
    ) -> String {
        let requiredCheck = requiredObject.map { " or '\($0)' not in names" } ?? ""
        """
        names = sorted(obj.name for obj in bpy.data.objects)
        if 'NGV_Room' not in names or 'DocumentBOnly' in names or 'AUTORUN_RAN' in names\(requiredCheck):
            raise RuntimeError(f'confirmed scene isolation failed: {names}')
        bpy.context.scene['inspection'] = '\(label)'
        """
    }

    private static func assertRecovered(_ result: BpyRuntimeJobResult, label: String) throws {
        guard result.response.state == .awaitingConfirmation,
              result.stagedOutputs["verification.json"] != nil else {
            throw BpyRuntimeError.invalidOutput(
                "The worker did not restore the confirmed scene after \(label)."
            )
        }
    }

    private static func waitUntilRunning(
        _ session: BpyRuntimeSession,
        jobID: UUID
    ) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let response = try? session.status(jobID: jobID),
               response.state == .running,
               response.activeProcessIdentifier.map({ $0 > 1 }) == true,
               response.activeProcessStartAbsoluteTime != nil,
               response.activeProcessExecutable != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw BpyRuntimeError.timedOut
    }

    private static func hostPeakMemoryBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss)
    }
}
