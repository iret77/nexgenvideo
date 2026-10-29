import Foundation

public struct ProductionMusicCoverageRequirementV2: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let roleID: String
    public let shotIDs: [String]
    public let checks: [String]
    public let minimumContinuousSeconds: Double

    public init(id: String, roleID: String, shotIDs: [String], checks: [String], minimumContinuousSeconds: Double) {
        self.id = id; self.roleID = roleID; self.shotIDs = shotIDs; self.checks = checks
        self.minimumContinuousSeconds = minimumContinuousSeconds
    }

    public static func requirements(for value: MusicvideoProductionExtensionV2) throws -> [Self] {
        var result: [Self] = []
        for item in value.coverage {
            for role in item.requiredRoleIDs where !item.approvedExceptionRoleIDs.contains(role) {
                guard let evidence = item.evidence.first(where: { $0.roleID == role }) else {
                    throw ProductionPlanningError.invalid("sequenceReview.musicCoverageMissing")
                }
                var checks = ["Confirm this required \(item.kind.rawValue) role is visible in the final edited film."]
                if evidence.showsFullBody { checks.append("The full body remains visible.") }
                if evidence.showsFloorContact { checks.append("Floor contact remains visible.") }
                if evidence.showsHandsAndOrientation { checks.append("The hands and instrument orientation remain visible.") }
                if item.kind == .stagedVocal { checks.append("The intended mouth performance is visible and matches the song.") }
                checks.append("Observe at least \(evidence.minimumContinuousSeconds) continuous seconds.")
                result.append(.init(id: "coverage." + item.id + "." + role, roleID: role, shotIDs: evidence.shotIDs,
                    checks: checks, minimumContinuousSeconds: evidence.minimumContinuousSeconds))
            }
        }
        for segment in value.performanceSegments {
            result.append(.init(id: "performance." + segment.draft.id, roleID: segment.draft.routeInputRoleID,
                shotIDs: segment.draft.shotIDs, checks: ["Check the actual performance against its declared song phrase and final mix; listen for unintended duplicated provider song audio."],
                minimumContinuousSeconds: 0))
            for (index, mouth) in segment.draft.mouthOwnership.enumerated() {
                result.append(.init(id: "mouth." + segment.draft.id + "." + String(index), roleID: mouth.performerID,
                    shotIDs: segment.draft.shotIDs, checks: ["Confirm the visible mouth of performer \(mouth.performerID) belongs to voice \(mouth.voiceID) from \(mouth.timelineStartSeconds) to \(mouth.timelineEndSeconds) song seconds."],
                    minimumContinuousSeconds: 0))
            }
        }
        return result
    }
}

public struct ProductionMusicCoverageObservationV2: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let visible: Bool
    public let startFrame: Int
    public let endFrame: Int
    public let evidence: String

    public init(id: String, visible: Bool, startFrame: Int, endFrame: Int, evidence: String) {
        self.id = id; self.visible = visible; self.startFrame = startFrame; self.endFrame = endFrame; self.evidence = evidence
    }

    public static func validate(_ values: [Self], requirements: [ProductionMusicCoverageRequirementV2],
                                edl: ProductionSequenceEDLV2, durationFrames: Int, rejectBlocking: Bool) throws {
        try PlanningValidation.unique(requirements.map(\.id), "sequenceReview.musicRequirements")
        try PlanningValidation.unique(values.map(\.id), "sequenceReview.musicObservations")
        try PlanningValidation.require(Set(values.map(\.id)) == Set(requirements.map(\.id)), "sequenceReview.musicCoverageMissing")
        for requirement in requirements {
            guard let observation = values.first(where: { $0.id == requirement.id }) else {
                throw ProductionPlanningError.invalid("sequenceReview.musicCoverageMissing")
            }
            try PlanningValidation.text(observation.evidence, "sequenceReview.musicObservation")
            try PlanningValidation.require(observation.startFrame >= 0 && observation.endFrame > observation.startFrame
                && observation.endFrame <= durationFrames, "sequenceReview.musicObservationRange")
            if observation.visible {
                let seconds = Double(observation.endFrame - observation.startFrame) / edl.timebase.framesPerSecond
                try PlanningValidation.require(seconds >= requirement.minimumContinuousSeconds, "sequenceReview.musicContinuousCoverage")
            }
            if rejectBlocking { try PlanningValidation.require(observation.visible, "sequenceReview.musicCoverageNotVisible") }
        }
    }
}
