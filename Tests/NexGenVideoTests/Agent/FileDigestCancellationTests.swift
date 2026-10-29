import Foundation
import NexGenEngine
import Testing

@Suite("Cancellable exact file digests")
struct FileDigestCancellationTests {
    @Test func normalFileStillMatchesKnownSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try FileDigest.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func cancelledReadRefusesBeforeReturningACompleteDigest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 42, count: 2_097_153).write(to: url)
        let work = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileDigest.sha256(of: url)
        }
        do {
            _ = try await work.value
            Issue.record("A cancelled file read returned a digest instead of refusing.")
        } catch is CancellationError {
        } catch { Issue.record("The file read failed for an unrelated reason: \(error)") }
    }
}
