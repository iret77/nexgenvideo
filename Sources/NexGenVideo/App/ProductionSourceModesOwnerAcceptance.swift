import AppKit
import NexGenEngine

@MainActor
enum ProductionSourceModesOwnerAcceptance {
    enum Kind: String, CaseIterable {
        case aiEnhanced, frameContinuation, nativeExtension, animatedStill
    }

    static func assignDraft(_ kind: Kind, context: ProductionPlanningAcceptanceFixture.Context,
                            sourceVideo: URL, driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot
        let original = try await readDraft(root)
        guard original.shots.count == 2, context.editor.projectState?.nextPhaseName == "shot_planning" else {
            throw GateBlocked("The source-mode owner case requires the actual two-shot pending Shot Planning document.")
        }
        try await ProductionV2PlanningAcceptance.selectPhase("shot_planning", context: context, driver: driver)
        switch kind {
        case .aiEnhanced:
            let target = original.shots[0].shotID
            try await driver.picker("shot-planning.source-mode." + target, title: "AI-enhanced footage",
                expected: SourceMode.aiEnhanced.rawValue, in: driver.window)
            let beforeCancel = try await readDraft(root)
            try await driver.chooseFile(nil, in: driver.window, trigger: "shot-planning.choose-source." + target)
            guard try await readDraft(root) == beforeCancel else { throw GateBlocked("Cancel changed the native AI source binding.") }
            let beforeAttach = context.editor.engineStateRevision
            try await driver.chooseFile(sourceVideo, in: driver.window, trigger: "shot-planning.choose-source." + target)
            try await driver.wait("native AI source selected", seconds: 30) {
                context.editor.engineStateRevision > beforeAttach
                    && driver.text("shot-planning.source-end." + target, in: driver.window) != nil
            }
            try await driver.fill("shot-planning.source-start." + target, value: "1", in: driver.window)
            try await driver.fill("shot-planning.source-end." + target, value: "7", in: driver.window)
            try await apply(target, context: context, driver: driver)
            let selected = try await readDraft(root)
            guard let intent = selected.shots.first(where: { $0.shotID == target }), intent.sourceMode == .aiEnhanced,
                  let source = intent.source, let range = intent.sourceInputRange,
                  range.startTicks == range.timebase.ticksPerSecond,
                  range.durationTicks == 6 * range.timebase.ticksPerSecond,
                  source.sha256 == (try await Task.detached { try FileDigest.sha256(of: sourceVideo) }.value) else {
                throw GateBlocked("The AI source mode or explicit 1…7-second original conditioning interval was not natively stored.")
            }
            let board = try await Task.detached { try PlanningWriterIO.storyboard(dataRoot: root) }.value
            guard let planned = board.timing.shots.first(where: { $0.id == target }),
                  !range.timebase.representsSameTime(range.durationTicks, as: planned.durationTicks, timebase: board.timing.timebase) else {
                throw GateBlocked("The AI input case must actually distinguish original conditioning duration from final editorial duration.")
            }
            try driver.record("native exact AI source range", fields: ["shotID": target, "sourceSHA256": source.sha256,
                "sourcePath": source.path, "sourceStartTicks": range.startTicks, "sourceDurationTicks": range.durationTicks,
                "sourceTimebase": range.timebase.ticksPerSecond, "plannedDurationTicks": planned.durationTicks,
                "plannedTimebase": board.timing.timebase.ticksPerSecond, "inputRangeIsSeparate": true])
        case .frameContinuation, .nativeExtension:
            let target = original.shots[1].shotID, predecessor = original.shots[0].shotID
            guard original.shots[0].sourceMode == .generated else { throw GateBlocked("A real Chain needs the actual generated predecessor.") }
            try await driver.picker("shot-planning.source-mode." + target, title: "AI generation",
                expected: SourceMode.generated.rawValue, in: driver.window)
            if driver.text("shot-planning.connection." + target, in: driver.window) == nil {
                try await driver.click("shot-planning.camera.disclosure." + target, in: driver.window, enabled: false)
            }
            let chain = kind == .frameContinuation
                ? ShotPlanningDraftV1.ShotIntent.ChainKind.frameContinuation : .nativeExtension
            try await driver.picker("shot-planning.connection." + target,
                title: kind == .frameContinuation ? "Continue from the previous final frame" : "Extend the previous video",
                expected: chain.rawValue, in: driver.window)
            try await driver.picker("shot-planning.predecessor." + target, title: "Shot 1", expected: predecessor, in: driver.window)
            try await apply(target, context: context, driver: driver)
            let selected = try await readDraft(root)
            guard let intent = selected.shots.first(where: { $0.shotID == target }), intent.sourceMode == .generated,
                  intent.source == nil, intent.sourceInputRange == nil, intent.chainKind == chain,
                  intent.predecessorShotID == predecessor else {
                throw GateBlocked("The native Connection picker lost its explicit chain or retained an unrelated imported source.")
            }
            try driver.record("native chain selection", fields: ["shotID": target, "predecessorShotID": predecessor,
                "kind": chain.rawValue, "sourceMode": intent.sourceMode.rawValue, "sourceCleared": true])
        case .animatedStill:
            guard original.shots[0].sourceMode == .generated,
                  original.shots[0].chainKind == .none else { throw GateBlocked("Animated-still delivery needs an independent generated shot.") }
        }
        let final = try await readDraft(root)
        guard final.shots.map(\.shotID) == original.shots.map(\.shotID) else {
            throw GateBlocked("Choosing a production source mode replaced stable Shot identities.")
        }
    }

    static func selectAnimatedStill(context: ProductionPlanningAcceptanceFixture.Context,
                                    driver: ProductionVisualSourcesDriver) async throws -> ProductionPlanProjectionV1 {
        let root = context.dataRoot
        let prior = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        guard let shot = prior.shots.first, shot.sourceMode == .generated,
              ShotDeliveryModeResolverV1.resolve(shot) == .providerVideo,
              context.editor.projectState?.nextPhaseName == "shotlist" else {
            throw GateBlocked("Choose Animated still on the actual unapproved technical Shot List.")
        }
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
        try await driver.click("production.plan.edit." + shot.id, in: driver.window)
        let sheet = try await driver.sheet("production.technical.delivery")
        try await driver.picker("production.technical.delivery", title: "Animated still",
            expected: ShotDeliveryModeV1.timelineAnimatedStill.rawValue, in: sheet)
        try driver.capture("animated-still-delivery", target: sheet)
        try await driver.click("production.technical.apply", in: sheet)
        try await driver.wait("native still delivery published", seconds: 30) { driver.window.attachedSheet == nil }
        let selected = try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
        guard let changed = selected.shots.first, let timing = selected.timing(for: shot.id),
              changed.id == shot.id, selected.shots.map(\.id) == prior.shots.map(\.id),
              ShotDeliveryModeResolverV1.resolve(changed) == .timelineAnimatedStill,
              selected.timings.map(\.durationTicks) == prior.timings.map(\.durationTicks),
              timing.nativeDurationTicks == nil, timing.sourceInTicks == 0 else {
            throw GateBlocked("Native still delivery changed the canonical edit or retained a final provider-video trim.")
        }
        let promotion = try await Task.detached {
            try PipelineShotPlanningPromotionStore.requireCurrent(projection: selected, dataRoot: root)
        }.value
        guard !promotion.routes.contains(where: { $0.shotID == shot.id }) else {
            throw GateBlocked("Animated-still delivery retained a paid final-video route.")
        }
        try driver.record("native animated-still delivery", fields: ["shotID": shot.id,
            "revision": selected.header.revision, "durationTicks": timing.durationTicks,
            "timebase": selected.timebase.ticksPerSecond, "finalVideoRoute": false,
            "finalProviderGenerationClaim": false])
        return selected
    }

    private static func apply(_ shotID: String, context: ProductionPlanningAcceptanceFixture.Context,
                              driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot
        let revision = try await readDraft(root).header.revision
        let engineRevision = context.editor.engineStateRevision
        try await driver.click("shot-planning.apply." + shotID, in: driver.window)
        try await driver.wait("native source mode applied", seconds: 30) {
            context.editor.engineStateRevision > engineRevision
        }
        guard try await readDraft(root).header.revision > revision else { throw GateBlocked("Native input did not append its canonical Shot Planning revision.") }
    }

    private static func readDraft(_ root: URL) async throws -> ShotPlanningDraftV1 {
        try await Task.detached {
            try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root,
                storyboard: PlanningWriterIO.storyboard(dataRoot: root))
        }.value
    }
}
