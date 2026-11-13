import BpyRuntimeProtocol
import Darwin
import Foundation
@testable import NexGenVideo
import Testing

@Suite("Bpy authenticated host observation")
struct BpyHostMonitorTests {
    @MainActor @Test func cleanupWithoutADetailedFailureNamesTheActualRetryAction() {
        let error = BpyRuntimeHost.cleanupError(reason: nil)
        #expect(error.localizedFailureReason == "The runtime storage is still in use.")
        #expect(error.localizedRecoverySuggestion?.contains("Quit NexGenVideo") == true)
        #expect(error.localizedRecoverySuggestion?.contains("above") == false)
        let detailed = BpyRuntimeHost.cleanupError(reason: "The owned storage operation is still running.")
        #expect(detailed.localizedFailureReason == "The owned storage operation is still running.")
        #expect(detailed.localizedRecoverySuggestion == error.localizedRecoverySuggestion)
    }

    private final class Kernel: @unchecked Sendable {
        let lock = NSLock()
        var processes: [Int32: BpyObservedProcess]
        var inspectionError: POSIXError?
        var vnodeReads = 0
        init(_ values: [BpyObservedProcess]) { processes = Dictionary(uniqueKeysWithValues: values.map { ($0.pid, $0) }) }
        func process(_ pid: Int32) -> BpyObservedProcess? { lock.withLock { processes[pid] } }
        func set(_ value: BpyObservedProcess?, pid: Int32) { lock.withLock { processes[pid] = value } }
        func failInspection() { lock.withLock { inspectionError = POSIXError(.EPERM) } }
        func inspector() -> BpyHostMonitor.Inspector {
            .init(canonical: { $0.path }, process: { self.process($0) }, descendants: { root in
                self.lock.withLock { self.processes.values.filter { $0.parent == root.pid } }
            }, matches: { self.process($0.pid)?.start == $0.start }, vnodes: { _ in
                try self.lock.withLock {
                    self.vnodeReads += 1
                    if let error = self.inspectionError { throw error }
                    return [.init(device: 1, inode: 42, links: 0, openFlags: 3, logical: 8_192, blocks: 16, path: nil)]
                }
            })
        }
    }

    private struct Fixture {
        let layout: BpyRuntimeBundleLayout
        let kernel: Kernel
        let supervisor: BpyObservedProcess
        let child: BpyObservedProcess
        let observation: BpyProcessObservation
        init() throws {
            layout = try .init(app: URL(fileURLWithPath: "/Fixture.app"), serviceName: bpyRuntimeServiceNames[0])
            supervisor = .init(pid: 20, start: 200, parent: 1, executable: layout.supervisor.path, footprint: 2_048)
            child = .init(pid: 30, start: 300, parent: 20, executable: layout.supervisor.path, footprint: 4_096)
            kernel = Kernel([.init(pid: 10, start: 100, parent: 1,
                executable: layout.service.appendingPathComponent("Contents/MacOS/NexGenVideoBpyService").path, footprint: 1_024),
                supervisor, child])
            observation = BpyProcessObservation(supervisor: supervisor,
                workerExecutable: layout.runtime.appendingPathComponent("python/bin/python3.13").path,
                inspector: kernel.inspector())
            try observation.captureChild(child)
        }
    }

    @Test func sampledChildAndHiddenVnodesRemainOwnedUntilBothProcessesExit() throws {
        let f = try Fixture()
        let sample = try f.observation.sample()
        #expect(sample.worker?.pid == 30)
        #expect(sample.worker?.start == 300)
        #expect(sample.vnodes.first?.inode == 42)
        f.kernel.set(nil, pid: 20)
        #expect(throws: POSIXError.self) { try f.observation.sample() }
        f.kernel.set(nil, pid: 30)
        let gone = try f.observation.sample()
        #expect(gone.supervisor == nil && gone.worker == nil && gone.descendants.isEmpty)
        #expect(gone.ended.map(\.pid) == [20, 30])
        #expect(gone.ended.map(\.start) == [200, 300])
    }

    @Test func inspectionDenialCannotBecomeEmptySuccessfulMeasurement() throws {
        let f = try Fixture()
        f.kernel.failInspection()
        #expect(throws: POSIXError.self) { try f.observation.sample() }
        #expect(f.kernel.vnodeReads == 1)
    }

    @Test func reusedWorkerAndSupervisorPIDOrForeignExecutableAreRefused() throws {
        for (pid, start, parent, executable) in [
            (Int32(30), UInt64(301), Int32(20), "/Fixture.app/foreign"),
            (30, 300, 20, "/unrelated"), (20, 201, 1, "/unrelated")
        ] {
            let f = try Fixture()
            f.kernel.set(.init(pid: pid, start: start, parent: parent, executable: executable, footprint: 1), pid: pid)
            #expect(throws: POSIXError.self) { try f.observation.sample() }
        }
    }

    @Test func execRetainsKernelBirthButOnlyTheBoundPythonExecutableIsAccepted() throws {
        let f = try Fixture()
        f.kernel.set(.init(pid: 30, start: 300, parent: 20,
            executable: f.layout.runtime.appendingPathComponent("python/bin/python3.13").path, footprint: 9_000), pid: 30)
        #expect(try f.observation.sample().worker?.footprint == 9_000)
        f.kernel.set(.init(pid: 30, start: 301, parent: 20,
            executable: f.layout.runtime.appendingPathComponent("python/bin/python3.13").path, footprint: 9_000), pid: 30)
        #expect(throws: POSIXError.self) { try f.observation.sample() }
    }

    @Test func aSecondDescendantCannotHideInsideTheSingleWorkerMeasurement() throws {
        let f = try Fixture()
        f.kernel.set(.init(pid: 31, start: 310, parent: 20, executable: f.layout.supervisor.path, footprint: 1), pid: 31)
        #expect(throws: POSIXError.self) { try f.observation.sample() }
    }

    private final class Reply: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var data: Data?
        func store(_ value: Data) { lock.withLock { data = value }; ready.signal() }
    }

    @Test func serviceCannotAttachAnArbitraryExistingProcessOrLaunchWithoutHostAdmission() throws {
        let f = try Fixture(), transport = UUID()
        let monitor = BpyHostMonitor(peerPID: { 10 }, transport: transport, layout: f.layout, inspector: f.kernel.inspector())
        for operation in [BpyMonitorRequest.Operation.attach, .launch, .sample, .detach] {
            let box = Reply()
            let request = BpyMonitorRequest(transport: transport, execution: UUID(), operation: operation, supervisorPID: 20)
            monitor.inspect(try JSONEncoder().encode(request)) { box.store($0) }
            try #require(box.ready.wait(timeout: .now() + 3) == .success)
            let result = try JSONDecoder().decode(BpyMonitorResponse.self, from: #require(box.lock.withLock { box.data }))
            #expect(result.status == .refused)
        }
        #expect(f.kernel.vnodeReads == 0)
    }

    @Test func realSupervisorSignalDeathCannotHideItsWaitingChild() throws {
        let input = Pipe(), output = Pipe()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
            try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        let process = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 3<&0; /bin/sh -c 'printf ready; read value' <&3 & wait"],
            environment: [:], directory: URL(fileURLWithPath: "/"), input: input.fileHandleForReading,
            output: output.fileHandleForWriting)
        defer { _ = try? process.terminateAndReap() }
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(Darwin.poll(&descriptor, 1, 3_000) == 1)
        try #require(output.fileHandleForReading.read(upToCount: 5) == Data("ready".utf8))
        let supervisor = try #require(try BpyKernelInspection.process(process.processIdentifier))
        let worker = try #require(BpyKernelInspection.descendants(of: supervisor).first)
        let observation = BpyProcessObservation(supervisor: supervisor, workerExecutable: worker.executable)
        try observation.captureChild(worker)
        try process.signal(SIGKILL)
        #expect(try process.waitForTermination().signal == SIGKILL)
        #expect(try BpyKernelInspection.matches(worker))
        #expect(throws: POSIXError.self) { try observation.sample() }
        try input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
        let deadline = try BpyRuntimeClock.awakeSeconds() + 3
        func workerPresent() throws -> Bool {
            do { return try BpyKernelInspection.matches(worker) }
            catch let pending as BpyKernelInspection.ExitPending
                where pending == .init(pid: worker.pid, start: worker.start) { return true }
        }
        while try workerPresent() {
            try #require(BpyRuntimeClock.awakeSeconds() < deadline)
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(try observation.sample().ended.map(\.start) == [supervisor.start, worker.start])
    }
}

@MainActor
struct BpyCleanupAdmissionTests {
    @MainActor private final class Fixture {
        let gate = BpyCleanupAdmission()
        let attempt = UUID()
        let ready = AsyncStream<Void>.makeStream()
        var occupied = true
        var pending = true
        var owned = true
        var valid = true
        var finishBeforeRegistration = false
        var validations = 0
        var allocations = 0
        var session: UUID?

        func validate() throws {
            validations += 1
            if !valid { throw BpyRuntimeError.unavailable("The document generation changed.") }
            if finishBeforeRegistration, validations == 2 { finish(success: true) }
        }

        func acquire() -> UUID? {
            guard !occupied else { return nil }
            if session == nil { session = UUID(); allocations += 1 }
            return session
        }

        func cleanup() -> BpyCleanupAdmission.Cleanup? {
            guard owned else { return nil }
            return .init(attempt: attempt, isPending: {
                self.ready.continuation.yield(())
                return self.pending
            }, occupiesSlot: { self.occupied }, failure: { "Owned cleanup did not release its slot." })
        }

        func start(id: UUID = UUID(), timeout: Duration = .seconds(5)) -> Task<UUID, any Error> {
            Task { try await gate.admit(id: id, timeout: timeout, validate: validate, acquire: acquire, cleanup: cleanup) }
        }

        func registered() async {
            var iterator = ready.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        func finish(success: Bool) {
            pending = false
            if success { occupied = false }
            gate.complete(attempt: attempt, success: success)
        }
    }

    @Test func ownClosingSlotWaitsForItsActualCompletionAndAllocatesOnce() async throws {
        let fixture = Fixture(), request = fixture.start()
        await fixture.registered()
        #expect(fixture.gate.pendingCount == 1)
        #expect(fixture.allocations == 0)
        fixture.gate.complete(attempt: UUID(), success: true)
        #expect(fixture.gate.pendingCount == 1)
        fixture.finish(success: true)
        let session = try await request.value
        #expect(session == fixture.session)
        #expect(fixture.allocations == 1)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func anotherDocumentsActiveSlotDoesNotBecomeAnOwnedCleanupWait() async {
        let fixture = Fixture()
        fixture.owned = false
        do { _ = try await fixture.start().value; Issue.record("A foreign slot was admitted.") }
        catch { #expect(error.localizedDescription.contains("other projects")) }
        #expect(fixture.gate.pendingCount == 0)
        #expect(fixture.allocations == 0)
    }

    @Test(arguments: [false, true]) func cleanupMustSucceedAndActuallyReleaseItsSlot(success: Bool) async {
        let fixture = Fixture(), request = fixture.start()
        await fixture.registered()
        fixture.pending = false
        fixture.gate.complete(attempt: fixture.attempt, success: success)
        do { _ = try await request.value; Issue.record("A reserved slot was reused.") }
        catch { #expect(error.localizedDescription.contains("did not release")) }
        #expect(fixture.allocations == 0)
        #expect(fixture.occupied)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func changedDocumentIdentityAfterCleanupPreventsLateAllocation() async {
        let fixture = Fixture(), request = fixture.start()
        await fixture.registered()
        fixture.valid = false
        fixture.finish(success: true)
        do { _ = try await request.value; Issue.record("A stale document acquired a session.") }
        catch { #expect(error.localizedDescription.contains("generation changed")) }
        #expect(fixture.allocations == 0)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func concurrentPresentationsJoinCleanupThenShareOneSession() async throws {
        let fixture = Fixture(), first = fixture.start(), second = fixture.start()
        await fixture.registered()
        await fixture.registered()
        #expect(fixture.gate.pendingCount == 2)
        fixture.finish(success: true)
        let firstSession = try await first.value, secondSession = try await second.value
        #expect(firstSession == secondSession)
        #expect(fixture.allocations == 1)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func cancellationUnregistersOnlyItsWaiterWithoutCompletingCleanup() async throws {
        let fixture = Fixture(), first = fixture.start(), second = fixture.start()
        await fixture.registered()
        await fixture.registered()
        first.cancel()
        do { _ = try await first.value; Issue.record("A cancelled request acquired a session.") }
        catch is CancellationError {} catch { Issue.record(error) }
        #expect(fixture.pending && fixture.occupied)
        #expect(fixture.gate.pendingCount == 1)
        fixture.finish(success: true)
        _ = try await second.value
        #expect(fixture.allocations == 1)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func cancellationBeforeAdmissionDoesNotAllocateOrRegister() async {
        let fixture = Fixture()
        fixture.occupied = false
        let request = fixture.start()
        request.cancel()
        do { _ = try await request.value; Issue.record("An already cancelled request was admitted.") }
        catch is CancellationError {} catch { Issue.record(error) }
        #expect(fixture.validations == 0)
        #expect(fixture.allocations == 0)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func timeoutLeavesCleanupAndSlotOwnedAndIgnoresLateCompletion() async {
        let fixture = Fixture(), request = fixture.start(timeout: .milliseconds(10))
        await fixture.registered()
        do { _ = try await request.value; Issue.record("A timed out request acquired a session.") }
        catch { #expect(error.localizedDescription.contains("still closing")) }
        #expect(fixture.pending && fixture.occupied)
        #expect(fixture.allocations == 0)
        #expect(fixture.gate.pendingCount == 0)
        fixture.finish(success: true)
        #expect(fixture.allocations == 0)
    }

    @Test func cleanupCompletedBeforeWaitRegistrationIsNotLost() async throws {
        let fixture = Fixture()
        fixture.finishBeforeRegistration = true
        _ = try await fixture.start().value
        #expect(fixture.allocations == 1)
        #expect(fixture.gate.pendingCount == 0)
    }

    @Test func presentationCloseAndShutdownCancelWaitersWithoutReleasingSlots() async {
        let fixture = Fixture(), id = UUID()
        let first = fixture.start(id: id), second = fixture.start()
        await fixture.registered()
        await fixture.registered()
        fixture.gate.cancel(id: id)
        fixture.gate.cancelAll()
        for request in [first, second] {
            do { _ = try await request.value; Issue.record("A closed presentation acquired a session.") }
            catch is CancellationError {} catch { Issue.record(error) }
        }
        #expect(fixture.pending && fixture.occupied)
        #expect(fixture.allocations == 0)
        #expect(fixture.gate.pendingCount == 0)
    }
}
