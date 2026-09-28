import Foundation
import NexGenEngine

enum PipelineGateEvidenceValidator {
    nonisolated static func requireCurrent(
        phase: String,
        dataRoot: URL,
        requirement: EngineRegistry.GateRequirement?
    ) throws {
        try GateGuard.checkApprovable(
            phase: phase,
            dataRoot: dataRoot,
            requirement: requirement
        )
        if phase == "production_design" {
            _ = try ProductionStyleStoreV1.load(dataRoot: dataRoot)
        }
        if phase == "treatment" {
            _ = try StoryCausalityStoreV1.requireCurrent(dataRoot: dataRoot)
        }
        if phase == "storyboard" {
            _ = try StoryboardCausalityV1.requireCurrent(dataRoot: dataRoot)
        }
        if phase == "frames" {
            try FrameObservationStoreV1.requireProjectStyleFrames(
                dataRoot: dataRoot
            )
        }
        if phase == "render" {
            try TakeReview.requireSelected(dataRoot: dataRoot, phase: "final")
        }
        if phase == "shotlist" {
            try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)
            try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(
                dataRoot: dataRoot
            )
            try PipelineLineageStore.requireCurrent(
                phase: PipelineExecutionPlanWriter.lineagePhaseID,
                snapshot: try PipelineExecutionPlanWriter.lineageSnapshot(
                    dataRoot: dataRoot
                ),
                dataRoot: dataRoot
            )
        }
    }
}
