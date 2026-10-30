import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyMemoryStateTests {
    private func clock(_ awake: Double, sleep: Double = 0) -> BpyClockReading {
        .init(awake: awake, continuous: awake + sleep)
    }

    private func request(_ state: inout BpyMemoryState, owner: UUID = UUID(), at time: Double = 0,
                         timeout: Double = 120, kind: BpyAdmissionIdentity.Kind = .job,
                         autoexec: Bool = false) throws -> BpyAdmissionIdentity {
        let generation = state.generations[owner] ?? UUID()
        try state.register(owner: owner, generation: generation)
        let identity = BpyAdmissionIdentity(id: UUID(), owner: owner, generation: generation,
            transport: UUID(), job: kind == .job ? UUID() : nil, kind: kind,
            insertedAt: time, admissionDeadline: time + timeout, timeout: timeout,
            diagnosticAutoexec: autoexec)
        try state.enqueue(identity, at: clock(time))
        return identity
    }

    private func healthy(_ state: inout BpyMemoryState, until end: Double, level: BpyMemoryPressure = .normal) {
        var now = state.previousClock?.awake ?? 0
        while now < end {
            now = min(end, now + 0.1)
            for permit in state.permits.values where permit.childRunning {
                state.serviceObserved(permit: permit.identity.id, at: clock(now))
            }
            state.sampled(level, permanent: false, at: clock(now))
        }
    }

    @Test func noInitialOrDispatchNormalAssumption() throws {
        var state = BpyMemoryState()
        let first = try request(&state)
        #expect(state.permits[first.id]?.admission == .queued)
        state.notified(flags: 1, at: clock(0))
        #expect(state.permits[first.id]?.admission == .queued)
        state.sampled(.normal, permanent: false, at: clock(0))
        #expect(state.permits[first.id]?.admission == .granted)
        let second = try request(&state)
        let third = try request(&state)
        #expect(state.permits[second.id]?.admission == .granted)
        #expect(state.permits[third.id]?.admission == .queued)
    }

    @Test func anUnreleasedPreparedLaunchRecordsTheActualAdmissionDeadlineGround() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let permit = try request(&state, timeout: 1)
        try state.prepareLaunch(permit: permit.id, at: clock(0))
        healthy(&state, until: 1)
        let stopped = try #require(state.permits[permit.id])
        #expect(stopped.firstRelease == nil)
        #expect(stopped.stop == .deadline)
        #expect(stopped.grounds.count == 1)
        #expect(stopped.grounds.first?.reason == .deadline)
        #expect(stopped.grounds.first?.clock?.awake == 1)
        #expect(stopped.cleanupStarted == 1)
        #expect(state.takeEffects().filter { $0.operation == .stop(.deadline) }.map(\.permit) == [permit.id])
    }

    @Test func warningDoesNotSerializeAdmittedChildren() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state), b = try request(&state)
        try state.releaseChild(permit: a.id, child: .worker, at: clock(0))
        try state.releaseChild(permit: b.id, child: .worker, at: clock(0))
        healthy(&state, until: 60, level: .warning)
        let c = try request(&state, at: 60)
        state.childExited(permit: a.id, at: clock(60))
        try state.releaseChild(permit: a.id, child: .verifier, at: clock(60))
        #expect(state.permits[a.id]?.children == [.worker, .verifier])
        #expect(state.permits[c.id]?.admission == .queued)
        healthy(&state, until: 80, level: .warning)
        state.childExited(permit: a.id, at: clock(80))
        state.finish(permit: a.id, at: clock(80))
        #expect(state.permits[c.id]?.admission == .queued)
        state.childExited(permit: b.id, at: clock(80))
        try state.releaseChild(permit: b.id, child: .verifier, at: clock(80))
        healthy(&state, until: 90, level: .warning)
        state.childExited(permit: b.id, at: clock(90))
        state.finish(permit: b.id, at: clock(90))
        #expect(state.permits[c.id]?.admission == .granted)
        let d = try request(&state, at: 90)
        #expect(state.permits[d.id]?.admission == .queued)
    }

    @Test func criticalPulseStopsBothBeforeCleanup() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state), b = try request(&state)
        try state.releaseChild(permit: a.id, child: .worker, at: clock(0))
        try state.releaseChild(permit: b.id, child: .worker, at: clock(0))
        _ = state.takeEffects()
        state.notified(flags: 1 | 4, at: clock(0.1))
        let stops = state.takeEffects().filter { $0.operation == .stop(.pressure) }
        #expect(Set(stops.compactMap(\.permit)) == Set([a.id, b.id]))
        state.sampled(.normal, permanent: false, at: clock(0.11))
        #expect(state.permits[a.id]?.stop == .pressure)
        #expect(state.permits[b.id]?.stop == .pressure)
        #expect(throws: BpyAdmissionFailure.self) {
            try state.releaseChild(permit: a.id, child: .verifier, at: clock(0.11))
        }
    }

    @Test func sampleGapBlocksReleaseBeforeItStopsExistingWork() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state)
        try state.releaseChild(permit: a.id, child: .worker, at: clock(0))
        let b = try request(&state, at: 0.3)
        #expect(state.permits[a.id]?.stop == nil)
        #expect(state.permits[b.id]?.admission == .queued)
        state.advance(at: clock(1))
        #expect(state.permits[a.id]?.stop == nil)
        state.sampled(.normal, permanent: false, at: clock(2.2))
        state.serviceObserved(permit: a.id, at: clock(2.2))
        state.advance(at: clock(2.25))
        #expect(state.permits[a.id]?.stop == nil)
        state.advance(at: clock(4.46))
        #expect(state.permits[a.id]?.stop == .monitorUnresponsive)
    }

    @Test func sleepInvalidatesEvidenceWithoutSpendingAwakeBudget() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state)
        try state.releaseChild(permit: a.id, child: .worker, at: clock(0))
        state.advance(at: clock(0.1, sleep: 3_600))
        #expect(state.permits[a.id]?.stop == nil)
        #expect(!state.isFresh(at: 0.1))
        let deadline = state.wakeRecoveryUntil
        state.advance(at: clock(0.2, sleep: 3_600))
        #expect(state.wakeRecoveryUntil == deadline)
        state.sampled(.normal, permanent: false, at: clock(0.2, sleep: 3_600))
        #expect(state.isFresh(at: 0.2))
        #expect(state.permits[a.id]?.firstRelease == 0)
    }

    @Test func closeResolvesAllOwnQueuesAndRacedGrantWithoutOtherSlot() throws {
        var state = BpyMemoryState()
        state.sampled(.warning, permanent: false, at: clock(0))
        let active = try request(&state)
        let owner = UUID()
        let probe = try request(&state, owner: owner, kind: .probe)
        let job = try request(&state, owner: owner)
        state.close(owner: owner, at: clock(0))
        #expect(state.permits[probe.id]?.admission == .failed(.closed))
        #expect(state.permits[job.id]?.admission == .failed(.closed))
        #expect(state.queue.isEmpty)
        #expect(state.permits[active.id]?.admission == .granted)
        state.close(owner: active.owner, at: clock(0))
        #expect(throws: BpyAdmissionFailure.self) {
            try state.releaseChild(permit: active.id, child: .worker, at: clock(0))
        }
        #expect(throws: BpyAdmissionFailure.self) {
            try state.enqueue(active, at: clock(0))
        }
    }

    @Test func unresolvedCleanupPoisonsBothSlotsAtOriginalDeadline() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state), b = try request(&state)
        try state.releaseChild(permit: a.id, child: .worker, at: clock(0))
        try state.releaseChild(permit: b.id, child: .worker, at: clock(0))
        let queued = try request(&state)
        state.cancel(permit: a.id, reason: .cancelled, at: clock(0.1))
        healthy(&state, until: 3.1)
        #expect(!state.cleanupFailed)
        healthy(&state, until: 5.1)
        #expect(state.cleanupFailed)
        #expect(state.permits[queued.id]?.admission == .failed(.cleanupFailed))
        #expect(state.permits[a.id]?.stop == .cancelled)
        state.childExited(permit: a.id, at: clock(5.2))
        state.finish(permit: a.id, at: clock(5.2))
        state.childExited(permit: b.id, at: clock(5.2))
        state.finish(permit: b.id, at: clock(5.2))
        state.sampled(.normal, permanent: false, at: clock(10))
        #expect(state.cleanupFailed)
        #expect(throws: BpyAdmissionFailure.self) { _ = try request(&state, at: 10) }
    }

    @Test func terminalCommitAtCollectionBoundaryIsAccepted() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state, timeout: 10)
        try state.releaseChild(permit: a.id, child: .worker, at: clock(0))
        state.childExited(permit: a.id, at: clock(1))
        state.sampled(.normal, permanent: false, at: clock(1))
        try state.releaseChild(permit: a.id, child: .verifier, at: clock(1))
        state.childExited(permit: a.id, at: clock(2))
        healthy(&state, until: 25)
        try state.commit(permit: a.id, at: clock(25))
        #expect(state.permits[a.id]?.terminalCommit == 25)
        #expect(state.permits[a.id]?.stop == nil)
    }

    @Test func unknownSensorAndFakeContinuationCannotAuthorize() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let a = try request(&state)
        #expect(throws: BpyAdmissionFailure.self) {
            try state.releaseChild(permit: a.id, child: .verifier, at: clock(0))
        }
        state.sampled(nil, permanent: true, at: clock(0.1))
        #expect(state.permits[a.id]?.stop == .monitorUnavailable)
        state.sampled(.normal, permanent: false, at: clock(0.2))
        #expect(state.sensorUnavailable)
        #expect(throws: BpyAdmissionFailure.self) { _ = try request(&state, at: 0.2) }
    }
    @Test func missingClockFailsQueuesAndStopsLiveWorkWithoutInventingATimestamp() throws {
        var state = BpyMemoryState()
        let owner = UUID(), generation = UUID()
        try state.register(owner: owner, generation: generation)
        let now = BpyClockReading(awake: 1, continuous: 1, uncertainty: 0)
        state.sampled(.normal, permanent: false, at: now)
        let live = BpyAdmissionIdentity(id: UUID(), owner: owner, generation: generation, transport: UUID(), job: UUID(),
            kind: .job, insertedAt: 1, admissionDeadline: 11, timeout: 10, diagnosticAutoexec: false)
        try state.enqueue(live, at: now)
        try state.releaseChild(permit: live.id, child: .worker, at: now)
        let queued = BpyAdmissionIdentity(id: UUID(), owner: owner, generation: generation, transport: UUID(), job: nil,
            kind: .probe, insertedAt: 1, admissionDeadline: 11, timeout: 10, diagnosticAutoexec: false)
        state.notified(flags: DispatchSource.MemoryPressureEvent.warning.rawValue, at: now)
        state.sampled(.warning, permanent: false, at: now)
        try state.enqueue(queued, at: now)
        state.clockUnavailable(at: nil)
        #expect(state.sensorUnavailable)
        #expect(state.permits[queued.id]?.admission == .failed(.sensorUnavailable))
        #expect(state.permits[live.id]?.stop == .monitorUnavailable)
        #expect(state.permits[live.id]?.grounds.last?.clock == nil)
        #expect(state.permits[live.id]?.cleanupStarted == nil)
        #expect(!state.cleanupFailed)
    }

    @Test func lateNormalReadCannotEraseADecidedObservationStop() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let job = try request(&state)
        try state.releaseChild(permit: job.id, child: .worker, at: clock(0))
        state.advance(at: clock(2.25))
        state.sampled(.normal, permanent: false, at: clock(3))
        #expect(state.permits[job.id]?.stop == .monitorUnresponsive)
    }

    @Test func watchdogUsesLatestPublishedReadInsteadOfStoppingForAHistoricalGap() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let job = try request(&state)
        try state.releaseChild(permit: job.id, child: .worker, at: clock(0))
        state.serviceObserved(permit: job.id, at: clock(2.2))
        state.sampled(.normal, permanent: false, at: clock(3))
        state.advance(at: clock(3.01))
        #expect(state.permits[job.id]?.stop == nil)
    }

    @Test func staleNormalIntervalCannotCountAsARecoveryDwell() throws {
        var state = BpyMemoryState()
        state.sampled(.critical, permanent: false, at: clock(0))
        state.sampled(.normal, permanent: false, at: clock(0.1))
        state.sampled(.normal, permanent: false, at: clock(5))
        #expect(state.criticalLatched)
        #expect(state.normalSince == 5)
        healthy(&state, until: 6.1)
        #expect(!state.criticalLatched)
    }

    @Test func probeQueueTimeoutAndChildExecutionTimeoutAreIndependent() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        let probe = try request(&state, timeout: 10, kind: .probe)
        try state.releaseChild(permit: probe.id, child: .probe, at: clock(0))
        healthy(&state, until: 11)
        #expect(state.permits[probe.id]?.stop == nil)
        healthy(&state, until: 120)
        #expect(state.permits[probe.id]?.stop == .deadline)
    }

    @Test func trustedCollectionCommitReleasesWarningAdmissionBeforeADelayedStatusReply() throws {
        var state = BpyMemoryState()
        state.sampled(.warning, permanent: false, at: clock(0))
        let first = try request(&state, timeout: 10)
        try state.releaseChild(permit: first.id, child: .worker, at: clock(0))
        let waiting = try request(&state, timeout: 120)
        state.childExited(permit: first.id, at: clock(0.1))
        state.sampled(.warning, permanent: false, at: clock(0.1))
        try state.releaseChild(permit: first.id, child: .verifier, at: clock(0.1))
        state.childExited(permit: first.id, at: clock(0.2))
        state.sampled(.warning, permanent: false, at: clock(0.2))
        try state.commit(permit: first.id, at: clock(0.2))
        #expect(state.permits[first.id]?.cleanupComplete == true)
        #expect(state.permits[waiting.id]?.admission == .granted)
        healthy(&state, until: 30, level: .warning)
        try state.commit(permit: first.id, at: clock(30))
        #expect(state.permits[first.id]?.terminalCommit == 0.2)
        #expect(state.permits[first.id]?.stop == nil)
    }

    @Test func retiredSessionOwnersDoNotAccumulateAndLiveWorkCannotBeRetired() throws {
        var state = BpyMemoryState()
        state.sampled(.normal, permanent: false, at: clock(0))
        for _ in 0..<100 {
            let owner = UUID(), admission = try request(&state, owner: owner)
            let retiredWithLiveWork = state.retire(owner: owner)
            #expect(!retiredWithLiveWork)
            state.close(owner: owner, at: clock(0))
            #expect(throws: BpyAdmissionFailure.self) { _ = try request(&state, owner: owner) }
            state.forget(permit: admission.id)
            let retiredAfterCleanup = state.retire(owner: owner)
            #expect(retiredAfterCleanup)
        }
        #expect(state.generations.isEmpty && state.closedOwners.isEmpty && state.permits.isEmpty)
    }

}
