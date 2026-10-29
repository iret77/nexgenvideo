import Foundation

/// Exact keyword search over cached transcripts
enum TranscriptSearch {
    struct Hit: Equatable, Sendable {
        let assetID: String
        let start: Double
        let end: Double
        let text: String
    }

    struct Result: Sendable {
        let hits: [Hit]
        let unavailableAssetIDs: Set<String>
    }

    static func searchAsync(query: String, assets: [(id: String, url: URL)]) async -> [Hit] {
        await resultAsync(query: query, assets: assets).hits
    }

    static func resultAsync(query: String, assets: [(id: String, url: URL)], limit: Int = 20) async -> Result {
        let task = Task.detached(priority: .utility) { result(query: query, assets: assets, limit: limit) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func search(query: String, assets: [(id: String, url: URL)], limit: Int = 20) -> [Hit] {
        result(query: query, assets: assets, limit: limit).hits
    }

    static func result(query: String, assets: [(id: String, url: URL)], limit: Int = 20) -> Result {
        let terms = terms(in: query)
        guard !terms.isEmpty, limit > 0 else { return Result(hits: [], unavailableAssetIDs: []) }
        var hits: [Hit] = []
        var unavailable = Set<String>()
        for asset in assets {
            guard !Task.isCancelled else { return Result(hits: [], unavailableAssetIDs: Set(assets.map(\.id))) }
            guard let transcript = TranscriptCache.cachedOnDisk(for: asset.url) else {
                unavailable.insert(asset.id)
                continue
            }
            guard hits.count < limit else { continue }
            for segment in transcript.segments where matches(segment.text, terms: terms) {
                hits.append(Hit(assetID: asset.id, start: segment.start, end: segment.end, text: segment.text))
                if hits.count >= limit { break }
            }
        }
        return Result(hits: hits, unavailableAssetIDs: unavailable)
    }

    /// Query split into words, edge punctuation stripped (so "budget," → "budget").
    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ text: String, terms: [String]) -> Bool {
        terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
