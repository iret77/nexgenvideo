import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

struct BpyLaunchLifecycleTests {
    @Test func failedOutputCanRetireButAnUnreadableReportCannotProveWorkerAbsence() {
        var streams = BpyLaunchLifecycle.Streams()
        streams.report = .eof; streams.errors = .eof; streams.output = .failing(EIO)
        #expect(!streams.terminal)
        streams.output.reachedEOF()
        #expect(!streams.terminal)
        streams.output = .failed(EIO); streams.errors = .open
        #expect(!streams.terminal)
        streams.errors = .eof
        #expect(streams.terminal)
        #expect(streams.output == .failed(EIO))
        #expect(streams.errorCode == EIO)
        streams.output.reachedEOF()
        #expect(streams.output == .failed(EIO))
        streams.report = .failed(EBADF)
        #expect(!streams.terminal)
        streams.output = .eof; streams.errors = .failed(EIO)
        #expect(!streams.terminal)
        streams.report = .eof
        #expect(streams.terminal)
        streams.errors = .eof
        #expect(streams.terminal)
        #expect(streams.errorCode == 0)
    }

    private final class Unstarted: @unchecked Sendable {
        private let lock = NSLock()
        private var awake = 100.0
        private var level = BpyMemoryPressure.normal
        private var bound = Set<UUID>(), stopped = Set<UUID>()
        func clock() -> BpyClockReading { lock.withLock { .init(awake: awake, continuous: awake) } }
        func sample() -> BpyMemoryCoordinator.SensorReading { lock.withLock { .init(level: level, error: nil, permanent: false) } }
        func set(_ value: BpyMemoryPressure, at time: Double) { lock.withLock { level = value; awake = time } }
        func install(_ id: UUID) { lock.withLock { _ = bound.insert(id) } }
        func claim(_ id: UUID) -> Bool {
            lock.withLock {
                guard bound.remove(id) != nil else { return false }
                stopped.insert(id)
                return true
            }
        }
        func mayStart(_ id: UUID) -> Bool { lock.withLock { bound.contains(id) && !stopped.contains(id) } }
    }

    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<BpyAdmissionIdentity, any Error>?
        let completed = DispatchSemaphore(value: 0)
        func finish(_ value: Result<BpyAdmissionIdentity, any Error>) { lock.withLock { result = value }; completed.signal() }
        func value() throws -> BpyAdmissionIdentity { try lock.withLock { try #require(result).get() } }
    }

    @Test func aPressureStopBeforeAnyLaunchFinishesWithoutTheClientOrAFalseGlobalCleanupFailure() throws {
        let fixture = Unstarted(), memory = BpyMemoryCoordinator(sensor: fixture.sample, clock: fixture.clock)
        let owner = UUID(), generation = UUID(), stopped = DispatchSemaphore(value: 0)
        try memory.register(owner: owner, generation: generation)
        let admission = try memory.admit(owner: owner, generation: generation, transport: UUID(), job: UUID(),
            kind: .job, timeout: 30, cancellation: .init())
        defer { memory.finish(admission.id); memory.forget(admission.id) }
        fixture.install(admission.id)
        try memory.bind(admission.id, handler: .init(request: { [weak memory] _ in
            if let memory { BpyLaunchLifecycle.finishUnstarted(permit: admission.id, memory: memory) { fixture.claim(admission.id) } }
            stopped.signal()
        }, cleanup: {}))
        fixture.set(.critical, at: 100.1)
        #expect(stopped.wait(timeout: .now() + 2) == .success)
        let receipt = try memory.receipt(admission.id)
        #expect(receipt.firstRelease == nil)
        #expect(receipt.stop == .pressure)
        #expect(receipt.cleanupComplete)
        #expect(receipt.cleanupFinishedAt == 100.1)
        #expect(!fixture.mayStart(admission.id))
        fixture.set(.warning, at: 106)
        #expect(!BpyLaunchLifecycle.finishUnstarted(permit: admission.id, memory: memory) { fixture.claim(admission.id) })
        #expect(try memory.receipt(admission.id).cleanupFinishedAt == 100.1)
        #expect(throws: BpyAdmissionFailure.self) { try memory.prepareLaunch(admission.id) }
        let next = Admission(), cancellation = BpyOperationCancellation()
        DispatchQueue.global().async {
            next.finish(Result { try memory.admit(owner: owner, generation: generation, transport: UUID(), job: UUID(),
                kind: .job, timeout: 30, cancellation: cancellation) })
        }
        let completed = next.completed.wait(timeout: .now() + 2)
        if completed != .success { cancellation.cancel(); _ = next.completed.wait(timeout: .now() + 1) }
        #expect(completed == .success)
        let successor = try next.value()
        defer { memory.finish(successor.id); memory.forget(successor.id) }
        #expect(try memory.receipt(successor.id).failure == nil)
    }

    private final class Observation {
        var hasProcess = true, running = true, hasSupervisor = false, spawnFinished = false
        var reportEOF = false, workerEnded = false
        var reason: BpyMemoryStop?, failure: BpyMemoryStop?
        var inspectionError: POSIXError?
        var events: [String] = []
        var finishes = 0

        func poll() throws -> Bool {
            try BpyLaunchLifecycle.poll(hasProcess: hasProcess,
                isRunning: { self.events.append("inspect-supervisor"); return self.running },
                reap: { self.events.append("reap-supervisor") },
                hasSupervisor: { self.hasSupervisor }, spawnFinished: { self.spawnFinished },
                stopped: { self.reason != nil }, failure: { self.failure }, reportEOF: { self.reportEOF },
                workerEnded: {
                    self.events.append("inspect-worker")
                    if let error = self.inspectionError { throw error }
                    return self.workerEnded
                }, stop: { if self.reason == nil { self.reason = $0 }; self.events.append("stop") },
                finish: { self.finishes += 1; self.events.append("finish") })
        }
    }

    @Test func inProgressSpawnCannotBeClassifiedAsFailureOrAuthorizedWithoutAnIdentity() throws {
        let observation = Observation()
        observation.hasProcess = false
        #expect(try !observation.poll())
        #expect(observation.events.isEmpty)
        observation.hasProcess = true
        #expect(try !observation.poll())
        #expect(observation.reason == nil)
        observation.spawnFinished = true
        #expect(try !observation.poll())
        #expect(observation.reason == .launchFailed)
        observation.running = false; observation.reportEOF = true; observation.workerEnded = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 1)
    }

    @Test func anObservedLiveSupervisorCanContinueToTheAuthorizationGate() throws {
        let observation = Observation()
        #expect(try !observation.poll())
        observation.hasSupervisor = true
        #expect(try observation.poll())
        #expect(observation.reason == nil)
        #expect(observation.finishes == 0)
        #expect(!observation.events.contains("stop"))
    }

    @Test func aFailedLaunchIsReapedBeforeAuthorizationAndWaitsForLateEOFAndItsWorker() throws {
        let observation = Observation()
        observation.running = false; observation.failure = .launchFailed
        #expect(try !observation.poll())
        #expect(observation.events == ["inspect-supervisor", "reap-supervisor", "stop"])
        #expect(observation.reason == .launchFailed)
        #expect(observation.finishes == 0)
        observation.reportEOF = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 0)
        observation.workerEnded = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 1)
        #expect(observation.reason == .launchFailed)
    }

    @Test func aStoppedLaunchCannotAuthorizeAndStillReapsAfterItsWorkerFinallyExits() throws {
        let observation = Observation()
        observation.reason = .pressure; observation.hasSupervisor = true; observation.failure = .launchFailed
        #expect(try !observation.poll())
        observation.running = false; observation.reportEOF = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 0)
        observation.workerEnded = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 1)
        #expect(observation.reason == .pressure)
        #expect(!observation.events.contains("stop"))
    }

    @Test func supervisorExitWithALiveWorkerRemainsOwnedAndGetsTheOrphanReason() throws {
        let observation = Observation()
        observation.running = false; observation.reportEOF = true
        #expect(try !observation.poll())
        #expect(observation.reason == .orphanedWorker)
        #expect(observation.finishes == 0)
        observation.inspectionError = POSIXError(.EIO)
        #expect(throws: POSIXError.self) { _ = try observation.poll() }
        #expect(observation.finishes == 0)
        observation.inspectionError = nil; observation.workerEnded = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 1)
    }

    @Test func readFailureCannotBecomeReportEOFOrAuthorizeEvenAfterTheSupervisorExits() throws {
        let observation = Observation()
        observation.hasSupervisor = true; observation.failure = .observationFailed
        #expect(try !observation.poll())
        #expect(observation.reason == .observationFailed)
        observation.running = false; observation.workerEnded = true
        #expect(try !observation.poll())
        #expect(observation.finishes == 0)
        #expect(!observation.events.contains("inspect-worker"))
    }
}
