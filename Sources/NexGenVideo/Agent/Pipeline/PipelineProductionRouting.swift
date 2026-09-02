import Foundation
import NexGenEngine

enum PipelineProductionRoutingError: Error, Equatable {
    case shotNotFound(String)
    case generationRequirementMissing(String)
    case noMatchingRoute(ProductionRouteNoMatchV1)
    case requiredInputsUnsupported(ReferencePlanFailureV2)
    case providerAdapterUnsupported([CapabilityOfferingIdentityV1])
    case selectedCatalogModelMissing
    case publicationInvalid(String)
    case publicationFailed(String)
}

struct PipelineProductionRouteSelection {
    let modelID: String
    let target: ResolvedGenerationTarget
    let requirement: ProductionRequirementV1
    let route: ProductionRouteV1
    let routeArtifactSHA256: String
    let referencePlan: ReferencePlanV2
    let referencePlanSHA256: String
    let orderedBindingsSHA256: String
}

typealias ProductionRouteCandidateProvider = (
    ProviderActivation
) -> [CatalogProductionRouteCandidate]

@MainActor
enum PipelineProductionRouting {
    private struct Publication: Codable, Equatable {
        static let schemaVersion = "production-routing-publication/v1"

        let schema: String
        let routeArtifactSHA256: String
        let referencePlanSHA256: String
        let orderedBindingsSHA256: String

        private enum CodingKeys: String, CodingKey {
            case schema
            case routeArtifactSHA256 = "route_artifact_sha256"
            case referencePlanSHA256 = "reference_plan_sha256"
            case orderedBindingsSHA256 = "ordered_bindings_sha256"
        }

        init(
            routeData: Data,
            referencePlanData: Data,
            orderedBindingsData: Data
        ) {
            schema = Self.schemaVersion
            routeArtifactSHA256 = FileDigest.sha256(of: routeData)
            referencePlanSHA256 = FileDigest.sha256(of: referencePlanData)
            orderedBindingsSHA256 = FileDigest.sha256(of: orderedBindingsData)
        }
    }

    static func resolveAndWrite(
        shotID: String,
        dataRoot: URL,
        activation: ProviderActivation = .current(),
        candidateProvider: ProductionRouteCandidateProvider = {
            ModelCatalog.shared.productionRouteCandidates(activation: $0)
        },
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> PipelineProductionRouteSelection {
        guard let selection = try resolveOptions(
            shotID: shotID,
            dataRoot: dataRoot,
            activation: activation,
            candidateProvider: candidateProvider
        ).first else {
            throw PipelineProductionRoutingError.selectedCatalogModelMissing
        }
        try publish(
            route: selection.route,
            referencePlan: selection.referencePlan,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        return selection
    }

    static func resolveAndWrite(
        shotID: String,
        dataRoot: URL,
        target: ResolvedGenerationTarget,
        activation: ProviderActivation = .current(),
        candidateProvider: ProductionRouteCandidateProvider = {
            ModelCatalog.shared.productionRouteCandidates(activation: $0)
        },
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> PipelineProductionRouteSelection {
        guard let selection = try resolveOptions(
            shotID: shotID,
            dataRoot: dataRoot,
            activation: activation,
            candidateProvider: candidateProvider
        ).first(where: { $0.target == target }) else {
            throw PipelineProductionRoutingError.selectedCatalogModelMissing
        }
        try publish(
            route: selection.route,
            referencePlan: selection.referencePlan,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        return selection
    }

    static func resolveOptions(
        shotID: String,
        dataRoot: URL,
        activation: ProviderActivation = .current(),
        candidateProvider: ProductionRouteCandidateProvider = {
            ModelCatalog.shared.productionRouteCandidates(activation: $0)
        }
    ) throws -> [PipelineProductionRouteSelection] {
        let dependencies = try loadDependencies(shotID: shotID, dataRoot: dataRoot)
        let records = candidateProvider(activation)
        let matches = try ProductionRequirementResolverV1.matchingRoutes(
            requirement: dependencies.requirement,
            demandSet: dependencies.demandSet,
            assetGraph: dependencies.assetGraph,
            dataRoot: dataRoot,
            candidates: records.map(\.candidate)
        )
        if matches.isEmpty {
            let resolution = try ProductionRequirementResolverV1.resolve(
                requirement: dependencies.requirement,
                demandSet: dependencies.demandSet,
                assetGraph: dependencies.assetGraph,
                dataRoot: dataRoot,
                candidates: records.map(\.candidate)
            )
            if case .noMatch(let noMatch) = resolution {
                throw PipelineProductionRoutingError.noMatchingRoute(noMatch)
            }
            throw PipelineProductionRoutingError.selectedCatalogModelMissing
        }
        var selections: [PipelineProductionRouteSelection] = []
        var firstFailure: ReferencePlanFailureV2?
        var adapterFailures: [CapabilityOfferingIdentityV1] = []
        for match in matches {
            guard let record = records.first(where: {
                $0.candidate == match.candidate && $0.target != nil
            }), let target = record.target else {
                continue
            }
            let buildResult = try ReferencePlannerV2.plan(
                id: "reference-plan-\(shotID)",
                dataRoot: dataRoot,
                route: match.route,
                requirement: dependencies.requirement,
                demandSet: dependencies.demandSet,
                graph: dependencies.assetGraph,
                candidate: match.candidate
            )
            guard case .plan(let referencePlan) = buildResult else {
                if case .requiredInputsUnsupported(let failure) = buildResult,
                   firstFailure == nil {
                    firstFailure = failure
                }
                continue
            }
            guard providerAdapterSupports(
                referencePlan: referencePlan,
                route: match.route,
                target: target,
                modelID: record.modelID,
                requirement: dependencies.requirement
            ) else {
                adapterFailures.append(match.route.offering)
                continue
            }
            selections.append(try makeSelection(
                modelID: record.modelID,
                target: target,
                requirement: dependencies.requirement,
                route: match.route,
                referencePlan: referencePlan
            ))
        }
        if selections.isEmpty {
            if let firstFailure {
                throw PipelineProductionRoutingError.requiredInputsUnsupported(firstFailure)
            }
            if !adapterFailures.isEmpty {
                throw PipelineProductionRoutingError.providerAdapterUnsupported(
                    adapterFailures.sorted { $0.offeringID < $1.offeringID }
                )
            }
            throw PipelineProductionRoutingError.selectedCatalogModelMissing
        }
        return selections
    }

    static func requireCurrent(
        shotID: String,
        dataRoot: URL,
        activation: ProviderActivation = .current(),
        candidateProvider: ProductionRouteCandidateProvider = {
            ModelCatalog.shared.productionRouteCandidates(activation: $0)
        }
    ) throws -> PipelineProductionRouteSelection {
        let dependencies = try loadDependencies(shotID: shotID, dataRoot: dataRoot)
        let directory = routingDirectory(shotID: shotID, dataRoot: dataRoot)
        let routeURL = directory.appendingPathComponent("route.v1.json")
        let planURL = directory.appendingPathComponent("plan.v2.json")
        let publicationURL = directory.appendingPathComponent("publication.v1.json")
        do {
            try requireSafeDirectory(directory, dataRoot: dataRoot, allowMissing: false)
            let publicationBefore = try Data(contentsOf: publicationURL)
            let routeData = try Data(contentsOf: routeURL)
            let planData = try Data(contentsOf: planURL)
            let publicationAfter = try Data(contentsOf: publicationURL)
            guard publicationBefore == publicationAfter else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The routing publication changed while it was being read."
                )
            }
            let publication = try JSONDecoder().decode(
                Publication.self,
                from: publicationAfter
            )
            guard publication.schema == Publication.schemaVersion,
                  publication.routeArtifactSHA256 == FileDigest.sha256(of: routeData),
                  publication.referencePlanSHA256 == FileDigest.sha256(of: planData) else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The routing publication does not match its committed bytes."
                )
            }
            let route = try JSONDecoder().decode(ProductionRouteV1.self, from: routeData)
            let records = candidateProvider(activation)
            guard let record = records.first(where: {
                $0.candidate.capabilities.offering == route.offering
                    && ProductionRouteCapabilitySnapshotV1(candidate: $0.candidate)
                        == route.capabilitySnapshot
                    && $0.target != nil
            }), let target = record.target else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The selected provider route is no longer in the live catalog."
                )
            }
            guard try ProductionRequirementResolverV1.revalidate(
                route,
                requirement: dependencies.requirement,
                demandSet: dependencies.demandSet,
                assetGraph: dependencies.assetGraph,
                dataRoot: dataRoot,
                candidate: record.candidate
            ) else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The selected provider route is no longer current."
                )
            }
            let referencePlan = try ReferencePlanCanonicalCodecV2.decode(
                planData,
                dataRoot: dataRoot,
                route: route,
                requirement: dependencies.requirement,
                demandSet: dependencies.demandSet,
                graph: dependencies.assetGraph,
                candidate: record.candidate
            )
            let selection = try makeSelection(
                modelID: record.modelID,
                target: target,
                requirement: dependencies.requirement,
                route: route,
                referencePlan: referencePlan
            )
            guard selection.routeArtifactSHA256 == publication.routeArtifactSHA256,
                  selection.referencePlanSHA256 == publication.referencePlanSHA256,
                  selection.orderedBindingsSHA256 == publication.orderedBindingsSHA256 else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The routing publication does not match its ordered bindings."
                )
            }
            return selection
        } catch let error as PipelineProductionRoutingError {
            throw error
        } catch {
            throw PipelineProductionRoutingError.publicationInvalid(
                error.localizedDescription
            )
        }
    }

    static func validateSubmission(
        genInput: GenerationInput,
        target: ResolvedGenerationTarget,
        references: [MediaAsset],
        editor: EditorViewModel
    ) throws {
        guard let proof = genInput.productionRouting else {
            if let shotID = genInput.promptShotId, shotID != "none" {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "A shot-bound video submission has no production-routing proof."
                )
            }
            return
        }
        let offeringCapabilitiesData = try ReferencePlanCanonicalCodecV2.encode(
            proof.offeringCapabilities
        )
        guard proof.schema == ProductionGenerationRoutingProofV1.schemaVersion,
              proof.modelID == genInput.model,
              proof.shotID == genInput.promptShotId,
              proof.matches(target),
              proof.offeringCapabilities.contractViolation == nil,
              validSHA256(proof.offeringCapabilitiesSHA256),
              proof.offeringCapabilitiesSHA256
                == FileDigest.sha256(of: offeringCapabilitiesData),
              let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The generation-routing proof does not match the submitted job."
            )
        }
        let selection = try requireCurrent(
            shotID: proof.shotID,
            dataRoot: dataRoot
        )
        guard selection.modelID == proof.modelID,
              selection.target == target,
              selection.route.projectID == proof.projectID,
              selection.route.offering.offeringID == proof.offeringID,
              selection.routeArtifactSHA256 == proof.routeArtifactSHA256,
              selection.route.requirementSHA256 == proof.requirementSHA256,
              selection.route.capabilitiesSHA256 == proof.capabilitiesSHA256,
              selection.route.routeSHA256 == proof.routeSHA256,
              selection.referencePlanSHA256 == proof.referencePlanSHA256,
              selection.orderedBindingsSHA256 == proof.orderedBindingsSHA256,
              providerAdapterSupports(
                  referencePlan: selection.referencePlan,
                  route: selection.route,
                  target: target,
                  modelID: selection.modelID,
                  requirement: selection.requirement
              ),
              selection.referencePlan.bindings.count == proof.orderedBindings.count,
              references.map(\.id) == proof.orderedBindings.map(\.mediaAssetID),
              submissionMatchesRequirement(
                  genInput,
                  requirement: proof.requirement
              ) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The submitted job no longer matches its current route and ordered ReferencePlan."
            )
        }
        for (binding, submitted) in zip(
            selection.referencePlan.bindings,
            proof.orderedBindings
        ) {
            guard binding.demandID == submitted.demandID,
                  binding.assetID == submitted.graphAssetID,
                  binding.assetVersion == submitted.graphAssetVersion,
                  binding.path == submitted.path,
                  binding.sha256 == submitted.sha256,
                  binding.modality.rawValue == submitted.modalityID,
                  ProductionIdentifierNormalizerV1.matches(
                      binding.semanticJobID,
                      submitted.semanticJobID
                  ),
                  ProductionIdentifierNormalizerV1.matches(
                      binding.inputSlotID,
                      submitted.inputSlotID
                  ),
                  binding.modeID == submitted.modeID,
                  let media = references.first(where: {
                      $0.id == submitted.mediaAssetID
                  }) else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "A submitted input does not match its exact ReferencePlan binding."
                )
            }
            let plannedURL = try ProjectLocalFile.requireHash(
                submitted.sha256,
                at: submitted.path,
                dataRoot: dataRoot
            ).standardizedFileURL.resolvingSymlinksInPath()
            guard media.url.standardizedFileURL.resolvingSymlinksInPath() == plannedURL else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "A submitted input path no longer matches its exact project bytes."
                )
            }
        }
        let semantic = Dictionary(
            grouping: proof.orderedBindings,
            by: { ProductionIdentifierNormalizerV1.canonical($0.semanticJobID) }
        )
        let sourceID = semantic[CoreReferenceSemanticJobIDV1.sourceVideo]?.first?.mediaAssetID
        let startID = (
            semantic[CoreReferenceSemanticJobIDV1.predecessorLastFrame]
                ?? semantic[CoreReferenceSemanticJobIDV1.firstFrame]
        )?.first?.mediaAssetID
        let endID = semantic[CoreReferenceSemanticJobIDV1.lastFrame]?.first?.mediaAssetID
        let ordinary = proof.orderedBindings.filter {
            ![
                CoreReferenceSemanticJobIDV1.sourceVideo,
                CoreReferenceSemanticJobIDV1.firstFrame,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                CoreReferenceSemanticJobIDV1.lastFrame,
            ].contains(ProductionIdentifierNormalizerV1.canonical($0.semanticJobID))
        }
        guard genInput.sourceVideoAssetId == sourceID,
              genInput.startFrameAssetId == startID,
              genInput.endFrameAssetId == endID,
              (genInput.referenceImageAssetIds ?? [])
                == ordinary.filter { $0.modalityID == "image" }.map(\.mediaAssetID),
              (genInput.referenceVideoAssetIds ?? [])
                == ordinary.filter { $0.modalityID == "video" }.map(\.mediaAssetID),
              (genInput.referenceAudioAssetIds ?? [])
                == ordinary.filter { $0.modalityID == "audio" }.map(\.mediaAssetID) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The provider submission's semantic input slots differ from the ReferencePlan."
            )
        }
    }

    private static func submissionMatchesRequirement(
        _ input: GenerationInput,
        requirement: ProductionRequirementV1
    ) -> Bool {
        if let requested = requirement.duration {
            switch input.videoDuration ?? .seconds(input.duration) {
            case .automatic:
                guard requested.allowsAutomatic else { return false }
            case .seconds(let seconds):
                let value = Double(seconds)
                guard requested.preferredSeconds.map({ $0 == value }) ?? true,
                      requested.minimumSeconds.map({ value >= $0 }) ?? true,
                      requested.maximumSeconds.map({ value <= $0 }) ?? true else {
                    return false
                }
            }
        }
        if let aspectRatio = requirement.aspectRatio,
           aspectRatio.caseInsensitiveCompare(input.aspectRatio) != .orderedSame {
            return false
        }
        if let resolution = requirement.resolution,
           resolution.caseInsensitiveCompare(input.resolution ?? "") != .orderedSame {
            return false
        }
        return !requirement.requiresOutputAudio || input.generateAudio == true
    }

    static func validateProviderEnvelope(
        genInput: GenerationInput,
        target: ResolvedGenerationTarget,
        params: BackendGenerationParams,
        uploadedReferences: [String]
    ) throws {
        guard let proof = genInput.productionRouting else { return }
        guard inputPolicyMatchesRoute(target: target, route: proof.route),
              let capabilities = target.binding?.resolvedVideoCapabilities,
              case .video(let video) = params,
              video.prompt == genInput.prompt,
              videoMatchesGenerationInput(video, genInput: genInput),
              videoMatchesRequirement(video, requirement: proof.requirement),
              uploadedReferences.count == proof.orderedBindings.count else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The provider request envelope does not match the routed video job."
            )
        }
        let inputPolicy = capabilities.inputPolicy
        var imageIndex = 0
        var videoIndex = 0
        var audioIndex = 0
        var actualOrder: [String] = []
        for binding in proof.orderedBindings {
            let value: String?
            switch ProductionIdentifierNormalizerV1.canonical(binding.semanticJobID) {
            case CoreReferenceSemanticJobIDV1.sourceVideo:
                value = video.sourceVideoURL
            case CoreReferenceSemanticJobIDV1.firstFrame,
                 CoreReferenceSemanticJobIDV1.predecessorLastFrame:
                value = video.startFrameURL
            case CoreReferenceSemanticJobIDV1.lastFrame:
                value = video.endFrameURL
            default:
                switch binding.modalityID {
                case "image":
                    value = video.referenceImageURLs.indices.contains(imageIndex)
                        ? video.referenceImageURLs[imageIndex]
                        : nil
                    imageIndex += 1
                case "video":
                    value = video.referenceVideoURLs.indices.contains(videoIndex)
                        ? video.referenceVideoURLs[videoIndex]
                        : nil
                    videoIndex += 1
                case "audio":
                    value = video.referenceAudioURLs.indices.contains(audioIndex)
                        ? video.referenceAudioURLs[audioIndex]
                        : nil
                    audioIndex += 1
                default:
                    value = nil
                }
            }
            guard let value else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The provider request dropped a planned input slot."
                )
            }
            actualOrder.append(value)
        }
        let plannedSource = proof.orderedBindings.contains {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.sourceVideo
            )
        }
        let plannedStart = proof.orderedBindings.contains {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }
        let plannedEnd = proof.orderedBindings.contains {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.lastFrame
            )
        }
        guard actualOrder == uploadedReferences,
              plannedSource == inputPolicy.requiresSourceVideo,
              (video.sourceVideoURL != nil) == plannedSource,
              (video.startFrameURL != nil) == plannedStart,
              (video.endFrameURL != nil) == plannedEnd,
              imageIndex == video.referenceImageURLs.count,
              videoIndex == video.referenceVideoURLs.count,
              audioIndex == video.referenceAudioURLs.count else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The provider request reordered or added inputs outside the ReferencePlan."
            )
        }
    }

    static func requiredMCPFieldNames(
        genInput: GenerationInput
    ) -> Set<String> {
        guard genInput.productionRouting != nil else {
            return []
        }
        var fields = Set<String>()
        if genInput.videoDuration != nil || genInput.duration > 0 {
            fields.insert("duration")
        }
        if !genInput.aspectRatio.isEmpty { fields.insert("aspectratio") }
        if genInput.resolution != nil { fields.insert("resolution") }
        if genInput.generateAudio != nil { fields.insert("generateaudio") }
        return fields
    }

    static func validateFalProviderEnvelope(
        genInput: GenerationInput,
        params: VideoGenerationParams,
        input: [String: Any],
        model: FalModel
    ) throws {
        guard let proof = genInput.productionRouting else { return }
        guard input["prompt"] as? String == params.prompt,
              params.prompt == genInput.prompt,
              videoMatchesGenerationInput(params, genInput: genInput),
              videoMatchesRequirement(params, requirement: proof.requirement),
              model.videoSendsAspectRatio || params.aspectRatio.isEmpty,
              model.videoSendsResolution || params.resolution == nil,
              model.videoGeneratesAudio || !params.generateAudio,
              proof.providerID == GenerationProvider.fal.rawValue else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The final fal request does not match the routed generation."
            )
        }
        let expectedDuration: String
        switch params.duration {
        case .automatic:
            expectedDuration = "auto"
        case .seconds(let seconds):
            expectedDuration = model.videoDuration == .secondsSuffix
                ? "\(seconds)s"
                : String(seconds)
        }
        let expectedAspectRatio = model.videoSendsAspectRatio
            ? params.aspectRatio
            : nil
        let expectedResolution = model.videoSendsResolution
            ? params.resolution
            : nil
        let expectedAudio = model.videoGeneratesAudio
            ? params.generateAudio
            : nil
        func matchesString(_ key: String, expected: String?) -> Bool {
            guard let expected else { return input[key] == nil }
            return input[key] as? String == expected
        }
        func matchesBool(_ key: String, expected: Bool?) -> Bool {
            guard let expected else { return input[key] == nil }
            return input[key] as? Bool == expected
        }
        guard input["duration"] as? String == expectedDuration,
              matchesString("aspect_ratio", expected: expectedAspectRatio),
              matchesString("resolution", expected: expectedResolution),
              matchesBool("generate_audio", expected: expectedAudio) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The final fal request changed or omitted a routed output field."
            )
        }
        guard params.sourceVideoURL == nil else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The selected fal adapter cannot submit the planned source video."
            )
        }
        let expectedImageURL: String?
        if model.videoFirstLastFrames {
            expectedImageURL = params.startFrameURL ?? params.referenceImageURLs.first
        } else if model.videoImageRef {
            expectedImageURL = params.referenceImageURLs.first
        } else {
            expectedImageURL = nil
        }
        func matchesArray(_ key: String, expected: [String]) -> Bool {
            guard !expected.isEmpty else { return input[key] == nil }
            return input[key] as? [String] == expected
        }
        guard matchesString("image_url", expected: expectedImageURL),
              matchesString(
                  "end_image_url",
                  expected: model.videoFirstLastFrames ? params.endFrameURL : nil
              ),
              matchesArray(
                  "image_urls",
                  expected: model.videoReferenceArrays
                      ? params.referenceImageURLs
                      : []
              ),
              matchesArray(
                  "video_urls",
                  expected: model.videoReferenceArrays
                      ? params.referenceVideoURLs
                      : []
              ),
              matchesArray(
                  "audio_urls",
                  expected: model.videoReferenceArrays
                      ? params.referenceAudioURLs
                      : []
              ) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The final fal request dropped, substituted, or reordered a routed input."
            )
        }
    }

    private static func videoMatchesGenerationInput(
        _ params: VideoGenerationParams,
        genInput: GenerationInput
    ) -> Bool {
        params.duration == (genInput.videoDuration ?? .seconds(genInput.duration))
            && params.aspectRatio == genInput.aspectRatio
            && params.resolution == genInput.resolution
            && genInput.generateAudio.map { params.generateAudio == $0 } == true
    }

    private static func videoMatchesRequirement(
        _ params: VideoGenerationParams,
        requirement: ProductionRequirementV1
    ) -> Bool {
        if let requested = requirement.duration {
            switch params.duration {
            case .automatic:
                guard requested.allowsAutomatic else { return false }
            case .seconds(let seconds):
                let value = Double(seconds)
                guard requested.preferredSeconds.map({ $0 == value }) ?? true,
                      requested.minimumSeconds.map({ value >= $0 }) ?? true,
                      requested.maximumSeconds.map({ value <= $0 }) ?? true else {
                    return false
                }
            }
        }
        if let aspectRatio = requirement.aspectRatio,
           params.aspectRatio != aspectRatio {
            return false
        }
        if let resolution = requirement.resolution,
           params.resolution != resolution {
            return false
        }
        return !requirement.requiresOutputAudio || params.generateAudio
    }

    nonisolated static func validateHistoricalProof(
        _ proof: ProductionGenerationRoutingProofV1,
        dataRoot: URL
    ) throws {
        guard proof.schema == ProductionGenerationRoutingProofV1.schemaVersion else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The historical generation-routing proof has an unsupported schema."
            )
        }
        let route = proof.route
        let referencePlan = proof.referencePlan
        let routeData = try ReferencePlanCanonicalCodecV2.encode(route)
        let planData = try ReferencePlanCanonicalCodecV2.encode(referencePlan)
        let requirementData = try ReferencePlanCanonicalCodecV2.encode(
            proof.requirement
        )
        let offeringCapabilitiesData = try ReferencePlanCanonicalCodecV2.encode(
            proof.offeringCapabilities
        )
        let bindingsData = try ReferencePlanCanonicalCodecV2.encode(
            referencePlan.bindings
        )
        let expectedOfferingID = [
            proof.providerID,
            proof.transportID,
            proof.endpointID,
            proof.modelParam ?? proof.modelID,
        ].joined(separator: "/")
        let historicalCandidate = ProductionRouteCandidateV1(
            capabilities: route.capabilitySnapshot.capabilities,
            providerActivated: true,
            liveAvailable: true,
            qualityScore: route.qualityScore,
            preferenceScore: route.preferenceScore,
            qualityTargetIDs: route.capabilitySnapshot.qualityTargetIDs,
            satisfiedProductionProfileRequirementIDs:
                route.capabilitySnapshot.satisfiedProductionProfileRequirementIDs,
            inputSlots: route.capabilitySnapshot.inputSlots,
            estimatedCost: route.estimatedCost,
            estimatedLatencySeconds: route.estimatedLatencySeconds
        )
        guard !proof.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proof.shotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proof.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proof.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proof.transportID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proof.endpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              route.schema == productionRouteV1Schema,
              referencePlan.schema == referencePlanV2Schema,
              proof.routeArtifactSHA256 == FileDigest.sha256(of: routeData),
              proof.referencePlanSHA256 == FileDigest.sha256(of: planData),
              proof.orderedBindingsSHA256 == FileDigest.sha256(of: bindingsData),
              proof.requirementSHA256 == FileDigest.sha256(of: requirementData),
              proof.offeringCapabilities.contractViolation == nil,
              validSHA256(proof.offeringCapabilitiesSHA256),
              proof.offeringCapabilitiesSHA256
                == FileDigest.sha256(of: offeringCapabilitiesData),
              route.projectID == proof.projectID,
              route.shotID == proof.shotID,
              route.offering.catalogModelID == proof.modelID,
              route.offering.providerID == proof.providerID,
              route.offering.endpointID == proof.endpointID,
              route.offering.offeringID == proof.offeringID,
              proof.offeringID == expectedOfferingID,
              route.requirementSHA256 == proof.requirementSHA256,
              route.capabilitiesSHA256 == proof.capabilitiesSHA256,
              route.routeSHA256 == proof.routeSHA256,
              referencePlan.projectID == proof.projectID,
              referencePlan.shotID == proof.shotID,
              referencePlan.route.offering == route.offering,
              referencePlan.route.requirementSHA256 == route.requirementSHA256,
              referencePlan.route.capabilitiesSHA256 == route.capabilitiesSHA256,
              referencePlan.route.routeSHA256 == route.routeSHA256,
              !referencePlan.demandSet.id.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              referencePlan.demandSet.role == ReferenceDemandSetV1.artifactRole,
              referencePlan.demandSet.path == PipelineLayout.referenceDemandSetFile(
                  shotID: proof.shotID
              ),
              validSHA256(referencePlan.demandSet.sha256),
              referencePlan.bindings.count == proof.orderedBindings.count else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "Historical generation provenance is not internally consistent."
            )
        }
        let fingerprints = try ProductionRequirementResolverV1.fingerprints(
            requirement: proof.requirement,
            candidate: historicalCandidate
        )
        guard route.capabilitySnapshot
                == ProductionRouteCapabilitySnapshotV1(candidate: historicalCandidate),
              route.requirementSHA256 == fingerprints.requirementSHA256,
              route.capabilitiesSHA256 == fingerprints.capabilitiesSHA256,
              route.routeSHA256 == fingerprints.routeSHA256,
              referencePlan.budget == historicalBudget(
                  for: route.capabilitySnapshot.capabilities.effective,
                  modality: route.offering.modality
              ) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "Historical route fingerprints are not reproducible."
            )
        }
        switch (proof.historicalAssetGraph, proof.historicalDemandSet) {
        case (let graph?, let demandSet?):
            try AssetGraphValidatorV1.validate(demandSet, against: graph)
            try AssetGraphValidatorV1.validateProjectFiles(
                graph,
                dataRoot: dataRoot
            )
            try ProductionRequirementResolverV1.validateBindings(
                proof.requirement,
                demandSet: demandSet
            )
            let demandData = try AssetGraphCanonicalCodecV1.encode(demandSet)
            guard graph.projectID == proof.projectID,
                  demandSet.projectID == proof.projectID,
                  demandSet.shotID == proof.shotID,
                  referencePlan.demandSet.id == demandSet.id,
                  referencePlan.demandSet.sha256
                    == FileDigest.sha256(of: demandData) else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "Historical production-input provenance is inconsistent."
                )
            }
            let rebuilt = try ReferencePlannerV2.plan(
                id: referencePlan.id,
                dataRoot: dataRoot,
                route: route,
                requirement: proof.requirement,
                demandSet: demandSet,
                graph: graph,
                candidate: historicalCandidate
            )
            guard case .plan(let expectedPlan) = rebuilt,
                  expectedPlan == referencePlan else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "Historical ReferencePlan bytes are not reproducible."
                )
            }
        case (nil, nil):
            break
        default:
            throw PipelineProductionRoutingError.publicationInvalid(
                "Historical production-input provenance is incomplete."
            )
        }
        let inputSlots = route.capabilitySnapshot.inputSlots
        guard Set(inputSlots.map(\.id)).count == inputSlots.count else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "Historical input-slot provenance is ambiguous."
            )
        }
        let slotsByID = Dictionary(uniqueKeysWithValues: inputSlots.map { ($0.id, $0) })
        var accounted = Set<String>()
        var selectedBindings: [ReferenceBindingV2] = []
        var imageCount = 0
        var videoCount = 0
        var audioCount = 0
        var geometryCount = 0
        var totalCount = 0
        var videoSeconds = 0.0
        var audioSeconds = 0.0
        for (index, pair) in zip(
            referencePlan.bindings,
            proof.orderedBindings
        ).enumerated() {
            let (binding, submitted) = pair
            guard accounted.insert(binding.demandID).inserted,
                  !binding.demandID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  !binding.assetID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  binding.assetVersion > 0,
                  validSHA256(binding.sha256),
                  let inputSlot = slotsByID[binding.inputSlotID],
                  inputSlot.modality == binding.modality,
                  Set(inputSlot.modeIDs.map(
                      ProductionIdentifierNormalizerV1.canonical
                  )).contains(
                      ProductionIdentifierNormalizerV1.canonical(binding.modeID)
                  ),
                  binding.demandID == submitted.demandID,
                  binding.assetID == submitted.graphAssetID,
                  binding.assetVersion == submitted.graphAssetVersion,
                  !submitted.mediaAssetID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  binding.path == submitted.path,
                  binding.sha256 == submitted.sha256,
                  binding.modality.rawValue == submitted.modalityID,
                  binding.semanticJobID == submitted.semanticJobID,
                  binding.inputSlotID == submitted.inputSlotID,
                  binding.modeID == submitted.modeID else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "Historical ReferencePlan binding \(index) is not internally consistent."
                )
            }
            if selectedBindings.contains(where: {
                $0.exclusionDemandIDs.contains(binding.demandID)
                    || binding.exclusionDemandIDs.contains($0.demandID)
            }) {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "Historical ReferencePlan bindings violate an exclusion."
                )
            }
            selectedBindings.append(binding)
            if inputSlot.countsTowardModalityBudget {
                switch binding.modality {
                case .image: imageCount += 1
                case .video: videoCount += 1
                case .audio: audioCount += 1
                case .geometry: geometryCount += 1
                }
            }
            if inputSlot.countsTowardTotalBudget {
                totalCount += 1
            }
            if inputSlot.countsTowardCombinedDuration {
                switch binding.modality {
                case .video:
                    if let duration = binding.durationSeconds {
                        guard duration.isFinite, duration >= 0 else {
                            throw PipelineProductionRoutingError.publicationInvalid(
                                "Historical video-reference duration is invalid."
                            )
                        }
                        videoSeconds += duration
                    } else if referencePlan.budget.combinedVideoSeconds != nil {
                        throw PipelineProductionRoutingError.publicationInvalid(
                            "Historical video-reference duration is missing."
                        )
                    }
                case .audio:
                    if let duration = binding.durationSeconds {
                        guard duration.isFinite, duration >= 0 else {
                            throw PipelineProductionRoutingError.publicationInvalid(
                                "Historical audio-reference duration is invalid."
                            )
                        }
                        audioSeconds += duration
                    } else if referencePlan.budget.combinedAudioSeconds != nil {
                        throw PipelineProductionRoutingError.publicationInvalid(
                            "Historical audio-reference duration is missing."
                        )
                    }
                case .image, .geometry:
                    break
                }
            }
            _ = try ProjectLocalFile.requireHash(
                binding.sha256,
                at: binding.path,
                dataRoot: dataRoot
            )
        }
        for drop in referencePlan.optionalDrops {
            guard accounted.insert(drop.demandID).inserted,
                  !drop.demandID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  !drop.detail.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "Historical ReferencePlan drop accounting is invalid."
                )
            }
        }
        let boundDemandIDs = Set(referencePlan.bindings.map(\.demandID))
        let boundAssetIDs = Set(referencePlan.bindings.map(\.assetID))
        let hasFirstFrame = referencePlan.bindings.contains {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }
        let hasLastFrame = referencePlan.bindings.contains {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.lastFrame
            )
        }
        let sourceVideo = referencePlan.bindings.first {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.sourceVideo
            )
        }
        let sourceCount = referencePlan.bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.sourceVideo
            )
        }.count
        let startCount = referencePlan.bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }.count
        let endCount = referencePlan.bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.lastFrame
            )
        }.count
        let ordinaryBindings = referencePlan.bindings.filter {
            ![
                CoreReferenceSemanticJobIDV1.sourceVideo,
                CoreReferenceSemanticJobIDV1.firstFrame,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                CoreReferenceSemanticJobIDV1.lastFrame,
            ].contains(ProductionIdentifierNormalizerV1.canonical($0.semanticJobID))
        }
        let sourceVideoMatches = proof.requirement.sourceVideoAssetID.map {
            sourceVideo?.assetID == $0
        } ?? (sourceVideo == nil)
        let videoDurationFits = referencePlan.budget.combinedVideoSeconds.map {
            videoSeconds <= $0
        } ?? true
        let audioDurationFits = referencePlan.budget.combinedAudioSeconds.map {
            audioSeconds <= $0
        } ?? true
        guard Set(proof.requirement.referenceDemandIDs).isSubset(of: accounted),
              Set(proof.requirement.identityLockAssetIDs).isSubset(of: boundAssetIDs),
              proof.requirement.requiresFirstFrame == hasFirstFrame,
              proof.requirement.requiresLastFrame == hasLastFrame,
              sourceVideoMatches,
              imageCount <= referencePlan.budget.imageCount,
              videoCount <= referencePlan.budget.videoCount,
              audioCount <= referencePlan.budget.audioCount,
              geometryCount <= referencePlan.budget.geometryCount,
              totalCount <= referencePlan.budget.totalCount,
              videoDurationFits,
              audioDurationFits,
              exactOfferingSupports(
                  referencePlan: referencePlan,
                  requirement: proof.requirement,
                  capabilities: proof.offeringCapabilities,
                  sourceCount: sourceCount,
                  startCount: startCount,
                  endCount: endCount,
                  imageCount: ordinaryBindings.filter {
                      $0.modality == .image
                  }.count,
                  videoCount: ordinaryBindings.filter {
                      $0.modality == .video
                  }.count,
                  audioCount: ordinaryBindings.filter {
                      $0.modality == .audio
                  }.count,
                  geometryCount: ordinaryBindings.filter {
                      $0.modality == .geometry
                  }.count
            ) else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "Historical ReferencePlan requirements, budgets, or exact offering "
                    + "capabilities are invalid."
            )
        }
    }

    nonisolated private static func historicalBudget(
        for profile: ResolvedCapabilityProfileV1,
        modality: CapabilityModalityV1
    ) -> ReferencePlanBudgetV2 {
        let integers = profile.fields.integers
        let decimals = profile.fields.decimals
        switch modality {
        case .video:
            return ReferencePlanBudgetV2(
                imageCount: integers[CapabilityFieldIDV1.referenceImages]?.value ?? 0,
                videoCount: integers[CapabilityFieldIDV1.referenceVideos]?.value ?? 0,
                audioCount: integers[CapabilityFieldIDV1.referenceAudios]?.value ?? 0,
                geometryCount: 0,
                totalCount: integers[CapabilityFieldIDV1.totalReferences]?.value ?? 0,
                combinedVideoSeconds: decimals[
                    CapabilityFieldIDV1.combinedVideoReferenceSeconds
                ]?.value,
                combinedAudioSeconds: decimals[
                    CapabilityFieldIDV1.combinedAudioReferenceSeconds
                ]?.value
            )
        case .image:
            let count = integers[CapabilityFieldIDV1.imageReferences]?.value ?? 0
            return ReferencePlanBudgetV2(
                imageCount: count,
                videoCount: 0,
                audioCount: 0,
                geometryCount: 0,
                totalCount: count
            )
        case .audio, .music:
            let count = profile.fields.booleans[
                CapabilityFieldIDV1.audioReference
            ]?.value == true ? 1 : 0
            return ReferencePlanBudgetV2(
                imageCount: 0,
                videoCount: 0,
                audioCount: count,
                geometryCount: 0,
                totalCount: count
            )
        }
    }

    nonisolated private static func validSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
    }

    private static func loadDependencies(
        shotID: String,
        dataRoot: URL
    ) throws -> (
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        assetGraph: AssetGraphV1
    ) {
        let (executionPlan, context) = try PipelineExecutionPlanWriter.load(
            dataRoot: dataRoot
        )
        try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
            dataRoot: dataRoot
        )
        guard let shot = executionPlan.shots.first(where: { $0.id == shotID }) else {
            throw PipelineProductionRoutingError.shotNotFound(shotID)
        }
        guard let requirement = shot.generationRequirement else {
            throw PipelineProductionRoutingError.generationRequirementMissing(shotID)
        }
        let (graph, demandSet, template) = try PipelineProductionInputsWriter.load(
            shotID: shotID,
            dataRoot: dataRoot
        )
        let shotIndex = executionPlan.shots.firstIndex(where: { $0.id == shotID })!
        try ProductionInputTemplateValidatorV1.validate(
            template,
            requirement: requirement,
            chainedFromPredecessor: template.coreInputs.predecessorLastFrameModeID != nil
                && shotIndex > 0
        )
        try ExecutionPlanValidator.validate(
            executionPlan,
            against: context,
            assetGraph: graph,
            demandSet: demandSet,
            forShotID: shotID
        )
        return (requirement, demandSet, graph)
    }

    private static func publish(
        route: ProductionRouteV1,
        referencePlan: ReferencePlanV2,
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        try requirePackMutation(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        let routeData = try ReferencePlanCanonicalCodecV2.encode(route)
        let planData = try ReferencePlanCanonicalCodecV2.encode(referencePlan)
        let orderedBindingsData = try ReferencePlanCanonicalCodecV2.encode(
            referencePlan.bindings
        )
        let publicationData = try ReferencePlanCanonicalCodecV2.encode(
            Publication(
                routeData: routeData,
                referencePlanData: planData,
                orderedBindingsData: orderedBindingsData
            )
        )
        let directory = routingDirectory(shotID: route.shotID, dataRoot: dataRoot)
        try requireSafeDirectory(directory, dataRoot: dataRoot, allowMissing: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try requireSafeDirectory(directory, dataRoot: dataRoot, allowMissing: false)
        let routeURL = directory.appendingPathComponent("route.v1.json")
        let planURL = directory.appendingPathComponent("plan.v2.json")
        let publicationURL = directory.appendingPathComponent("publication.v1.json")
        let previousRoute = try existingBytes(at: routeURL)
        let previousPlan = try existingBytes(at: planURL)
        let previousPublication = try existingBytes(at: publicationURL)
        let staging = directory.appendingPathComponent(
            ".routing-\(UUID().uuidString)",
            isDirectory: true
        )
        var canonicalWritesStarted = false
        do {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            let stagedRoute = staging.appendingPathComponent("route.json")
            let stagedPlan = staging.appendingPathComponent("plan.json")
            let stagedPublication = staging.appendingPathComponent("publication.json")
            try routeData.write(to: stagedRoute, options: .atomic)
            try planData.write(to: stagedPlan, options: .atomic)
            try publicationData.write(to: stagedPublication, options: .atomic)
            try requirePackMutation(
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            canonicalWritesStarted = true
            try Data(contentsOf: stagedRoute).write(to: routeURL, options: .atomic)
            try Data(contentsOf: stagedPlan).write(to: planURL, options: .atomic)
            try Data(contentsOf: stagedPublication).write(
                to: publicationURL,
                options: .atomic
            )
            guard try Data(contentsOf: routeURL) == routeData,
                  try Data(contentsOf: planURL) == planData,
                  try Data(contentsOf: publicationURL) == publicationData else {
                throw PipelineProductionRoutingError.publicationFailed(
                    "Persisted routing bytes differ from the canonical publication."
                )
            }
        } catch {
            if !canonicalWritesStarted {
                try? FileManager.default.removeItem(at: staging)
                if let routingError = error as? PipelineProductionRoutingError {
                    throw routingError
                }
                throw PipelineProductionRoutingError.publicationFailed(
                    error.localizedDescription
                )
            }
            do {
                try restore(previousRoute, at: routeURL)
                try restore(previousPlan, at: planURL)
                try restore(previousPublication, at: publicationURL)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw PipelineProductionRoutingError.publicationFailed(
                    "The previous routing publication could not be restored."
                )
            }
            try? FileManager.default.removeItem(at: staging)
            if let routingError = error as? PipelineProductionRoutingError {
                throw routingError
            }
            throw PipelineProductionRoutingError.publicationFailed(
                error.localizedDescription
            )
        }
        try? FileManager.default.removeItem(at: staging)
    }

    private static func requirePackMutation(
        dataRoot: URL,
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?
    ) throws {
        _ = try ProjectPackGate.requireMutation(
            projectURL: FrameInventory.projectHome(of: dataRoot),
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
    }

    private static func routingDirectory(shotID: String, dataRoot: URL) -> URL {
        PipelineLayout.url(
            PipelineLayout.referencePlanFile(shotID: shotID),
            in: dataRoot
        ).deletingLastPathComponent()
    }

    private static func makeSelection(
        modelID: String,
        target: ResolvedGenerationTarget,
        requirement: ProductionRequirementV1,
        route: ProductionRouteV1,
        referencePlan: ReferencePlanV2
    ) throws -> PipelineProductionRouteSelection {
        let routeData = try ReferencePlanCanonicalCodecV2.encode(route)
        let planData = try ReferencePlanCanonicalCodecV2.encode(referencePlan)
        let bindingsData = try ReferencePlanCanonicalCodecV2.encode(
            referencePlan.bindings
        )
        return PipelineProductionRouteSelection(
            modelID: modelID,
            target: target,
            requirement: requirement,
            route: route,
            routeArtifactSHA256: FileDigest.sha256(of: routeData),
            referencePlan: referencePlan,
            referencePlanSHA256: FileDigest.sha256(of: planData),
            orderedBindingsSHA256: FileDigest.sha256(of: bindingsData)
        )
    }

    static func providerAdapterSupports(
        referencePlan: ReferencePlanV2,
        route: ProductionRouteV1,
        target: ResolvedGenerationTarget,
        modelID: String,
        requirement: ProductionRequirementV1
    ) -> Bool {
        guard referencePlan.route.offering == route.offering,
              referencePlan.route.requirementSHA256 == route.requirementSHA256,
              referencePlan.route.capabilitiesSHA256 == route.capabilitiesSHA256,
              referencePlan.route.routeSHA256 == route.routeSHA256,
              target.modelId == modelID,
              route.offering.catalogModelID == modelID,
              target.provider.rawValue == route.offering.providerID,
              target.endpoint == route.offering.endpointID,
              inputPolicyMatchesRoute(target: target, route: route),
              let capabilities = target.binding?.resolvedVideoCapabilities else {
            return false
        }
        let inputPolicy = capabilities.inputPolicy
        guard route.offering.modality == .video else { return true }
        let sourceCount = referencePlan.bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.sourceVideo
            )
        }.count
        let startCount = referencePlan.bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }.count
        let endCount = referencePlan.bindings.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.lastFrame
            )
        }.count
        let ordinary = referencePlan.bindings.filter {
            ![
                CoreReferenceSemanticJobIDV1.sourceVideo,
                CoreReferenceSemanticJobIDV1.firstFrame,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                CoreReferenceSemanticJobIDV1.lastFrame,
            ].contains(ProductionIdentifierNormalizerV1.canonical($0.semanticJobID))
        }
        let imageCount = ordinary.filter { $0.modality == .image }.count
        let videoCount = ordinary.filter { $0.modality == .video }.count
        let audioCount = ordinary.filter { $0.modality == .audio }.count
        let geometryCount = ordinary.filter { $0.modality == .geometry }.count
        guard exactOfferingSupports(
            referencePlan: referencePlan,
            requirement: requirement,
            capabilities: capabilities,
            sourceCount: sourceCount,
            startCount: startCount,
            endCount: endCount,
            imageCount: imageCount,
            videoCount: videoCount,
            audioCount: audioCount,
            geometryCount: geometryCount
        ) else {
            return false
        }
        if target.transport == .mcp {
            return mcpAdapterSupports(
                referencePlan: referencePlan,
                route: route,
                target: target,
                requirement: requirement,
                sourceCount: sourceCount,
                startCount: startCount,
                endCount: endCount,
                imageCount: imageCount,
                videoCount: videoCount,
                audioCount: audioCount,
                geometryCount: geometryCount
            )
        }
        switch target.provider {
        case .runway:
            guard let model = RunwayModelRegistry.model(for: target.endpoint) else {
                return false
            }
            guard requirement.resolution == nil,
                  !requirement.requiresOutputAudio else {
                return false
            }
            if inputPolicy.requiresSourceVideo {
                return sourceCount == 1
                    && startCount == 0
                    && endCount == 0
                    && imageCount == 0
                    && videoCount == 0
                    && audioCount == 0
                    && geometryCount == 0
            }
            return sourceCount == 0
                && endCount == 0
                && videoCount == 0
                && audioCount == 0
                && geometryCount == 0
                && startCount + imageCount == 1
        case .fal:
            guard let model = FalModelRegistry.model(for: modelID)
                    ?? FalModelRegistry.model(for: target.endpoint),
                  !inputPolicy.requiresSourceVideo,
                  sourceCount == 0,
                  startCount <= 1,
                  endCount <= 1,
                  geometryCount == 0,
                  requirement.aspectRatio == nil
                    || model.videoSendsAspectRatio
                    || startCount == 1,
                  requirement.resolution == nil || model.videoSendsResolution,
                  !requirement.requiresOutputAudio || model.videoGeneratesAudio else {
                return false
            }
            if startCount > 0 || endCount > 0 {
                guard model.videoFirstLastFrames else { return false }
            }
            if videoCount > 0 || audioCount > 0 {
                guard model.videoReferenceArrays else { return false }
            }
            if imageCount > 0 {
                if model.videoReferenceArrays {
                    if model.videoImageRef || (model.videoFirstLastFrames && startCount == 0) {
                        return false
                    }
                } else if model.videoImageRef {
                    guard imageCount == 1, startCount == 0, endCount == 0 else {
                        return false
                    }
                } else if model.videoFirstLastFrames {
                    guard imageCount == 1, startCount == 0 else { return false }
                } else {
                    return false
                }
            }
            return true
        case .higgsfield, .openart, .ace:
            return false
        case .google, .marble, .elevenlabs:
            return false
        }
    }

    nonisolated private static func exactOfferingSupports(
        referencePlan: ReferencePlanV2,
        requirement: ProductionRequirementV1,
        capabilities: ResolvedVideoOfferingCapabilitiesV1,
        sourceCount: Int,
        startCount: Int,
        endCount: Int,
        imageCount: Int,
        videoCount: Int,
        audioCount: Int,
        geometryCount: Int
    ) -> Bool {
        let supportsAspectRatio = requirement.aspectRatio.map {
            capabilities.aspectRatios.isEmpty
                || capabilities.aspectRatios.contains($0)
        } ?? true
        let supportsResolution = requirement.resolution.map {
            capabilities.resolutions?.contains($0) ?? true
        } ?? true
        guard capabilities.contractViolation == nil,
              exactDurationSupports(
                  requirement.duration,
                  capabilities: capabilities.durationCapabilities
              ),
              supportsAspectRatio,
              supportsResolution,
              !requirement.requiresOutputAudio || capabilities.supportsNativeAudio,
              sourceCount <= 1,
              startCount <= 1,
              endCount <= 1,
              geometryCount == 0,
              sourceCount == (capabilities.inputPolicy.requiresSourceVideo ? 1 : 0),
              startCount == (requirement.requiresFirstFrame ? 1 : 0),
              endCount == (requirement.requiresLastFrame ? 1 : 0),
              (requirement.sourceVideoAssetID != nil) == (sourceCount == 1),
              startCount == 0 || capabilities.supportsFirstFrame,
              endCount == 0 || capabilities.supportsLastFrame else {
            return false
        }
        if capabilities.inputPolicy.requiresSourceVideo,
           startCount + endCount + videoCount + audioCount > 0 {
            return false
        }
        let ordinaryCount = imageCount + videoCount + audioCount
        if capabilities.framesAndReferencesExclusive,
           startCount + endCount > 0,
           ordinaryCount > 0 {
            return false
        }
        if capabilities.requiresReferenceImage,
           startCount + imageCount == 0 {
            return false
        }
        let imageLimit = capabilities.maxReferenceImages(
            hasVideoReference: videoCount > 0
        )
        let imageBudget = imageCount
            + (capabilities.inputPolicy.framesCountTowardImageReferenceLimit
                ? startCount + endCount : 0)
        guard imageBudget <= imageLimit,
              videoCount <= capabilities.maxReferenceVideos,
              audioCount <= capabilities.maxReferenceAudios else {
            return false
        }
        let totalBudget = ordinaryCount
            + (capabilities.inputPolicy.framesCountTowardTotalReferenceLimit
                ? startCount + endCount : 0)
        if let maximum = capabilities.maxTotalReferences,
           totalBudget > maximum {
            return false
        }
        if let maximum = capabilities.maxCombinedVideoReferenceSeconds {
            guard videoCount == 0
                    || referencePlan.budget.combinedVideoSeconds.map({ $0 <= maximum }) == true
            else { return false }
        }
        if let maximum = capabilities.maxCombinedAudioReferenceSeconds {
            guard audioCount == 0
                    || referencePlan.budget.combinedAudioSeconds.map({ $0 <= maximum }) == true
            else { return false }
        }
        return true
    }

    nonisolated private static func exactDurationSupports(
        _ requested: RequestedDurationV1?,
        capabilities: VideoDurationCapabilities
    ) -> Bool {
        guard let requested else { return true }
        if requested.allowsAutomatic, capabilities.supportsAuto { return true }
        if let preferred = requested.preferredSeconds {
            guard preferred.isFinite,
                  preferred.rounded() == preferred,
                  preferred >= Double(Int.min),
                  preferred <= Double(Int.max) else {
                return false
            }
            return capabilities.accepts(.seconds(Int(preferred)))
        }
        let minimum = requested.minimumSeconds ?? -Double.greatestFiniteMagnitude
        let maximum = requested.maximumSeconds ?? Double.greatestFiniteMagnitude
        guard minimum <= maximum else { return false }
        if capabilities.discrete.contains(where: {
            Double($0) >= minimum && Double($0) <= maximum
        }) {
            return true
        }
        if let range = capabilities.range {
            return Swift.max(Double(range.min), minimum)
                <= Swift.min(Double(range.max), maximum)
        }
        return capabilities.discrete.isEmpty && capabilities.range == nil
    }

    private static func mcpAdapterSupports(
        referencePlan: ReferencePlanV2,
        route: ProductionRouteV1,
        target: ResolvedGenerationTarget,
        requirement: ProductionRequirementV1,
        sourceCount: Int,
        startCount: Int,
        endCount: Int,
        imageCount: Int,
        videoCount: Int,
        audioCount: Int,
        geometryCount: Int
    ) -> Bool {
        guard let binding = target.binding,
              let capabilities = binding.resolvedVideoCapabilities,
              binding.transport == .mcp,
              binding.provider.rawValue == route.offering.providerID,
              binding.providerRef == route.offering.endpointID,
              !binding.providerRef.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              mcpOutputFieldsAreSchemaBacked(
                  requirement,
                  route: route,
                  endpointID: target.endpoint
              ) else {
            return false
        }
        let inputPolicy = capabilities.inputPolicy
        let plannedMediaCount = sourceCount + startCount + endCount
            + imageCount + videoCount + audioCount + geometryCount
        guard binding.mcpMediaRoles != nil || plannedMediaCount == 0 else {
            return false
        }
        let declaredRoles = binding.mcpMediaRoles ?? []
        let roles = Set(declaredRoles.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        guard declaredRoles.allSatisfy({
                  $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      .lowercased()
              }),
              roles.count == declaredRoles.count,
              !roles.contains("") else {
            return false
        }
        let declaredSlots = route.capabilitySnapshot.inputSlots
        guard Set(declaredSlots.map(\.id)).count == declaredSlots.count else {
            return false
        }
        let slots = Dictionary(
            uniqueKeysWithValues: declaredSlots.map { ($0.id, $0) }
        )
        var requestOrder: [Int] = []
        for planned in referencePlan.bindings {
            guard let slot = slots[planned.inputSlotID],
                  slot.modality == planned.modality,
                  Set(slot.modeIDs.map(
                      ProductionIdentifierNormalizerV1.canonical
                  )).contains(
                      ProductionIdentifierNormalizerV1.canonical(planned.modeID)
                  ) else {
                return false
            }
            requestOrder.append(slot.requestOrder)
        }
        guard requestOrder == requestOrder.sorted() else { return false }
        let genericImage = roles.contains("image")
            || roles.contains("image_references")
        let startImage = roles.contains("start_image")
        let endImage = roles.contains("end_image")
        let genericVideo = roles.contains("video")
            || roles.contains("video_references")
        let genericAudio = roles.contains("audio")
            || roles.contains("audio_references")
        guard sourceCount <= 1,
              sourceCount == (inputPolicy.requiresSourceVideo ? 1 : 0),
              startCount <= 1,
              endCount <= 1,
              geometryCount == 0,
              sourceCount == 0 || genericVideo,
              startCount == 0 || startImage || genericImage,
              endCount == 0 || endImage || genericImage,
              imageCount == 0 || genericImage,
              videoCount == 0 || genericVideo,
              audioCount == 0 || genericAudio else {
            return false
        }
        if sourceCount > 0, videoCount > 0 { return false }
        if startCount > 0, imageCount > 0, !startImage { return false }
        if endCount > 0, imageCount > 0, !endImage { return false }
        if startCount > 0, endCount > 0,
           !startImage || !endImage {
            return false
        }
        return true
    }

    private static func inputPolicyMatchesRoute(
        target: ResolvedGenerationTarget,
        route: ProductionRouteV1
    ) -> Bool {
        guard let capabilities = target.binding?.resolvedVideoCapabilities,
              capabilities.contractViolation == nil,
              target.binding?.productionInputPolicy == capabilities.inputPolicy else {
            return false
        }
        let policy = capabilities.inputPolicy
        let fields = route.capabilitySnapshot.capabilities.effective.fields.booleans
        func exact(_ fieldID: String, equals expected: Bool) -> Bool {
            guard let field = fields[fieldID] else { return false }
            return field.value == expected
                && field.origin.kind == .endpointOverlay
                && field.origin.endpointID == target.endpoint
        }
        return exact(
            CapabilityFieldIDV1.sourceVideoRequired,
            equals: policy.requiresSourceVideo
        ) && exact(
            CapabilityFieldIDV1.framesCountTowardImageReferenceLimit,
            equals: policy.framesCountTowardImageReferenceLimit
        ) && exact(
            CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit,
            equals: policy.framesCountTowardTotalReferenceLimit
        )
    }

    private static func mcpOutputFieldsAreSchemaBacked(
        _ requirement: ProductionRequirementV1,
        route: ProductionRouteV1,
        endpointID: String
    ) -> Bool {
        let fields = route.capabilitySnapshot.capabilities.effective.fields
        func isEndpointEvidence(_ evidence: [CapabilityEvidenceV1]) -> Bool {
            evidence.contains { $0.kind == .providerSchema }
        }
        func isEndpointOrigin(_ origin: ResolvedCapabilityOriginV1) -> Bool {
            origin.kind == .endpointOverlay && origin.endpointID == endpointID
        }
        if let duration = requirement.duration {
            var evidence: [CapabilityEvidenceV1] = []
            var origins: [ResolvedCapabilityOriginV1] = []
            for fieldID in [
                CapabilityFieldIDV1.durationValues,
                CapabilityFieldIDV1.durationMinimum,
                CapabilityFieldIDV1.durationMaximum,
                CapabilityFieldIDV1.durationAutomatic,
            ] {
                if let value = fields.integerLists[fieldID] {
                    evidence += value.evidence
                    origins.append(value.origin)
                }
                if let value = fields.decimals[fieldID] {
                    evidence += value.evidence
                    origins.append(value.origin)
                }
                if let value = fields.booleans[fieldID],
                   duration.allowsAutomatic {
                    evidence += value.evidence
                    origins.append(value.origin)
                }
            }
            guard isEndpointEvidence(evidence),
                  origins.contains(where: isEndpointOrigin) else {
                return false
            }
        }
        if requirement.aspectRatio != nil {
            guard let field = fields.strings[CapabilityFieldIDV1.aspectRatios],
                  isEndpointEvidence(field.evidence),
                  isEndpointOrigin(field.origin) else {
                return false
            }
        }
        if requirement.resolution != nil {
            guard let field = fields.strings[CapabilityFieldIDV1.resolutions],
                  isEndpointEvidence(field.evidence),
                  isEndpointOrigin(field.origin) else {
                return false
            }
        }
        if requirement.requiresOutputAudio {
            guard let field = fields.booleans[CapabilityFieldIDV1.nativeAudio],
                  field.value,
                  isEndpointEvidence(field.evidence),
                  isEndpointOrigin(field.origin) else {
                return false
            }
        }
        return true
    }

    private static func requireSafeDirectory(
        _ directory: URL,
        dataRoot: URL,
        allowMissing: Bool
    ) throws {
        let normalizedRoot = dataRoot.standardizedFileURL
        let normalizedDirectory = directory.standardizedFileURL
        guard normalizedDirectory.path.hasPrefix(normalizedRoot.path + "/") else {
            throw PipelineProductionRoutingError.publicationInvalid(
                "The routing publication escaped the project data root."
            )
        }
        var current = normalizedRoot
        let suffix = normalizedDirectory.path.dropFirst(normalizedRoot.path.count)
        for component in suffix.split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(
                atPath: current.path
            )) != nil {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "A routing publication path is a symbolic link."
                )
            }
            guard FileManager.default.fileExists(atPath: current.path) else {
                if allowMissing { return }
                throw PipelineProductionRoutingError.publicationInvalid(
                    "The routing publication directory is missing."
                )
            }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw PipelineProductionRoutingError.publicationInvalid(
                    "A routing publication path is not a directory."
                )
            }
        }
    }

    private static func existingBytes(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
