import AppKit
import BpyRuntimeProtocol
import Darwin
import Foundation
import NexGenEngine

private final class BpySelfTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<BpyRuntimeJobResult, Error>?
    private var completedAt: ContinuousClock.Instant?

    func store(_ value: Result<BpyRuntimeJobResult, Error>) {
        lock.lock()
        result = value
        completedAt = ContinuousClock.now
        lock.unlock()
    }

    func load() -> Result<BpyRuntimeJobResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let completedAt = completionTime() { return completedAt <= deadline }
            guard clock.now < deadline else {
                return completionTime().map { $0 <= deadline } ?? false
            }
            do {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10))))
            } catch { return false }
        }
    }

    private func completionTime() -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return completedAt
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
    private static var terminationOperation: BpyRuntimeOperation?

    static func scheduleIfRequested() {
        if let outputPath = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY_BOUNDARY"],
           !outputPath.isEmpty {
            DispatchQueue.main.async {
                do {
                    try runBoundaryProbe(outputPath: outputPath)
                    FileHandle.standardOutput.write(Data("SELFTEST_BPY_BOUNDARY_OK\n".utf8))
                    Darwin.exit(0)
                } catch {
                    recordInspectionFailureDiagnostic()
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
                    recordInspectionFailureDiagnostic()
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
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: output,
                    withIntermediateDirectories: true
                )
                outputDirectory = output
                pendingResult = try await run(output: output)
                AppTermination.request()
            } catch {
                recordInspectionFailureDiagnostic()
                if let outputDirectory {
                    do {
                        var diagnostic = try BpyRuntimeObservation.shared.diagnosticSnapshot()
                        diagnostic["hostPID"] = getpid()
                        diagnostic["sourceSHA"] = Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""
                        diagnostic["error"] = error.localizedDescription
                        try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
                            .write(to: outputDirectory.appendingPathComponent("runtime-failure-observation.json"), options: .atomic)
                    } catch {
                        FileHandle.standardError.write(Data("SELFTEST_BPY_DIAGNOSTIC_FAIL \(error.localizedDescription)\n".utf8))
                    }
                }
                let message = "SELFTEST_BPY_FAIL \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                Darwin.exit(1)
            }
        }
    }

    private static func recordInspectionFailureDiagnostic() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              let path = environment["NGV_BPY_COMMAND_EVIDENCE"], !path.isEmpty else { return }
        do {
            var record = try BpyRuntimeObservation.shared.inspectionFailureSnapshot()
            record["hostPID"] = getpid()
            record["sourceSHA"] = Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""
            let url = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("host-inspection-failures-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: url, options: .withoutOverwriting)
        } catch {
            FileHandle.standardError.write(Data("SELFTEST_BPY_INSPECTION_DIAGNOSTIC_FAIL \(error.localizedDescription)\n".utf8))
        }
    }

    private static func runBoundaryProbe(outputPath: String) throws {
        for slot in bpyRuntimeServiceNames.indices {
            try runBoundaryProbe(outputPath: outputPath + ".slot\(slot).json", slot: slot)
        }
    }

    private static func runBoundaryProbe(outputPath: String, slot: Int) throws {
        let connection = NSXPCConnection(serviceName: bpyRuntimeServiceNames[slot])
        connection.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        let nonce = UUID()
        let layout = try BpyRuntimeBundleLayout(app: Bundle.main.bundleURL, serviceName: bpyRuntimeServiceNames[slot])
        connection.exportedInterface = NSXPCInterface(with: BpyHostMonitorProtocol.self)
        let monitor = BpyHostMonitor(connection: connection, transport: nonce, layout: layout)
        connection.exportedObject = monitor
        connection.resume()
        defer { connection.invalidate() }
        guard let service = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? BpyRuntimeServiceProtocol else {
            throw BpyRuntimeError.unavailable("The boundary XPC service is unavailable.")
        }
        func call(_ timeout: TimeInterval = 30, _ send: (@escaping (Data) -> Void) -> Void) throws -> Data {
            let box = BpyBoundaryReplyBox()
            let finished = DispatchSemaphore(value: 0)
            send { response in box.store(response: response); finished.signal() }
            guard finished.wait(timeout: .now() + timeout) == .success else { throw BpyRuntimeError.timedOut }
            guard let body = box.load().0 else { throw BpyRuntimeError.invalidOutput("The boundary probe returned no result.") }
            return body
        }
        let limits = BpyRuntimeLimits(timeoutSeconds: 20)
        let preparationRequest = try JSONEncoder().encode(BpyOpenSessionRequest(sessionID: nonce,
            documentID: "native-boundary", limits: limits))
        func storageProof() throws -> BpyStoragePreparation {
            let response = try JSONDecoder().decode(BpyServiceResponse.self,
                from: call { service.openSession(preparationRequest, withReply: $0) })
            guard response.ok, let proof = response.storagePreparation else {
                throw BpyRuntimeError.invalidOutput("The boundary storage owner is unavailable.")
            }
            return proof
        }
        let preparation = try storageProof()
        let worker = try BpyRuntimeVolume.create(preparation: preparation, serviceName: bpyRuntimeServiceNames[slot],
            maximumBytes: limits.physicalStorageBytes)
        var dataVolume: BpyRuntimeVolume?
        defer {
            BpyMemoryCoordinator.shared.close(owner: nonce)
            if let proof = try? storageProof() {
                try? dataVolume?.release(serviceStopped: false, serviceProof: proof)
                try? worker.release(serviceStopped: false, serviceProof: proof)
            }
        }
        guard let dataBytes = limits.dataStorageBytes else { throw BpyRuntimeError.invalidOutput("Invalid boundary capacity.") }
        let ownedData = try BpyRuntimeVolume.create(preparation: preparation, serviceName: bpyRuntimeServiceNames[slot],
            maximumBytes: dataBytes, role: .data)
        dataVolume = ownedData
        let pair = BpyStoragePair(id: preparation.id, worker: worker.lease, data: ownedData.lease)
        let memory = BpyMemoryCoordinator.shared
        try memory.register(owner: nonce, generation: nonce)
        func run(_ mode: BpyBoundaryMode) throws -> BpyBoundaryRun {
            let admission = try memory.admit(owner: nonce, generation: nonce, transport: nonce, job: nil,
                kind: .boundary, timeout: 20, cancellation: .init())
            defer { memory.finish(admission.id); memory.forget(admission.id) }
            try monitor.install(.init(slot: bpyRuntimeServiceNames[slot], identity: admission, pair: pair, limits: limits,
                workerVolume: worker, dataVolume: ownedData, sourceSHA256: nil, fingerprint: nil, diagnosticDeniedPaths: []))
            let request = try JSONEncoder().encode(BpyBoundaryProbeRequest(nonce: nonce, execution: UUID(), mode: mode,
                storagePair: pair, admission: admission.id, admissionDeadline: admission.admissionDeadline, limits: limits))
            let run = try JSONDecoder().decode(BpyBoundaryRun.self, from: call { service.runBoundaryProbe(request, withReply: $0) })
            guard run.report.mode == mode.rawValue, run.supervisorParentProcessIdentifier == getpid(),
                  run.supervisorGone, run.childGone else { throw BpyRuntimeError.invalidOutput("Boundary process ownership failed.") }
            return run
        }
        let first = try run(.denials)
        let retained = try [run(.openUnlinked), run(.readonlyUnlinked), run(.mappedUnlinked)]
        let external = try run(.externalReadonly)
        let internalLinked = try run(.internalWritable)
        let fileport = try run(.fileportUnlinked)
        let followup = try run(.denials)
        let result = BpyBoundaryProbeResult(nonce: nonce, serviceProcessIdentifier: preparation.servicePID,
            serviceStartAbsoluteTime: preparation.serviceStart,
            supervisorProcessIdentifier: first.supervisorProcessIdentifier,
            supervisorParentProcessIdentifier: first.supervisorParentProcessIdentifier,
            supervisorStartAbsoluteTime: first.supervisorStartAbsoluteTime,
            childProcessIdentifier: first.child.processIdentifier, childStartAbsoluteTime: first.child.startAbsoluteTime,
            childParentProcessIdentifier: first.report.parentProcessIdentifier,
            allowedWriteSucceeded: first.report.allowedWriteSucceeded, outsideWriteDeniedErrno: first.report.outsideWriteDeniedErrno,
            forkDeniedErrno: first.report.forkDeniedErrno, networkDeniedErrno: first.report.networkDeniedErrno,
            signalDeniedErrnos: first.report.signalDeniedErrnos,
            unlinkedBytesObserved: retained.map(\.observedRetainedBytes).min() ?? 0,
            unlinkedLimitReason: retained.allSatisfy { $0.limitReason == "disk" } ? "disk" : "",
            cleanupSupervisorGone: retained.allSatisfy(\.supervisorGone), cleanupChildGone: retained.allSatisfy(\.childGone),
            internalLinkedWritableDeduplicated: internalLinked.internalLinkedWritableDeduplicated,
            fileportRetentionDeniedErrno: fileport.report.retentionDeniedErrno, fileportRetentionDenied: fileport.retentionDenied,
            fileportBytesObserved: fileport.observedRetainedBytes, fileportLimitReason: fileport.limitReason ?? "",
            healthyFollowupSucceeded: external.limitReason == nil && external.observedRetainedBytes < 1_048_576
                && followup.supervisorGone && followup.childGone && followup.report.allowedWriteSucceeded)
        let data = try JSONEncoder().encode(result)
        let permissionErrors = [Int32(EPERM), Int32(EACCES)]
        guard result.schema == "nexgenvideo/bpy-boundary-probe/5",
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
              result.supervisorParentProcessIdentifier == getpid(),
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
              result.internalLinkedWritableDeduplicated,
              ((permissionErrors.contains(result.fileportRetentionDeniedErrno) && result.fileportRetentionDenied)
                || (result.fileportRetentionDeniedErrno == 0 && result.fileportBytesObserved >= 1_048_576
                    && result.fileportLimitReason == "disk")),
              result.healthyFollowupSucceeded else {
            throw BpyRuntimeError.invalidOutput("The signed boundary probe did not prove every denial and cleanup invariant.")
        }
        guard let peer = try BpyKernelInspection.process(connection.processIdentifier),
              peer.pid == result.serviceProcessIdentifier, peer.start == result.serviceStartAbsoluteTime,
              peer.executable == (try BpyRuntimePath.canonical(layout.service.appendingPathComponent("Contents/MacOS/NexGenVideoBpyService"))),
              var proof = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BpyRuntimeError.invalidOutput("The boundary reply does not match its service slot.")
        }
        proof["hostProcessIdentifier"] = getpid()
        proof["slot"] = slot
        proof["serviceName"] = bpyRuntimeServiceNames[slot]
        proof["serviceExecutable"] = peer.executable
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static func runHostCrashProbe(mode: String) throws {
        let project = VideoProject()
        retainedProjects = [project]
        project.makeWindowControllers()
        BpyRuntimeHost.shared.register(document: project, documentID: UUID().uuidString)
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
                    try recordHostCrashProof(mode: mode, jobID: jobID, response: response)
                    _ = Darwin.kill(getpid(), SIGKILL)
                }
                if mode == "after-authorization",
                   response.activeProcessAuthorizationID == nil,
                   response.activeWorkerProcessIdentifier.map({ $0 > 1 }) == true {
                    try recordHostCrashProof(mode: mode, jobID: jobID, response: response)
                    _ = Darwin.kill(getpid(), SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw BpyRuntimeError.timedOut
    }

    private static func recordHostCrashProof(mode: String, jobID: UUID, response: BpyServiceResponse) throws {
        guard response.jobID == jobID else {
            throw BpyRuntimeError.invalidOutput("The crash probe returned a different job identity.")
        }
        guard let path = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY_HOST_CRASH_EVIDENCE"] else {
            throw BpyRuntimeError.invalidOutput("The crash probe has no evidence destination.")
        }
        var proof: [String: Any] = ["schema": 1, "mode": mode, "pid": getpid(), "jobID": jobID.uuidString,
            "state": response.state?.rawValue ?? "missing",
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""]
        proof["supervisorPID"] = response.activeProcessIdentifier
        proof["workerPID"] = response.activeWorkerProcessIdentifier
        proof["authorizationID"] = response.activeProcessAuthorizationID?.uuidString
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func applicationWillTerminate() {
        guard var result = pendingResult, let outputDirectory else { return }
        guard !BpyRuntimeHost.shared.hasReservedSlots else {
            FileHandle.standardError.write(Data("SELFTEST_BPY_FAIL Runtime storage survived AppDelegate shutdown.\n".utf8))
            return
        }
        guard let terminationOperation, !BpyRuntimeHost.shared.isOperationActive(terminationOperation) else {
            FileHandle.standardError.write(Data("SELFTEST_BPY_FAIL A document operation survived AppDelegate shutdown.\n".utf8))
            return
        }
        result["operationShutdown"] = true
        result["appDelegateShutdown"] = true
        result["hostPeakMemoryBytes"] = hostPeakMemoryBytes()
        do {
            result["runtimeObservation"] = try BpyRuntimeObservation.shared.evidence()
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

    private static func run(output: URL) async throws -> [String: Any] {
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
        BpyRuntimeHost.shared.register(document: earlyCloseProject, documentID: UUID().uuidString)
        guard let earlyCloseSession = BpyRuntimeHost.shared.session(for: earlyCloseProject) else {
            throw BpyRuntimeError.invalidOutput("The close-before-open lifecycle could not reserve a slot.")
        }
        let earlyCloseBox = BpySelfTestBox()
        DispatchQueue.global(qos: .userInitiated).async {
            earlyCloseBox.store(Result {
                let response = try earlyCloseSession.ready()
                return BpyRuntimeJobResult(response: response, stagedOutputs: [:])
            })
        }
        try await Task.sleep(for: .milliseconds(10))
        earlyCloseProject.close()
        try waitUntilReleased(earlyCloseSession)
        guard await earlyCloseBox.wait(timeout: .seconds(10)),
              earlyCloseBox.load() != nil else {
            throw BpyRuntimeError.invalidOutput("Close-before-open did not settle the client call.")
        }

        let failedProject = VideoProject()
        failedProject.makeWindowControllers()
        BpyRuntimeHost.shared.register(document: failedProject, documentID: UUID().uuidString)
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
        let documentA = UUID().uuidString, documentB = UUID().uuidString, documentC = UUID().uuidString
        projectA.makeWindowControllers()
        guard let presentationA = BpyRuntimeHost.shared.register(document: projectA, documentID: documentA) else {
            throw BpyRuntimeError.invalidOutput("The first document presentation could not register.")
        }
        projectB.makeWindowControllers()
        guard let presentationB = BpyRuntimeHost.shared.register(document: projectB, documentID: documentB) else {
            throw BpyRuntimeError.invalidOutput("The second document presentation could not register.")
        }
        projectC.makeWindowControllers()
        guard let presentationC = BpyRuntimeHost.shared.register(document: projectC, documentID: documentC) else {
            throw BpyRuntimeError.invalidOutput("The third document presentation could not register.")
        }
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

        let operation = try BpyRuntimeHost.shared.acquireOperation(document: projectA, documentID: documentA)
        let joinedOperation = try BpyRuntimeHost.shared.acquireOperation(document: projectA, documentID: documentA)
        BpyRuntimeHost.shared.releasePresentation(presentationA)
        guard BpyRuntimeHost.shared.isOperationActive(operation),
              BpyRuntimeHost.shared.isOperationActive(joinedOperation),
              operation.session === sessionA, joinedOperation.session === sessionA,
              try operation.session.ready().runtime?.serviceProcessIdentifier == readyA.runtime?.serviceProcessIdentifier else {
            throw BpyRuntimeError.invalidOutput("A screen change closed its active document operation.")
        }
        BpyRuntimeHost.shared.releaseOperation(operation)
        BpyRuntimeHost.shared.releaseOperation(operation)
        guard !BpyRuntimeHost.shared.isOperationActive(operation),
              BpyRuntimeHost.shared.isOperationActive(joinedOperation) else {
            throw BpyRuntimeError.invalidOutput("Releasing an operation invalidated a different operation.")
        }
        guard let outgoing = BpyRuntimeHost.shared.register(document: projectA, documentID: documentA),
              BpyRuntimeHost.shared.register(document: projectA, documentID: documentA) != nil else {
            throw BpyRuntimeError.invalidOutput("Overlapping presentations could not register.")
        }
        BpyRuntimeHost.shared.releasePresentation(outgoing)
        BpyRuntimeHost.shared.releasePresentation(outgoing)
        BpyRuntimeHost.shared.releaseOperation(joinedOperation)
        guard sessionA.isAvailable else {
            throw BpyRuntimeError.invalidOutput("The visible location editor lost its runtime after operation completion.")
        }

        let warmID = UUID()
        let warmRequest: [String: Any] = [
            "schema": "nexgenvideo/bpy-warm-probe/1", "hostPID": getpid(),
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "jobID": warmID.uuidString, "source": "pass",
        ]
        try JSONSerialization.data(withJSONObject: warmRequest, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("warm-job.json"), options: .atomic)
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
        warm.release()

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
        let sceneReceipt: [String: Any] = [
            "schema": "nexgenvideo/bpy-scene-acceptance/1", "hostPID": getpid(),
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "jobID": firstID.uuidString,
            "response": try JSONSerialization.jsonObject(with: JSONEncoder().encode(first.response)),
            "stagedOutputNames": first.stagedOutputs.keys.sorted(),
        ]
        try JSONSerialization.data(withJSONObject: sceneReceipt, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("acceptance-scene-response.json"), options: .atomic)
        guard first.response.state == .awaitingConfirmation,
              (first.response.metrics["worker_host_monitor_samples"] ?? 0) > 0,
              (first.response.metrics["verifier_host_monitor_samples"] ?? 0) > 0,
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
        guard let protocolCheckpoint = first.stagedOutputs["scene.blend"] else {
            throw BpyRuntimeError.invalidOutput("The protocol probe requires its actual verified checkpoint.")
        }
        try FileManager.default.copyItem(at: protocolCheckpoint,
            to: output.appendingPathComponent("native-protocol-checkpoint.blend"))
        _ = try sessionA.confirm(jobID: firstID, revision: "revision-a")
        var protocolEvidence = try sessionA.nativeProtocolProbe(confirmedJobID: firstID)
        try protocolEvidence.write(to: output.appendingPathComponent("native-protocol-evidence.json"))

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
        duplicate.release()
        first.release()
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
            guard case .rejected("A Job ID cannot be reused with different source, inputs, revision, or options.") = error else { throw error }
        }
        let duplicateReceipt: [String: Any] = [
            "schema": "nexgenvideo/bpy-duplicate-replay/1", "hostPID": getpid(),
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "response": try JSONSerialization.jsonObject(with: JSONEncoder().encode(duplicate.response)),
            "changedDuplicateRejected": true,
        ]
        try JSONSerialization.data(withJSONObject: duplicateReceipt, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("native-duplicate-replay.json"), options: .atomic)

        let fifo = approvedDirectory.appendingPathComponent("fifo.json")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw BpyRuntimeError.invalidInput("The FIFO rejection fixture could not be created.") }
        defer { try? FileManager.default.removeItem(at: fifo) }
        let fifoInput = try BpyApprovedInputCopy(approvedDirectory: approvedDirectory, filename: "fifo.json")
        let fifoResult = BpySelfTestBox()
        DispatchQueue.global(qos: .userInitiated).async {
            fifoResult.store(Result {
                try sessionA.runJob(id: UUID(), expectedRevision: "warm-probe",
                    source: "raise RuntimeError('A FIFO must never reach the worker')", inputs: [fifoInput])
            })
        }
        let rejectedBeforeWriter = await fifoResult.wait(timeout: .seconds(5))
        let fifoWriter = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if fifoWriter >= 0 { Darwin.close(fifoWriter) }
        if !rejectedBeforeWriter { _ = await fifoResult.wait(timeout: .seconds(5)) }
        guard rejectedBeforeWriter, let rejected = fifoResult.load() else {
            throw BpyRuntimeError.invalidOutput("Approved input blocked while opening a FIFO without a writer.")
        }
        switch rejected {
        case .success: throw BpyRuntimeError.invalidOutput("Approved input accepted a FIFO.")
        case .failure(let error):
            guard let runtimeError = error as? BpyRuntimeError,
                  case .invalidInput("Approved input must be a bounded single-link file.") = runtimeError else { throw error }
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

        let firstConfirmedScene = URL(fileURLWithPath: firstSessionRoot, isDirectory: true)
            .appendingPathComponent("results", isDirectory: true)
            .appendingPathComponent(firstID.uuidString, isDirectory: true)
            .appendingPathComponent("scene.blend")
        let confirmedSceneSHA = try FileDigest.sha256(of: firstConfirmedScene)
        guard confirmedSceneSHA == verification["sceneSHA256"] as? String else {
            throw BpyRuntimeError.invalidOutput("The document isolation control does not match the verified scene.")
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
            diagnosticDeniedPaths: [firstConfirmedScene.path]
        )
        guard secondDocument.response.state == .awaitingConfirmation,
              (secondDocument.response.metrics["worker_host_monitor_samples"] ?? 0) > 0,
              (secondDocument.response.metrics["verifier_host_monitor_samples"] ?? 0) > 0,
              let secondVerificationURL = secondDocument.stagedOutputs["verification.json"] else {
            throw BpyRuntimeError.invalidOutput("The second document did not complete.")
        }
        let secondVerification = try verificationObject(secondVerificationURL)
        try assertDenied(secondVerification, paths: [firstConfirmedScene.path])
        let isolationReceipt: [String: Any] = [
            "schema": "nexgenvideo/bpy-cross-document-denial/1", "hostPID": getpid(),
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "firstDocumentJobID": firstID.uuidString, "secondDocumentJobID": secondDocumentID.uuidString,
            "firstScenePath": firstConfirmedScene.path, "hostSceneSHA256": confirmedSceneSHA,
            "verification": secondVerification,
        ]
        try JSONSerialization.data(withJSONObject: isolationReceipt, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("native-cross-document-denial.json"), options: .atomic)
        _ = try sessionB.confirm(jobID: secondDocumentID, revision: "document-b-revision")
        secondDocument.release()

        let forgedID = UUID()
        let forged = try sessionA.runJob(
            id: forgedID,
            expectedRevision: "revision-a",
            source: """
            import os
            os.write(1, b'NGV_TIMEOUT_SOURCE_STARTED\\n')
            os.write(1, b'{"type":"result","ok":true}\\n')
            while True:
                pass
            """,
            timeoutSeconds: 10
        )
        guard forged.response.state == .timedOut, forged.response.stdout?.contains("NGV_TIMEOUT_SOURCE_STARTED") == true else {
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
        afterTimeout.release()

        let cancelID = UUID()
        let cancelBox = BpySelfTestBox()
        let cancelAdmissionBox = BpyBoundaryReplyBox()
        let cancelReceiptResume = DispatchSemaphore(value: 0)
        defer { cancelReceiptResume.signal() }
        try JSONSerialization.data(withJSONObject: [
            "schema": "nexgenvideo/bpy-cancellation-start/1",
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "hostPID": ProcessInfo.processInfo.processIdentifier,
            "jobID": cancelID.uuidString
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-cancellation-start.json"), options: .atomic)
        DispatchQueue.global(qos: .userInitiated).async {
            cancelBox.store(Result {
                try sessionA.runJob(
                    id: cancelID,
                    expectedRevision: "revision-b",
                    source: "while True: pass",
                    timeoutSeconds: 30,
                    diagnosticReceiptBarrier: { admission in
                        cancelAdmissionBox.store(response: try JSONEncoder().encode(admission))
                        guard cancelReceiptResume.wait(timeout: .now() + 10) == .success else {
                            throw BpyRuntimeError.invalidOutput("The cancellation receipt barrier did not resume.")
                        }
                    }
                )
            })
        }
        try waitUntilRunning(sessionA, jobID: cancelID)
        let barrierDeadline = ProcessInfo.processInfo.systemUptime + 10
        while cancelAdmissionBox.load().0 == nil {
            if let early = cancelBox.load() {
                switch early {
                case .success(let result):
                    result.release()
                    throw BpyRuntimeError.invalidOutput("The cancellation job settled before its receipt barrier.")
                case .failure(let error): throw error
                }
            }
            guard ProcessInfo.processInfo.systemUptime < barrierDeadline else { throw BpyRuntimeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let admissionBytes = cancelAdmissionBox.load().0 else { throw BpyRuntimeError.timedOut }
        let cancelAdmission = try JSONDecoder().decode(BpyAdmissionIdentity.self, from: admissionBytes)
        guard cancelAdmission.job == cancelID else { throw SpatialSceneError.changed }
        _ = try sessionA.cancel(jobID: cancelID)
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 5
        var cancelledReceipt = try BpyMemoryCoordinator.shared.receipt(cancelAdmission.id)
        while !cancelledReceipt.cleanupComplete {
            guard ProcessInfo.processInfo.systemUptime < cleanupDeadline else { throw BpyRuntimeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
            cancelledReceipt = try BpyMemoryCoordinator.shared.receipt(cancelAdmission.id)
        }
        guard cancelledReceipt.stop == .cancelled, cancelledReceipt.firstRelease != nil else {
            throw BpyRuntimeError.invalidOutput("Cancellation lost its original execution receipt.")
        }
        cancelReceiptResume.signal()
        guard await cancelBox.wait(timeout: .seconds(10)), let cancelOutcome = cancelBox.load() else {
            throw BpyRuntimeError.invalidOutput("Cancellation did not settle the active operation.")
        }
        switch cancelOutcome {
        case .success(let result):
            defer { result.release() }
            guard result.response.state == .cancelled else { throw BpyRuntimeError.invalidOutput("Cancellation returned a live candidate.") }
        case .failure(let error):
            guard error as? BpyAdmissionFailure == .cancelled else { throw error }
        }
        let cancelledStatus = try sessionA.status(jobID: cancelID)
        guard cancelledStatus.state == .cancelled,
              cancelledStatus.activeProcessIdentifier == nil,
              cancelledStatus.activeWorkerProcessIdentifier == nil else {
            throw BpyRuntimeError.invalidOutput("Cancellation did not prove the owned process exited.")
        }
        do {
            _ = try BpyMemoryCoordinator.shared.receipt(cancelAdmission.id)
            throw BpyRuntimeError.invalidOutput("Cancellation retained a finished execution permit.")
        } catch let error as BpyAdmissionFailure where error == .closed {}
        try JSONSerialization.data(withJSONObject: [
            "schema": "nexgenvideo/bpy-cancellation-receipt/1",
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "hostPID": ProcessInfo.processInfo.processIdentifier,
            "jobID": cancelID.uuidString,
            "receiptBeforeWaiterResumed": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cancelledReceipt)),
            "statusAfterWaiterSettled": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cancelledStatus)),
            "permitRetiredAfterWaiterSettled": true
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-cancellation-receipt.json"), options: .atomic)

        let transportJobID = UUID()
        let transportBox = BpySelfTestBox()
        DispatchQueue.global(qos: .userInitiated).async {
            transportBox.store(Result {
                try sessionA.runJob(id: transportJobID, expectedRevision: "revision-b",
                                    source: "while True: pass", timeoutSeconds: 30)
            })
        }
        try waitUntilRunning(sessionA, jobID: transportJobID)
        let authorizationDeadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            let status = try sessionA.status(jobID: transportJobID)
            if status.activeProcessIdentifier != nil, status.activeProcessStartAbsoluteTime != nil,
               status.activeProcessExecutable != nil, status.activeWorkerProcessIdentifier != nil,
               status.activeProcessAuthorizationID == nil { break }
            guard ProcessInfo.processInfo.systemUptime < authorizationDeadline else { throw BpyRuntimeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        let droppedReply = try sessionA.nativeDroppedStatusReplyProbe(jobID: transportJobID)
        try droppedReply.write(to: output.appendingPathComponent("native-dropped-reply.json"), options: .atomic)
        guard await transportBox.wait(timeout: .seconds(10)), let lostTransport = transportBox.load() else {
            throw BpyRuntimeError.invalidOutput("The lost transport did not settle the prior job.")
        }
        if case .success(let result) = lostTransport,
           result.response.state == .awaitingConfirmation || result.response.state == .confirmed {
            throw BpyRuntimeError.invalidOutput("A transport-lost job became a candidate.")
        }
        let transportReady = try sessionA.ready()
        guard transportReady.confirmedRevision == "revision-b" else {
            throw BpyRuntimeError.invalidOutput("Transport recovery lost the confirmed checkpoint.")
        }
        let afterTransportID = UUID()
        let afterTransport = try sessionA.runJob(id: afterTransportID, expectedRevision: "revision-b",
                                               source: inspectionSource(label: "after-dropped-reply"))
        try assertRecovered(afterTransport, label: "dropped XPC reply")
        _ = try sessionA.cancel(jobID: afterTransportID)

        let threadID = UUID()
        let threadResult = try sessionA.runJob(
            id: threadID,
            expectedRevision: "revision-b",
            source: """
            import threading
            import time
            print('NGV_THREAD_SOURCE_STARTED', flush=True)
            def persistent_thread():
                while True:
                    time.sleep(0.05)
            threading.Thread(target=persistent_thread).start()
            """,
            timeoutSeconds: 10
        )
        guard threadResult.response.state == .timedOut, threadResult.response.stdout?.contains("NGV_THREAD_SOURCE_STARTED") == true else {
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
        afterThread.release()

        let nativeOutputID = UUID()
        let nativeOutput = try sessionA.runJob(
            id: nativeOutputID,
            expectedRevision: "revision-c",
            source: """
            import ctypes
            payload = b'{"type":"result","state":"confirmed","ok":true}\\n'
            libc = ctypes.CDLL(None)
            libc.write.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
            buffer = ctypes.create_string_buffer(payload)
            if libc.write(1, buffer, len(payload)) != len(payload):
                raise RuntimeError('native stdout write failed')
            """
        )
        guard nativeOutput.response.state == .awaitingConfirmation,
              nativeOutput.response.stdout?.contains("\"state\":\"confirmed\"") == true else {
            throw BpyRuntimeError.invalidOutput("Native output corrupted the job control path.")
        }
        _ = try sessionA.confirm(jobID: nativeOutputID, revision: "revision-d")
        nativeOutput.release()

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
            marker = bpy.data.objects.new('FORK_BLOCKED', None)
            bpy.context.scene.collection.objects.link(marker)
            """
        )
        guard forkResult.response.state == .awaitingConfirmation,
              forkResult.response.metrics["descendant_peak_count"] == 0 else {
            throw BpyRuntimeError.invalidOutput("The kernel process limit did not block fork.")
        }
        _ = try sessionA.confirm(jobID: forkID, revision: "revision-e")
        forkResult.release()

        let checkpointProbeID = UUID()
        let checkpointProbe = try sessionA.runJob(
            id: checkpointProbeID,
            expectedRevision: "revision-e",
            source: inspectionSource(label: "after-fork-confirmation", requiredObject: "FORK_BLOCKED")
        )
        try assertRecovered(checkpointProbe, label: "fork checkpoint save/reload")
        _ = try sessionA.cancel(jobID: checkpointProbeID)
        checkpointProbe.release()

        let memoryPolicyEvidence = try BpyMemoryRuntimeAcceptance.run(
            output: output, session: sessionA, counterpart: sessionB, expectedRevision: "revision-e"
        )
        var untrustedExitEvidence: [[String: Any]] = []
        for code in [Int32(71), Int32(72)] {
            let source = """
            import os
            os.write(1, b'UNTRUSTED_EXIT_REACHED\\n')
            os._exit(\(code))
            """
            let rejected = try sessionA.runJob(id: UUID(), expectedRevision: "revision-e", source: source)
            guard rejected.response.state == .failed,
                  rejected.response.stdout?.contains("UNTRUSTED_EXIT_REACHED") == true,
                  rejected.response.message == "worker reported exit \(code) without an observed resource limit" else {
                throw BpyRuntimeError.invalidOutput("Untrusted exit codes claimed a native resource observation.")
            }
            untrustedExitEvidence.append(["exitCode": Int(code), "source": source,
                "response": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rejected.response))])
        }
        let untrustedExitBytes = try JSONSerialization.data(withJSONObject: untrustedExitEvidence, options: [.sortedKeys])
        try untrustedExitBytes.write(to: output.appendingPathComponent("native-untrusted-exits.json"))

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
        guard identityWriteFailure.response.state == .failed,
              identityWriteFailure.response.message == BpyAdmissionFailure.launchFailed.errorDescription,
              identityWriteFailure.response.outputs.isEmpty, identityWriteFailure.stagedOutputs.isEmpty else {
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
        guard identityCaptureFailure.response.state == .failed,
              identityCaptureFailure.response.message == BpyAdmissionFailure.launchFailed.errorDescription,
              identityCaptureFailure.response.outputs.isEmpty, identityCaptureFailure.stagedOutputs.isEmpty else {
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
        DispatchQueue.global(qos: .userInitiated).async {
            parentDeathBox.store(Result {
                try sessionA.runJob(
                    id: parentDeathID,
                    expectedRevision: "revision-e",
                    source: parentDeathSource,
                    timeoutSeconds: 30
                )
            })
        }
        try waitUntilRunning(sessionA, jobID: parentDeathID)
        guard let servicePID = readyA.runtime?.serviceProcessIdentifier,
              servicePID > 1, Darwin.kill(servicePID, SIGKILL) == 0,
              await parentDeathBox.wait(timeout: .seconds(10)),
              let parentDeathOutcome = parentDeathBox.load(),
              case .failure = parentDeathOutcome else {
            throw BpyRuntimeError.invalidOutput("The service-kill recovery probe could not start.")
        }
        try await Task.sleep(for: .milliseconds(500))
        let restoredProtocol = try sessionA.nativeProtocolRestoreProbe(addingTo: protocolEvidence)
        let reopened = restoredProtocol.ready
        protocolEvidence = restoredProtocol.evidence
        try restoredProtocol.checkpoint.write(to: output.appendingPathComponent("native-protocol-restored-checkpoint.blend"), options: .atomic)
        try protocolEvidence.write(to: output.appendingPathComponent("native-protocol-evidence.json"), options: .atomic)
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
        let closingOperation = try BpyRuntimeHost.shared.acquireOperation(document: projectA, documentID: documentA)
        projectA.close()
        guard !BpyRuntimeHost.shared.isOperationActive(closingOperation), !sessionA.isAvailable else {
            throw BpyRuntimeError.invalidOutput("Closing the document retained an active operation.")
        }
        do {
            _ = try BpyRuntimeHost.shared.acquireOperation(document: projectA, documentID: documentA)
            throw BpyRuntimeError.invalidOutput("A closed document acquired a new operation.")
        } catch let error as BpyRuntimeError {
            guard case .unavailable(_) = error else { throw error }
        }
        BpyRuntimeHost.shared.releaseOperation(closingOperation)
        try waitUntilReleased(sessionA)
        BpyRuntimeHost.shared.releasePresentation(presentationC)
        let operationOnly = try BpyRuntimeHost.shared.acquireOperation(document: projectC, documentID: documentC)
        _ = try operationOnly.session.ready()
        BpyRuntimeHost.shared.releaseOperation(operationOnly)
        guard !BpyRuntimeHost.shared.isOperationActive(operationOnly), !operationOnly.session.isAvailable else {
            throw BpyRuntimeError.invalidOutput("The last background operation retained its runtime.")
        }
        try waitUntilReleased(operationOnly.session)
        BpyRuntimeHost.shared.register(document: projectC, documentID: documentC)
        let physicalStorage = try verifyPhysicalStorage(serviceName: originalSlot)
        let spatialAuthoring = try await SpatialSceneRuntimeAcceptance.run(serviceName: originalSlot, output: output)

        let constrained = BpyRuntimeSession(
            documentID: "acceptance-resource-limits",
            limits: BpyRuntimeLimits(
                timeoutSeconds: 30,
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
            for name in ('NGV_OBJECT_LIMIT_A', 'NGV_OBJECT_LIMIT_B'):
                target = bpy.data.objects.new(name, None)
                bpy.context.scene.collection.objects.link(target)
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard structuralLimit.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("The object-count limit was not terminal.")
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
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
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
        let prefixedUserGeometry = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            mesh = bpy.data.meshes.new('NGV_PREFIXED_USER_MESH')
            mesh.from_pydata(
                [(float(index), 0, 0) for index in range(9)],
                [],
                [(0, 1, 2), (3, 4, 5), (6, 7, 8)]
            )
            target = bpy.data.objects.new('NGV_GEOMETRY_VERIFIER_CAMERA_user_mesh', mesh)
            bpy.context.scene.collection.objects.link(target)
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard prefixedUserGeometry.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("A user mesh with the verifier-camera prefix escaped verification.")
        }
        let zeroEffectiveResolution = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            bpy.context.scene.render.resolution_x = 4
            bpy.context.scene.render.resolution_y = 4
            bpy.context.scene.render.resolution_percentage = 1
            """
        )
        guard zeroEffectiveResolution.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("Zero effective render resolution escaped verification.")
        }
        let noEnabledViewLayer = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            for view_layer in bpy.context.scene.view_layers:
                view_layer.use = False
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard noEnabledViewLayer.response.state == .resourceLimited else {
            throw BpyRuntimeError.invalidOutput("A scene without an enabled View Layer escaped verification.")
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
        guard unlinkedStorage.response.state == .resourceLimited,
              unlinkedStorage.response.message == "job exceeded the disk limit" else {
            throw BpyRuntimeError.invalidOutput("Open unlinked vnodes escaped the disk limit.")
        }
        let renameChurnStorage = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            import os
            home = Path(os.environ['HOME'])
            paths = [home / 'rename-over-quota-a-0.bin', home / 'rename-over-quota-b-0.bin']
            for path in paths:
                path.write_bytes(b'x' * 1400000)
            index = 1
            while True:
                for offset, source in enumerate(paths):
                    destination = home / f'rename-over-quota-{offset}-{index}.bin'
                    os.rename(source, destination)
                    paths[offset] = destination
                index += 1
            """,
            timeoutSeconds: 5
        )
        guard renameChurnStorage.response.state == .resourceLimited,
              renameChurnStorage.response.message == "job exceeded the disk limit" else {
            throw BpyRuntimeError.invalidOutput("Closed rename-churn storage escaped the disk limit.")
        }
        let healthyChurn = try constrained.runJob(
            id: UUID(),
            expectedRevision: nil,
            source: """
            from concurrent.futures import ThreadPoolExecutor
            import os
            import shutil
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
                    tree = home / f'churn-tree-{index % 2}.part'
                    nested = tree / 'nested'
                    nested.mkdir(parents=True)
                    (nested / 'payload').write_bytes(b'x' * 4096)
                    relocated = home / f'churn-tree-{index % 2}.tmp'
                    os.rename(tree, relocated)
                    shutil.rmtree(relocated)
                    index += 1
            with ThreadPoolExecutor(max_workers=1) as executor:
                executor.submit(churn).result()
            bpy.context.scene.render.resolution_x = 64
            bpy.context.scene.render.resolution_y = 64
            """
        )
        guard healthyChurn.response.state == .awaitingConfirmation,
              let healthyChurnID = healthyChurn.response.jobID else {
            throw BpyRuntimeError.invalidOutput("Legitimate nested rename/delete churn failed the resource scan.")
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
        guard constrained.close() else {
            throw BpyRuntimeError.invalidOutput("The resource-limit runtime storage was not released.")
        }

        guard let reusedSession = BpyRuntimeHost.shared.session(for: projectC),
              reusedSession.serviceName == originalSlot else {
            throw BpyRuntimeError.invalidOutput("Closing a real document did not release its slot.")
        }
        _ = try reusedSession.ready()
        projectC.close()
        try waitUntilReleased(reusedSession)

        let unavailableSensor = try await Task.detached {
            try BpyMemoryRuntimeAcceptance.unavailableSensor(output: output, serviceName: originalSlot)
        }.value
        let reapedRecovery = try await Task.detached {
            try BpyReapedRecoveryAcceptance.run(output: output, serviceName: originalSlot)
        }.value
        let productionSpatial = try await ProductionSpatialAcceptance.run(output: output)
        let storageRecovery = try await BpyStorageRecoveryAcceptance.run(output: output)

        terminationOperation = try BpyRuntimeHost.shared.acquireOperation(document: projectB, documentID: documentB)
        BpyRuntimeHost.shared.releasePresentation(presentationB)
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
            "nativeProtocolEvidenceSHA256": FileDigest.sha256(of: protocolEvidence),
            "nativeProtocolEvidenceFile": "native-protocol-evidence.json",
            "forgedResultState": forged.response.state?.rawValue ?? "",
            "cancelState": cancelledStatus.state?.rawValue ?? "",
            "transportTimeoutRecovered": afterTransport.response.state == .awaitingConfirmation,
            "droppedReplyEvidenceSHA256": FileDigest.sha256(of: droppedReply),
            "memoryPolicyVersion": "system-pressure-v1",
            "memoryPolicy": memoryPolicyEvidence,
            "unavailableSensor": unavailableSensor,
            "reapedRecovery": reapedRecovery,
            "untrustedExitEvidenceFile": "native-untrusted-exits.json",
            "untrustedExitEvidenceSHA256": FileDigest.sha256(of: untrustedExitBytes),
            "structuralLimitState": structuralLimit.response.state?.rawValue ?? "",
            "renderOnlyGeometryState": renderOnlyGeometry.response.state?.rawValue ?? "",
            "secondarySceneGeometryState": secondarySceneGeometry.response.state?.rawValue ?? "",
            "prefixedUserGeometryState": prefixedUserGeometry.response.state?.rawValue ?? "",
            "zeroEffectiveResolutionState": zeroEffectiveResolution.response.state?.rawValue ?? "",
            "noEnabledViewLayerState": noEnabledViewLayer.response.state?.rawValue ?? "",
            "storageLimitState": storageLimit.response.state?.rawValue ?? "",
            "physicalStorage": physicalStorage,
            "spatialAuthoring": spatialAuthoring,
            "productionSpatial": productionSpatial,
            "storageRecovery": storageRecovery,
            "aggregateByteLimitState": aggregateBytes.response.state?.rawValue ?? "",
            "unlinkedStorageLimitState": unlinkedStorage.response.state?.rawValue ?? "",
            "renameChurnStorageLimitState": renameChurnStorage.response.state?.rawValue ?? "",
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
            "operationPresentationLifetime": true,
            "overlappingPresentations": true,
            "operationDocumentClose": true,
            "operationLastRelease": true,
            "appTerminationJobStarted": true,
        ]
    }

    private static func verifyPhysicalStorage(serviceName: String) throws -> [[String: Any]] {
        let session = BpyRuntimeSession(
            documentID: "acceptance-physical-storage",
            limits: .init(inputBytes: 16 * 1_024 * 1_024, outputBytes: 8 * 1_024 * 1_024,
                          diskBytes: 64 * 1_024 * 1_024), serviceName: serviceName
        )
        defer { session.close() }
        _ = try session.ready()
        let script = try String(contentsOf: session.bundledRuntimeRoot.appendingPathComponent("storage_probe.py"), encoding: .utf8)
        var proofs: [[String: Any]] = []
        for mode in ["fileport", "memory-entry", "scm-rights"] {
            let jobID = UUID()
            let result = try session.runJob(id: jobID, expectedRevision: nil,
                                            source: "ngv_storage_probe_mode = '\(mode)'\n" + script)
            guard result.response.state == .awaitingConfirmation,
                  let url = result.stagedOutputs["storage-proof.json"],
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  value["mode"] as? String == mode,
                  let capacity = value["capacityBytes"] as? UInt64, capacity > 0, capacity <= 64 * 1_024 * 1_024,
                  let filled = value["filledBytes"] as? UInt64, filled > 0, filled <= capacity,
                  value["fileSizeLimitBytes"] as? UInt64 == 8 * 1_024 * 1_024,
                  let pressureFiles = value["pressureFileCount"] as? Int, pressureFiles >= 2,
                  let largestFile = value["largestPressureFileBytes"] as? UInt64,
                  largestFile > 0, largestFile <= 8 * 1_024 * 1_024,
                  value["retainedBytes"] as? UInt64 == 4 * 1_024 * 1_024,
                  value["storageErrno"] as? Int == Int(ENOSPC),
                  let denied = value["retentionDeniedErrno"] as? Int,
                  (denied == 0 || (mode != "memory-entry" && [Int(EPERM), Int(EACCES)].contains(denied))) else {
                throw BpyRuntimeError.invalidOutput("The bounded volume did not prove ENOSPC for \(mode).")
            }
            proofs.append(value)
            _ = try session.cancel(jobID: jobID)
        }
        guard session.close() else {
            throw BpyRuntimeError.invalidOutput("The bounded runtime volume could not be released.")
        }
        return proofs
    }

    private static func waitUntilReleased(_ session: BpyRuntimeSession) throws {
        let deadline = Date().addingTimeInterval(90)
        while session.occupiesHostSlot, Date() < deadline {
            if let failure = session.cleanupFailure {
                throw BpyRuntimeError.invalidOutput("Runtime cleanup failed: " + failure)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !session.occupiesHostSlot else {
            throw BpyRuntimeError.invalidOutput("The closed document retained its runtime slot.")
        }
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
        scene.world = bpy.data.worlds.new('NGV_World')
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
        return """
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
