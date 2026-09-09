import Foundation
import NexGenEngine

enum PromptDialectRegistryError: LocalizedError, Equatable {
    case unsupported(modelID: String, endpointID: String, modeID: String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let modelID, let endpointID, let modeID):
            return "No verified prompt dialect is registered for model '\(modelID)', endpoint '\(endpointID)', mode '\(modeID)'. Select a supported route before generating."
        }
    }
}

enum PromptDialectRegistry {
    static func requireVideoDialect(
        modelID: String,
        endpointID: String? = nil,
        modeID: String
    ) throws -> VideoPromptDialectV1 {
        let identity = [modelID, endpointID ?? ""]
            .joined(separator: " ")
            .lowercased()
        if identity.contains("seedance") {
            return VideoPromptDialectV1(
                id: identity.contains("2.5") ? "seedance-2.5" : "seedance",
                version: 1,
                family: .seedance,
                evidence: "ai-film-production/video-prompting ch.12,14"
            )
        }
        if identity.contains("minimax-h3") || identity.contains("hailuo-3")
            || identity.contains("hailuo 3") {
            return VideoPromptDialectV1(
                id: "minimax-h3",
                version: 1,
                family: .h3,
                evidence: "MiniMax H3 official prompt-writing guides 2026-09-02"
            )
        }
        if identity.contains("kling") {
            return VideoPromptDialectV1(
                id: "kling",
                version: 1,
                family: .cameraFirst,
                evidence: "ai-film-production/platforms-models ch.21"
            )
        }
        if identity.contains("veo") {
            return VideoPromptDialectV1(
                id: "veo",
                version: 1,
                family: .cameraFirst,
                evidence: "ai-film-production/platforms-models ch.21"
            )
        }
        if identity.contains("grok") {
            return VideoPromptDialectV1(
                id: "grok-imagine",
                version: 1,
                family: .styleFirst,
                evidence: "ai-film-production/platforms-models ch.21"
            )
        }
        if identity.contains("runway") {
            return VideoPromptDialectV1(
                id: "runway-video",
                version: 1,
                family: .generic,
                evidence: "Runway official prompting guide"
            )
        }
        throw PromptDialectRegistryError.unsupported(
            modelID: modelID,
            endpointID: endpointID ?? modelID,
            modeID: modeID
        )
    }
}
