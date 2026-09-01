import Foundation
import NexGenEngine

enum CatalogCapabilityRuntimeError: Error {
    case unavailable
    case missingResource
}

enum CatalogCapabilityRuntime {
    private static let loadResult: Result<ModelCapabilityResolver, Error> = Result {
        let corpus = try BundledModelCapabilityCorpus.load()
        return try ModelCapabilityResolver(
            knowledgeBase: corpus.productionKnowledgeBase()
        )
    }

    static var resolver: ModelCapabilityResolver? {
        try? loadResult.get()
    }

    static var loadError: Error? {
        guard case .failure(let error) = loadResult else { return nil }
        return error
    }

    static func observationTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
