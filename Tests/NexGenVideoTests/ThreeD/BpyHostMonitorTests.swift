import BpyRuntimeProtocol
import Darwin
import Foundation
@testable import NexGenVideo
import Testing

@Suite("Bpy authenticated host observation")
struct BpyHostMonitorTests {
    private final class Kernel: @unchecked Sendable {
        let lock = NSLock()
        var processes: [Int32: BpyObservedProcess]
        var inspectionError: POSIXError?
        var vnodeReads = 0

        init(_ processes: [BpyObservedProcess]) { self.processes = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }) }

        func process(_ pid: Int32) -> BpyObservedProcess? {
            lock.lock(); defer { lock.unlock() }
            return processes[pid]
        }

        func set(_ value: BpyObservedProcess?, pid: Int32) {
            lock.lock(); defer { lock.unlock() }
            processes[pid] = value
        }

        func failInspection() {
            lock.lock(); defer { lock.unlock() }
            inspectionError = POSIXError(.EPERM)
        }

        func inspector() -> BpyHostMonitor.Inspector {
            .init(canonical: { $0.path }, process: { self.process($0) }, descendants: { root in
                self.lock.lock(); defer { self.lock.unlock() }
                return self.processes.values.filter { $0.parent == root.pid }
            }, matches: { self.process($0.pid)?.start == $0.start }, vnodes: { _ in
                self.lock.lock(); defer { self.lock.unlock() }
                self.vnodeReads += 1
                if let error = self.inspectionError { throw error }
                return [.init(device: 1, inode: 42, links: 0, openFlags: 3, logical: 8_192, blocks: 16, path: nil)]
            })
        }
    }

    private struct Fixture {
        let transport = UUID()
        let execution = UUID()
        let layout: BpyRuntimeBundleLayout
        let kernel: Kernel
        let monitor: BpyHostMonitor

        init() throws {
            layout = try .init(app: URL(fileURLWithPath: "/Fixture.app"), serviceName: bpyRuntimeServiceNames[0])
            kernel = Kernel([
                .init(pid: 10, start: 100, parent: 1,
                      executable: layout.service.appendingPathComponent("Contents/MacOS/NexGenVideoBpyService").path, footprint: 1_024),
                .init(pid: 20, start: 200, parent: 10, executable: layout.supervisor.path, footprint: 2_048),
                .init(pid: 30, start: 300, parent: 20, executable: layout.supervisor.path, footprint: 4_096),
            ])
            monitor = BpyHostMonitor(peerPID: { 10 }, transport: transport, layout: layout, inspector: kernel.inspector())
        }

        func request(_ operation: BpyMonitorRequest.Operation, epoch: UUID? = nil, sequence: UInt64 = 0) -> BpyMonitorRequest {
            .init(transport: transport, execution: execution, operation: operation, epoch: epoch, sequence: sequence, supervisorPID: 20)
        }
    }

    private final class Reply: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Data?
        func store(_ data: Data) { lock.lock(); value = data; lock.unlock(); ready.signal() }
        func load() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func inspect(_ monitor: BpyHostMonitor, _ request: BpyMonitorRequest) throws -> BpyMonitorResponse {
        let reply = Reply()
        monitor.inspect(try JSONEncoder().encode(request)) { reply.store($0) }
        try #require(reply.ready.wait(timeout: .now() + 3) == .success)
        return try JSONDecoder().decode(BpyMonitorResponse.self, from: #require(reply.load()))
    }

    @Test func attachSampleAndDetachRequireActualChildExit() throws {
        let f = try Fixture()
        let attached = try inspect(f.monitor, f.request(.attach))
        #expect(attached.status == .attached)
        let epoch = try #require(attached.epoch)
        let sample = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1))
        #expect(sample.status == .observed)
        #expect(sample.worker?.pid == 30)
        #expect(sample.worker?.start == 300)
        #expect(sample.vnodes.first?.inode == 42)
        f.kernel.set(nil, pid: 20)
        #expect(try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 2)).status == .refused)
        f.kernel.set(nil, pid: 30)
        let detached = try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 3))
        #expect(detached.status == .detached)
        #expect(detached.ended.map(\.pid) == [20, 30])
        #expect(detached.ended.map(\.start) == [200, 300])
        #expect(try inspect(f.monitor, f.request(.attach)).status == .refused)
    }

    @Test func forgedTransportEpochSequenceAndSupervisorAreRefused() throws {
        let f = try Fixture()
        let wrongTransport = BpyMonitorRequest(transport: UUID(), execution: f.execution, operation: .attach, supervisorPID: 20)
        #expect(try inspect(f.monitor, wrongTransport).status == .refused)
        let wrongParent = BpyMonitorRequest(transport: f.transport, execution: f.execution, operation: .attach, supervisorPID: 30)
        #expect(try inspect(f.monitor, wrongParent).status == .refused)
        let attached = try inspect(f.monitor, f.request(.attach))
        let epoch = try #require(attached.epoch)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: UUID(), sequence: 1)).status == .refused)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 2)).status == .refused)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1)).status == .observed)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1)).status == .refused)
    }

    @Test func inspectionDenialCannotBecomeEmptySuccessfulMeasurement() throws {
        let f = try Fixture()
        let epoch = try #require(inspect(f.monitor, f.request(.attach)).epoch)
        f.kernel.failInspection()
        let result = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1))
        #expect(result.status == .refused)
        #expect(result.errorCode == EPERM)
        f.kernel.set(nil, pid: 20)
        #expect(try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 2)).status == .refused)
    }

    @Test func reusedServiceIdentityAndForeignExecutableAreRefused() throws {
        let f = try Fixture()
        let epoch = try #require(inspect(f.monitor, f.request(.attach)).epoch)
        f.kernel.set(.init(pid: 30, start: 300, parent: 20, executable: "/unrelated", footprint: 1), pid: 30)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1)).status == .refused)
        let peer = try #require(f.kernel.process(10))
        f.kernel.set(.init(pid: 10, start: 101, parent: 1, executable: peer.executable, footprint: 1), pid: 10)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 2)).status == .refused)
    }

    @Test func reusedWorkerPIDCannotAcquireThePreviousObservationLease() throws {
        let f = try Fixture()
        let epoch = try #require(inspect(f.monitor, f.request(.attach)).epoch)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1)).status == .observed)
        f.kernel.set(.init(pid: 30, start: 301, parent: 20, executable: f.layout.supervisor.path, footprint: 1), pid: 30)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 2)).status == .refused)
    }
    @Test func lostAttachReplyCanRecoverOnlyAfterPriorProcessesEnd() throws {
        let f = try Fixture()
        let first = try inspect(f.monitor, f.request(.attach))
        let epoch = try #require(first.epoch)
        _ = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1))
        f.kernel.set(.init(pid: 40, start: 400, parent: 10, executable: f.layout.supervisor.path, footprint: 1), pid: 40)
        let next = BpyMonitorRequest(transport: f.transport, execution: UUID(), operation: .attach, supervisorPID: 40)
        #expect(try inspect(f.monitor, next).status == .refused)
        f.kernel.set(nil, pid: 20)
        #expect(try inspect(f.monitor, next).status == .refused)
        f.kernel.set(nil, pid: 30)
        let recovered = try inspect(f.monitor, next)
        #expect(recovered.status == .attached)
        #expect(recovered.supervisor?.pid == 40)
        #expect(recovered.epoch != epoch)
        #expect(try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 2)).status == .refused)
    }

    @Test func sampleAfterExitContainsExactEndedIdentities() throws {
        let f = try Fixture()
        let epoch = try #require(inspect(f.monitor, f.request(.attach)).epoch)
        _ = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1))
        f.kernel.set(nil, pid: 20)
        f.kernel.set(nil, pid: 30)
        let gone = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 2))
        #expect(gone.status == .gone)
        #expect(gone.supervisor == nil)
        #expect(gone.ended.map(\.start) == [200, 300])
    }

    private func recover(_ monitor: BpyHostMonitor) throws -> Bool {
        let reply = Reply()
        monitor.recover(timeout: 0.02) { reply.store(Data([$0 ? 1 : 0])) }
        try #require(reply.ready.wait(timeout: .now() + 3) == .success)
        return try #require(reply.load()) == Data([1])
    }

    @Test func lostDetachReplyCanBeFetchedAgainWithoutAnActiveLease() throws {
        let f = try Fixture()
        let epoch = try #require(inspect(f.monitor, f.request(.attach)).epoch)
        _ = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1))
        f.kernel.set(nil, pid: 20)
        f.kernel.set(nil, pid: 30)
        let original = try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 2))
        let retry = try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 3))
        #expect(retry.status == .detached)
        #expect(retry.ended == original.ended)
        #expect(retry.sequence == 3)
        #expect(try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 3)).status == .detached)
        #expect(try inspect(f.monitor, f.request(.detach, epoch: epoch, sequence: 2)).status == .refused)
        #expect(try inspect(f.monitor, f.request(.detach, epoch: UUID(), sequence: 4)).status == .refused)
    }

    @Test func transportRecoveryCannotIgnoreWorkerSurvivingItsSupervisor() throws {
        let f = try Fixture()
        let epoch = try #require(inspect(f.monitor, f.request(.attach)).epoch)
        _ = try inspect(f.monitor, f.request(.sample, epoch: epoch, sequence: 1))
        f.kernel.set(nil, pid: 20)
        #expect(try !recover(f.monitor))
        f.kernel.set(nil, pid: 30)
        #expect(try recover(f.monitor))
        #expect(try inspect(f.monitor, f.request(.attach)).status == .refused)
    }

    @Test func transportRecoveryDrainsAnAlreadyQueuedAttach() throws {
        let f = try Fixture()
        let reply = Reply()
        f.monitor.inspect(try JSONEncoder().encode(f.request(.attach))) { reply.store($0) }
        #expect(try !recover(f.monitor))
        try #require(reply.ready.wait(timeout: .now() + 3) == .success)
        let attached = try JSONDecoder().decode(BpyMonitorResponse.self, from: #require(reply.load()))
        #expect(attached.status == .attached)
    }

    @Test func realSupervisorSignalDeathCannotHideItsWaitingChild() throws {
        let input = Pipe(), output = Pipe()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let supervisor = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 3<&0; /bin/sh -c 'printf ready; read value' <&3 & wait"],
            environment: [:], directory: URL(fileURLWithPath: "/"), input: input.fileHandleForReading,
            output: output.fileHandleForWriting)
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(Darwin.poll(&descriptor, 1, 3_000) == 1)
        try #require(output.fileHandleForReading.read(upToCount: 5) == Data("ready".utf8))
        let host = try #require(BpyKernelInspection.process(getpid()))
        let shell = try #require(BpyKernelInspection.process(supervisor.processIdentifier)).executable
        let transport = UUID(), execution = UUID()
        let layout = try BpyRuntimeBundleLayout(app: URL(fileURLWithPath: "/Fixture.app"), serviceName: bpyRuntimeServiceNames[0])
        let inspector = BpyHostMonitor.Inspector(canonical: { url in
            url.lastPathComponent == "NexGenVideoBpyService" ? host.executable : shell
        }, vnodes: { _ in [] })
        let monitor = BpyHostMonitor(peerPID: { host.pid }, transport: transport, layout: layout, inspector: inspector)
        let attached = try inspect(monitor, .init(transport: transport, execution: execution,
            operation: .attach, supervisorPID: supervisor.processIdentifier))
        let epoch = try #require(attached.epoch)
        let sample = try inspect(monitor, .init(transport: transport, execution: execution,
            operation: .sample, epoch: epoch, sequence: 1, supervisorPID: supervisor.processIdentifier))
        let worker = try #require(sample.worker)
        #expect(worker.executable == shell)
        try supervisor.signal(SIGKILL)
        #expect(try supervisor.waitForTermination().signal == SIGKILL)
        #expect(try BpyKernelInspection.matches(worker))
        #expect(try !recover(monitor))
        try input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while try BpyKernelInspection.matches(worker) {
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(try recover(monitor))
    }

}
