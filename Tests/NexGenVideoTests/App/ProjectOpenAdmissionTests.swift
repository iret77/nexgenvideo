import Foundation
import Testing
@testable import NexGenVideo

@MainActor
struct ProjectOpenAdmissionTests {
    @Test func confirmedQuitDrainsSuspendedOpenAndRefusesItsLatePublication() async throws {
        let admission = ProjectOpenAdmission()
        let barrier = AdmissionBarrier()
        var publications = 0
        let opening = Task {
            try await admission.perform {
                await barrier.wait()
                try admission.requireOpen()
                publications += 1
                return nil
            }
        }
        defer { barrier.release(); opening.cancel() }
        try #require(await until { barrier.started })
        var drained = false
        let closing = Task { await admission.confirmTerminationAndDrain(); drained = true }
        defer { closing.cancel() }
        try #require(await until { admission.isConfirmedTermination })
        #expect(!drained)
        barrier.release()
        await closing.value
        do {
            _ = try await opening.value
            Issue.record("A suspended open committed after confirmed termination.")
        } catch is CancellationError { }
        #expect(drained && publications == 0 && !admission.canOpen)
        do {
            _ = try await admission.perform { publications += 1; return nil }
            Issue.record("A new open was accepted after the quit drain.")
        } catch is CancellationError { }
        #expect(publications == 0)
    }

    @Test func confirmedQuitWaitsForAnAlreadyStartedNewProjectSave() async throws {
        let admission = ProjectOpenAdmission()
        let save = try admission.beginPublication()
        var drained = false
        let closing = Task { await admission.confirmTerminationAndDrain(); drained = true }
        defer { admission.finishPublication(save); closing.cancel() }
        try #require(await until { admission.isConfirmedTermination })
        #expect(!drained)
        #expect(throws: CancellationError.self) { try admission.beginPublication() }
        admission.finishPublication(save)
        await closing.value
        #expect(drained && !admission.canOpen)
    }

    @Test func unconfirmedAdmissionRemainsUsable() async throws {
        let admission = ProjectOpenAdmission()
        var opened = false
        _ = try await admission.perform { opened = true; return nil }
        let save = try admission.beginPublication()
        admission.finishPublication(save)
        #expect(opened && admission.canOpen && !admission.isConfirmedTermination)
    }

    private func until(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

@MainActor
private final class AdmissionBarrier {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0; started = true }
    }

    func release() {
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}
