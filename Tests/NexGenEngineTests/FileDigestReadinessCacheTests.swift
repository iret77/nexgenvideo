import Foundation
import Testing
@testable import NexGenEngine

@Suite("Readiness digest cache")
struct FileDigestReadinessCacheTests {
    @Test func unchangedFilesReuseReadsAndReplacementsInvalidateEvenWithRestoredDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("take.mp4")
        try Data("first".utf8).write(to: url)
        let date = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let cache = FileDigestReadinessCache(capacity: 1)
        var reads = 0
        func read(_ handle: FileHandle) throws -> String {
            reads += 1
            return FileDigest.sha256(of: try handle.readToEnd() ?? Data())
        }
        let first = try cache.digest(of: url, read: read)
        #expect(try cache.digest(of: url, read: read) == first)
        #expect(reads == 1)
        try Data("other".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        #expect(try cache.digest(of: url, read: read) != first)
        #expect(reads == 2)
        try FileManager.default.removeItem(at: url)
        #expect(throws: (any Error).self) { try cache.digest(of: url, read: read) }
    }

    @Test func inPlaceEditsAndCapacityEvictionRequireNewReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let cache = FileDigestReadinessCache(capacity: 1)
        var reads = 0
        func read(_ handle: FileHandle) throws -> String {
            reads += 1
            return FileDigest.sha256(of: try handle.readToEnd() ?? Data())
        }
        let prior = try cache.digest(of: first, read: read)
        let handle = try FileHandle(forWritingTo: first)
        try handle.write(contentsOf: Data("new bytes".utf8))
        try handle.close()
        #expect(try cache.digest(of: first, read: read) != prior)
        _ = try cache.digest(of: second, read: read)
        _ = try cache.digest(of: first, read: read)
        #expect(reads == 4)
    }
}
