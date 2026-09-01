import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Pipeline execution shot inputs")
struct PipelineExecutionShotInputTests {
    @Test("shotlist tool publishes three closed execution variants")
    func schemaVariants() throws {
        let root = try #require(
            PipelineArtifactWriteContract.shotlistSchema["properties"]
                as? [String: [String: Any]]
        )
        let executionShots = try #require(root["execution_shots"])
        let items = try #require(executionShots["items"] as? [String: Any])
        let variants = try #require(items["anyOf"] as? [[String: Any]])
        #expect(variants.count == 3)

        let required = Set(
            PipelineArtifactWriteContract.shotlistSchema["required"] as? [String] ?? []
        )
        #expect(required.contains("execution_shots"))

        let keyed = try Dictionary(uniqueKeysWithValues: variants.map { variant in
            let properties = try #require(
                variant["properties"] as? [String: [String: Any]]
            )
            let source = try #require(properties["source_mode"]?["enum"] as? [String])
            return (try #require(source.first), properties)
        })
        #expect(keyed[ExecutionSourceModeV1.generated.rawValue]?["generation_requirement"] != nil)
        #expect(keyed[ExecutionSourceModeV1.aiEnhanced.rawValue]?["generation_requirement"] != nil)
        #expect(keyed[ExecutionSourceModeV1.imported.rawValue]?["generation_requirement"] == nil)
        #expect(keyed[ExecutionSourceModeV1.imported.rawValue]?["core_inputs"] == nil)
        #expect(keyed[ExecutionSourceModeV1.imported.rawValue]?["reference_demands"] == nil)
        for sourceMode in [
            ExecutionSourceModeV1.generated.rawValue,
            ExecutionSourceModeV1.aiEnhanced.rawValue,
        ] {
            let requirement = try #require(
                keyed[sourceMode]?["generation_requirement"]
            )
            let properties = try #require(
                requirement["properties"] as? [String: [String: Any]]
            )
            #expect(properties["modality_id"]?["enum"] as? [String] == ["video"])

            let coreInputs = try #require(keyed[sourceMode]?["core_inputs"])
            let coreProperties = try #require(
                coreInputs["properties"] as? [String: [String: Any]]
            )
            #expect(coreProperties["audio_timing_mode_id"] != nil)
        }
    }

    @Test("decoder rejects fields from a different source-mode variant")
    func rejectsCrossVariantFields() throws {
        var imported = commonInput(sourceMode: .imported)
        imported["primary_action"] = "Hold the final pose."
        imported["camera"] = ["movement_id": "locked"]
        imported["continuity_locks"] = []
        imported["renderability"] = "green"
        imported["risks"] = []

        let validData = try JSONSerialization.data(withJSONObject: imported)
        let decoded = try JSONDecoder().decode(
            PipelineExecutionShotInput.self,
            from: validData
        )
        #expect(decoded.sourceMode == .imported)

        imported["generation_requirement"] = generationRequirement()

        let data = try JSONSerialization.data(withJSONObject: imported)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PipelineExecutionShotInput.self, from: data)
        }
    }

    @Test("generated input modes use the shared canonical identifier")
    func canonicalGeneratedModes() throws {
        var generated = commonInput(sourceMode: .generated)
        generated["generation_requirement"] = [
            "modality_id": "video",
            "mode_ids": ["IMAGE_TO_VIDEO"],
            "duration": ["allows_automatic": true],
            "requires_output_audio": false,
        ]
        generated["core_inputs"] = [
            "first_frame_mode_id": "image-to-video",
        ]
        generated["reference_demands"] = []

        let data = try JSONSerialization.data(withJSONObject: generated)
        let decoded = try JSONDecoder().decode(
            PipelineExecutionShotInput.self,
            from: data
        )
        #expect(decoded.coreInputs?.firstFrameModeID == "image-to-video")
    }

    @Test("blocking entity identifiers are unique after canonicalization")
    func canonicalBlockingUniqueness() throws {
        var imported = commonInput(sourceMode: .imported)
        imported["primary_action"] = "Hold the final pose."
        imported["camera"] = ["movement_id": "locked"]
        imported["continuity_locks"] = []
        imported["renderability"] = "green"
        imported["risks"] = []
        imported["blocking"] = [
            ["entity_id": "Claude_Mouse", "performance": "Hold."],
            ["entity_id": " claude-mouse ", "performance": "Turn."],
        ]

        let data = try JSONSerialization.data(withJSONObject: imported)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PipelineExecutionShotInput.self, from: data)
        }
    }

    @Test("a chained shot declares audio timing only through core inputs")
    func chainedAudioTimingCoreInput() throws {
        var chained = commonInput(sourceMode: .generated)
        chained["generation_requirement"] = [
            "modality_id": "video",
            "mode_ids": ["image-to-video", "audio-to-video"],
            "duration": ["allows_automatic": true],
            "requires_output_audio": false,
        ]
        chained["core_inputs"] = [
            "predecessor_last_frame_mode_id": "image-to-video",
            "audio_timing_mode_id": "audio-to-video",
        ]
        chained["reference_demands"] = []

        let data = try JSONSerialization.data(withJSONObject: chained)
        let decoded = try JSONDecoder().decode(
            PipelineExecutionShotInput.self,
            from: data
        )
        #expect(decoded.coreInputs?.audioTimingModeID == "audio-to-video")
        #expect(decoded.referenceDemands.isEmpty)

        chained["reference_demands"] = [audioTimingDemand()]
        let invalid = try JSONSerialization.data(withJSONObject: chained)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PipelineExecutionShotInput.self, from: invalid)
        }
    }

    @Test("timed beats cannot exceed the owning shot duration")
    func timedBeatShotDuration() throws {
        var generated = commonInput(sourceMode: .generated)
        generated["generation_requirement"] = [
            "modality_id": "video",
            "mode_ids": ["text-to-video"],
            "duration": [
                "maximum_seconds": 10,
                "allows_automatic": false,
            ],
            "requires_output_audio": false,
        ]
        generated["core_inputs"] = [:]
        generated["reference_demands"] = []
        generated["timed_action_beats"] = [[
            "time_seconds": 5,
            "action": "Turn toward camera.",
        ]]

        let data = try JSONSerialization.data(withJSONObject: generated)
        let decoded = try JSONDecoder().decode(
            PipelineExecutionShotInput.self,
            from: data
        )
        #expect(throws: PipelineExecutionShotInputValidationError.invalid(
            "execution_shot[shot-001].timed_action_beats[0]"
        )) {
            try decoded.validate(timedBeatMaximumSeconds: 4)
        }
    }

    private func commonInput(sourceMode: ExecutionSourceModeV1) -> [String: Any] {
        [
            "id": "shot-001",
            "source_mode": sourceMode.rawValue,
            "start_state": [
                "summary": "The performer waits at the doorway.",
                "entity_state_ids": [],
            ],
            "end_state": [
                "summary": "The performer faces the room.",
                "entity_state_ids": [],
            ],
            "blocking": [],
            "timed_action_beats": [],
            "acceptance": [[
                "id": "acceptance-001",
                "requirement": "The performer remains identifiable.",
                "severity": "required",
            ]],
        ]
    }

    private func generationRequirement() -> [String: Any] {
        [
            "modality_id": "video",
            "mode_ids": ["text-to-video"],
            "duration": ["allows_automatic": true],
            "requires_output_audio": false,
        ]
    }

    private func audioTimingDemand() -> [String: Any] {
        [
            "id": "audio-timing",
            "asset_path": "audio/track.wav",
            "modality": "audio",
            "semantic_job_id": "CORE.AUDIO_TIMING",
            "is_required": true,
            "priority": 0,
            "preservation_scope_ids": [],
            "exclusion_demand_ids": [],
            "input_slot_id": CoreReferenceInputSlotIDV1.audioTiming,
            "mode_id": "audio-to-video",
            "identity_lock": false,
            "canon_ids": [],
        ]
    }

}
