import Foundation
import NexGenEngine

enum CatalogCapabilityRuntimeError: Error {
    case unavailable
    case missingResource
}

enum CatalogCapabilityRuntime {
    private static let loadResult: Result<ModelCapabilityResolver, Error> = Result {
        guard let directory = Bundle.module.url(
            forResource: "ModelCapabilities",
            withExtension: nil
        ) else {
            throw CatalogCapabilityRuntimeError.missingResource
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent("model-capabilities.v1.json")
        )
        return try ModelCapabilityResolver(
            knowledgeBase: ModelCapabilityKnowledgeBaseCodec.decode(data)
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
