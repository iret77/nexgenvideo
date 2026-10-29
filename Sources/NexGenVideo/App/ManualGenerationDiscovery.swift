import Foundation
import NexGenEngine

@MainActor
enum ManualGenerationDiscovery {
    static func images(session: URLSession, catalog: ModelCatalog,
        textToImage: [String] = ["fal-ai/flux/schnell", "fal-ai/flux/dev"],
        imageToImage: [String] = ["fal-ai/gemini-25-flash-image/edit"]) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested else {
            throw GateBlocked("Isolated discovery requires explicit native acceptance.")
        }
        try MusicvideoGenerationHTTP.installImageCatalog(textToImage: textToImage, imageToImage: imageToImage)
        let ids = try await FalClient(apiKey: "simulator-only-key", session: session).availableImageModelIds()
        let expectedRequests = ["text-to-image", "image-to-image"].map {
            "https://api.fal.ai/v1/models?category=\($0)&status=active&limit=100"
        }
        guard ids == Set(textToImage + imageToImage),
              MusicvideoGenerationHTTP.requests.map(\.url) == expectedRequests,
              MusicvideoGenerationHTTP.requests.allSatisfy({ $0.method == "GET" }),
              MusicvideoGenerationHTTP.unexpectedRequests.isEmpty else {
            throw GateBlocked("The isolated image catalog was not read through the actual Fal client.")
        }
        catalog.applyDiscovered(FalModelRegistry.discoveredEntries(availableModelIds: ids), for: .fal)
        return ["endpointIDs": ids.sorted(), "requests": expectedRequests, "liveProvider": false]
    }
}
