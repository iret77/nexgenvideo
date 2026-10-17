import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Pipeline execution-plan composer contract")
struct PipelineExecutionPlanComposerContractTests {
    @MainActor
    @Test("fractional shots route the whole render including handles through the provider envelope")
    func renderDurationMatchesProviderRequest() throws {
        for (net, mode, expected) in [(3.5, CutHandlesMode.backToBack, 4), (4.0, .withOverlap, 6), (3.5, .withOverlap, 6)] {
            let requirement = try durationRequirement(net: net, mode: mode)
            #expect(requirement.duration?.preferredSeconds == Double(expected))
            let input = PipelineProductionRoutingTests.generationInput(requirement: requirement)
            let proof = try #require(input.productionRouting)
            let target = ResolvedGenerationTarget(
                modelId: input.model, provider: .fal, endpoint: input.model,
                binding: ProviderBinding(
                    provider: .fal, transport: .api, kind: .generation,
                    providerRef: input.model, billing: .perCall,
                    productionInputPolicy: proof.offeringCapabilities.inputPolicy,
                    resolvedVideoCapabilities: proof.offeringCapabilities
                )
            )
            try PipelineProductionRouting.validateProviderEnvelope(
                genInput: input, target: target,
                params: .video(VideoGenerationParams(
                    prompt: input.prompt, duration: .seconds(expected),
                    aspectRatio: input.aspectRatio, resolution: input.resolution,
                    generateAudio: false
                )), uploadedReferences: []
            )
            #expect(throws: PipelineProductionRoutingError.self) {
                try PipelineProductionRouting.validateProviderEnvelope(
                    genInput: input, target: target,
                    params: .video(VideoGenerationParams(
                        prompt: input.prompt, duration: .seconds(expected - 1),
                        aspectRatio: input.aspectRatio, resolution: input.resolution,
                        generateAudio: false
                    )), uploadedReferences: []
                )
            }
        }
    }

    @Test("render bounds reject a net-only maximum instead of dropping handles")
    func renderDurationRejectsContradictoryBounds() throws {
        #expect(throws: PipelineExecutionShotInputValidationError.self) {
            _ = try durationRequirement(net: 4, mode: .withOverlap, maximum: 4)
        }
        let requirement = try durationRequirement(net: 4, mode: .withOverlap, maximum: 6)
        #expect(requirement.duration?.maximumSeconds == 6)
        #expect(requirement.duration?.preferredSeconds == 6)
    }

    private func durationRequirement(net: Double, mode: CutHandlesMode, maximum: Double = 15) throws -> GenerationRequirementV1 {
        let shot = try Shot(id: "s001", timeStart: 0, timeEnd: net, durationS: net,
            type: .bRoll, description: "Clouds move", visualPrompt: "Clouds move", mood: "calm", keyframeStrategy: .none)
        let brief = try Brief(project: "duration-fixture", generated: "2026-10-17", mission: .demo,
            targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "narrative",
            conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none,
            lyricsIntegration: .ignored, cutHandlesMode: mode)
        let json: [String: Any] = [
            "id": shot.id, "source_mode": "generated",
            "start_state": ["summary": "Clouds enter", "entity_state_ids": []],
            "end_state": ["summary": "Clouds leave", "entity_state_ids": []],
            "blocking": [], "timed_action_beats": [], "reference_demands": [],
            "acceptance": [["id": "clouds", "requirement": "Clouds move", "severity": "required"]],
            "core_inputs": [:],
            "generation_requirement": [
                "modality_id": "video", "mode_ids": ["text-to-video"],
                "duration": ["minimum_seconds": 1, "maximum_seconds": maximum, "allows_automatic": false],
                "requires_output_audio": false,
            ],
        ]
        let input = try JSONDecoder().decode(PipelineExecutionShotInput.self, from: JSONSerialization.data(withJSONObject: json))
        return try #require(PipelineExecutionPlanComposer.generationRequirement(
            shot: shot, input: input, sourceAssetID: nil, demandAssetIDs: [:], brief: brief, bible: nil
        ))
    }

    @Test("shot references and execution demands have the same exact path set")
    func exactReferencePathSet() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = demand(id: "first", path: "refs/first.png")
        let second = demand(id: "second", path: "refs/second.png")

        try PipelineExecutionPlanComposer.validateReferenceCorrespondence(
            shotID: "shot-001",
            referenceImageRefs: ["refs/first.png"],
            referenceDemands: [first],
            dataRoot: fixture.dataRoot
        )

        #expect(throws: PipelineExecutionPlanComposerError.referenceSetMismatch(
            "shot-001"
        )) {
            try PipelineExecutionPlanComposer.validateReferenceCorrespondence(
                shotID: "shot-001",
                referenceImageRefs: ["refs/first.png", "refs/second.png"],
                referenceDemands: [first],
                dataRoot: fixture.dataRoot
            )
        }
        #expect(throws: PipelineExecutionPlanComposerError.referenceSetMismatch(
            "shot-001"
        )) {
            try PipelineExecutionPlanComposer.validateReferenceCorrespondence(
                shotID: "shot-001",
                referenceImageRefs: ["refs/first.png"],
                referenceDemands: [first, second],
                dataRoot: fixture.dataRoot
            )
        }
    }

    @Test("identity assets are unique and stable after reference merging")
    func mergedIdentityAssetIDs() throws {
        let identifiers = try PipelineExecutionPlanComposer.identityAssetIDs(
            referenceDemands: [
                demand(id: "first", path: "refs/first.png"),
                demand(id: "duplicate", path: "refs/first.png"),
                demand(id: "second", path: "refs/second.png"),
            ],
            demandAssetIDs: [
                "first": "asset-b",
                "duplicate": "asset-b",
                "second": "asset-a",
            ]
        )

        #expect(identifiers == ["asset-a", "asset-b"])
        #expect(throws: PipelineExecutionPlanComposerError.invalidReference("first")) {
            _ = try PipelineExecutionPlanComposer.identityAssetIDs(
                referenceDemands: [demand(id: "first", path: "refs/first.png")],
                demandAssetIDs: [:]
            )
        }
    }

    @Test("blocking aliases emit the Shot character reference spelling")
    func canonicalBlockingOutput() throws {
        let shotBlocking = try CharacterBlocking(
            characterRef: "Claude_Mouse",
            position: "left third",
            pose: "standing",
            gaze: "toward camera",
            relationToSet: "beside the doorway"
        )
        let blocking = try PipelineExecutionPlanComposer.executionBlocking(
            shotID: "shot-001",
            shotBlocking: [shotBlocking],
            inputBlocking: [
                PipelineExecutionBlockingInput(
                    entityID: " claude-mouse ",
                    anchorDemandID: nil,
                    performance: "Hold the mark."
                ),
            ],
            demandAssetIDs: [:]
        )

        #expect(blocking.map(\.entityID) == ["Claude_Mouse"])
    }

    @Test("core semantic aliases never become generic reference jobs")
    func canonicalCoreDemandAlias() {
        let input = PipelineReferenceDemandInput(
            id: "audio-timing",
            assetPath: "media/shot-audio.m4a",
            modality: .audio,
            semanticJobID: "core.audio_timing",
            isRequired: true,
            priority: 0,
            preservationScopeIDs: [],
            exclusionDemandIDs: [],
            inputSlotID: "core.input.audio_timing",
            modeID: "audio-to-video",
            identityLock: false,
            entityID: nil,
            canonIDs: [],
            stateID: nil,
            viewID: nil
        )

        #expect(PipelineExecutionPlanComposer.genericReferenceDemandIDs([input]).isEmpty)
    }

    private func demand(id: String, path: String) -> PipelineReferenceDemandInput {
        PipelineReferenceDemandInput(
            id: id,
            assetPath: path,
            modality: .image,
            semanticJobID: "look.identity",
            isRequired: true,
            priority: 1,
            preservationScopeIDs: [],
            exclusionDemandIDs: [],
            inputSlotID: "reference.image",
            modeID: "reference-to-video",
            identityLock: true,
            entityID: "Claude Mouse",
            canonIDs: [],
            stateID: nil,
            viewID: nil
        )
    }

    private struct Fixture {
        let projectRoot: URL
        let dataRoot: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            projectRoot = root
            dataRoot = root.appendingPathComponent("pipeline", isDirectory: true)
            let references = dataRoot.appendingPathComponent("refs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: references,
                withIntermediateDirectories: true
            )
            try Data("first".utf8).write(
                to: references.appendingPathComponent("first.png")
            )
            try Data("second".utf8).write(
                to: references.appendingPathComponent("second.png")
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: projectRoot)
        }
    }
}
