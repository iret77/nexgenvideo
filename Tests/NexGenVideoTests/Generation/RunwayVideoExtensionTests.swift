import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Runway extension uses its actual source operation", .serialized)
struct RunwayVideoExtensionTests {
    @Test func extensionRequestUsesItsOwnOfficialEnvelope() throws {
        let source = "runway://actual-source-upload"
        let params = VideoGenerationParams(prompt: "The approved movement continues.", duration: .seconds(8),
            aspectRatio: "16:9", resolution: nil, sourceVideoURL: source, generateAudio: false)
        let body = try RunwayClient.videoExtensionBody(params)
        #expect(body["model"] as? String == "seedance2_5")
        #expect(body["mode"] as? String == "extend")
        #expect(body["promptVideo"] as? String == source)
        #expect(body["promptText"] as? String == params.prompt)
        #expect(body["duration"] as? Int == 8)
        #expect(body["audio"] as? Bool == false)
        #expect(Set(body.keys) == Set(["model", "mode", "promptVideo", "promptText", "duration", "audio"]))
    }

    @Test func sourceExtensionCannotAcceptAnIndependentFrameOrUnsupportedOutputShape() {
        for params in [
            VideoGenerationParams(prompt: "Continue.", duration: .seconds(8), aspectRatio: "16:9", resolution: nil),
            VideoGenerationParams(prompt: "Continue.", duration: .seconds(3), aspectRatio: "16:9", resolution: nil, sourceVideoURL: "runway://source"),
            VideoGenerationParams(prompt: "Continue.", duration: .seconds(31), aspectRatio: "16:9", resolution: nil, sourceVideoURL: "runway://source"),
            VideoGenerationParams(prompt: "Continue.", duration: .seconds(8), aspectRatio: "16:9", resolution: "1080p", sourceVideoURL: "runway://source"),
            VideoGenerationParams(prompt: "Continue.", duration: .seconds(8), aspectRatio: "16:9", resolution: nil,
                sourceVideoURL: "runway://source", startFrameURL: "runway://unrelated-frame"),
            VideoGenerationParams(prompt: "Continue.", duration: .seconds(8), aspectRatio: "16:9", resolution: nil,
                sourceVideoURL: "runway://source", referenceImageURLs: ["runway://look"]),
            VideoGenerationParams(prompt: "  ", duration: .seconds(8), aspectRatio: "16:9", resolution: nil, sourceVideoURL: "runway://source"),
        ] {
            #expect(throws: (any Error).self) { try RunwayClient.videoExtensionBody(params) }
        }
    }

    @Test func realClientKeepsUploadAndExtensionInsideItsInjectedTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProductionRunwaySourceHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ProductionRunwaySourceHTTP.clear() }
        let bytes = Data("actual upload bytes, not a decoded-video validity claim".utf8)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        ProductionRunwaySourceHTTP.install(operation: .extend, output: Data("isolated task output".utf8))
        let client = RunwayClient(apiKey: "simulator-only-key", session: session, pollIntervalNanoseconds: 0)
        let offered = try await client.availableModelIds()
        #expect(offered == ["seedance2_5"])
        let uploaded = try await client.uploadReference(fileURL: source, filename: source.lastPathComponent)
        #expect(uploaded == ProductionRunwaySourceHTTP.sourceURI)
        #expect(ProductionRunwaySourceHTTP.uploadedBytes == bytes)
        let task = try await client.createVideoExtension(params: .init(prompt: "Continue the compiled movement.",
            duration: .seconds(8), aspectRatio: "16:9", resolution: nil, sourceVideoURL: uploaded, generateAudio: false))
        #expect(task == ProductionRunwaySourceHTTP.requestID)
        let result = try await client.result(taskId: task)
        #expect(result.urls == ["https://media.invalid/native-source-output.mov"])
        #expect(ProductionRunwaySourceHTTP.unexpectedRequests.isEmpty)
        #expect(ProductionRunwaySourceHTTP.requests.filter { $0.url.hasSuffix("/video_to_video") }.count == 1)
    }

    @Test func onlyActualModelDiscoveryCanOfferTheExtension() throws {
        #expect(!RunwayModelRegistry.discoveredEntries(availableModelIds: ["aleph2"]).contains { $0.id == "runway/seedance2_5" })
        let offered = try #require(RunwayModelRegistry.discoveredEntries(availableModelIds: ["seedance2_5"]).first)
        let policy = try #require(offered.offers?.first?.productionInputPolicy)
        #expect(policy.requiresSourceVideo)
        #expect(policy.sourceOperation == .extendForward)
        #expect(!policy.preservesSourceComposition)
        let transform = try #require(RunwayModelRegistry.discoveredEntries(availableModelIds: ["aleph2"]).first?.offers?.first?.productionInputPolicy)
        #expect(transform.sourceOperation != .extendForward)
        #expect(transform.preservesSourceComposition)
    }

    @Test func extensionNativeLimitsDoNotRequireGuessedCapabilityResearch() throws {
        let entry = try #require(RunwayModelRegistry.entries.first { $0.id == "runway/seedance2_5" })
        let resolver = try ModelCapabilityResolver(knowledgeBase: BundledModelCapabilityCorpus.load().productionKnowledgeBase())
        let actual = try #require(ModelCatalog.offeringCapabilities(for: entry, resolver: resolver).first)
        #expect(actual.effective.fields.booleans[CapabilityFieldIDV1.sourceVideo]?.value == true)
        #expect(actual.effective.fields.booleans[CapabilityFieldIDV1.firstFrame]?.value == false)
        #expect(actual.effective.fields.booleans[CapabilityFieldIDV1.lastFrame]?.value == false)
        #expect(actual.effective.fields.decimals[CapabilityFieldIDV1.durationMinimum]?.value == 4)
        #expect(actual.effective.fields.decimals[CapabilityFieldIDV1.durationMaximum]?.value == 30)
        #expect(actual.effective.fields.strings[CapabilityFieldIDV1.modes]?.value == ["video-to-video"])
        #expect(actual.effective.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 0)
        #expect(actual.effective.fields.integers[CapabilityFieldIDV1.referenceVideos]?.value == 0)
        #expect(actual.effective.fields.integers[CapabilityFieldIDV1.referenceAudios]?.value == 0)
    }
}
