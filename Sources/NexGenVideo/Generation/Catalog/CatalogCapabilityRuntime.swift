import Foundation
import NexGenEngine

enum CatalogCapabilityRuntimeError: Error {
    case unavailable
    case missingResource
}

enum CatalogCapabilityRuntime {
    private struct State: Sendable {
        let corpus: ModelCapabilityCorpusDocument
        let resolver: ModelCapabilityResolver
    }

    private static let loadResult: Result<State, Error> = Result {
        let corpus = try BundledModelCapabilityCorpus.load()
        return State(
            corpus: corpus,
            resolver: try ModelCapabilityResolver(
                knowledgeBase: corpus.productionKnowledgeBase()
            )
        )
    }

    static var resolver: ModelCapabilityResolver? {
        try? loadResult.get().resolver
    }

    static var corpus: ModelCapabilityCorpusDocument? {
        try? loadResult.get().corpus
    }

    static var loadError: Error? {
        guard case .failure(let error) = loadResult else { return nil }
        return error
    }

    static func observationTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
