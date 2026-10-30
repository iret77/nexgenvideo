import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

struct BpyLaunchGateReleaseTests {
    private final class Gate {
        let lock = NSLock()
        var stop: BpyMemoryStop?
        var released = false
        var writes = 0
        private var readFD: Int32
        private let writeFD: Int32

        init() throws {
            var values: [Int32] = [-1, -1]
            guard pipe(&values) == 0 else { throw POSIXError(.EIO) }
            readFD = values[0]; writeFD = values[1]
            guard fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
        }
        func closeRead() { if readFD >= 0 { Darwin.close(readFD); readFD = -1 } }
        func write() throws {
            writes += 1
            var byte: UInt8 = 1
            guard Darwin.write(writeFD, &byte, 1) == 1 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        func pending() throws -> Int32 {
            var bytes: Int32 = -1
            guard ioctl(readFD, UInt(FIONREAD), &bytes) == 0 else { throw POSIXError(.EIO) }
            return bytes
        }
        deinit { closeRead(); Darwin.close(writeFD) }
    }

    @Test func stopAfterTheIdentityPrecheckPreventsAnyGateByteOrReleaseFlag() throws {
        try withPermit { memory, permit in
            let gate = try Gate()
            #expect(gate.stop == nil)
            gate.lock.withLock { gate.stop = .observationFailed }
            let accepted = try BpyLaunchGateRelease.authorize(memory: memory, permit: permit, lock: gate.lock,
                stopped: { gate.stop != nil }, writing: { try gate.write() }, released: { gate.released = true })
            #expect(!accepted && !gate.released && gate.writes == 0)
            #expect(try gate.pending() == 0)
            #expect(try memory.receipt(permit).stop == nil)
        }
    }

    @Test func aStoppedClosedGateDefersButAnUnstoppedBrokenGateStillReportsEPIPE() throws {
        try withPermit { memory, permit in
            let gate = try Gate()
            gate.closeRead()
            gate.lock.withLock { gate.stop = .ownershipViolation }
            #expect(try !BpyLaunchGateRelease.authorize(memory: memory, permit: permit, lock: gate.lock,
                stopped: { gate.stop != nil }, writing: { try gate.write() }, released: { gate.released = true }))
            #expect(gate.writes == 0 && !gate.released)
        }
        try withPermit { memory, permit in
            let gate = try Gate()
            gate.closeRead()
            do {
                _ = try BpyLaunchGateRelease.authorize(memory: memory, permit: permit, lock: gate.lock,
                    stopped: { gate.stop != nil }, writing: { try gate.write() }, released: { gate.released = true })
                Issue.record("An unstopped broken gate was hidden.")
            } catch let error as POSIXError { #expect(error.code == .EPIPE) }
            #expect(gate.writes == 1 && !gate.released)
        }
    }

    private func withPermit(_ body: (BpyMemoryCoordinator, UUID) throws -> Void) throws {
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) },
            clock: { .init(awake: 100, continuous: 100) })
        let owner = UUID(), generation = UUID()
        try memory.register(owner: owner, generation: generation)
        let permit = try memory.admit(owner: owner, generation: generation, transport: UUID(), job: nil,
            kind: .probe, timeout: 10, cancellation: .init())
        defer { memory.launchEnded(permit.id); memory.finish(permit.id); memory.forget(permit.id) }
        try memory.prepareLaunch(permit.id)
        try body(memory, permit.id)
    }
}
