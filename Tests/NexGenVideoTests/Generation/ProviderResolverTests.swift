import Testing

@testable import NexGenVideo

@Suite("ProviderResolver — LLM → NGV → Provider")
struct ProviderResolverTests {

    private func binding(_ p: GenerationProvider, _ t: ProviderTransport, _ ref: String,
                         _ billing: BillingMode,
                         _ kind: ProviderCapabilityKind = .generation) -> ProviderBinding {
        ProviderBinding(provider: p, transport: t, kind: kind, providerRef: ref, billing: billing)
    }

    private func videoCapabilities(
        policy: ProviderProductionInputPolicyV1,
        supportsNativeAudio: Bool = false
    ) -> ResolvedVideoOfferingCapabilitiesV1 {
        ResolvedVideoOfferingCapabilitiesV1(
            videoCapabilities: VideoCaps(
                durations: [5],
                resolutions: nil,
                aspectRatios: ["16:9"],
                supportsFirstFrame: false,
                supportsLastFrame: false,
                maxReferenceImages: 0,
                maxReferenceVideos: 0,
                maxReferenceAudios: 0,
                maxTotalReferences: 0,
                maxCombinedVideoRefSeconds: nil,
                maxCombinedAudioRefSeconds: nil,
                framesAndReferencesExclusive: false,
                referenceTagNoun: "image",
                requiresSourceVideo: policy.requiresSourceVideo,
                requiresReferenceImage: false
            ),
            inputPolicy: policy,
            supportsNativeAudio: supportsNativeAudio
        )
    }

    @Test func cheapestActivatedBindingWins() {
        let cheap = binding(.fal, .api, "fal-ai/seedance", .perCall)
        let pricey = binding(.higgsfield, .api, "hf/seedance", .perCall)
        let activation = ProviderActivation(active: [
            .init(provider: .fal, transport: .api),
            .init(provider: .higgsfield, transport: .api),
        ])
        let cost: (ProviderBinding) -> Double = { $0.provider == .fal ? 1.0 : 2.0 }
        let picked = ProviderResolver.resolve(bindings: [pricey, cheap], activation: activation, effectiveCost: cost)
        #expect(picked == cheap)
    }

    @Test func inactiveProviderIsNeverChosenEvenIfCheaper() {
        // The globally-cheapest option is on a provider the user hasn't activated → skip it.
        let cheapButInactive = binding(.higgsfield, .api, "hf/seedance", .perCall)
        let activeDearer = binding(.fal, .api, "fal-ai/seedance", .perCall)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let cost: (ProviderBinding) -> Double = { $0.provider == .higgsfield ? 0.1 : 5.0 }
        let picked = ProviderResolver.resolve(bindings: [cheapButInactive, activeDearer], activation: activation, effectiveCost: cost)
        #expect(picked == activeDearer)
    }

    @Test func noActivatedProviderOffersItReturnsNil() {
        let onlyInactive = binding(.higgsfield, .mcp, "hf/seedance", .subscription)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let picked = ProviderResolver.resolve(bindings: [onlyInactive], activation: activation, effectiveCost: { _ in 1 })
        #expect(picked == nil)
    }

    @Test func subscriptionTransportCanBeatPayPerCall() {
        // Billing-aware: the SAME model over an MCP subscription (flat, ~0 marginal) beats
        // the pay-per-call API when the caller's effectiveCost reflects the subscription.
        let apiCall = binding(.higgsfield, .api, "hf/model", .perCall)
        let mcpSub = binding(.higgsfield, .mcp, "hf/model", .subscription)
        let activation = ProviderActivation(active: [
            .init(provider: .higgsfield, transport: .api),
            .init(provider: .higgsfield, transport: .mcp),
        ])
        let cost: (ProviderBinding) -> Double = { $0.billing == .subscription ? 0.0 : 3.0 }
        let picked = ProviderResolver.resolve(bindings: [apiCall, mcpSub], activation: activation, effectiveCost: cost)
        #expect(picked == mcpSub)
    }

    @Test func resolvesWorkflowToolCallsNotJustModels() {
        // A provider capability can be a workflow TOOL (e.g. background removal), not only a
        // model render — resolved the same way: cheapest activated provider offering the tool.
        // OpenArt/Runway expose MCP tool-calls; here Runway-via-MCP (subscription) beats fal-API.
        let runwayTool = binding(.runway, .mcp, "remove_background", .subscription, .tool)
        let falTool = binding(.fal, .api, "bg-removal", .perCall, .tool)
        let activation = ProviderActivation(active: [
            .init(provider: .runway, transport: .mcp),
            .init(provider: .fal, transport: .api),
        ])
        let cost: (ProviderBinding) -> Double = { $0.billing == .subscription ? 0.0 : 2.0 }
        let picked = ProviderResolver.resolve(bindings: [falTool, runwayTool], activation: activation, effectiveCost: cost)
        #expect(picked?.kind == .tool)
        #expect(picked == runwayTool)
    }

    @Test func perTransportActivationIsRespected() {
        // API key present, MCP not connected → only the API binding is eligible.
        let api = binding(.higgsfield, .api, "hf/model", .perCall)
        let mcp = binding(.higgsfield, .mcp, "hf/model", .subscription)
        let activation = ProviderActivation(active: [.init(provider: .higgsfield, transport: .api)])
        let picked = ProviderResolver.resolve(bindings: [mcp, api], activation: activation, effectiveCost: { $0.billing == .subscription ? 0 : 9 })
        #expect(picked == api)
    }

    @Test func providerPickerGetsOneBestActiveBindingPerProvider() {
        let falAPI = binding(.fal, .api, "fal/model", .perCall)
        let runwayAPI = binding(.runway, .api, "runway/model", .perCall)
        let runwayMCP = binding(.runway, .mcp, "generate_image", .subscription)
        let inactiveGoogle = binding(.google, .api, "google/model", .perCall)
        let activation = ProviderActivation(active: [
            .init(provider: .fal, transport: .api),
            .init(provider: .runway, transport: .api),
            .init(provider: .runway, transport: .mcp),
        ])

        let options = ProviderResolver.preferredActiveBindingPerProvider(
            bindings: [falAPI, runwayAPI, runwayMCP, inactiveGoogle],
            activation: activation,
            effectiveCost: { $0.billing == .subscription ? 0 : 2 }
        )

        #expect(options == [falAPI, runwayMCP])
    }

    @Test func compatibilityIsAppliedBeforeCollapsingSiblingEndpoints() {
        let textPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let editPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let text = ProviderBinding(
            provider: .runway,
            transport: .api,
            kind: .generation,
            providerRef: "runway/text",
            billing: .perCall,
            costPerCall: 1,
            productionInputPolicy: textPolicy,
            resolvedVideoCapabilities: videoCapabilities(policy: textPolicy)
        )
        let edit = ProviderBinding(
            provider: .runway,
            transport: .api,
            kind: .generation,
            providerRef: "runway/edit",
            billing: .perCall,
            costPerCall: 2,
            productionInputPolicy: editPolicy,
            resolvedVideoCapabilities: videoCapabilities(policy: editPolicy)
        )
        let activation = ProviderActivation(active: [
            .init(provider: .runway, transport: .api),
        ])

        let options = ProviderResolver.preferredActiveBindingPerProvider(
            bindings: [text, edit],
            activation: activation,
            effectiveCost: ProviderManifest.effectiveCost,
            isCompatible: {
                $0.resolvedVideoCapabilities?.inputPolicy.requiresSourceVideo == true
            }
        )

        #expect(options == [edit])
    }

    @Test func exactOutputCompatibilityIsAppliedBeforeCollapsingSiblingEndpoints() {
        let policy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let incompatible = ProviderBinding(
            provider: .runway,
            transport: .api,
            kind: .generation,
            providerRef: "runway/ten-second-portrait",
            billing: .perCall,
            costPerCall: 1,
            productionInputPolicy: policy,
            resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1(
                videoCapabilities: VideoCaps(
                    durations: [10],
                    resolutions: ["1080p"],
                    aspectRatios: ["9:16"],
                    supportsFirstFrame: false,
                    supportsLastFrame: false,
                    maxReferenceImages: 0,
                    maxReferenceVideos: 0,
                    maxReferenceAudios: 0,
                    maxTotalReferences: 0,
                    maxCombinedVideoRefSeconds: nil,
                    maxCombinedAudioRefSeconds: nil,
                    framesAndReferencesExclusive: false,
                    referenceTagNoun: "image",
                    requiresSourceVideo: false,
                    requiresReferenceImage: false
                ),
                inputPolicy: policy,
                supportsNativeAudio: false
            )
        )
        let compatible = ProviderBinding(
            provider: .runway,
            transport: .api,
            kind: .generation,
            providerRef: "runway/five-second-landscape",
            billing: .perCall,
            costPerCall: 2,
            productionInputPolicy: policy,
            resolvedVideoCapabilities: videoCapabilities(policy: policy)
        )
        let activation = ProviderActivation(active: [
            .init(provider: .runway, transport: .api),
        ])

        let options = ProviderResolver.preferredActiveBindingPerProvider(
            bindings: [incompatible, compatible],
            activation: activation,
            effectiveCost: ProviderManifest.effectiveCost,
            isCompatible: { binding in
                GenerationService.videoBindingIsCompatible(
                    binding,
                    requiringSourceVideo: false,
                    matchingCapabilities: {
                        $0.validate(
                            duration: .seconds(5),
                            aspectRatio: "16:9",
                            resolution: nil,
                            generateAudio: false,
                            displayName: "Shared model"
                        ) == nil
                    }
                )
            }
        )

        #expect(options == [compatible])
    }

    @Test func nativeAudioCompatibilityIsAppliedBeforeCollapsingSiblingEndpoints() {
        let policy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        func endpoint(_ reference: String, cost: Double, nativeAudio: Bool) -> ProviderBinding {
            ProviderBinding(
                provider: .runway,
                transport: .api,
                kind: .generation,
                providerRef: reference,
                billing: .perCall,
                costPerCall: cost,
                productionInputPolicy: policy,
                resolvedVideoCapabilities: videoCapabilities(
                    policy: policy,
                    supportsNativeAudio: nativeAudio
                )
            )
        }
        let silent = endpoint("runway/silent", cost: 1, nativeAudio: false)
        let nativeAudio = endpoint("runway/native-audio", cost: 2, nativeAudio: true)
        let activation = ProviderActivation(active: [
            .init(provider: .runway, transport: .api),
        ])

        let options = ProviderResolver.preferredActiveBindingPerProvider(
            bindings: [silent, nativeAudio],
            activation: activation,
            effectiveCost: ProviderManifest.effectiveCost,
            isCompatible: { binding in
                GenerationService.videoBindingIsCompatible(
                    binding,
                    requiringSourceVideo: false,
                    matchingCapabilities: {
                        $0.validate(
                            duration: .seconds(5),
                            aspectRatio: "16:9",
                            resolution: nil,
                            generateAudio: true,
                            displayName: "Shared model"
                        ) == nil
                    }
                )
            }
        )

        #expect(options == [nativeAudio])
    }

    @Test func initialPromptPreservationFailsOpenForDivergentSiblingEndpoints() {
        let textPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: false,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let editPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: false
        )
        let text = ProviderBinding(
            provider: .runway,
            transport: .api,
            kind: .generation,
            providerRef: "runway/text",
            billing: .perCall,
            productionInputPolicy: textPolicy,
            resolvedVideoCapabilities: videoCapabilities(policy: textPolicy)
        )
        let edit = ProviderBinding(
            provider: .runway,
            transport: .mcp,
            kind: .generation,
            providerRef: "runway/edit",
            billing: .subscription,
            productionInputPolicy: editPolicy,
            resolvedVideoCapabilities: videoCapabilities(policy: editPolicy)
        )
        let both = ProviderActivation(active: [
            .init(provider: .runway, transport: .api),
            .init(provider: .runway, transport: .mcp),
        ])
        let editOnly = ProviderActivation(active: [
            .init(provider: .runway, transport: .mcp),
        ])

        #expect(!PromptCompiler.preservesComposition(
            bindings: [text, edit],
            activation: both
        ))
        #expect(PromptCompiler.preservesComposition(
            bindings: [text, edit],
            activation: editOnly
        ))
    }
}
