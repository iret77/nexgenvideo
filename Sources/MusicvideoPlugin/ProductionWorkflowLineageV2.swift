import Foundation
import NexGenEngine

enum MusicvideoProductionLineageV2 {
    static let phases = ["analysis"] + Array(ProductionPlanningLineageV2.phases.dropFirst())
    static let executionInputPhases: Set<String> = ["analysis", "brief", "production_design", "treatment", "script", "storyboard", "shot_planning", "bible"]

    static func snapshot(phase: String, dataRoot: URL) throws -> PhaseLineageSnapshot {
        if phase == "analysis" { return try MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: dataRoot) }
        let base = try ProductionPlanningLineageV2.snapshot(phase: phase, dataRoot: dataRoot)
        let analysis = try MusicvideoPipelineLineage.snapshot(phase: "analysis", dataRoot: dataRoot)
        let bytes = try JSONSerialization.data(withJSONObject: ["core": base.inputFingerprint,
            "analysisInputs": analysis.inputFingerprint, "analysisArtifact": analysis.artifactFingerprint], options: [.sortedKeys])
        return PhaseLineageSnapshot(inputFingerprint: FileDigest.sha256(of: bytes), artifactFingerprint: base.artifactFingerprint)
    }

    static func artifactPaths(phase: String, dataRoot: URL) throws -> [String] {
        if phase == "analysis" { return try MusicvideoPipelineLineage.artifactPaths(phase: phase, dataRoot: dataRoot) }
        return try ProductionPlanningLineageV2.artifactPaths(phase: phase, dataRoot: dataRoot)
    }

    static func requireCurrent(phase: String, dataRoot: URL) throws {
        try PipelineLineageStore.requireCurrent(phase: phase, snapshot: snapshot(phase: phase, dataRoot: dataRoot), dataRoot: dataRoot)
    }
}
