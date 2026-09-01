import Foundation
import Testing
@testable import NexGenEngine

@Suite("Production requirement routing")
struct ProductionRequirementRoutingTests {
    @Test("a capable route wins when a higher-scored route cannot preserve the requirement")
    func capableRouteWins() throws {
        let fixture = try makeFixture([])
        defer { fixture.remove() }
        let requirement = makeRequirement(visibleEntityCount: 3)
        let restrictive = makeCandidate(
            offeringID: "restrictive",
            qualityScore: 100,
            visibleEntityCount: 2
        )
        let capable = makeCandidate(
            offeringID: "capable",
            qualityScore: 10,
            visibleEntityCount: 3
        )

        let resolution = try ProductionRequirementResolverV1.resolve(
            requirement: requirement,
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [restrictive, capable]
        )

        guard case .matched(let route, let candidate) = resolution else {
            Issue.record("expected the capable route to match")
            return
        }
        #expect(route.offering.offeringID == "capable")
        #expect(candidate == capable)
    }

    @Test("a malformed candidate cannot suppress another valid route")
    func malformedCandidateIsIsolated() throws {
        let fixture = try makeFixture([])
        defer { fixture.remove() }
        let requirement = makeRequirement()
        let malformedCapabilities = makeCapabilities(
            offeringID: "malformed",
            visibleEntityCount: 10
        )
        let duplicateSlot = ProductionInputSlotCapabilityV1(
            id: "reference.image",
            modality: .image,
            modeIDs: ["text-to-video"],
            requestOrder: 0,
            countsTowardModalityBudget: true,
            countsTowardTotalBudget: true,
            countsTowardCombinedDuration: false
        )
        let malformed = ProductionRouteCandidateV1(
            capabilities: malformedCapabilities,
            providerActivated: true,
            liveAvailable: true,
            qualityScore: 100,
            inputSlots: [duplicateSlot, duplicateSlot]
        )
        let valid = makeCandidate(offeringID: "valid", qualityScore: 1)

        let resolution = try ProductionRequirementResolverV1.resolve(
            requirement: requirement,
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [malformed, valid]
        )
        guard case .matched(let route, _) = resolution else {
            Issue.record("expected the valid candidate to survive")
            return
        }
        #expect(route.offering.offeringID == "valid")

        let matches = try ProductionRequirementResolverV1.matchingRoutes(
            requirement: requirement,
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [malformed, valid]
        )
        #expect(matches.map(\.candidate) == [valid])
    }

    @Test("only malformed candidates produce a deterministic no-match")
    func onlyMalformedCandidatesDoNotThrow() throws {
        let fixture = try makeFixture([])
        defer { fixture.remove() }
        let slot = ProductionInputSlotCapabilityV1(
            id: "reference.image",
            modality: .image,
            modeIDs: ["text-to-video"],
            requestOrder: 0,
            countsTowardModalityBudget: true,
            countsTowardTotalBudget: true,
            countsTowardCombinedDuration: false
        )
        let malformed = ProductionRouteCandidateV1(
            capabilities: makeCapabilities(
                offeringID: "malformed-only",
                visibleEntityCount: 10
            ),
            providerActivated: true,
            liveAvailable: true,
            inputSlots: [slot, slot]
        )

        let resolution = try ProductionRequirementResolverV1.resolve(
            requirement: makeRequirement(),
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [malformed]
        )
        guard case .noMatch(let noMatch) = resolution else {
            Issue.record("expected an isolated no-match")
            return
        }
        #expect(noMatch.evaluations.isEmpty)
        #expect(noMatch.recoveryActions == [
            .activateProviderOrModel,
            .researchCapabilities,
            .editRequirements,
        ])
    }

    @Test("inactive and unavailable offerings expose exact activation deficits")
    func activationDeficits() throws {
        let fixture = try makeFixture([])
        defer { fixture.remove() }
        let requirement = makeRequirement()
        let inactive = makeCandidate(
            offeringID: "inactive",
            providerActivated: false
        )
        let unavailable = makeCandidate(
            offeringID: "unavailable",
            liveAvailable: false
        )

        let resolution = try ProductionRequirementResolverV1.resolve(
            requirement: requirement,
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [inactive, unavailable]
        )

        guard case .noMatch(let noMatch) = resolution else {
            Issue.record("expected activation deficits")
            return
        }
        #expect(noMatch.evaluations.map { $0.deficits.map(\.code) } == [
            [.providerNotActivated],
            [.offerUnavailable],
        ])
        #expect(noMatch.recoveryActions == [
            .activateProviderOrModel,
            .editRequirements,
        ])
    }

    @Test("undeclared quality and profile support fail with explicit deficits")
    func undeclaredProductionSupportFailsClosed() throws {
        let fixture = try makeFixture([])
        defer { fixture.remove() }
        let requirement = makeRequirement(
            productionProfileRequirementIDs: ["profile.requirement.v1"],
            qualityTarget: "master"
        )

        let resolution = try ProductionRequirementResolverV1.resolve(
            requirement: requirement,
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [makeCandidate(offeringID: "undeclared-support")]
        )

        guard case .noMatch(let noMatch) = resolution else {
            Issue.record("expected undeclared support to fail closed")
            return
        }
        #expect(noMatch.evaluations.first?.deficits.map(\.code) == [
            .qualityUnsupported,
            .productionProfileRequirementUnsupported,
        ])
    }

    @Test("generic reference IDs exclude dedicated core demands")
    func genericReferencesExcludeCoreDemands() throws {
        let fixture = try makeFixture([
            Input(id: "look-reference", modality: .image, isRequired: true),
            Input(
                id: "first-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
            ),
        ])
        defer { fixture.remove() }
        let requirement = makeRequirement(
            referenceDemandIDs: ["look-reference"],
            requiresFirstFrame: true
        )

        try ProductionRequirementResolverV1.validateBindings(
            requirement,
            demandSet: fixture.demandSet
        )

        #expect(throws: ProductionRequirementResolverErrorV1.invalidRequirement("structure")) {
            try ProductionRequirementResolverV1.validateBindings(
                makeRequirement(
                    referenceDemandIDs: ["look-reference", "first-frame"],
                    requiresFirstFrame: true
                ),
                demandSet: fixture.demandSet
            )
        }
    }

    @Test("every dedicated core demand is validated outside generic references")
    func dedicatedCoreDemandsDoNotRequireGenericIDs() throws {
        let firstFrame = try makeFixture([
            Input(
                id: "first-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
            ),
        ])
        defer { firstFrame.remove() }
        try ProductionRequirementResolverV1.validateBindings(
            makeRequirement(requiresFirstFrame: true),
            demandSet: firstFrame.demandSet
        )

        let lastFrame = try makeFixture([
            Input(
                id: "last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.lastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.lastFrame
            ),
        ])
        defer { lastFrame.remove() }
        try ProductionRequirementResolverV1.validateBindings(
            makeRequirement(requiresLastFrame: true),
            demandSet: lastFrame.demandSet
        )

        let predecessor = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
        ])
        defer { predecessor.remove() }
        try ProductionRequirementResolverV1.validateBindings(
            makeRequirement(requiresFirstFrame: true),
            demandSet: predecessor.demandSet
        )

        let sourceVideo = try makeFixture([
            Input(
                id: "source-video",
                modality: .video,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.sourceVideo,
                inputSlotID: CoreReferenceInputSlotIDV1.sourceVideo
            ),
        ])
        defer { sourceVideo.remove() }
        try ProductionRequirementResolverV1.validateBindings(
            makeRequirement(sourceVideoAssetID: "asset-source-video"),
            demandSet: sourceVideo.demandSet
        )

        let audioTiming = try makeFixture([
            Input(
                id: "audio-timing",
                modality: .audio,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
                inputSlotID: CoreReferenceInputSlotIDV1.audioTiming
            ),
        ])
        defer { audioTiming.remove() }
        try ProductionRequirementResolverV1.validateBindings(
            makeRequirement(),
            demandSet: audioTiming.demandSet
        )
    }

    @Test("planner retains chained predecessor and audio timing outside generic IDs")
    func plannerRetainsDedicatedChainedInputs() throws {
        let fixture = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
            Input(
                id: "audio-timing",
                modality: .audio,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
                inputSlotID: CoreReferenceInputSlotIDV1.audioTiming
            ),
        ])
        defer { fixture.remove() }
        let requirement = makeRequirement(requiresFirstFrame: true)
        let candidate = ProductionRouteCandidateV1(
            capabilities: makeCapabilities(
                offeringID: "chained-audio",
                imageCount: 1,
                audioCount: 1,
                totalCount: 2,
                firstFrame: true
            ),
            providerActivated: true,
            liveAvailable: true,
            inputSlots: [
                ProductionInputSlotCapabilityV1(
                    id: CoreReferenceInputSlotIDV1.firstFrame,
                    modality: .image,
                    modeIDs: ["text-to-video"],
                    requestOrder: 0,
                    countsTowardModalityBudget: true,
                    countsTowardTotalBudget: true,
                    countsTowardCombinedDuration: false
                ),
                ProductionInputSlotCapabilityV1(
                    id: CoreReferenceInputSlotIDV1.audioTiming,
                    modality: .audio,
                    modeIDs: ["text-to-video"],
                    requestOrder: 1,
                    countsTowardModalityBudget: true,
                    countsTowardTotalBudget: true,
                    countsTowardCombinedDuration: false
                ),
            ]
        )

        let plan = try planned(
            id: "plan-chained-audio",
            fixture: fixture,
            route: makeRoute(requirement: requirement, candidate: candidate),
            requirement: requirement,
            candidate: candidate
        )

        #expect(requirement.referenceDemandIDs.isEmpty)
        #expect(plan.bindings.map(\.demandID) == [
            "predecessor-last-frame",
            "audio-timing",
        ])
    }

    @Test("no-match resolution does not rewrite or reduce the requirement")
    func noMatchPreservesRequirement() throws {
        let fixture = try makeFixture([])
        defer { fixture.remove() }
        let requirement = makeRequirement(
            visibleEntityCount: 7,
            duration: RequestedDurationV1(preferredSeconds: 18),
            resolution: "4k",
            aspectRatio: "2.39:1",
            requiresOutputAudio: true
        )
        let original = try ReferencePlanCanonicalCodecV2.encode(requirement)

        let resolution = try ProductionRequirementResolverV1.resolve(
            requirement: requirement,
            demandSet: fixture.demandSet,
            assetGraph: fixture.graph,
            dataRoot: fixture.dataRoot,
            candidates: [makeCandidate(offeringID: "restricted", visibleEntityCount: 1)]
        )

        guard case .noMatch(let noMatch) = resolution else {
            Issue.record("expected the requirement to remain unmatched")
            return
        }
        #expect(try ReferencePlanCanonicalCodecV2.encode(requirement) == original)
        #expect(noMatch.requirementSHA256 == FileDigest.sha256(of: original))
        #expect(noMatch.evaluations[0].deficits.map(\.code).contains(.visibleEntityCapacity))
    }

    @Test("a required reference over budget fails instead of being dropped")
    func requiredReferenceOverBudget() throws {
        let fixture = try makeFixture([
            Input(id: "required", modality: .image, isRequired: true),
        ])
        defer { fixture.remove() }
        let requirement = makeRequirement(referenceDemandIDs: fixture.demandIDs)
        let candidate = makePlanningCandidate(
            offeringID: "zero-reference",
            imageCount: 0,
            totalCount: 0
        )

        let result = try ReferencePlannerV2.plan(
            id: "plan-required-over-budget",
            dataRoot: fixture.dataRoot,
            route: makeRoute(requirement: requirement, candidate: candidate),
            requirement: requirement,
            demandSet: fixture.demandSet,
            graph: fixture.graph,
            candidate: candidate
        )

        guard case .requiredInputsUnsupported(let failure) = result else {
            Issue.record("expected the required reference to fail closed")
            return
        }
        #expect(failure.deficits.map(\.demandID) == ["required", "required"])
        #expect(failure.deficits.map(\.code) == [.modalityBudget, .totalBudget])
    }

    @Test("optional references are selected and dropped deterministically")
    func deterministicOptionalDrops() throws {
        let fixture = try makeFixture([
            Input(id: "required", modality: .image, isRequired: true, priority: 0),
            Input(id: "optional-low", modality: .image, priority: 1),
            Input(id: "optional-high", modality: .image, priority: 10),
        ])
        defer { fixture.remove() }
        let requirement = makeRequirement(referenceDemandIDs: fixture.demandIDs)
        let candidate = makePlanningCandidate(
            offeringID: "two-references",
            imageCount: 2,
            totalCount: 2
        )
        let route = makeRoute(requirement: requirement, candidate: candidate)

        let first = try planned(
            id: "plan-optional",
            fixture: fixture,
            route: route,
            requirement: requirement,
            candidate: candidate
        )
        let second = try planned(
            id: "plan-optional",
            fixture: fixture,
            route: route,
            requirement: requirement,
            candidate: candidate
        )

        #expect(first.bindings.map(\.demandID) == ["required", "optional-high"])
        #expect(first.optionalDrops == [
            ReferencePlanDropV2(
                demandID: "optional-low",
                reason: .modalityBudget,
                detail: "reference.image_count"
            ),
        ])
        #expect(first == second)
        #expect(
            try ReferencePlanCanonicalCodecV2.encode(first)
                == ReferencePlanCanonicalCodecV2.encode(second)
        )
    }

    @Test("one placement reports exclusions, modality, total, and duration deficits together")
    func simultaneousDeficits() throws {
        let fixture = try makeFixture([
            Input(id: "selected", modality: .image, isRequired: true),
            Input(
                id: "blocked",
                modality: .video,
                isRequired: true,
                exclusions: ["selected"],
                durationSeconds: 10
            ),
        ])
        defer { fixture.remove() }
        let requirement = makeRequirement(referenceDemandIDs: fixture.demandIDs)
        let candidate = makePlanningCandidate(
            offeringID: "simultaneous-deficits",
            imageCount: 1,
            videoCount: 0,
            totalCount: 1,
            combinedVideoSeconds: 5
        )

        let result = try ReferencePlannerV2.plan(
            id: "plan-simultaneous-deficits",
            dataRoot: fixture.dataRoot,
            route: makeRoute(requirement: requirement, candidate: candidate),
            requirement: requirement,
            demandSet: fixture.demandSet,
            graph: fixture.graph,
            candidate: candidate
        )

        guard case .requiredInputsUnsupported(let failure) = result else {
            Issue.record("expected all placement deficits")
            return
        }
        #expect(failure.deficits.map(\.demandID) == Array(repeating: "blocked", count: 4))
        #expect(failure.deficits.map(\.code) == [
            .mutuallyExclusive,
            .modalityBudget,
            .totalBudget,
            .combinedDuration,
        ])
    }

    @Test("a duration-limited route rejects references with unknown duration")
    func unknownDurationFailsClosed() throws {
        let fixture = try makeFixture([
            Input(id: "unknown-duration", modality: .video, isRequired: true),
        ])
        defer { fixture.remove() }
        let requirement = makeRequirement(referenceDemandIDs: fixture.demandIDs)
        let candidate = makePlanningCandidate(
            offeringID: "duration-limited",
            videoCount: 1,
            totalCount: 1,
            combinedVideoSeconds: 5
        )

        let result = try ReferencePlannerV2.plan(
            id: "plan-unknown-duration",
            dataRoot: fixture.dataRoot,
            route: makeRoute(requirement: requirement, candidate: candidate),
            requirement: requirement,
            demandSet: fixture.demandSet,
            graph: fixture.graph,
            candidate: candidate
        )

        guard case .requiredInputsUnsupported(let failure) = result else {
            Issue.record("expected unknown duration to fail closed")
            return
        }
        #expect(failure.deficits.map(\.code) == [.unknownDuration])
        #expect(failure.deficits.map(\.scopeID) == ["reference.combined_video_seconds"])
    }

    @Test("fifty mixed inputs retain stable order and canonical bytes")
    func fiftyMixedInputsAreStable() throws {
        let modalities: [AssetPhysicalModalityV1] = [.image, .video, .audio]
        let inputs = (0..<50).map { index in
            Input(
                id: String(format: "demand-%02d", index),
                modality: modalities[index % modalities.count],
                priority: 50 - index,
                durationSeconds: index % modalities.count == 0 ? nil : 1
            )
        }
        let fixture = try makeFixture(inputs)
        defer { fixture.remove() }
        let requirement = makeRequirement(referenceDemandIDs: fixture.demandIDs)
        let candidate = makePlanningCandidate(
            offeringID: "fifty-inputs",
            imageCount: 17,
            videoCount: 17,
            audioCount: 16,
            totalCount: 50,
            combinedVideoSeconds: 17,
            combinedAudioSeconds: 16
        )
        let route = makeRoute(requirement: requirement, candidate: candidate)

        let first = try planned(
            id: "plan-fifty",
            fixture: fixture,
            route: route,
            requirement: requirement,
            candidate: candidate
        )
        let second = try planned(
            id: "plan-fifty",
            fixture: fixture,
            route: route,
            requirement: requirement,
            candidate: candidate
        )
        let firstBytes = try ReferencePlanCanonicalCodecV2.encode(first)
        let secondBytes = try ReferencePlanCanonicalCodecV2.encode(second)
        let expectedRequestOrder = modalities.flatMap { modality in
            inputs.filter { $0.modality == modality }.map(\.id)
        }

        #expect(first.bindings.map(\.demandID) == expectedRequestOrder)
        #expect(first.optionalDrops.isEmpty)
        #expect(firstBytes == secondBytes)
        #expect(
            try ReferencePlanCanonicalCodecV2.decode(
                firstBytes,
                dataRoot: fixture.dataRoot,
                route: route,
                requirement: requirement,
                demandSet: fixture.demandSet,
                graph: fixture.graph,
                candidate: candidate
            ) == first
        )
    }

    @Test("asset graph validation rejects hash drift and symbolic-link escapes")
    func fileDriftAndSymlinkEscape() throws {
        let driftFixture = try makeFixture([
            Input(id: "drift", modality: .image, isRequired: true),
        ])
        defer { driftFixture.remove() }
        let driftPath = driftFixture.dataRoot.appendingPathComponent("inputs/drift.bin")
        try Data("changed".utf8).write(to: driftPath)
        let expected = driftFixture.graph.assets[0].sha256
        let actual = try FileDigest.sha256(of: driftPath)
        #expect(
            throws: ProjectLocalFileError.hashMismatch(
                path: "inputs/drift.bin",
                expected: expected,
                actual: actual
            )
        ) {
            try AssetGraphValidatorV1.validateProjectFiles(
                driftFixture.graph,
                dataRoot: driftFixture.dataRoot
            )
        }

        let linkFixture = try makeFixture([
            Input(id: "linked", modality: .image, isRequired: true),
        ])
        defer { linkFixture.remove() }
        let linkedPath = linkFixture.dataRoot.appendingPathComponent("inputs/linked.bin")
        let escapedPath = linkFixture.projectRoot.appendingPathComponent("escaped.bin")
        try FileManager.default.removeItem(at: linkedPath)
        try Data("asset-linked".utf8).write(to: escapedPath)
        try FileManager.default.createSymbolicLink(
            at: linkedPath,
            withDestinationURL: escapedPath
        )
        #expect(throws: ProjectLocalFileError.symbolicLink("inputs/linked.bin")) {
            try AssetGraphValidatorV1.validateProjectFiles(
                linkFixture.graph,
                dataRoot: linkFixture.dataRoot
            )
        }
    }

    @Test("core first-frame input is a singleton image slot")
    func coreFirstFrameSlotIsSingletonImage() throws {
        let wrongModality = try makeFixture([
            Input(
                id: "first-frame-video",
                modality: .video,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
            ),
        ])
        defer { wrongModality.remove() }
        #expect(throws: AssetGraphValidationError.invalidCoreReference("first-frame-video")) {
            try AssetGraphValidatorV1.validate(
                wrongModality.demandSet,
                against: wrongModality.graph
            )
        }

        let duplicate = try makeFixture([
            Input(
                id: "first-frame-a",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
            ),
            Input(
                id: "first-frame-b",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame
            ),
        ])
        defer { duplicate.remove() }
        #expect(throws: AssetGraphValidationError.invalidCoreReference(
            CoreReferenceSemanticJobIDV1.firstFrame
        )) {
            try AssetGraphValidatorV1.validate(duplicate.demandSet, against: duplicate.graph)
        }
    }

    @Test("a chained predecessor reference is the sole required image demand")
    func chainedPredecessorShape() throws {
        let valid = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
        ])
        defer { valid.remove() }
        try AssetGraphValidatorV1.validate(valid.demandSet, against: valid.graph)
        try AssetGraphValidatorV1.validateProjectFiles(
            valid.graph,
            dataRoot: valid.dataRoot
        )

        let withTiming = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
            Input(
                id: "audio-timing",
                modality: .audio,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
                inputSlotID: CoreReferenceInputSlotIDV1.audioTiming
            ),
        ])
        defer { withTiming.remove() }
        try AssetGraphValidatorV1.validate(
            withTiming.demandSet,
            against: withTiming.graph
        )

        let invalid = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
            Input(id: "extra-reference", modality: .image),
        ])
        defer { invalid.remove() }
        #expect(throws: AssetGraphValidationError.invalidChainedReferencePlan) {
            try AssetGraphValidatorV1.validate(invalid.demandSet, against: invalid.graph)
        }
    }

    @Test("render-frame provenance rejects an opaque proof payload")
    func renderFrameRequiresTypedProof() throws {
        let fixture = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
        ])
        defer { fixture.remove() }
        let source = try #require(fixture.graph.assets.first)
        let proofPath = try #require(source.provenance.sourceProofPath)
        let opaque = Data(#"{"accepted":true}"#.utf8)
        try opaque.write(to: fixture.dataRoot.appendingPathComponent(proofPath))
        let asset = try AssetGraphContentAddressV1.reidentified(AssetGraphNodeV1(
            id: "pending",
            version: source.version,
            path: source.path,
            sha256: source.sha256,
            modality: source.modality,
            entityID: source.entityID,
            canonIDs: source.canonIDs,
            stateID: source.stateID,
            viewID: source.viewID,
            approval: source.approval,
            provenance: AssetProvenanceV1(
                kindID: source.provenance.kindID,
                sourceAssetID: source.provenance.sourceAssetID,
                modelID: source.provenance.modelID,
                promptSHA256: source.provenance.promptSHA256,
                sourceShotID: source.provenance.sourceShotID,
                sourceRoleID: source.provenance.sourceRoleID,
                sourceProofPath: proofPath,
                sourceProofSHA256: FileDigest.sha256(of: opaque),
                recordedAt: source.provenance.recordedAt
            ),
            allowedUseIDs: source.allowedUseIDs,
            durationSeconds: source.durationSeconds
        ))
        let graph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: fixture.graph.projectID,
                assets: [asset]
            ),
            projectID: fixture.graph.projectID,
            assets: [asset]
        )

        #expect(throws: AssetGraphValidationError.invalidProvenance(asset.id)) {
            try AssetGraphValidatorV1.validateProjectFiles(
                graph,
                dataRoot: fixture.dataRoot
            )
        }
    }

    @Test("render-frame provenance binds the current output and exact last frame")
    func renderFrameBindsCurrentOutputAndLastFrame() throws {
        let fixture = try makeFixture([
            Input(
                id: "predecessor-last-frame",
                modality: .image,
                isRequired: true,
                semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
                expectedSourceShotID: "shot-000"
            ),
        ])
        defer { fixture.remove() }
        try AssetGraphValidatorV1.validateProjectFiles(
            fixture.graph,
            dataRoot: fixture.dataRoot
        )

        let phase = "preview-predecessor-last-frame"
        let proof = try loadRenderProofManifest(
            dataRoot: fixture.dataRoot,
            phase: phase
        )
        let proofEntry = try #require(proof.entries["shot-000"])
        let outputURL = fixture.dataRoot.appendingPathComponent(proofEntry.output)
        try Data("tampered-render".utf8).write(to: outputURL)
        let assetID = try #require(fixture.graph.assets.first?.id)
        #expect(throws: AssetGraphValidationError.invalidProvenance(
            assetID
        )) {
            try AssetGraphValidatorV1.validateProjectFiles(
                fixture.graph,
                dataRoot: fixture.dataRoot
            )
        }
        try Data("render-predecessor-last-frame".utf8).write(to: outputURL)

        var manifest = try loadRenderManifest(
            dataRoot: fixture.dataRoot,
            phase: phase
        )
        var entry = try #require(manifest.entries["shot-000"])
        entry.lastFramePath = "inputs/not-the-current-last-frame.png"
        manifest.entries[entry.shotId] = entry
        try saveRenderManifest(manifest, dataRoot: fixture.dataRoot)

        #expect(throws: AssetGraphValidationError.invalidProvenance(
            assetID
        )) {
            try AssetGraphValidatorV1.validateProjectFiles(
                fixture.graph,
                dataRoot: fixture.dataRoot
            )
        }
    }

    private func planned(
        id: String,
        fixture: Fixture,
        route: ProductionRouteV1,
        requirement: ProductionRequirementV1,
        candidate: ProductionRouteCandidateV1
    ) throws -> ReferencePlanV2 {
        let result = try ReferencePlannerV2.plan(
            id: id,
            dataRoot: fixture.dataRoot,
            route: route,
            requirement: requirement,
            demandSet: fixture.demandSet,
            graph: fixture.graph,
            candidate: candidate
        )
        guard case .plan(let plan) = result else {
            Issue.record("expected a reference plan")
            throw FixtureError.expectedPlan
        }
        return plan
    }

    private func makeRequirement(
        visibleEntityCount: Int = 0,
        referenceDemandIDs: [String] = [],
        duration: RequestedDurationV1? = nil,
        resolution: String? = nil,
        aspectRatio: String? = nil,
        requiresOutputAudio: Bool = false,
        requiresFirstFrame: Bool = false,
        requiresLastFrame: Bool = false,
        sourceVideoAssetID: String? = nil,
        productionProfileRequirementIDs: [String] = [],
        qualityTarget: String? = nil
    ) -> ProductionRequirementV1 {
        ProductionRequirementV1(
            modalityID: "video",
            modeIDs: ["text-to-video"],
            visibleEntityCount: visibleEntityCount,
            referenceDemandIDs: referenceDemandIDs,
            requiresFirstFrame: requiresFirstFrame,
            requiresLastFrame: requiresLastFrame,
            sourceVideoAssetID: sourceVideoAssetID,
            duration: duration,
            resolution: resolution,
            aspectRatio: aspectRatio,
            requiresOutputAudio: requiresOutputAudio,
            productionProfileRequirementIDs: productionProfileRequirementIDs,
            qualityTarget: qualityTarget
        )
    }

    private func makeCandidate(
        offeringID: String,
        providerActivated: Bool = true,
        liveAvailable: Bool = true,
        qualityScore: Double = 0,
        visibleEntityCount: Int = 10
    ) -> ProductionRouteCandidateV1 {
        ProductionRouteCandidateV1(
            capabilities: makeCapabilities(
                offeringID: offeringID,
                visibleEntityCount: visibleEntityCount
            ),
            providerActivated: providerActivated,
            liveAvailable: liveAvailable,
            qualityScore: qualityScore
        )
    }

    private func makePlanningCandidate(
        offeringID: String,
        visibleEntityCount: Int = 10,
        imageCount: Int = 0,
        videoCount: Int = 0,
        audioCount: Int = 0,
        totalCount: Int = 0,
        combinedVideoSeconds: Double? = nil,
        combinedAudioSeconds: Double? = nil,
        firstFrame: Bool = false
    ) -> ProductionRouteCandidateV1 {
        ProductionRouteCandidateV1(
            capabilities: makeCapabilities(
                offeringID: offeringID,
                visibleEntityCount: visibleEntityCount,
                imageCount: imageCount,
                videoCount: videoCount,
                audioCount: audioCount,
                totalCount: totalCount,
                combinedVideoSeconds: combinedVideoSeconds,
                combinedAudioSeconds: combinedAudioSeconds,
                firstFrame: firstFrame
            ),
            providerActivated: true,
            liveAvailable: true,
            inputSlots: AssetPhysicalModalityV1.allCases.enumerated().map { index, modality in
                ProductionInputSlotCapabilityV1(
                    id: "reference.\(modality.rawValue)",
                    modality: modality,
                    modeIDs: ["text-to-video"],
                    requestOrder: index,
                    countsTowardModalityBudget: true,
                    countsTowardTotalBudget: true,
                    countsTowardCombinedDuration: true
                )
            }
        )
    }

    private func makeCapabilities(
        offeringID: String,
        visibleEntityCount: Int = 10,
        imageCount: Int = 0,
        videoCount: Int = 0,
        audioCount: Int = 0,
        totalCount: Int = 0,
        combinedVideoSeconds: Double? = nil,
        combinedAudioSeconds: Double? = nil,
        firstFrame: Bool = false
    ) -> ResolvedOfferingCapabilityProfileV1 {
        var integers: [String: ResolvedCapabilityValueV1<Int>] = [
            CapabilityFieldIDV1.visibleCharacters: value(visibleEntityCount),
            CapabilityFieldIDV1.referenceImages: value(imageCount),
            CapabilityFieldIDV1.referenceVideos: value(videoCount),
            CapabilityFieldIDV1.referenceAudios: value(audioCount),
            CapabilityFieldIDV1.totalReferences: value(totalCount),
        ]
        integers["video.reference_geometry"] = value(0)
        var decimals: [String: ResolvedCapabilityValueV1<Double>] = [
            CapabilityFieldIDV1.durationMinimum: value(1),
            CapabilityFieldIDV1.durationMaximum: value(30),
        ]
        if let combinedVideoSeconds {
            decimals[CapabilityFieldIDV1.combinedVideoReferenceSeconds] = value(
                combinedVideoSeconds
            )
        }
        if let combinedAudioSeconds {
            decimals[CapabilityFieldIDV1.combinedAudioReferenceSeconds] = value(
                combinedAudioSeconds
            )
        }
        let profile = ResolvedCapabilityProfileV1(
            requestedIdentity: nil,
            resolvedIdentity: nil,
            defensiveProfileID: nil,
            researchNeeded: false,
            fields: ResolvedCapabilityFieldsV1(
                integers: integers,
                decimals: decimals,
                booleans: [
                    CapabilityFieldIDV1.nativeAudio: value(true),
                    CapabilityFieldIDV1.firstFrame: value(firstFrame),
                ],
                strings: [
                    CapabilityFieldIDV1.modes: value(["text-to-video"]),
                    CapabilityFieldIDV1.resolutions: value(["1080p"]),
                    CapabilityFieldIDV1.aspectRatios: value(["16:9"]),
                ]
            )
        )
        return ResolvedOfferingCapabilityProfileV1(
            offering: CapabilityOfferingIdentityV1(
                providerID: "fixture-provider",
                offeringID: offeringID,
                endpointID: "\(offeringID)-endpoint",
                catalogModelID: "fixture/\(offeringID)",
                modality: .video
            ),
            intrinsic: profile,
            effective: profile
        )
    }

    private func value<Value>(_ value: Value) -> ResolvedCapabilityValueV1<Value>
    where Value: Codable & Sendable & Equatable {
        ResolvedCapabilityValueV1(
            value: value,
            semantics: .hardAPILimit,
            origin: ResolvedCapabilityOriginV1(
                kind: .exact,
                profileID: "fixture-profile"
            ),
            evidence: []
        )
    }

    private func makeRoute(
        requirement: ProductionRequirementV1,
        candidate: ProductionRouteCandidateV1
    ) -> ProductionRouteV1 {
        let fingerprints = try! ProductionRequirementResolverV1.fingerprints(
            requirement: requirement,
            candidate: candidate
        )
        return ProductionRouteV1(
            id: "route-shot-001",
            projectID: "project-fixture",
            shotID: "shot-001",
            offering: candidate.capabilities.offering,
            capabilitySnapshot: ProductionRouteCapabilitySnapshotV1(candidate: candidate),
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

    private func makeFixture(_ inputs: [Input]) throws -> Fixture {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dataRoot = projectRoot.appendingPathComponent("pipeline")
        let inputRoot = dataRoot.appendingPathComponent("inputs")
        let proofRoot = dataRoot.appendingPathComponent(PipelineLayout.rendersDir)
        try FileManager.default.createDirectory(
            at: inputRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: proofRoot,
            withIntermediateDirectories: true
        )
        let assets = try inputs.map { input -> AssetGraphNodeV1 in
            let path = "inputs/\(input.id).bin"
            let url = dataRoot.appendingPathComponent(path)
            let data = Data("asset-\(input.id)".utf8)
            try data.write(to: url)
            var proofPath: String?
            var proofData: Data?
            if let sourceShotID = input.expectedSourceShotID {
                let phase = "preview-\(input.id)"
                let outputPath = "inputs/\(input.id)-render.mp4"
                let outputData = Data("render-\(input.id)".utf8)
                try outputData.write(
                    to: dataRoot.appendingPathComponent(outputPath)
                )
                let proof = RenderProofManifest(
                    project: "project-fixture",
                    phase: phase,
                    entries: [
                        sourceShotID: RenderProofEntry(
                            shotId: sourceShotID,
                            output: outputPath,
                            outputSha256: FileDigest.sha256(of: outputData),
                            providerPrompt: "Compiled fixture prompt.",
                            generationModel: "fixture-model"
                        ),
                    ]
                )
                try saveRenderProofManifest(proof, dataRoot: dataRoot)
                var renderManifest = RenderManifest(
                    project: proof.project,
                    phase: phase
                )
                renderManifest.entries[sourceShotID] = RenderEntry(
                    shotId: sourceShotID,
                    phase: phase,
                    status: .rendered,
                    output: outputPath,
                    lastFramePath: path
                )
                try saveRenderManifest(renderManifest, dataRoot: dataRoot)
                proofPath = PipelineLayout.renderProofFile(phase: phase)
                proofData = try Data(contentsOf: dataRoot.appendingPathComponent(proofPath!))
                let renderPath = PipelineLayout.renderManifestFile(phase: phase)
                let renderData = try Data(
                    contentsOf: dataRoot.appendingPathComponent(renderPath)
                )
                let routingPath = PipelineLayout.renderRoutingProofFile(phase: phase)
                let routingData = Data("fixture-routing-\(input.id)".utf8)
                try routingData.write(
                    to: dataRoot.appendingPathComponent(routingPath)
                )
                let publication = RenderRecordPublicationV1(
                    transactionID: "fixture-\(input.id)",
                    project: proof.project,
                    phase: phase,
                    renderManifest: RenderPublishedArtifactV1(
                        path: renderPath,
                        sha256: FileDigest.sha256(of: renderData)
                    ),
                    renderProof: RenderPublishedArtifactV1(
                        path: proofPath!,
                        sha256: FileDigest.sha256(of: proofData!)
                    ),
                    renderRoutingProof: RenderPublishedArtifactV1(
                        path: routingPath,
                        sha256: FileDigest.sha256(of: routingData)
                    ),
                    framesManifest: nil,
                    lastFrames: [
                        sourceShotID: RenderLastFrameProofV1(
                            shotID: sourceShotID,
                            phase: phase,
                            path: path,
                            sha256: FileDigest.sha256(of: data),
                            sourceOutput: outputPath,
                            sourceOutputSHA256: FileDigest.sha256(of: outputData),
                            extractedAt: "2026-08-31T00:00:00Z"
                        ),
                    ],
                    committedAt: "2026-08-31T00:00:00Z"
                )
                let publicationData = try JSONEncoder().encode(publication)
                try publicationData.write(
                    to: dataRoot.appendingPathComponent(
                        RenderRecordPublicationV1.artifactPath(phase: phase)
                    )
                )
            }
            return try AssetGraphContentAddressV1.reidentified(AssetGraphNodeV1(
                id: "pending",
                version: 1,
                path: path,
                sha256: FileDigest.sha256(of: data),
                modality: input.modality,
                approval: .approved,
                provenance: AssetProvenanceV1(
                    kindID: input.expectedSourceShotID == nil
                        ? "fixture.import"
                        : CoreAssetProvenanceKindIDV1.renderFrame,
                    sourceShotID: input.expectedSourceShotID,
                    sourceRoleID: input.expectedSourceShotID == nil
                        ? nil
                        : CoreReferenceSemanticJobIDV1.lastFrame,
                    sourceProofPath: proofPath,
                    sourceProofSHA256: proofData.map { FileDigest.sha256(of: $0) },
                    recordedAt: "2026-08-31T00:00:00Z"
                ),
                allowedUseIDs: [input.semanticJobID],
                durationSeconds: input.assetDurationSeconds
            ))
        }
        let graph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: "project-fixture",
                assets: assets
            ),
            projectID: "project-fixture",
            assets: assets
        )
        let graphData = try AssetGraphCanonicalCodecV1.encode(graph)
        let assetIDByInputID = Dictionary(uniqueKeysWithValues: zip(inputs, assets).map {
            ($0.0.id, $0.1.id)
        })
        let demands = inputs.map { input in
            ReferenceDemandV1(
                id: input.id,
                assetID: assetIDByInputID[input.id]!,
                modality: input.modality,
                semanticJobID: input.semanticJobID,
                isRequired: input.isRequired,
                priority: input.priority,
                preservationScopeIDs: input.preservationScopeIDs,
                exclusionDemandIDs: input.exclusions,
                inputSlotID: input.inputSlotID,
                modeID: input.modeID,
                durationSeconds: input.durationSeconds,
                expectedSourceShotID: input.expectedSourceShotID
            )
        }
        let demandSet = ReferenceDemandSetV1(
            id: "reference-demands-shot-001",
            projectID: graph.projectID,
            shotID: "shot-001",
            assetGraph: CanonicalArtifactReferenceV1(
                id: graph.id,
                role: AssetGraphV1.artifactRole,
                path: PipelineLayout.assetGraphFile,
                sha256: FileDigest.sha256(of: graphData)
            ),
            demands: demands
        )
        return Fixture(
            projectRoot: projectRoot,
            dataRoot: dataRoot,
            graph: graph,
            demandSet: demandSet
        )
    }

    private struct Input {
        let id: String
        let modality: AssetPhysicalModalityV1
        let isRequired: Bool
        let semanticJobID: String
        let priority: Int
        let preservationScopeIDs: [String]
        let exclusions: [String]
        let inputSlotID: String
        let modeID: String
        let durationSeconds: Double?
        let assetDurationSeconds: Double?
        let expectedSourceShotID: String?

        init(
            id: String,
            modality: AssetPhysicalModalityV1,
            isRequired: Bool = false,
            semanticJobID: String = "fixture.reference",
            priority: Int = 0,
            preservationScopeIDs: [String] = [],
            exclusions: [String] = [],
            inputSlotID: String? = nil,
            modeID: String = "text-to-video",
            durationSeconds: Double? = nil,
            assetDurationSeconds: Double? = nil,
            expectedSourceShotID: String? = nil
        ) {
            self.id = id
            self.modality = modality
            self.isRequired = isRequired
            self.semanticJobID = semanticJobID
            self.priority = priority
            self.preservationScopeIDs = preservationScopeIDs
            self.exclusions = exclusions
            self.inputSlotID = inputSlotID ?? "reference.\(modality.rawValue)"
            self.modeID = modeID
            self.durationSeconds = durationSeconds
            self.assetDurationSeconds = assetDurationSeconds ?? durationSeconds
            self.expectedSourceShotID = expectedSourceShotID
        }
    }

    private struct Fixture {
        let projectRoot: URL
        let dataRoot: URL
        let graph: AssetGraphV1
        let demandSet: ReferenceDemandSetV1

        var demandIDs: [String] { demandSet.demands.map(\.id) }

        func remove() {
            try? FileManager.default.removeItem(at: projectRoot)
        }
    }

    private enum FixtureError: Error {
        case expectedPlan
    }
}
