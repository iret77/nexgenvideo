import Foundation
import Testing
@testable import NexGenVideo

@Suite("Spoken search distinguishes unavailable cache from no matches")
struct TranscriptSearchAvailabilityTests {
    private func source() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-source-\(UUID().uuidString).wav")
        try Data("cache matching fixture, not a speech recognition proof".utf8).write(to: url)
        return url
    }

    private func write(_ result: TranscriptionResult, source: URL) throws -> URL {
        let cache = try #require(TranscriptCache.diskURL(for: source))
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: cache, options: .atomic)
        return cache
    }

    @Test func corruptJSONIsNotConsideredCachedAndRepairRestoresRealKeywordSearch() async throws {
        let source = try source()
        let cache = try #require(TranscriptCache.diskURL(for: source))
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid JSON".utf8).write(to: cache, options: .atomic)
        #expect(!TranscriptCache.hasCachedOnDisk(for: source))
        let unavailable = await TranscriptSearch.resultAsync(query: "budget", assets: [("clip", source)])
        #expect(unavailable.hits.isEmpty)
        #expect(unavailable.unavailableAssetIDs == ["clip"])
        _ = try write(TranscriptionResult(text: "Budget meeting", language: "en", words: [],
                                         segments: [.init(text: "Budget meeting", start: 1, end: 2)]), source: source)
        #expect(TranscriptCache.hasCachedOnDisk(for: source))
        let repaired = await TranscriptSearch.resultAsync(query: "budget", assets: [("clip", source)])
        #expect(repaired.unavailableAssetIDs.isEmpty)
        #expect(repaired.hits == [.init(assetID: "clip", start: 1, end: 2, text: "Budget meeting")])
        let noMatch = await TranscriptSearch.resultAsync(query: "harbor", assets: [("clip", source)])
        #expect(noMatch.hits.isEmpty)
        #expect(noMatch.unavailableAssetIDs.isEmpty)
    }

    @Test func unavailableAssetsAreReportedEvenAfterHitLimitIsReached() async throws {
        let present = try source(), absent = try source()
        let cache = try write(.init(text: "Meeting", language: "en", words: [],
                                    segments: [.init(text: "Meeting", start: 0, end: 1)]), source: present)
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: present)
            try? FileManager.default.removeItem(at: absent)
        }
        let result = await TranscriptSearch.resultAsync(query: "meeting", assets: [("present", present), ("absent", absent)], limit: 1)
        #expect(result.hits.count == 1)
        #expect(result.unavailableAssetIDs == ["absent"])
        #expect(TranscriptSearch.search(query: "meeting", assets: [("present", present)]) == result.hits)
    }

    @Test func invalidRangesAndUnrepresentableTimesDoNotCountAsValidCache() throws {
        let source = try source()
        let cache = try #require(TranscriptCache.diskURL(for: source))
        defer {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: source)
        }
        for (start, end) in [(-1.0, 2.0), (2, 1), (1, 1), (0, 1e100)] {
            _ = try write(.init(text: "Bad range", language: "en", words: [],
                                segments: [.init(text: "Bad range", start: start, end: end)]), source: source)
            #expect(!TranscriptCache.hasCachedOnDisk(for: source))
            #expect(TranscriptCache.cachedOnDisk(for: source) == nil)
        }
        _ = try write(.init(text: "silence", language: nil, words: [], segments: []), source: source)
        #expect(!TranscriptCache.hasCachedOnDisk(for: source))
        _ = try write(.init(text: "", language: nil, words: [], segments: []), source: source)
        #expect(TranscriptCache.hasCachedOnDisk(for: source))
    }

    @Test func decoderFailureDoesNotPublishAnEmptyCurrentVisualIndex() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-image-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: VisualIndexer.IndexError.self) { try VisualIndexer.requireImage(url) }
        let key = try #require(EmbeddingStore.key(for: url))
        #expect(EmbeddingStore.header(key: key) == nil)
    }
}
