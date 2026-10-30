import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyMediaReadScopeTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pipeline") }

    @Test func verifiedProjectBytesKeepTheirDigestAndRejectChangedOrOversizedFiles() throws {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x58, count: 131_072), url = root.appendingPathComponent("proof.json")
        try bytes.write(to: url)
        let token = BpyOperationCancellation()
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) })
        let scope = BpyMediaReadScope.operation(dataRoot: root, owner: UUID(), cancellation: token, memory: memory)
        let expected = SpatialSceneStore.digest(bytes)
        #expect(try scope.verifiedData(at: url, expectedSHA256: expected, maximum: UInt64(Int.max)) == bytes)
        try Data("changed".utf8).write(to: url)
        #expect(throws: CocoaError(.fileReadCorruptFile)) {
            _ = try scope.verifiedData(at: url, expectedSHA256: expected, maximum: UInt64(Int.max))
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: BpyRuntimeLimits.maximumOutputBytes + 1)
        try handle.close()
        #expect(throws: CocoaError(.fileReadTooLarge)) {
            _ = try scope.verifiedData(at: url, expectedSHA256: expected, maximum: BpyRuntimeLimits.maximumOutputBytes)
        }
        #expect(!token.isCancelled)
    }

    @Test func documentCloseReachesTheActualOperationAfterItsHashScopeHasEnded() throws {
        let root = root(), generation = UUID(), token = BpyOperationCancellation()
        BpyMediaReadScope.register(root: root, generation: generation)
        try BpyMediaReadScope.withScope(dataRoot: root, cancellation: token) { scope in
            #expect(scope.owner == generation)
            #expect(scope.cancellation === token)
        }
        #expect(!token.isCancelled)
        BpyMediaReadScope.close(root: root, generation: generation)
        #expect(token.isCancelled)
        #expect(throws: BpyAdmissionFailure.self) { try BpyMediaReadScope.withScope(dataRoot: root) { try $0.check() } }
    }

    @Test func replacementCancelsOldWorkAndStaleCloseCannotCancelItsSuccessor() throws {
        let root = root(), old = UUID(), new = UUID(), first = BpyOperationCancellation(), second = BpyOperationCancellation()
        BpyMediaReadScope.register(root: root, generation: old)
        try BpyMediaReadScope.withScope(dataRoot: root, cancellation: first) { try $0.check() }
        BpyMediaReadScope.register(root: root, generation: new)
        defer { BpyMediaReadScope.close(root: root, generation: new) }
        #expect(first.isCancelled)
        try BpyMediaReadScope.withScope(dataRoot: root, cancellation: second) { scope in
            #expect(scope.owner == new)
            BpyMediaReadScope.close(root: root, generation: old)
            try scope.check()
        }
        #expect(!second.isCancelled)
    }

    @Test func cancellationAtTheEndOfAReadCannotPublishAnOtherwiseSuccessfulValue() throws {
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) })
        let token = BpyOperationCancellation(), owner = UUID()
        let scope = BpyMediaReadScope.operation(dataRoot: root(), owner: owner, cancellation: token, memory: memory)
        #expect(throws: BpyAdmissionFailure.self) {
            _ = try scope.withConsumer { _ in token.cancel(); return 42 }
        }
        let other = try memory.beginConsumer(owner: owner, cancellation: .init())
        defer { other.release() }
        try other.check()
    }

    @Test func transactionsInheritTheirDocumentWhileAnotherProjectRemainsIndependent() throws {
        let root = root(), staging = self.root(), other = self.root(), generation = UUID()
        BpyMediaReadScope.register(root: root, generation: generation)
        defer { BpyMediaReadScope.close(root: root, generation: generation) }
        try BpyMediaReadScope.withTransaction(source: root, staging: staging) {
            try BpyMediaReadScope.withScope(dataRoot: staging) { transaction in
                #expect(transaction.owner == generation)
                try BpyMediaReadScope.withScope(dataRoot: other) { independent in
                    #expect(independent.owner != generation)
                    BpyMediaReadScope.close(root: root, generation: generation)
                    try independent.check()
                }
                #expect(throws: BpyAdmissionFailure.self) { try transaction.check() }
            }
        }
    }

    @Test func endingATemporaryTransactionDoesNotCancelItsCallersLongerOperation() throws {
        let root = root(), staging = self.root(), generation = UUID(), caller = BpyOperationCancellation()
        BpyMediaReadScope.register(root: root, generation: generation)
        defer { BpyMediaReadScope.close(root: root, generation: generation) }
        try BpyMediaReadScope.withTransaction(source: root, staging: staging) {
            try BpyMediaReadScope.withScope(dataRoot: staging, cancellation: caller) { scope in
                #expect(scope.owner == generation)
                #expect(scope.cancellation === caller)
                try scope.check()
            }
        }
        try caller.check()
        BpyMediaReadScope.close(root: root, generation: generation)
        #expect(caller.isCancelled)
    }

    @Test func directoryURLSpellingDoesNotCreateAnotherOwnerAndCallerCancellationIsLocal() throws {
        let root = root(), generation = UUID(), first = BpyOperationCancellation(), second = BpyOperationCancellation()
        BpyMediaReadScope.register(root: root, generation: generation)
        defer { BpyMediaReadScope.close(root: root, generation: generation) }
        try BpyMediaReadScope.withScope(dataRoot: URL(fileURLWithPath: root.path, isDirectory: true), cancellation: first) { scope in
            #expect(scope.owner == generation)
            try BpyMediaReadScope.withScope(dataRoot: URL(fileURLWithPath: root.path, isDirectory: false), cancellation: second) { secondScope in
                #expect(secondScope.owner == generation)
                first.cancel()
                #expect(second.isCancelled)
            }
        }
        let next = BpyOperationCancellation()
        try BpyMediaReadScope.withScope(dataRoot: root, cancellation: next) { try $0.check() }
        #expect(!next.isCancelled)
    }

    private final class Waiting: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<UUID, any Error>?
        func finish(_ value: Result<UUID, any Error>) { lock.withLock { result = value }; ended.signal() }
        func value() throws -> UUID { try lock.withLock { try #require(result).get() } }
    }

    @Test func closingTheDocumentWakesItsQueuedDecodeWithoutConsumingCapacity() async throws {
        let root = root(), generation = UUID(), pool = BpyMediaDecode.Pool(capacity: 1), waiting = Waiting()
        BpyMediaReadScope.register(root: root, generation: generation)
        defer { BpyMediaReadScope.close(root: root, generation: generation) }
        let blocker = try pool.reserve(1, cancellation: .init(), timeout: 5, checking: {})
        defer { pool.release(blocker) }
        let observed = await onBpyTestThread {
            Thread {
                waiting.finish(Result {
                    try BpyMediaReadScope.withScope(dataRoot: root) { scope in
                        try pool.reserve(1, cancellation: scope.cancellation, timeout: 5,
                            checking: { try scope.check(); waiting.entered.signal() })
                    }
                })
            }.start()
            let entered = waiting.entered.wait(timeout: .now() + 1)
            let endedBeforeClose = waiting.ended.wait(timeout: .now() + 0.05)
            BpyMediaReadScope.close(root: root, generation: generation)
            let endedAfterClose = waiting.ended.wait(timeout: .now() + 1)
            return (entered, endedBeforeClose, endedAfterClose)
        }
        #expect(observed.0 == .success)
        #expect(observed.1 == .timedOut)
        #expect(observed.2 == .success)
        #expect(throws: BpyAdmissionFailure.self) { _ = try waiting.value() }
        pool.release(blocker)
        let replacement = try pool.reserve(1, cancellation: .init(), timeout: 1, checking: {})
        pool.release(replacement)
    }
}
