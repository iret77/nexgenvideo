import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Bpy unreaped child ownership")
struct BpyOwnedProcessTests {
    @Test func exitObservationDoesNotReapAndRepeatedReapIsStable() throws {
        let process = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"], environment: [:], directory: URL(fileURLWithPath: "/"))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while try process.isRunning {
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(try !process.isRunning)
        #expect(try process.waitUntilExit() == 7)
        try process.signal(SIGKILL)
        #expect(try process.waitUntilExit() == 7)
    }

    @Test func ownedTermIgnoringChildIsStoppedKilledAndReaped() throws {
        let output = Pipe()
        let process = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf ready; while :; do :; done"],
            environment: [:], directory: URL(fileURLWithPath: "/"), output: output.fileHandleForWriting)
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        try output.fileHandleForWriting.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(Darwin.poll(&descriptor, 1, 3_000) == 1)
        try #require(descriptor.revents & Int16(POLLIN) != 0)
        let ready = try output.fileHandleForReading.read(upToCount: 5)
        try #require(ready == Data("ready".utf8))
        try process.terminateAndReap()
        #expect(try !process.isRunning)
        #expect(try process.waitUntilExit() == 128 + SIGKILL)
    }

    @Test func identityInspectionFailureCannotBecomeAnEmptyTree() throws {
        #expect(throws: POSIXError(.EPERM)) {
            try BpyProcessTreeInspection.descendants(root: 10, start: 100, identity: { _ in
                throw POSIXError(.EPERM)
            }, list: { _, _ in .init(count: 0, error: 0, pids: []) })
        }
    }

    @Test func supervisorEscalationPolicyDoesNotForceKillTheProcess() throws {
        let output = Pipe()
        let process = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf ready; while :; do :; done"],
            environment: [:], directory: URL(fileURLWithPath: "/"), output: output.fileHandleForWriting,
            allowsForcedTermination: false)
        defer {
            try? process.signal(SIGKILL)
            _ = try? process.waitUntilExit()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try output.fileHandleForWriting.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(Darwin.poll(&descriptor, 1, 3_000) == 1)
        try #require(descriptor.revents & Int16(POLLIN) != 0)
        try #require(output.fileHandleForReading.read(upToCount: 5) == Data("ready".utf8))
        #expect(throws: POSIXError(.ETIMEDOUT)) { try process.terminateAndReap() }
        #expect(try process.isRunning)
    }

    @Test func unknownServiceCannotSelectAnArbitraryBundle() throws {
        let app = URL(fileURLWithPath: "/Fixture.app")
        #expect(throws: CocoaError.self) {
            try BpyRuntimeBundleLayout(app: app, serviceName: "../../outside")
        }
        let first = try BpyRuntimeBundleLayout(app: app, serviceName: bpyRuntimeServiceNames[0])
        let second = try BpyRuntimeBundleLayout(app: app, serviceName: bpyRuntimeServiceNames[1])
        #expect(first.runtime != second.runtime)
        #expect(first.runtime.path.contains("NexGenVideoBpyService0.xpc/Contents/Resources/"))
        #expect(second.supervisor.path.hasSuffix("NexGenVideoBpyService1.xpc/Contents/MacOS/NexGenVideoBpySupervisor"))
    }
    @Test func explicitNullStreamsWorkAndClosedStreamIsRejected() throws {
        let process = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "if read value; then exit 9; fi; printf output; printf error >&2"],
            environment: [:], directory: URL(fileURLWithPath: "/"),
            input: .nullDevice, output: .nullDevice, errors: .nullDevice)
        #expect(try process.waitUntilExit() == 0)
        let closed = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        try closed.close()
        #expect(throws: POSIXError(.EBADF)) {
            try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
                environment: [:], directory: URL(fileURLWithPath: "/"), input: closed)
        }
    }

    @Test func hostTreatsUnreapedZombieAsEnded() throws {
        let input = Pipe()
        defer { try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close() }
        let process = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read value; exit 7"], environment: [:], directory: URL(fileURLWithPath: "/"),
            input: input.fileHandleForReading, output: .nullDevice, errors: .nullDevice)
        let observed = try BpyKernelInspection.process(process.processIdentifier)
        let live = try #require(observed)
        #expect(try BpyKernelInspection.matches(live))
        try input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while try process.isRunning {
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(try BpyKernelInspection.process(process.processIdentifier) == nil)
        #expect(try !BpyKernelInspection.matches(live))
        #expect(try process.waitUntilExit() == 7)
        #expect(try !BpyKernelInspection.matches(live))
    }

    @Test func canonicalExecutableUsesKernelFilesystemPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let alias = root.appendingPathComponent("alias")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        #expect(try BpyRuntimePath.canonical(alias) == BpyRuntimePath.canonical(target))
        #expect(try BpyRuntimePath.canonical(URL(fileURLWithPath: "/tmp")) == "/private/tmp")
        #expect(throws: POSIXError.self) { try BpyRuntimePath.canonical(root.appendingPathComponent("missing")) }
    }

    @Test func nonzeroNormalExitCannotBeConfusedWithSignalDeath() throws {
        let normal = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 137"], environment: [:], directory: URL(fileURLWithPath: "/"))
        let normalResult = try normal.waitForTermination()
        #expect(normalResult.exitStatus == 137)
        #expect(normalResult.exitedNormally)
        #expect(normalResult.signal == nil)
        let killed = try BpyOwnedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do :; done"], environment: [:], directory: URL(fileURLWithPath: "/"))
        try killed.signal(SIGKILL)
        let killedResult = try killed.waitForTermination()
        #expect(killedResult.exitStatus == 137)
        #expect(!killedResult.exitedNormally)
        #expect(killedResult.signal == SIGKILL)
        #expect(try killed.waitForTermination() == killedResult)
    }

    private final class MappingChurn: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var failure: Int32 = 0
        func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop(error: Int32 = 0) { lock.lock(); stopped = true; if error != 0 { failure = error }; lock.unlock() }
        func error() -> Int32 { lock.lock(); defer { lock.unlock() }; return failure }
    }

    @Test func mappingInspectionHandlesConcurrentRegionChanges() throws {
        let observed = try BpyKernelInspection.process(getpid())
        let identity = try #require(observed)
        let churn = MappingChurn()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while !churn.shouldStop() {
                let size = 4 * 1_024 * 1_024
                guard let region = Darwin.mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                      region != UnsafeMutableRawPointer(bitPattern: -1) else { churn.stop(error: errno); return }
                region.storeBytes(of: UInt8(1), as: UInt8.self)
                if Darwin.munmap(region, size) != 0 { churn.stop(error: errno); return }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        defer {
            churn.stop()
            #expect(group.wait(timeout: .now() + 3) == .success)
            #expect(churn.error() == 0)
        }
        for _ in 0..<8 {
            #expect(try !BpyKernelInspection.mappings(identity).isEmpty)
            #expect(try BpyKernelInspection.matches(identity))
        }
    }

}
