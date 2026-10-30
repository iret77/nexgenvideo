import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyRuntimeResultLeaseTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var releases: [Bool] = []
        private var invalidations = 0
        func release(_ detached: Bool) { lock.withLock { releases.append(detached) } }
        func invalidate() { lock.withLock { invalidations += 1 } }
        var snapshot: ([Bool], Int) { lock.withLock { (releases, invalidations) } }
    }

    @Test func joinedCallersKeepIndependentOwnershipAndReplayNeverRevivesAReleasedResult() async throws {
        try await withFile { file, disposed in
            let events = Events(), bytes = try file.read(maximum: 8)
            let first = lease(file: file, events: events)
            let second = try first.joinedForReplay()
            #expect(first.id == second.id)
            first.release()
            #expect(!first.isAvailable && second.isAvailable)
            #expect(try second.data("frame.png", maximum: 8) == bytes)
            #expect(events.snapshot.0.isEmpty)
            let third = try first.joinedForReplay()
            second.release()
            #expect(try third.data("frame.png", maximum: 8) == bytes)
            let beforeRelease = await waitForBpyTestSignal(disposed, until: .now())
            #expect(beforeRelease == .timedOut)
            third.release()
            third.release()
            #expect(events.snapshot.0 == [false])
            #expect(throws: (any Error).self) { _ = try first.joinedForReplay() }
            let afterRelease = await waitForBpyTestSignal(disposed, until: .now() + 2)
            #expect(afterRelease == .success)
        }
    }

    @Test func documentCloseInvalidatesEveryCallerOnceAndWaitsForAnActualReader() async throws {
        try await withFile { file, disposed in
            let events = Events(), first = lease(file: file, events: events)
            let second = try first.joinedForReplay()
            let reader = try second.file("frame.png")
            let registration = second.observeInvalidation { events.invalidate() }
            defer { withExtendedLifetime(registration) {} }
            first.invalidate()
            second.invalidate()
            #expect(!first.isAvailable && !second.isAvailable)
            #expect(events.snapshot.0 == [false])
            #expect(events.snapshot.1 == 1)
            #expect(throws: (any Error).self) { _ = try second.data("frame.png", maximum: 8) }
            #expect(throws: (any Error).self) { _ = try second.joinedForReplay() }
            #expect(try reader.read(maximum: 8) == Data("fixture".utf8))
            let beforeRelease = await waitForBpyTestSignal(disposed, until: .now())
            #expect(beforeRelease == .timedOut)
            first.release(); second.release()
            #expect(events.snapshot.0 == [false])
            reader.release()
            let afterRelease = await waitForBpyTestSignal(disposed, until: .now() + 2)
            #expect(afterRelease == .success)
        }
    }

    @Test func detachedProofSurvivesAnotherCallersReleaseAndCannotBeReplaced() async throws {
        try await withFile { file, disposed in
            let events = Events(), first = lease(file: file, events: events)
            let second = try first.joinedForReplay()
            let proof = Data("original-proof".utf8)
            try first.transferExecution()
            try first.detach(proof: proof)
            first.release()
            #expect(second.isDetached)
            try second.authenticate(proof: proof)
            #expect(throws: (any Error).self) { try second.detach(proof: Data("replacement".utf8)) }
            #expect(try second.data("frame.png", maximum: 8) == Data("fixture".utf8))
            second.release()
            #expect(events.snapshot.0 == [true])
            let disposal = await waitForBpyTestSignal(disposed, until: .now() + 2)
            #expect(disposal == .success)
        }
    }

    private func lease(file: BpyRuntimeFile, events: Events) -> BpyRuntimeResultLease {
        .init(transport: UUID(), job: UUID(), slot: bpyRuntimeServiceNames[0], owner: UUID(),
            limits: .init(), sourceRevision: nil, sourceSHA256: nil, fingerprint: "fixture",
            response: .init(ok: true, state: .awaitingConfirmation), files: ["frame.png": file],
            onRelease: { events.release($0) })
    }

    private func withFile(_ body: (BpyRuntimeFile, DispatchSemaphore) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let disposed = DispatchSemaphore(value: 0)
        let file = try BpyRuntimeFile.copy(data: Data("fixture".utf8), to: root.appendingPathComponent("frame.png"), maximum: 8, disposed: { removed, _ in
            if removed { disposed.signal() }
        })
        defer { file.release() }
        try await body(file, disposed)
    }
}
