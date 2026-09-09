import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Musicvideo production prompt projection")
struct PipelineMusicvideoProductionWriterTests {
    @Test("approved visual-arc parameters reach only their bound shots")
    func visualArcParametersBecomeDirectives() {
        let arc = MusicVisualArcDraftV1(
            concept: "A recurring doorway changes with the chorus.",
            motifs: [MusicArcMotifV1(
                id: "doorway",
                description: "The doorway remains the spatial anchor.",
                setupIDs: ["wide"]
            )],
            sections: [MusicArcSectionV1(
                sectionID: "chorus-2",
                musicalFunction: "second release",
                visualFunction: "widen the performance",
                motifIDs: ["doorway"],
                shotIDs: ["s002"],
                constants: [MusicArcParameterV1(
                    kind: .lighting,
                    targetID: "doorway",
                    value: "keep the amber doorway practical",
                    rationale: "Preserve recognition across choruses."
                )],
                variations: [MusicArcParameterV1(
                    kind: .camera,
                    targetID: "wide",
                    value: "increase lateral travel to two meters",
                    rationale: "Express the second chorus expansion."
                )],
                lyricsRelation: .unused,
                changeExplanation: "The motif stays constant while camera energy increases."
            )]
        )

        let directives = PipelineMusicvideoProductionWriter.visualArcDirectives(
            visualArc: arc,
            shotID: "s002"
        )
        #expect(directives.contains { $0.contains("keep the amber doorway practical") })
        #expect(directives.contains { $0.contains("increase lateral travel to two meters") })
        #expect(directives.contains { $0.contains("chorus-2") })
        #expect(PipelineMusicvideoProductionWriter.visualArcDirectives(
            visualArc: arc,
            shotID: "unbound-shot"
        ).isEmpty)
    }

    @Test("generated coverage requires exact reference demands while imported coverage does not")
    func coverageBindsGenerationReferences() throws {
        let generated = try executionInput(
            sourceMode: .generated,
            referenceDemands: [referenceDemand()]
        )
        let covered = coverage(referenceDemandIDs: ["dancer-full-body"])
        try PipelineMusicvideoProductionWriter.validateCoverageReferences(
            [covered],
            inputs: [generated.id: generated]
        )
        let directives = PipelineMusicvideoProductionWriter.coverageDirectives(
            coverage: [covered],
            shotID: generated.id
        )
        #expect(directives.contains { $0.contains("keep the full body visible") })
        #expect(directives.contains { $0.contains("keep floor contact visible") })

        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try PipelineMusicvideoProductionWriter.validateCoverageReferences(
                [coverage(referenceDemandIDs: [])],
                inputs: [generated.id: generated]
            )
        }

        let imported = try executionInput(sourceMode: .imported, referenceDemands: [])
        try PipelineMusicvideoProductionWriter.validateCoverageReferences(
            [coverage(referenceDemandIDs: [])],
            inputs: [imported.id: imported]
        )
    }

    private func coverage(referenceDemandIDs: [String]) -> MusicPerformanceCoverageItemV1 {
        MusicPerformanceCoverageItemV1(
            id: "dance-chorus",
            sectionIDs: ["chorus"],
            kind: .dance,
            requiredRoleIDs: ["master"],
            evidence: [MusicCoverageEvidenceV1(
                roleID: "master",
                shotIDs: ["s001"],
                performerIDs: ["dancer"],
                setupIDs: ["wide"],
                showsFullBody: true,
                showsFloorContact: true,
                showsHandsAndOrientation: false,
                minimumContinuousSeconds: 4,
                assemblyRoleID: "dance-master",
                referenceDemandIDs: referenceDemandIDs
            )],
            approvedExceptionRoleIDs: [],
            choreographyBeatIDs: ["chorus-hit"]
        )
    }

    private func executionInput(
        sourceMode: ExecutionSourceModeV1,
        referenceDemands: [[String: Any]]
    ) throws -> PipelineExecutionShotInput {
        var value: [String: Any] = [
            "id": "s001",
            "source_mode": sourceMode.rawValue,
            "start_state": ["summary": "The dancer is centered.", "entity_state_ids": []],
            "end_state": ["summary": "The dancer lands on beat.", "entity_state_ids": []],
            "blocking": [],
            "timed_action_beats": [],
            "acceptance": [[
                "id": "coverage",
                "requirement": "The complete dance phrase remains visible.",
                "severity": "required",
            ]],
        ]
        if sourceMode == .imported {
            value["primary_action"] = "Perform the complete dance phrase."
            value["camera"] = ["movement_id": "locked"]
            value["continuity_locks"] = []
            value["renderability"] = "green"
            value["risks"] = []
        } else {
            value["generation_requirement"] = [
                "modality_id": "video",
                "mode_ids": ["image-to-video"],
                "duration": ["allows_automatic": true],
                "requires_output_audio": false,
            ]
            value["core_inputs"] = [:]
            value["reference_demands"] = referenceDemands
        }
        return try JSONDecoder().decode(
            PipelineExecutionShotInput.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    private func referenceDemand() -> [String: Any] {
        [
            "id": "dancer-full-body",
            "asset_path": "bible/dancer-full-body.png",
            "modality": "image",
            "semantic_job_id": "identity.full-body",
            "is_required": true,
            "priority": 100,
            "preservation_scope_ids": ["identity"],
            "exclusion_demand_ids": [],
            "input_slot_id": CoreReferenceInputSlotIDV1.referenceImage,
            "mode_id": "image-to-video",
            "identity_lock": true,
            "entity_id": "dancer",
            "canon_ids": ["dancer-v1"],
            "view_id": "full-body",
        ]
    }
}
