import Foundation
import NexGenEngine

enum PipelineShotDelivery {
    static func modes(dataRoot: URL) throws -> [String: ShotDeliveryModeV1] {
        let plan = try PipelineExecutionPlanWriter.load(dataRoot: dataRoot).0
        var result: [String: ShotDeliveryModeV1] = [:]
        for shot in plan.shots where shot.sourceMode != .imported {
            guard let mode = ShotDeliveryModeResolverV1.resolve(shot) else {
                throw PipelineExecutionPlanError.persistedArtifactInvalid(
                    "Shot \(shot.id) has no executable visual delivery mode."
                )
            }
            result[shot.id] = mode
        }
        return result
    }

    static func stillShotIDs(dataRoot: URL) throws -> Set<String> {
        Set(try modes(dataRoot: dataRoot).compactMap {
            $0.value == .timelineAnimatedStill ? $0.key : nil
        })
    }
}
