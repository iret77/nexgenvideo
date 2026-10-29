import Foundation
import AVFoundation
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
            VideoGenerationParams(prompt: String(repeating: "e\u{301}", count: 7_501), duration: .seconds(8),
                aspectRatio: "16:9", resolution: nil, sourceVideoURL: "runway://source"),
        ] {
            #expect(throws: (any Error).self) { try RunwayClient.videoExtensionBody(params) }
        }
    }

    @Test func extensionValidatesTheActualTrimInsteadOfRejectingTheLongOriginal() async throws {
        let short = try await ProductionSourceModeFixture.makeMovingVideo()
        let long = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: short); try? FileManager.default.removeItem(at: long) }
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: short)
        let track = try #require(try await source.loadTracks(withMediaType: .video).first)
        let target = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        for part in 0..<4 {
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 1)),
                of: track, at: CMTime(value: Int64(part * 8), timescale: 1))
        }
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: long, as: .mov)
        await #expect(throws: (any Error).self) { try await RunwayVideoExtensionContract.requireSource(long, aspectRatio: "16:9") }
        let trim = TrimmedSource(sourceURL: long, trimStartFrame: 30, trimEndFrame: 750, sourceFramesConsumed: 180, fps: 30)
        let effective = try await RunwayVideoExtensionContract.trimmedSource(trim, aspectRatio: "16:9")
        defer { try? FileManager.default.removeItem(at: effective) }
        let actual = try await AVURLAsset(url: effective).load(.duration)
        #expect(CMTimeCompare(actual, CMTime(value: 6, timescale: 1)) == 0)
        try await RunwayVideoExtensionContract.requireSource(effective, aspectRatio: "16:9")
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
        for audio in [false, true] {
            ProductionRunwaySourceHTTP.install(operation: .extend, output: Data("isolated task output".utf8), audio: audio)
            let client = RunwayClient(apiKey: "simulator-only-key", session: session, pollIntervalNanoseconds: 0)
            let offered = try await client.availableModelIds()
            #expect(offered == ["seedance2_5"])
            let uploaded = try await client.uploadReference(fileURL: source, filename: source.lastPathComponent)
            #expect(uploaded == ProductionRunwaySourceHTTP.sourceURI)
            #expect(ProductionRunwaySourceHTTP.uploadedBytes == bytes)
            let task = try await client.createVideoExtension(params: .init(prompt: "Continue the compiled movement.",
                duration: .seconds(8), aspectRatio: "16:9", resolution: nil, sourceVideoURL: uploaded, generateAudio: audio))
            #expect(task == ProductionRunwaySourceHTTP.requestID)
            let result = try await client.result(taskId: task)
            #expect(result.urls == ["https://media.invalid/native-source-output.mov"])
            #expect(ProductionRunwaySourceHTTP.unexpectedRequests.isEmpty)
            #expect(ProductionRunwaySourceHTTP.requests.filter { $0.url.hasSuffix("/video_to_video") }.count == 1)
            #expect(ProductionRunwaySourceHTTP.submittedBody?["audio"] as? Bool == audio)
        }
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

    @Test func videoOfferingNeedsItsActualAccountModelDiscovery() throws {
        let entry = try #require(RunwayModelRegistry.discoveredEntries(availableModelIds: ["seedance2_5"]).first)
        let binding = try #require(ProviderManifest.bindings(from: entry.offers ?? [], modelId: entry.id).first)
        func live(_ entries: [CatalogEntry], state: ProviderDiscoveryState = .ready(modelCount: 1)) -> Bool {
            ModelCatalog.productionOfferingIsLive(modelID: entry.id, modality: .video, binding: binding,
                modelExists: true, modelEnabled: true, discoveredByProvider: entries.isEmpty ? [:] : [.runway: entries],
                providerDiscovery: [.runway: state])
        }
        #expect(!live([]))
        #expect(!live(RunwayModelRegistry.discoveredEntries(availableModelIds: ["aleph2"])))
        #expect(live([entry]))
        #expect(live([entry], state: .stale(modelCount: 1, message: "Temporary transport failure")))
        #expect(!live([entry], state: .checking))
        #expect(!live([entry], state: .actionRequired("Replace the key")))
    }

    @MainActor @Test func credentialChangeClearsThePreviousAccountModelEntitlements() throws {
        let catalog = ModelCatalog()
        let entries = RunwayModelRegistry.discoveredEntries(availableModelIds: ["seedance2_5"])
        catalog.applyDiscovered(entries, for: .runway)
        catalog.setProviderDiscoveryState(.ready(modelCount: entries.count), for: .runway)
        #expect(catalog.discoveredModelCount(for: .runway) == 1)
        CatalogDiscovery.invalidateCredentialBoundDiscovery(catalog: catalog)
        #expect(catalog.discoveredModelCount(for: .runway) == 0)
        if case .inactive? = catalog.providerDiscovery[.runway] {} else { Issue.record("A credential change retained old discovery readiness.") }
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
        #expect(actual.effective.fields.decimals[CapabilityFieldIDV1.combinedVideoReferenceSeconds]?.value == 30)
        #expect(actual.effective.fields.strings[CapabilityFieldIDV1.modes]?.value == ["video-to-video"])
        #expect(actual.effective.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 0)
        #expect(actual.effective.fields.integers[CapabilityFieldIDV1.referenceVideos]?.value == 0)
        #expect(actual.effective.fields.integers[CapabilityFieldIDV1.referenceAudios]?.value == 0)
        let native = try #require(entry.offers?.first?.resolvedVideoCapabilities)
        let slots = ModelCatalog.inputSlots(capabilities: native, modeIDs: ["video-to-video"])
        #expect(slots.first { $0.id == CoreReferenceInputSlotIDV1.sourceVideo }?.countsTowardCombinedDuration == true)
        let transform = try #require(RunwayModelRegistry.entries.first { $0.id == "runway/aleph2" }?.offers?.first?.resolvedVideoCapabilities)
        let transformSlots = ModelCatalog.inputSlots(capabilities: transform, modeIDs: ["video-to-video"])
        #expect(transformSlots.first { $0.id == CoreReferenceInputSlotIDV1.sourceVideo }?.countsTowardCombinedDuration == false)
    }

    @Test func actualTransformAdapterFillsOnlyItsExecutableModeWithoutBecomingExtension() throws {
        let entry = try #require(RunwayModelRegistry.entries.first { $0.id == "runway/aleph2" })
        let resolver = try ModelCapabilityResolver(knowledgeBase: BundledModelCapabilityCorpus.load().productionKnowledgeBase())
        let actual = try #require(ModelCatalog.offeringCapabilities(for: entry, resolver: resolver).first)
        let modes = try #require(actual.effective.fields.strings[CapabilityFieldIDV1.modes]?.value)
        #expect(modes == ["video-to-video"])
        let native = try #require(entry.offers?.first?.resolvedVideoCapabilities)
        #expect(native.inputPolicy.preservesSourceComposition)
        #expect(native.inputPolicy.sourceOperation != .extendForward)
        let slots = ModelCatalog.inputSlots(capabilities: native, modeIDs: modes)
        #expect(slots.map(\.id) == [CoreReferenceInputSlotIDV1.sourceVideo])
        #expect(slots.first?.countsTowardCombinedDuration == false)
    }
}
