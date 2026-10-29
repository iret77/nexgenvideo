import Foundation
import NexGenEngine

enum MusicvideoProductionGateV2 {
    static func requireCurrent(phase: String, dataRoot: URL) throws {
        switch phase {
        case "analysis": try MusicvideoGateChecks.requireRealAnalysis(dataRoot: dataRoot)
        case "brief":
            try MusicvideoGateChecks.requireRealBrief(dataRoot: dataRoot)
            let range = try json(PlaybackRangeV1.self, path: PlaybackRangeV1.currentPath, root: dataRoot)
            try range.validate()
            try range.header.requireCurrentInputs(dataRoot: dataRoot)
        case "production_design": try MusicvideoGateChecks.requireRealProductionDesign(dataRoot: dataRoot)
        case "treatment": _ = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: dataRoot, approval: true)
        case "script": _ = try ProductionPlanningLineageV2.script(dataRoot: dataRoot)
        case "storyboard", "shot_planning":
            let board = try ProductionPlanningLineageV2.storyboard(dataRoot: dataRoot)
            try requireMusicTiming(board.timing, dataRoot: dataRoot)
            if phase == "shot_planning" {
                let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
                try ShotPlanningValidatorV1.validate(draft, timing: board.timing, approval: true)
            }
        case "bible":
            guard let bible = try loadBible(dataRoot: dataRoot) else { throw GateBlocked("The current production Bible is missing.") }
            try bible.validate()
        case "shotlist":
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            let board = try ProductionPlanningLineageV2.storyboard(dataRoot: dataRoot)
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: dataRoot, storyboard: board)
            let promotion = try json(ShotPlanningPromotionV1.self, path: ShotPlanningPromotionV1.currentPath, root: dataRoot)
            let graph = try json(AssetGraphV1.self, path: promotion.assetGraph.path, root: dataRoot)
            guard let bible = try loadBible(dataRoot: dataRoot) else { throw GateBlocked("The current production Bible is missing.") }
            try ShotPlanningPromotionValidatorV1.validate(promotion, draft: draft, timing: board.timing, bible: bible,
                assetGraph: graph, projection: projection)
            try requireMusicTiming(board.timing, dataRoot: dataRoot)
            try promotion.header.requireCurrentInputs(dataRoot: dataRoot)
            _ = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
        case "sanity":
            _ = try ProductionPlanAuditV1.requireCurrent(projection: ProductionPlanningLineageV2.projection(dataRoot: dataRoot), dataRoot: dataRoot)
        case "frames":
            _ = try ProductionPlanFramesV1.requireCurrent(projection: ProductionPlanningLineageV2.projection(dataRoot: dataRoot), dataRoot: dataRoot)
        case "render_review":
            let review = try json(RenderReviewV1.self, path: RenderReviewV1.currentPath, root: dataRoot)
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            _ = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
            try RenderReviewValidatorV1.validate(review, projection: projection, approval: true)
            try review.header.requireCurrentInputs(dataRoot: dataRoot)
        case "render":
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            let board = try ProductionPlanningLineageV2.storyboard(dataRoot: dataRoot)
            _ = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
            let assembly = try json(ProductionPlanAssemblyProofV1.self, path: ProductionPlanAssemblyProofV1.relativePath, root: dataRoot)
            try ProductionPlanAssemblyV1.validate(assembly, projection: projection, timing: board.timing)
            try assembly.header.requireCurrentInputs(dataRoot: dataRoot)
            for ref in assembly.artifactReferences { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        default: throw GateBlocked("This phase does not belong to the Music Video production contract.")
        }
    }

    static func requireMusicTiming(_ timing: StoryboardTimingV1, dataRoot: URL) throws {
        let range = try json(PlaybackRangeV1.self, path: PlaybackRangeV1.currentPath, root: dataRoot)
        try range.validate()
        try range.header.requireCurrentInputs(dataRoot: dataRoot)
        guard let track = range.header.inputs.first(where: { $0.role == "musicvideo.track" }),
              let audio = timing.audio, audio.source == track, audio.offsetTicks == 0,
              audio.durationTicks == range.audioDurationTicks, timing.timebase == range.timebase,
              timing.rangeStartTicks == (timing.mode == .multicam ? 0 : range.startTicks),
              timing.rangeDurationTicks == (timing.mode == .multicam ? range.audioDurationTicks : range.durationTicks) else {
            throw GateBlocked("The Music Video timing must bind the original approved song and exact native playback range. Multicam plans retain the full song before the selected output cut.")
        }
    }

    private static func json<T: Decodable>(_ type: T.Type, path: String, root: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root)))
    }
}
