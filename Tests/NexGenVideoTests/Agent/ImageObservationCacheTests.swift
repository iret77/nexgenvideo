import Foundation
import Testing
@testable import NexGenVideo

@Suite("Transient image inspection")
@MainActor
struct ImageObservationCacheTests {
    @Test("inspection writes nothing, deduplicates and expires bounded evidence")
    func boundedEvidence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = ImageObservationCache(maximumBytes: 8)
        let bytes = Data("first".utf8)
        let receipt = try cache.observe(project: home, sourceSHA256: "source", image: bytes, mediaID: "image")
        let repeated = try cache.observe(project: home, sourceSHA256: "source", image: bytes, mediaID: "image")
        #expect(receipt.id == repeated.id)
        #expect(try cache.require(receipt.id, project: home, sourceSHA256: "source").bytes == bytes)
        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect(throws: (any Error).self) { try cache.require(receipt.id, project: home.appendingPathComponent("other"), sourceSHA256: "source") }
        #expect(throws: (any Error).self) { try cache.require(receipt.id, project: home, sourceSHA256: "changed") }
        _ = try cache.observe(project: home, sourceSHA256: "next", image: Data("second".utf8), mediaID: "next")
        #expect(throws: (any Error).self) { try cache.require(receipt.id, project: home, sourceSHA256: "source") }
        #expect(throws: (any Error).self) { try cache.observe(project: home, sourceSHA256: "empty", image: Data(), mediaID: "empty") }
    }
    @Test("tiny images cannot grow receipt metadata without limit")
    func boundsEntryCount() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = ImageObservationCache(maximumBytes: 1024)
        let first = try cache.observe(project: home, sourceSHA256: "first", image: Data([1]), mediaID: "first")
        for index in 0..<128 {
            _ = try cache.observe(project: home, sourceSHA256: String(index), image: Data([1]), mediaID: String(index))
        }
        #expect(throws: (any Error).self) { try cache.require(first.id, project: home, sourceSHA256: "first") }
    }

}
