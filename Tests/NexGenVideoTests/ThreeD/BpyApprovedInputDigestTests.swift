import Foundation
import Testing
@testable import NexGenVideo

@Suite("Bounded approved Bpy input hashing")
struct BpyApprovedInputDigestTests {
    @Test func hashesTheExactBoundedBytesIncludingEmptyFiles() throws {
        try withInput(Data("abc".utf8)) { handle in
            #expect(try BpyApprovedInputDigest.read(handle, expectedBytes: 3)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
        try withInput(Data()) { handle in
            #expect(try BpyApprovedInputDigest.read(handle, expectedBytes: 0)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }
    }

    @Test func rejectsTruncationAndStopsAtTheOriginalSizeWhenAFileGrows() throws {
        try withInput(Data("abc".utf8)) { handle in
            #expect(throws: BpyRuntimeError.self) { try BpyApprovedInputDigest.read(handle, expectedBytes: 4) }
        }
        try withInput(Data(repeating: 1, count: 2_097_152)) { handle in
            #expect(throws: BpyRuntimeError.self) { try BpyApprovedInputDigest.read(handle, expectedBytes: 1_048_576) }
            #expect(try handle.offset() == 1_048_577)
        }
        try withInput(Data([1])) { handle in
            #expect(throws: BpyRuntimeError.self) { try BpyApprovedInputDigest.read(handle, expectedBytes: 0) }
        }
    }

    @Test func cancelledHashDoesNotReadTheFile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let task = Task.detached {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try BpyApprovedInputDigest.read(handle, expectedBytes: 3)
                Issue.record("A cancelled approved-input hash completed")
            } catch is CancellationError {
                #expect(try handle.offset() == 0)
            }
        }
        try await task.value
    }

    private func withInput(_ data: Data, body: (FileHandle) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        try body(handle)
    }
}
