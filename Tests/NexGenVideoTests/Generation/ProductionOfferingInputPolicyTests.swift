import Foundation
import Testing

@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Production offering input policies")
struct ProductionOfferingInputPolicyTests {
    @Test("same logical model keeps provider endpoint input policies separate")
    func divergentProviderEndpointPolicies() throws {
        let resolver = try #require(CatalogCapabilityRuntime.resolver)
        var entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bytedance/seedance-2.5/text-to-video"
        })
        guard case .video(let baseCapabilities) = entry.uiCapabilities else {
            Issue.record("Expected video capabilities")
            return
        }
        let falPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let runwayPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: true,
            framesCountTowardTotalReferenceLimit: true
        )
        let higgsfieldPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: true
        )
        entry.offers = [
            ProviderOffer(
                provider: .fal,
                providerRef: "fal/seedance-image",
                productionInputPolicy: falPolicy,
                resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1(
                    videoCapabilities: baseCapabilities,
                    inputPolicy: falPolicy,
                    supportsNativeAudio: true
                )
            ),
            ProviderOffer(
                provider: .runway,
                providerRef: "runway/seedance-image",
                productionInputPolicy: runwayPolicy,
                resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1(
                    videoCapabilities: baseCapabilities,
                    inputPolicy: runwayPolicy,
                    supportsNativeAudio: false
                )
            ),
            ProviderOffer(
                provider: .higgsfield,
                transport: .mcp,
                providerRef: "generate_video",
                modelParam: "seedance-image",
                productionInputPolicy: higgsfieldPolicy,
                resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1(
                    videoCapabilities: baseCapabilities,
                    inputPolicy: higgsfieldPolicy,
                    supportsNativeAudio: true
                )
            ),
        ]
        entry.resolvedOfferingCapabilities = nil

        let resolved = try ModelCatalog.offeringCapabilities(
            for: entry,
            resolver: resolver
        )
        #expect(resolved.count == 3)
        let fal = try #require(resolved.first {
            $0.offering.providerID == GenerationProvider.fal.rawValue
        })
        let runway = try #require(resolved.first {
            $0.offering.providerID == GenerationProvider.runway.rawValue
        })
        let higgsfield = try #require(resolved.first {
            $0.offering.providerID == GenerationProvider.higgsfield.rawValue
        })

        #expect(endpointPolicy(fal) == [false, false, false])
        #expect(endpointPolicy(runway) == [false, true, true])
        #expect(endpointPolicy(higgsfield) == [true, false, true])

        let falSlots = ModelCatalog.inputSlots(capabilities: withRoutingModes(fal))
        let runwaySlots = ModelCatalog.inputSlots(capabilities: withRoutingModes(runway))
        let higgsfieldSlots = ModelCatalog.inputSlots(
            capabilities: withRoutingModes(higgsfield)
        )
        let falFirst = try #require(falSlots.first {
            $0.id == CoreReferenceInputSlotIDV1.firstFrame
        })
        let runwayFirst = try #require(runwaySlots.first {
            $0.id == CoreReferenceInputSlotIDV1.firstFrame
        })

        #expect(!falFirst.countsTowardModalityBudget)
        #expect(!falFirst.countsTowardTotalBudget)
        #expect(runwayFirst.countsTowardModalityBudget)
        #expect(runwayFirst.countsTowardTotalBudget)
        #expect(higgsfieldSlots.contains {
            $0.id == CoreReferenceInputSlotIDV1.sourceVideo
        })
        #expect(!higgsfieldSlots.contains {
            $0.id == CoreReferenceInputSlotIDV1.firstFrame
                || $0.id == CoreReferenceInputSlotIDV1.lastFrame
        })
    }

    @Test("missing exact endpoint policy fails closed")
    func missingEndpointPolicyFailsClosed() throws {
        let resolver = try #require(CatalogCapabilityRuntime.resolver)
        var entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bytedance/seedance-2.5/image-to-video"
        })
        entry.offers = [ProviderOffer(
            provider: .fal,
            providerRef: "fal/unversioned-input-policy"
        )]
        entry.resolvedOfferingCapabilities = nil

        #expect(throws: ModelCapabilityKnowledgeError.invalidOffering(
            "missing_production_input_policy"
        )) {
            _ = try ModelCatalog.offeringCapabilities(for: entry, resolver: resolver)
        }
    }

    @Test("malformed exact endpoint contract fails closed")
    func malformedEndpointContractFailsClosed() throws {
        let resolver = try #require(CatalogCapabilityRuntime.resolver)
        var entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bytedance/seedance-2.5/image-to-video"
        })
        let policy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let malformed = ResolvedVideoOfferingCapabilitiesV1(
            schemaVersion: 1,
            inputPolicy: policy,
            durationValues: [],
            durationMinimum: 10,
            durationMaximum: 5,
            supportsAutomaticDuration: false,
            supportsNativeAudio: false,
            resolutions: ["720p"],
            aspectRatios: ["16:9"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: 0,
            maxCombinedVideoReferenceSeconds: nil,
            maxCombinedAudioReferenceSeconds: nil,
            framesAndReferencesExclusive: false,
            requiresReferenceImage: true,
            maxReferenceImagesWhenVideoPresent: nil
        )
        entry.offers = [ProviderOffer(
            provider: .fal,
            providerRef: "fal/malformed",
            productionInputPolicy: policy,
            resolvedVideoCapabilities: malformed
        )]
        entry.resolvedOfferingCapabilities = nil

        #expect(throws: ModelCapabilityKnowledgeError.invalidOffering(
            "invalid_resolved_video_offering_capabilities_v1"
        )) {
            _ = try ModelCatalog.offeringCapabilities(for: entry, resolver: resolver)
        }
        #expect(malformed.validate(
            duration: .seconds(5),
            aspectRatio: "16:9",
            resolution: "720p",
            generateAudio: false,
            displayName: "Malformed"
        ) != nil)
    }

    @Test("required image contracts must expose a usable image slot")
    func requiredImageContractMustBeFulfillable() {
        let sourceVideoPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let impossible = exactCapabilities(
            policy: sourceVideoPolicy,
            durations: [5],
            resolutions: ["720p"],
            aspectRatios: ["16:9"],
            maxReferenceImages: 0,
            requiresReferenceImage: true
        )
        #expect(
            impossible.contractViolation
                == "required_reference_image_unfulfillable"
        )

        let firstFramePolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let firstFrameOnly = exactCapabilities(
            policy: firstFramePolicy,
            durations: [5],
            resolutions: ["720p"],
            aspectRatios: ["16:9"],
            maxReferenceImages: 0,
            requiresReferenceImage: true
        )
        #expect(firstFrameOnly.contractViolation == nil)
    }

    @Test("video submission and dispatch reject a different offering policy")
    @MainActor
    func executionUsesApprovedOfferingPolicy() throws {
        let entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bytedance/seedance-2.5/text-to-video"
        })
        let model = try #require(entry.videoModel)
        let textPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: true,
            framesCountTowardTotalReferenceLimit: true
        )
        let editPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let source = MediaAsset(
            id: "source",
            url: URL(fileURLWithPath: "/tmp/source.mp4"),
            type: .video,
            name: "source"
        )
        let input = GenerationInput(
            prompt: "test",
            model: model.id,
            duration: 5,
            aspectRatio: "16:9"
        )
        let edit = VideoGenerationSubmission.make(
            genInput: input,
            model: model,
            offeringCapabilities: ResolvedVideoOfferingCapabilitiesV1(
                videoCapabilities: model.caps,
                inputPolicy: editPolicy,
                supportsNativeAudio: false
            ),
            inputAssets: .init(sourceVideo: source),
            placeholderDuration: 5,
            generateAudio: false
        )
        let params = edit.buildParams(["uploaded-source"])
        let editTarget = target(
            modelID: model.id,
            provider: .runway,
            endpoint: "runway/edit",
            policy: editPolicy,
            capabilities: ResolvedVideoOfferingCapabilitiesV1(
                videoCapabilities: model.caps,
                inputPolicy: editPolicy,
                supportsNativeAudio: false
            )
        )
        let textTarget = target(
            modelID: model.id,
            provider: .fal,
            endpoint: "fal/text",
            policy: textPolicy,
            capabilities: ResolvedVideoOfferingCapabilitiesV1(
                videoCapabilities: model.caps,
                inputPolicy: textPolicy,
                supportsNativeAudio: false
            )
        )

        #expect(throws: Never.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                edit.resolvedVideoCapabilities,
                target: editTarget,
                params: params
            )
        }
        #expect(throws: Error.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                edit.resolvedVideoCapabilities,
                target: textTarget,
                params: params
            )
        }
    }

    @Test("same logical model dispatches only within the approved endpoint output contract")
    func executionUsesApprovedOfferingOutputs() throws {
        let policy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let accepted = exactCapabilities(
            policy: policy,
            durations: [5],
            resolutions: ["720p"],
            aspectRatios: ["16:9"],
            maxReferenceImages: 1
        )
        let rejected = exactCapabilities(
            policy: policy,
            durations: [10],
            resolutions: ["1080p"],
            aspectRatios: ["9:16"],
            maxReferenceImages: 0
        )
        let params = BackendGenerationParams.video(VideoGenerationParams(
            prompt: "test",
            duration: 5,
            aspectRatio: "16:9",
            resolution: "720p",
            referenceImageURLs: ["reference"],
            generateAudio: false
        ))
        let fal = target(
            modelID: "logical/shared-video",
            provider: .fal,
            endpoint: "fal/shared-video",
            policy: policy,
            capabilities: accepted
        )
        let runway = target(
            modelID: "logical/shared-video",
            provider: .runway,
            endpoint: "runway/shared-video",
            policy: policy,
            capabilities: rejected
        )

        #expect(throws: Never.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                accepted,
                target: fal,
                params: params
            )
        }
        #expect(throws: Error.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                accepted,
                target: runway,
                params: params
            )
        }
        #expect(throws: Error.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                rejected,
                target: runway,
                params: params
            )
        }
    }

    @Test("dispatch enforces exact native-audio support")
    func executionUsesApprovedNativeAudioCapability() throws {
        let policy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let withAudio = exactCapabilities(
            policy: policy,
            durations: [5],
            resolutions: ["720p"],
            aspectRatios: ["16:9"],
            maxReferenceImages: 0,
            supportsNativeAudio: true
        )
        let silent = exactCapabilities(
            policy: policy,
            durations: [5],
            resolutions: ["720p"],
            aspectRatios: ["16:9"],
            maxReferenceImages: 0
        )
        let params = BackendGenerationParams.video(VideoGenerationParams(
            prompt: "test",
            duration: 5,
            aspectRatio: "16:9",
            resolution: "720p",
            generateAudio: true
        ))
        let audioTarget = target(
            modelID: "logical/shared-video",
            provider: .fal,
            endpoint: "fal/native-audio",
            policy: policy,
            capabilities: withAudio
        )
        let silentTarget = target(
            modelID: "logical/shared-video",
            provider: .runway,
            endpoint: "runway/silent",
            policy: policy,
            capabilities: silent
        )

        #expect(throws: Never.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                withAudio,
                target: audioTarget,
                params: params
            )
        }
        #expect(throws: Error.self) {
            try GenerationService.validateVideoDispatchCapabilities(
                silent,
                target: silentTarget,
                params: params
            )
        }
    }

    @Test("source-video offering enforces its required image at the shared boundary")
    @MainActor
    func sourceVideoRequiredImageIsCentralized() throws {
        let entry = try #require(FalModelRegistry.entries.first {
            $0.id == "bytedance/seedance-2.5/image-to-video"
        })
        let model = try #require(entry.videoModel)
        let policy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let capabilities = exactCapabilities(
            policy: policy,
            durations: [5],
            resolutions: nil,
            aspectRatios: ["16:9"],
            maxReferenceImages: 1,
            requiresReferenceImage: true
        )
        let source = MediaAsset(
            id: "source",
            url: URL(fileURLWithPath: "/tmp/source.mp4"),
            type: .video,
            name: "source"
        )
        let reference = MediaAsset(
            id: "reference",
            url: URL(fileURLWithPath: "/tmp/reference.png"),
            type: .image,
            name: "reference"
        )

        #expect(VideoGenerationSubmission.InputAssets(
            sourceVideo: source
        ).validate(
            for: model,
            offeringCapabilities: capabilities
        ) != nil)
        #expect(VideoGenerationSubmission.InputAssets(
            sourceVideo: source,
            imageRefs: [reference]
        ).validate(
            for: model,
            offeringCapabilities: capabilities
        ) == nil)
    }

    @Test("video rerun reconstructs every semantic input from durable asset ids")
    @MainActor
    func videoRerunReconstructsInlineInputs() throws {
        let editor = EditorViewModel()
        let source = MediaAsset(
            id: "source",
            url: URL(fileURLWithPath: "/tmp/source.mp4"),
            type: .video,
            name: "source"
        )
        let start = MediaAsset(
            id: "start",
            url: URL(fileURLWithPath: "/tmp/start.png"),
            type: .image,
            name: "start"
        )
        let end = MediaAsset(
            id: "end",
            url: URL(fileURLWithPath: "/tmp/end.png"),
            type: .image,
            name: "end"
        )
        let image = MediaAsset(
            id: "image",
            url: URL(fileURLWithPath: "/tmp/reference.png"),
            type: .image,
            name: "image"
        )
        let video = MediaAsset(
            id: "video",
            url: URL(fileURLWithPath: "/tmp/reference.mp4"),
            type: .video,
            name: "video"
        )
        let audio = MediaAsset(
            id: "audio",
            url: URL(fileURLWithPath: "/tmp/reference.wav"),
            type: .audio,
            name: "audio"
        )
        editor.mediaAssets = [source, start, end, image, video, audio]

        var sourceInput = GenerationInput(
            prompt: "test",
            model: "shared-video",
            duration: 5,
            aspectRatio: "16:9"
        )
        sourceInput.sourceVideoAssetId = source.id
        sourceInput.imageURLAssetIds = [source.id, image.id]
        sourceInput.referenceImageAssetIds = [image.id]
        let sourceAssets = try EditSubmitter.videoInputAssets(
            sourceInput,
            editor: editor
        )
        #expect(sourceAssets.sourceVideo?.id == source.id)
        #expect(sourceAssets.frames.isEmpty)
        #expect(sourceAssets.imageRefs.map(\.id) == [image.id])

        var referenceInput = GenerationInput(
            prompt: "test",
            model: "shared-video",
            duration: 5,
            aspectRatio: "16:9"
        )
        referenceInput.imageURLAssetIds = [start.id, end.id]
        referenceInput.startFrameAssetId = start.id
        referenceInput.endFrameAssetId = end.id
        referenceInput.referenceImageAssetIds = [image.id]
        referenceInput.referenceVideoAssetIds = [video.id]
        referenceInput.referenceAudioAssetIds = [audio.id]
        let referenceAssets = try EditSubmitter.videoInputAssets(
            referenceInput,
            editor: editor
        )
        #expect(referenceAssets.sourceVideo == nil)
        #expect(referenceAssets.frames.map(\.id) == [start.id, end.id])
        #expect(referenceAssets.imageRefs.map(\.id) == [image.id])
        #expect(referenceAssets.videoRefs.map(\.id) == [video.id])
        #expect(referenceAssets.audioRefs.map(\.id) == [audio.id])
    }

    @Test("generation reference labels use persisted semantic slots")
    @MainActor
    func referenceLabelsUseSemanticSlots() {
        let source = MediaAsset(
            id: "source",
            url: URL(fileURLWithPath: "/tmp/source.mp4"),
            type: .video,
            name: "source"
        )
        let image = MediaAsset(
            id: "image",
            url: URL(fileURLWithPath: "/tmp/reference.png"),
            type: .image,
            name: "image"
        )
        var sourceInput = GenerationInput(
            prompt: "test",
            model: "provider-neutral-model",
            duration: 5,
            aspectRatio: "16:9"
        )
        sourceInput.imageURLAssetIds = [source.id, image.id]
        sourceInput.sourceVideoAssetId = source.id
        sourceInput.referenceImageAssetIds = [image.id]

        let labels = GenerationReferencesStrip.slots(
            for: sourceInput,
            in: [source, image]
        ).map(\.0)

        #expect(labels == ["Source", "Image Ref"])
    }

    private func endpointPolicy(
        _ capability: ResolvedOfferingCapabilityProfileV1
    ) -> [Bool] {
        let fields = capability.effective.fields.booleans
        return [
            fields[CapabilityFieldIDV1.sourceVideoRequired]?.value,
            fields[CapabilityFieldIDV1.framesCountTowardImageReferenceLimit]?.value,
            fields[CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit]?.value,
        ].compactMap { $0 }
    }

    private func withRoutingModes(
        _ capability: ResolvedOfferingCapabilityProfileV1
    ) -> ResolvedOfferingCapabilityProfileV1 {
        var fields = capability.effective.fields
        let origin = ResolvedCapabilityOriginV1(
            kind: .exact,
            profileID: "test-routing-mode"
        )
        fields.strings[CapabilityFieldIDV1.modes] = ResolvedCapabilityValueV1(
            value: ["image-to-video"],
            semantics: .supportedSet,
            origin: origin,
            evidence: []
        )
        fields.booleans[CapabilityFieldIDV1.firstFrame] = ResolvedCapabilityValueV1(
            value: true,
            semantics: .supportedValue,
            origin: origin,
            evidence: []
        )
        fields.booleans[CapabilityFieldIDV1.lastFrame] = ResolvedCapabilityValueV1(
            value: true,
            semantics: .supportedValue,
            origin: origin,
            evidence: []
        )
        let effective = ResolvedCapabilityProfileV1(
            requestedIdentity: capability.effective.requestedIdentity,
            resolvedIdentity: capability.effective.resolvedIdentity,
            defensiveProfileID: capability.effective.defensiveProfileID,
            researchNeeded: capability.effective.researchNeeded,
            fields: fields
        )
        return ResolvedOfferingCapabilityProfileV1(
            offering: capability.offering,
            intrinsic: capability.intrinsic,
            effective: effective
        )
    }

    private func target(
        modelID: String,
        provider: GenerationProvider,
        endpoint: String,
        policy: ProviderProductionInputPolicyV1,
        capabilities: ResolvedVideoOfferingCapabilitiesV1
    ) -> ResolvedGenerationTarget {
        let binding = ProviderBinding(
            provider: provider,
            transport: .api,
            kind: .generation,
            providerRef: endpoint,
            billing: .perCall,
            productionInputPolicy: policy,
            resolvedVideoCapabilities: capabilities
        )
        return ResolvedGenerationTarget(
            modelId: modelID,
            provider: provider,
            endpoint: endpoint,
            binding: binding
        )
    }

    private func exactCapabilities(
        policy: ProviderProductionInputPolicyV1,
        durations: [Int],
        resolutions: [String]?,
        aspectRatios: [String],
        maxReferenceImages: Int,
        requiresReferenceImage: Bool = false,
        supportsNativeAudio: Bool = false
    ) -> ResolvedVideoOfferingCapabilitiesV1 {
        ResolvedVideoOfferingCapabilitiesV1(
            schemaVersion: 1,
            inputPolicy: policy,
            durationValues: durations,
            durationMinimum: nil,
            durationMaximum: nil,
            supportsAutomaticDuration: false,
            supportsNativeAudio: supportsNativeAudio,
            resolutions: resolutions,
            aspectRatios: aspectRatios,
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: maxReferenceImages,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: maxReferenceImages,
            maxCombinedVideoReferenceSeconds: nil,
            maxCombinedAudioReferenceSeconds: nil,
            framesAndReferencesExclusive: false,
            requiresReferenceImage: requiresReferenceImage,
            maxReferenceImagesWhenVideoPresent: nil
        )
    }
}

private extension CatalogEntry {
    var videoModel: VideoModelConfig? {
        guard case .video(let capabilities) = uiCapabilities else { return nil }
        return VideoModelConfig(entry: self, caps: capabilities)
    }
}
