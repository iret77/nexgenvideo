import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Pipeline production provider envelopes")
struct PipelineProductionRoutingTests {
    @MainActor
    @Test("generic provider envelope preserves every routed output field")
    func genericEnvelopeOutputFieldsAreExact() throws {
        let requirement = Self.requirement()
        let input = Self.generationInput(requirement: requirement)
        let exact = Self.params()
        let target = Self.target(
            modelID: "fixture-model",
            provider: .fal,
            endpoint: "fixture-model"
        )

        try PipelineProductionRouting.validateProviderEnvelope(
            genInput: input,
            target: target,
            params: .video(exact),
            uploadedReferences: []
        )
        #expect(PipelineProductionRouting.requiredMCPFieldNames(
            genInput: input
        ) == Set(["duration", "aspectratio", "resolution", "generateaudio"]))

        for changed in [
            VideoGenerationParams(
                prompt: exact.prompt,
                duration: .seconds(6),
                aspectRatio: exact.aspectRatio,
                resolution: exact.resolution,
                generateAudio: exact.generateAudio
            ),
            VideoGenerationParams(
                prompt: exact.prompt,
                duration: exact.duration,
                aspectRatio: "9:16",
                resolution: exact.resolution,
                generateAudio: exact.generateAudio
            ),
            VideoGenerationParams(
                prompt: exact.prompt,
                duration: exact.duration,
                aspectRatio: exact.aspectRatio,
                resolution: "1080p",
                generateAudio: exact.generateAudio
            ),
            VideoGenerationParams(
                prompt: exact.prompt,
                duration: exact.duration,
                aspectRatio: exact.aspectRatio,
                resolution: exact.resolution,
                generateAudio: false
            ),
        ] {
            #expect(throws: PipelineProductionRoutingError.self) {
                try PipelineProductionRouting.validateProviderEnvelope(
                    genInput: input,
                    target: target,
                    params: .video(changed),
                    uploadedReferences: []
                )
            }
        }
    }

    @MainActor
    @Test("fal envelope preserves the exact encoded output fields")
    func falEnvelopeOutputFieldsAreExact() throws {
        let modelID = "bytedance/seedance-2.0/text-to-video"
        let model = try #require(FalModelRegistry.model(for: modelID))
        let requirement = Self.requirement()
        let generationInput = Self.generationInput(
            requirement: requirement,
            modelID: modelID
        )
        let params = Self.params()
        let exact = FalInputBuilder.videoInput(params, model: model)

        try PipelineProductionRouting.validateFalProviderEnvelope(
            genInput: generationInput,
            params: params,
            input: exact,
            model: model
        )

        for mutation in [
            ("duration", "6" as Any),
            ("aspect_ratio", "9:16" as Any),
            ("resolution", "1080p" as Any),
            ("generate_audio", false as Any),
        ] {
            var changed = exact
            changed[mutation.0] = mutation.1
            #expect(throws: PipelineProductionRoutingError.self) {
                try PipelineProductionRouting.validateFalProviderEnvelope(
                    genInput: generationInput,
                    params: params,
                    input: changed,
                    model: model
                )
            }
        }
    }

    @MainActor
    @Test("fal adapter rejects output fields its model cannot encode")
    func falAdapterRejectsUnsupportedOutputFields() throws {
        let requirement = Self.requirement()
        let modelID = "fal-ai/kling-video/v2.5-turbo/pro/text-to-video"
        let route = Self.route(requirement: requirement, endpoint: modelID)
        let plan = Self.plan(route: route, bindings: [])
        let target = ResolvedGenerationTarget(
            modelId: modelID,
            provider: .fal,
            endpoint: modelID,
            binding: ProviderBinding(
                provider: .fal,
                transport: .api,
                kind: .generation,
                providerRef: modelID,
                billing: .perCall,
                productionInputPolicy: Self.inputPolicy(),
                resolvedVideoCapabilities: Self.videoCapabilities()
            )
        )

        #expect(!PipelineProductionRouting.providerAdapterSupports(
            referencePlan: plan,
            route: route,
            target: target,
            modelID: target.modelId,
            requirement: requirement
        ))
    }

    @MainActor
    @Test("fal image-to-video preserves aspect through its required start frame")
    func falImageToVideoUsesStartFrameAspect() throws {
        let modelID = "bytedance/seedance-2.5/image-to-video"
        let model = try #require(FalModelRegistry.model(for: modelID))
        let requirement = Self.requirement(requiresFirstFrame: true)
        let route = Self.route(requirement: requirement, endpoint: modelID)
        let binding = Self.binding(
            semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
            inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
        )
        let plan = Self.plan(route: route, bindings: [binding])
        let providerBinding = try #require(
            ProviderManifest.bindings(
                from: model.entry.offers ?? [],
                modelId: modelID
            ).first
        )
        let target = ResolvedGenerationTarget(
            modelId: modelID,
            provider: .fal,
            endpoint: modelID,
            binding: providerBinding
        )

        #expect(PipelineProductionRouting.providerAdapterSupports(
            referencePlan: plan,
            route: route,
            target: target,
            modelID: modelID,
            requirement: requirement
        ))
    }

    @MainActor
    @Test("MCP adapter requires endpoint-backed outputs and exact media roles")
    func mcpAdapterRequiresSchemaBackedFieldsAndRoles() throws {
        let requirement = Self.requirement(requiresFirstFrame: true)
        let route = Self.route(
            requirement: requirement,
            endpoint: "generate_video",
            endpointBackedFields: true
        )
        let binding = Self.binding(
            semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
            inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
        )
        let plan = Self.plan(route: route, bindings: [binding])

        func target(
            roles: [String]?,
            capabilities: ResolvedVideoOfferingCapabilitiesV1 = Self.videoCapabilities()
        ) -> ResolvedGenerationTarget {
            ResolvedGenerationTarget(
                modelId: "fixture-model",
                provider: .higgsfield,
                endpoint: "generate_video",
                binding: ProviderBinding(
                    provider: .higgsfield,
                    transport: .mcp,
                    kind: .generation,
                    providerRef: "generate_video",
                    billing: .subscription,
                    modelParam: "fixture-model",
                    mcpMediaRoles: roles,
                    productionInputPolicy: Self.inputPolicy(),
                    resolvedVideoCapabilities: capabilities
                )
            )
        }

        #expect(PipelineProductionRouting.providerAdapterSupports(
            referencePlan: plan,
            route: route,
            target: target(roles: ["start_image"]),
            modelID: "fixture-model",
            requirement: requirement
        ))
        let aliasedRoute = Self.route(
            requirement: requirement,
            endpoint: "generate_video",
            endpointBackedFields: true,
            inputSlotModeID: "IMAGE_TO_VIDEO"
        )
        #expect(PipelineProductionRouting.providerAdapterSupports(
            referencePlan: Self.plan(route: aliasedRoute, bindings: [binding]),
            route: aliasedRoute,
            target: target(roles: ["start_image"]),
            modelID: "fixture-model",
            requirement: requirement
        ))
        #expect(!PipelineProductionRouting.providerAdapterSupports(
            referencePlan: plan,
            route: route,
            target: target(roles: []),
            modelID: "fixture-model",
            requirement: requirement
        ))
        #expect(!PipelineProductionRouting.providerAdapterSupports(
            referencePlan: plan,
            route: route,
            target: target(
                roles: ["start_image"],
                capabilities: Self.videoCapabilities(durations: [10])
            ),
            modelID: "fixture-model",
            requirement: requirement
        ))
        let undeclaredSlot = Self.binding(
            semanticJobID: "look.identity",
            inputSlotID: CoreReferenceInputSlotIDV1.referenceImage
        )
        #expect(!PipelineProductionRouting.providerAdapterSupports(
            referencePlan: Self.plan(route: route, bindings: [undeclaredSlot]),
            route: route,
            target: target(roles: ["image"]),
            modelID: "fixture-model",
            requirement: requirement
        ))

        let unproven = Self.route(
            requirement: requirement,
            endpoint: "generate_video",
            endpointBackedFields: false
        )
        #expect(!PipelineProductionRouting.providerAdapterSupports(
            referencePlan: Self.plan(route: unproven, bindings: [binding]),
            route: unproven,
            target: target(roles: ["start_image"]),
            modelID: "fixture-model",
            requirement: requirement
        ))
    }

    static func requirement(
        requiresFirstFrame: Bool = false
    ) -> ProductionRequirementV1 {
        ProductionRequirementV1(
            modalityID: CapabilityModalityV1.video.rawValue,
            modeIDs: ["image-to-video"],
            visibleEntityCount: 1,
            requiresFirstFrame: requiresFirstFrame,
            duration: RequestedDurationV1(
                preferredSeconds: 5,
                minimumSeconds: 5,
                maximumSeconds: 5
            ),
            resolution: "720p",
            aspectRatio: "16:9",
            requiresOutputAudio: true
        )
    }

    private static func params() -> VideoGenerationParams {
        VideoGenerationParams(
            prompt: "Compiled prompt.",
            duration: .seconds(5),
            aspectRatio: "16:9",
            resolution: "720p",
            generateAudio: true
        )
    }

    static func generationInput(
        requirement: ProductionRequirementV1,
        modelID: String = "fixture-model",
        projectID: String = "project-001",
        shotID: String = "shot-001"
    ) -> GenerationInput {
        let durationSeconds = Int(
            (requirement.duration?.preferredSeconds
                ?? requirement.duration?.minimumSeconds
                ?? requirement.duration?.maximumSeconds
                ?? 5).rounded()
        )
        let aspectRatio = requirement.aspectRatio ?? "16:9"
        let route = route(
            requirement: requirement,
            endpoint: modelID,
            projectID: projectID,
            shotID: shotID
        )
        let plan = plan(route: route, bindings: [])
        let offeringCapabilities = videoCapabilities(
            durations: [durationSeconds],
            supportsNativeAudio: true,
            resolutions: requirement.resolution.map { [$0] },
            aspectRatios: [aspectRatio]
        )
        let routeData = try! ReferencePlanCanonicalCodecV2.encode(route)
        let planData = try! ReferencePlanCanonicalCodecV2.encode(plan)
        let bindingsData = try! ReferencePlanCanonicalCodecV2.encode(
            plan.bindings
        )
        let offeringCapabilitiesData = try! ReferencePlanCanonicalCodecV2.encode(
            offeringCapabilities
        )
        var input = GenerationInput(
            prompt: "Compiled prompt.",
            model: modelID,
            duration: durationSeconds,
            aspectRatio: aspectRatio,
            resolution: requirement.resolution
        )
        input.videoDuration = .seconds(durationSeconds)
        input.generateAudio = requirement.requiresOutputAudio
        input.productionRouting = ProductionGenerationRoutingProofV1(
            projectID: route.projectID,
            shotID: route.shotID,
            modelID: modelID,
            providerID: GenerationProvider.fal.rawValue,
            transportID: ProviderTransport.api.rawValue,
            endpointID: modelID,
            modelParam: nil,
            offeringID: route.offering.offeringID,
            requirement: requirement,
            route: route,
            referencePlan: plan,
            routeArtifactSHA256: FileDigest.sha256(of: routeData),
            requirementSHA256: route.requirementSHA256,
            capabilitiesSHA256: route.capabilitiesSHA256,
            routeSHA256: route.routeSHA256,
            referencePlanSHA256: FileDigest.sha256(of: planData),
            orderedBindingsSHA256: FileDigest.sha256(of: bindingsData),
            orderedBindings: [],
            offeringCapabilities: offeringCapabilities,
            offeringCapabilitiesSHA256: FileDigest.sha256(
                of: offeringCapabilitiesData
            )
        )
        return input
    }

    private static func route(
        requirement: ProductionRequirementV1,
        endpoint: String,
        endpointBackedFields: Bool = false,
        inputSlotModeID: String = "image-to-video",
        projectID: String = "project-001",
        shotID: String = "shot-001"
    ) -> ProductionRouteV1 {
        let evidence = CapabilityEvidenceV1(
            sourceTitle: "Fixture provider schema",
            observedAt: "2026-08-31T00:00:00Z",
            kind: .providerSchema,
            confidence: 1
        )
        let kind: ResolvedCapabilityOriginKindV1 = endpointBackedFields
            ? .endpointOverlay
            : .exact
        let origin = ResolvedCapabilityOriginV1(
            kind: kind,
            profileID: "fixture-profile",
            endpointID: endpointBackedFields ? endpoint : nil
        )
        let policyOrigin = ResolvedCapabilityOriginV1(
            kind: .endpointOverlay,
            profileID: "fixture-input-policy",
            endpointID: endpoint
        )
        func value<Value>(
            _ value: Value
        ) -> ResolvedCapabilityValueV1<Value>
        where Value: Codable & Sendable & Equatable {
            ResolvedCapabilityValueV1(
                value: value,
                semantics: .hardAPILimit,
                origin: origin,
                evidence: endpointBackedFields ? [evidence] : []
            )
        }
        let durationMinimum = requirement.duration?.minimumSeconds
            ?? requirement.duration?.preferredSeconds
            ?? requirement.duration?.maximumSeconds
            ?? 5
        let durationMaximum = requirement.duration?.maximumSeconds
            ?? requirement.duration?.preferredSeconds
            ?? requirement.duration?.minimumSeconds
            ?? 5
        let durationValues = Set([
            requirement.duration?.preferredSeconds,
            requirement.duration?.minimumSeconds,
            requirement.duration?.maximumSeconds,
        ].compactMap { seconds -> Int? in
            guard let seconds, seconds.rounded() == seconds else { return nil }
            return Int(seconds)
        }).sorted()
        let profile = ResolvedCapabilityProfileV1(
            requestedIdentity: nil,
            resolvedIdentity: nil,
            defensiveProfileID: nil,
            researchNeeded: false,
            fields: ResolvedCapabilityFieldsV1(
                integers: [
                    CapabilityFieldIDV1.visibleCharacters:
                        value(requirement.visibleEntityCount),
                    CapabilityFieldIDV1.referenceImages: value(1),
                    CapabilityFieldIDV1.referenceVideos: value(0),
                    CapabilityFieldIDV1.referenceAudios: value(0),
                    CapabilityFieldIDV1.totalReferences: value(1),
                ],
                decimals: [
                    CapabilityFieldIDV1.durationMinimum: value(durationMinimum),
                    CapabilityFieldIDV1.durationMaximum: value(durationMaximum),
                ],
                booleans: [
                    CapabilityFieldIDV1.nativeAudio: value(true),
                    CapabilityFieldIDV1.firstFrame: value(true),
                    CapabilityFieldIDV1.lastFrame: value(false),
                    CapabilityFieldIDV1.sourceVideo:
                        value(requirement.sourceVideoAssetID != nil),
                    CapabilityFieldIDV1.sourceVideoRequired:
                        ResolvedCapabilityValueV1(
                            value: false,
                            semantics: .hardAPILimit,
                            origin: policyOrigin,
                            evidence: [evidence]
                        ),
                    CapabilityFieldIDV1.framesCountTowardImageReferenceLimit:
                        ResolvedCapabilityValueV1(
                            value: false,
                            semantics: .hardAPILimit,
                            origin: policyOrigin,
                            evidence: [evidence]
                        ),
                    CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit:
                        ResolvedCapabilityValueV1(
                            value: false,
                            semantics: .hardAPILimit,
                            origin: policyOrigin,
                            evidence: [evidence]
                        ),
                ],
                strings: [
                    CapabilityFieldIDV1.modes: value(requirement.modeIDs),
                    CapabilityFieldIDV1.aspectRatios:
                        value(requirement.aspectRatio.map { [$0] } ?? []),
                    CapabilityFieldIDV1.resolutions:
                        value(requirement.resolution.map { [$0] } ?? []),
                ],
                integerLists: [
                    CapabilityFieldIDV1.durationValues: value(durationValues),
                ]
            )
        )
        let providerID = endpoint == "generate_video"
            ? GenerationProvider.higgsfield.rawValue
            : GenerationProvider.fal.rawValue
        let transportID = endpoint == "generate_video"
            ? ProviderTransport.mcp.rawValue
            : ProviderTransport.api.rawValue
        let catalogModelID = endpoint == "generate_video"
            ? "fixture-model"
            : endpoint
        let offering = CapabilityOfferingIdentityV1(
            providerID: providerID,
            offeringID: [
                providerID,
                transportID,
                endpoint,
                catalogModelID,
            ].joined(separator: "/"),
            endpointID: endpoint,
            catalogModelID: catalogModelID,
            modality: .video
        )
        let candidate = ProductionRouteCandidateV1(
            capabilities: ResolvedOfferingCapabilityProfileV1(
                offering: offering,
                intrinsic: profile,
                effective: profile
            ),
            providerActivated: true,
            liveAvailable: true,
            inputSlots: endpoint == "generate_video"
                ? [ProductionInputSlotCapabilityV1(
                    id: CoreReferenceInputSlotIDV1.firstFrame,
                    modality: .image,
                    modeIDs: [inputSlotModeID],
                    requestOrder: 0,
                    countsTowardModalityBudget: false,
                    countsTowardTotalBudget: false,
                    countsTowardCombinedDuration: false
                )]
                : []
        )
        let fingerprints = try! ProductionRequirementResolverV1.fingerprints(
            requirement: requirement,
            candidate: candidate
        )
        return ProductionRouteV1(
            id: "route-\(shotID)",
            projectID: projectID,
            shotID: shotID,
            offering: offering,
            capabilitySnapshot: ProductionRouteCapabilitySnapshotV1(
                candidate: candidate
            ),
            requirementSHA256: fingerprints.requirementSHA256,
            capabilitiesSHA256: fingerprints.capabilitiesSHA256,
            routeSHA256: fingerprints.routeSHA256,
            researchNeeded: false,
            qualityScore: 0,
            preferenceScore: 0,
            estimatedCost: nil,
            estimatedLatencySeconds: nil
        )
    }

    private static func plan(
        route: ProductionRouteV1,
        bindings: [ReferenceBindingV2]
    ) -> ReferencePlanV2 {
        let fields = route.capabilitySnapshot.capabilities.effective.fields
        let imageCount = fields.integers[
            CapabilityFieldIDV1.referenceImages
        ]?.value ?? 0
        let videoCount = fields.integers[
            CapabilityFieldIDV1.referenceVideos
        ]?.value ?? 0
        let audioCount = fields.integers[
            CapabilityFieldIDV1.referenceAudios
        ]?.value ?? 0
        return ReferencePlanV2(
            id: "reference-plan-shot-001",
            projectID: route.projectID,
            shotID: route.shotID,
            demandSet: CanonicalArtifactReferenceV1(
                id: "demand-set-shot-001",
                role: ReferenceDemandSetV1.artifactRole,
                path: PipelineLayout.referenceDemandSetFile(shotID: route.shotID),
                sha256: String(repeating: "b", count: 64)
            ),
            route: ReferencePlanRouteBindingV2(
                offering: route.offering,
                requirementSHA256: route.requirementSHA256,
                capabilitiesSHA256: route.capabilitiesSHA256,
                routeSHA256: route.routeSHA256
            ),
            budget: ReferencePlanBudgetV2(
                imageCount: imageCount,
                videoCount: videoCount,
                audioCount: audioCount,
                geometryCount: 0,
                totalCount: fields.integers[
                    CapabilityFieldIDV1.totalReferences
                ]?.value ?? imageCount + videoCount + audioCount,
                combinedVideoSeconds: fields.decimals[
                    CapabilityFieldIDV1.combinedVideoReferenceSeconds
                ]?.value,
                combinedAudioSeconds: fields.decimals[
                    CapabilityFieldIDV1.combinedAudioReferenceSeconds
                ]?.value
            ),
            bindings: bindings,
            optionalDrops: []
        )
    }

    private static func binding(
        semanticJobID: String,
        inputSlotID: String
    ) -> ReferenceBindingV2 {
        let demand = ReferenceDemandV1(
            id: "demand-001",
            assetID: "asset-001",
            modality: .image,
            semanticJobID: semanticJobID,
            isRequired: true,
            priority: 100,
            inputSlotID: inputSlotID,
            modeID: "image-to-video"
        )
        let asset = AssetGraphNodeV1(
            id: demand.assetID,
            version: 1,
            path: "inputs/start.png",
            sha256: String(repeating: "c", count: 64),
            modality: .image,
            approval: .approved,
            provenance: AssetProvenanceV1(
                kindID: "fixture.import",
                recordedAt: "2026-08-31T00:00:00Z"
            ),
            allowedUseIDs: [semanticJobID]
        )
        return ReferenceBindingV2(demand: demand, asset: asset)
    }

    private static func inputPolicy() -> ProviderProductionInputPolicyV1 {
        ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
    }

    static func videoCapabilities(
        durations: [Int] = [5],
        supportsNativeAudio: Bool = true,
        resolutions: [String]? = ["720p"],
        aspectRatios: [String] = ["16:9"]
    ) -> ResolvedVideoOfferingCapabilitiesV1 {
        ResolvedVideoOfferingCapabilitiesV1(
            videoCapabilities: VideoCaps(
                durations: durations,
                resolutions: resolutions,
                aspectRatios: aspectRatios,
                supportsFirstFrame: true,
                supportsLastFrame: false,
                maxReferenceImages: 1,
                maxReferenceVideos: 0,
                maxReferenceAudios: 0,
                maxTotalReferences: 1,
                maxCombinedVideoRefSeconds: nil,
                maxCombinedAudioRefSeconds: nil,
                framesAndReferencesExclusive: false,
                referenceTagNoun: "image",
                requiresSourceVideo: false,
                requiresReferenceImage: false
            ),
            supportsNativeAudio: supportsNativeAudio
        )
    }

    private static func target(
        modelID: String,
        provider: GenerationProvider,
        endpoint: String
    ) -> ResolvedGenerationTarget {
        let binding = ProviderBinding(
            provider: provider,
            transport: .api,
            kind: .generation,
            providerRef: endpoint,
            billing: .perCall,
            productionInputPolicy: inputPolicy(),
            resolvedVideoCapabilities: videoCapabilities()
        )
        return ResolvedGenerationTarget(
            modelId: modelID,
            provider: provider,
            endpoint: endpoint,
            binding: binding
        )
    }
}
