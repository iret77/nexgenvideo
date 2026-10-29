import Foundation
import Testing
@testable import NexGenVideo

@MainActor
struct InlineAudioOutputTests {
    @Test func batchAudioPreservesAnExistingUnverifiedOutput() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.wav")
        let retained = Data("previous provider bytes".utf8)
        try retained.write(to: output)
        #expect(throws: GenerationRequestError.self) {
            try GenerationService.writeInlineAudioOutput(Data("new response".utf8), to: output, preservingExisting: true)
        }
        #expect(try Data(contentsOf: output) == retained)
    }

    @Test func batchAudioCannotReplaceADanglingOutputLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.wav")
        let target = directory.appendingPathComponent("missing.wav")
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)
        #expect(throws: GenerationRequestError.self) {
            try GenerationService.writeInlineAudioOutput(Data("new response".utf8), to: output, preservingExisting: true)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.path) == target.path)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func batchAudioPublishesExactlyOnceAndAbandonedWorkWritesNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.wav")
        let bytes = Data("actual inline response".utf8)
        try GenerationService.writeInlineAudioOutput(bytes, to: output, preservingExisting: true)
        #expect(try Data(contentsOf: output) == bytes)
        #expect(throws: GenerationRequestError.self) {
            try GenerationService.writeInlineAudioOutput(Data("replacement".utf8), to: output, preservingExisting: true)
        }
        let late = directory.appendingPathComponent("late.wav")
        let lifetime = GenerationBatchExecutionLifetime()
        lifetime.abandon()
        #expect(throws: CancellationError.self) {
            try GenerationBatchExecutionLifetime.$current.withValue(lifetime) {
                try GenerationService.writeInlineAudioOutput(bytes, to: late, preservingExisting: true)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: late.path))
        #expect(try Data(contentsOf: output) == bytes)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inline-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
