import BpyRuntimeProtocol
import Foundation
import Testing

struct BpyRuntimeOutputLedgerTests {
    @Test func confirmedCheckpointAllowsTheNextFullResultAtTheSmallestLegalRetainedEnvelope() async throws {
        try await withDirectory { root in
            let limits = BpyRuntimeLimits(inputBytes: 448 * 1_024 * 1_024, diskBytes: 512 * 1_024 * 1_024)
            #expect(limits.isValid)
            let capacity = try #require(limits.retainedOutputBytes)
            #expect(capacity == limits.outputBytes)
            let ledger = BpyRuntimeOutputLedger(capacity: capacity), job = UUID(), next = UUID()
            try ledger.reserve(job, maximum: limits.outputBytes)
            let completed = DispatchSemaphore(value: 0)
            let checkpoint = try file(root, name: "checkpoint.blend", job: job, ledger: ledger, completed: completed)
            defer { checkpoint.release() }
            ledger.settle(job)
            #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try ledger.reserve(next, maximum: limits.outputBytes) }
            try ledger.updateCheckpoint(job, resultScene: nil, confirmedScene: checkpoint, change: .confirm)
            #expect(ledger.materialized(job) == 0)
            #expect(ledger.chargedBytes(job, file: checkpoint) == 0)
            #expect(try checkpoint.read(maximum: 4) == Data([1, 2, 3, 4]))
            try ledger.reserve(next, maximum: limits.outputBytes)
            let beforeRelease = await waitForBpyTestSignal(completed, until: .now())
            #expect(beforeRelease == .timedOut)
            checkpoint.release()
            let afterRelease = await waitForBpyTestSignal(completed, until: .now() + 2)
            #expect(afterRelease == .success)
            #expect(!FileManager.default.fileExists(atPath: checkpoint.url.path))
            ledger.settle(next)
        }
    }

    @Test func directlyConfirmedAndSupersededResultsStayChargedUntilTheirOwnRelease() async throws {
        try await withDirectory { root in
            let ledger = BpyRuntimeOutputLedger(capacity: 12), first = UUID(), second = UUID()
            try ledger.reserve(first, maximum: 8)
            let firstDisposed = DispatchSemaphore(value: 0), siblingDisposed = DispatchSemaphore(value: 0)
            let sceneA = try file(root, name: "a.blend", job: first, ledger: ledger, completed: firstDisposed)
            let sibling = try file(root, name: "a.png", job: first, ledger: ledger, completed: siblingDisposed)
            let checkpointA = try sceneA.retained()
            defer { sceneA.release(); sibling.release(); checkpointA.release() }
            try ledger.updateCheckpoint(first, resultScene: sceneA, confirmedScene: checkpointA, change: .confirm)
            #expect(ledger.chargedBytes(first, file: sceneA) == 4)
            try ledger.reserve(second, maximum: 4)
            let secondDisposed = DispatchSemaphore(value: 0)
            let sceneB = try file(root, name: "b.blend", job: second, ledger: ledger, completed: secondDisposed)
            let checkpointB = try sceneB.retained()
            defer { sceneB.release(); checkpointB.release() }
            try ledger.updateCheckpoint(second, resultScene: sceneB, confirmedScene: checkpointB, change: .confirm)
            checkpointA.release()
            #expect(ledger.materialized(first) == 8)
            #expect(ledger.chargedBytes(first, file: sceneA) == 4)
            #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try ledger.reserve(UUID(), maximum: 1) }
            #expect(try sceneA.read(maximum: 4) == Data([1, 2, 3, 4]))
            try ledger.updateCheckpoint(first, resultScene: sceneA, confirmedScene: checkpointB, change: .release)
            #expect(ledger.chargedBytes(first, file: sceneA) == 4)
            sceneA.release()
            let firstDisposal = await waitForBpyTestSignal(firstDisposed, until: .now() + 2)
            #expect(firstDisposal == .success)
            #expect(ledger.materialized(first) == 4)
            #expect(ledger.chargedBytes(first, file: sibling) == 4)
            let next = UUID()
            try ledger.reserve(next, maximum: 4)
            try ledger.updateCheckpoint(second, resultScene: sceneB, confirmedScene: checkpointB, change: .release)
            sceneB.release()
            #expect(ledger.materialized(second) == 0)
            let secondBeforeRelease = await waitForBpyTestSignal(secondDisposed, until: .now())
            #expect(secondBeforeRelease == .timedOut)
            #expect(try checkpointB.read(maximum: 4) == Data([1, 2, 3, 4]))
            ledger.settle(next)
            try ledger.reserve(UUID(), maximum: 8)
            sibling.release(); checkpointB.release()
            let siblingDisposal = await waitForBpyTestSignal(siblingDisposed, until: .now() + 2)
            #expect(siblingDisposal == .success)
            let secondDisposal = await waitForBpyTestSignal(secondDisposed, until: .now() + 2)
            #expect(secondDisposal == .success)
        }
    }

    @Test func defaultEnvelopeAllowsFourFullResultsWhileTheCheckpointRemainsPinned() async throws {
        try await withDirectory { root in
            let limits = BpyRuntimeLimits(), capacity = try #require(limits.retainedOutputBytes)
            let ledger = BpyRuntimeOutputLedger(capacity: capacity), job = UUID()
            try ledger.reserve(job, maximum: limits.outputBytes)
            let completed = DispatchSemaphore(value: 0)
            let checkpoint = try file(root, name: "checkpoint.blend", job: job, ledger: ledger, completed: completed)
            defer { checkpoint.release() }
            try ledger.updateCheckpoint(job, resultScene: nil, confirmedScene: checkpoint, change: .confirm)
            let next = (0..<4).map { _ in UUID() }
            for id in next { try ledger.reserve(id, maximum: limits.outputBytes) }
            #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try ledger.reserve(UUID(), maximum: 1) }
            #expect(try checkpoint.read(maximum: 4) == Data([1, 2, 3, 4]))
            checkpoint.release()
            let disposal = await waitForBpyTestSignal(completed, until: .now() + 2)
            #expect(disposal == .success)
            for id in next { ledger.settle(id) }
        }
    }

    @Test func releasedCheckpointAndLaterDisposalPreserveSiblingCharges() async throws {
        try await withDirectory { root in
            let ledger = BpyRuntimeOutputLedger(capacity: 20), job = UUID()
            try ledger.reserve(job, maximum: 20)
            let oldDisposed = DispatchSemaphore(value: 0), siblingDisposed = DispatchSemaphore(value: 0)
            let old = try file(root, name: "old.blend", job: job, ledger: ledger, completed: oldDisposed)
            let sibling = try file(root, name: "image.bin", job: job, ledger: ledger, completed: siblingDisposed)
            defer { old.release(); sibling.release() }
            #expect(ledger.materialized(job) == 8)
            #expect(throws: CocoaError(.fileReadCorruptFile)) {
                try ledger.updateCheckpoint(UUID(), resultScene: nil, confirmedScene: old, change: .confirm)
            }
            try ledger.updateCheckpoint(job, resultScene: nil, confirmedScene: old, change: .confirm)
            try ledger.updateCheckpoint(job, resultScene: nil, confirmedScene: old, change: .confirm)
            #expect(ledger.materialized(job) == 4)
            #expect(ledger.chargedBytes(job, file: sibling) == 4)
            let replacementJob = UUID()
            try ledger.reserve(replacementJob, maximum: 16)
            let replacementDisposed = DispatchSemaphore(value: 0)
            let replacement = try file(root, name: "replacement.blend", job: replacementJob, ledger: ledger, completed: replacementDisposed)
            defer { replacement.release() }
            try ledger.updateCheckpoint(replacementJob, resultScene: nil, confirmedScene: replacement, change: .confirm)
            old.release()
            let oldDisposal = await waitForBpyTestSignal(oldDisposed, until: .now() + 2)
            #expect(oldDisposal == .success)
            #expect(ledger.materialized(job) == 4)
            #expect(try sibling.read(maximum: 4) == Data([1, 2, 3, 4]))
            sibling.release()
            let siblingDisposal = await waitForBpyTestSignal(siblingDisposed, until: .now() + 2)
            #expect(siblingDisposal == .success)
            #expect(ledger.materialized(job) == 0)
            try ledger.reserve(UUID(), maximum: 20)
            replacement.release()
            let replacementDisposal = await waitForBpyTestSignal(replacementDisposed, until: .now() + 2)
            #expect(replacementDisposal == .success)
        }
    }

    private func file(_ root: URL, name: String, job: UUID, ledger: BpyRuntimeOutputLedger,
                      completed: DispatchSemaphore) throws -> BpyRuntimeFile {
        let ticket = try ledger.materialize(job, bytes: 4)
        let file = try BpyRuntimeFile.copy(data: Data([1, 2, 3, 4]), to: root.appendingPathComponent(name), maximum: 4, disposed: { removed, _ in
            if removed { ledger.disposed(ticket); ledger.disposed(ticket); completed.signal() }
        })
        try ledger.bind(ticket, file: file)
        return file
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}
