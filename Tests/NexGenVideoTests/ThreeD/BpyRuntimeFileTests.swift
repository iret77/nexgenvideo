import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

struct BpyRuntimeFileTests {
    private struct Interrupted: Error {}

    @Test func incrementalVerifiedDataKeepsTheExactDigestAndStopsBetweenChunks() throws {
        try withDirectory { root in
            let bytes = Data(repeating: 0x62, count: 3 * 65_536)
            let file = try BpyRuntimeFile.copy(data: bytes, to: root.appendingPathComponent("proof.json"), maximum: UInt64(bytes.count))
            defer { file.release() }
            let token = BpyOperationCancellation()
            var checks = 0
            #expect(throws: BpyAdmissionFailure.cancelled) {
                _ = try file.verifiedData(maximum: UInt64(Int.max), preallocate: false, checking: {
                    checks += 1
                    if checks == 2 { token.cancel() }
                    try token.check()
                })
            }
            #expect(checks == 2)
            #expect(!Task.isCancelled)
            #expect(try file.verifiedData(maximum: UInt64(Int.max), preallocate: false) == bytes)
        }
    }

    @Test func sceneVerificationStopsOnThePassedTokenBetweenFileChunksWithoutTaskCancellation() throws {
        try withDirectory { root in
            let bytes = Data(repeating: 0x57, count: 3 * 65_536), url = root.appendingPathComponent("scene.blend")
            let file = try BpyRuntimeFile.copy(data: bytes, to: url, maximum: UInt64(bytes.count))
            let payload = SpatialScenePayload(file: file), cancellation = BpyOperationCancellation()
            defer { payload.releaseRuntimeSource() }
            var checks = 0
            #expect(!Task.isCancelled)
            #expect(throws: BpyAdmissionFailure.self) {
                _ = try payload.verify(checking: {
                    checks += 1
                    if checks == 3 { cancellation.cancel() }
                    try cancellation.check()
                })
            }
            #expect(checks == 3)
            #expect(!Task.isCancelled)
            let control = BpyOperationCancellation()
            #expect(try payload.verify(checking: control.check) == SpatialSceneStore.digest(bytes))
        }
    }

    @Test func projectBorrowDoesNotDeleteCanonicalBytes() throws {
        try withDirectory { root in
            let bytes = Data("BLENDER-canonical".utf8), url = root.appendingPathComponent("scene.blend")
            try bytes.write(to: url)
            let hash = SpatialSceneStore.digest(bytes)
            let borrowed = try BpyRuntimeFile.borrow("scene.blend", in: root, maximum: 1_024, expectedSHA256: hash)
            borrowed.release()
            #expect(try Data(contentsOf: url) == bytes)
            let payload = SpatialScenePayload(path: "scene.blend", root: root, sha256: hash, byteCount: UInt64(bytes.count))
            #expect(try payload.verify(checking: {}) == hash)
            try Data("changed".utf8).write(to: url, options: .atomic)
            #expect(throws: (any Error).self) { _ = try payload.verify(checking: {}) }
        }
    }

    @Test func ownedFileSurvivesItsOriginalOwnerUntilLastBorrowReleases() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("result.bin")
        let disposed = DispatchSemaphore(value: 0)
        let original = try BpyRuntimeFile.copy(data: Data(repeating: 0x75, count: 131_072), to: url, maximum: 131_072, disposed: { removed, _ in
            if removed { disposed.signal() }
        })
        let borrow = try original.retained()
        original.release()
        #expect(try borrow.read(offset: 65_536, maximum: 65_536) == Data(repeating: 0x75, count: 65_536))
        #expect(disposed.wait(timeout: .now()) == .timedOut)
        borrow.release()
        #expect(disposed.wait(timeout: .now() + 2) == .success)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func interruptedCopyKeepsUncertainBytesChargedUntilPhysicalCleanup() throws {
        try withDirectory { root in
            let limits = BpyRuntimeLimits()
            let ledger = BpyRetentionLedger()
            let slot = bpyRuntimeServiceNames[0]
            try ledger.configure(slot: slot, limits: limits)
            let reservation = try ledger.reserve(slot: slot, owner: UUID(), kind: .retained, bytes: 131_072)
            defer { ledger.settle(reservation) }
            let url = root.appendingPathComponent("result.bin")
            do {
                _ = try ledger.creatingFile(reservation, bytes: 131_072) {
                    try BpyRuntimeFile.receive(at: url, byteCount: 131_072, expectedSHA256: String(repeating: "0", count: 64), disposed: { _, _ in }) { offset, count in
                        if offset != 0 {
                            guard chmod(root.path, 0o500) == 0 else { throw POSIXError(.EIO) }
                            throw Interrupted()
                        }
                        return Data(repeating: 0x42, count: count)
                    }
                }
                Issue.record("The interrupted source unexpectedly completed.")
            } catch let failure as BpyRuntimeFile.CreationError {
                defer { _ = chmod(root.path, 0o700) }
                ledger.settle(reservation)
                #expect(ledger.snapshot.reduce(UInt64(0)) { $0 + $1.bytes } == 131_072)
                let finished = DispatchSemaphore(value: 0)
                failure.cleanup.whenComplete { finished.signal() }
                #expect(finished.wait(timeout: .now()) == .timedOut)
                #expect(chmod(root.path, 0o700) == 0)
                #expect(finished.wait(timeout: .now() + 3) == .success)
                #expect(ledger.snapshot.isEmpty)
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            }
        }
    }

    @Test func acknowledgedSequenceFilesCanExceedOneRuntimeRetainedEnvelope() throws {
        try withDirectory { root in
            let limits = BpyRuntimeLimits(inputBytes: 8, outputBytes: 8)
            let sequence = BpySequenceRetention(root: root)
            for index in 0..<5 { try sequence.copy(Data(repeating: UInt8(index), count: 8), to: root.appendingPathComponent("frame-\(index).png")) }
            let borrowed = try sequence.borrow()
            #expect(borrowed.reduce(UInt64(0)) { $0 + $1.byteCount } == 40)
            #expect(40 > (limits.retainedOutputBytes ?? UInt64.max))
            sequence.release()
            #expect(try borrowed.allSatisfy { try $0.read(maximum: 8).count == 8 })
            for file in borrowed { file.release() }
        }
    }

    @Test func activeEncoderKeepsItsRawFileAndDiskReservationThroughAbandonment() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sequence = BpySequenceRetention(root: root)
        let media = try sequence.encoding(width: 8, height: 8)
        let pin = try media.retainForIO()
        defer { pin.release() }
        let bytes = Data("encoder-still-writing".utf8)
        try bytes.write(to: media.url)
        sequence.release()
        media.abandon()
        #expect(try Data(contentsOf: media.url) == bytes)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(throws: (any Error).self) { _ = try media.finish() }
        pin.release()
        let deadline = try BpyRuntimeClock.awakeSeconds() + 3
        while FileManager.default.fileExists(atPath: root.path), try BpyRuntimeClock.awakeSeconds() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let root = try directory()
        defer { _ = chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
