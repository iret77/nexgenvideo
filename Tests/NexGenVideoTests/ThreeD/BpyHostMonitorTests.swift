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
        while try BpyKernelInspection.matches(worker) {
            try #require(BpyRuntimeClock.awakeSeconds() < deadline)
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(try observation.sample().ended.map(\.start) == [supervisor.start, worker.start])
    }
}
