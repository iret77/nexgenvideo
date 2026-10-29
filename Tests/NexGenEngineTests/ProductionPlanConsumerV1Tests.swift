import Foundation
import Testing
@testable import NexGenEngine

@Suite("Normalized production consumers")
struct ProductionPlanConsumerV1Tests {
    private let shotID = "shot-00000000-0000-0000-0000-000000000001"

    @Test func nestedIntervalsRetainTheEarlierLongestOverlap() {
        let findings = CoverageIntervalsV1.findings([
            .init(id: "long", startSeconds: 0, endSeconds: 10),
            .init(id: "short", startSeconds: 1, endSeconds: 2),
            .init(id: "later", startSeconds: 3, endSeconds: 4),
            .init(id: "adjacent", startSeconds: 10, endSeconds: 11)
        ], mode: .beat, rangeEndSeconds: 11)
        #expect(findings.map(\.code) == ["SHOT_OVERLAP", "SHOT_OVERLAP"])
        #expect(findings.map(\.shotId) == ["short", "later"])
        #expect(findings.allSatisfy { $0.message.contains("long") })
    }

    @Test func sharedCoverageRetainsStrictThresholdBoundaries() {
        let exactGaps = CoverageIntervalsV1.findings([.init(id: "one", startSeconds: 0.5, endSeconds: 1.5)],
                                                   mode: .beat, rangeEndSeconds: 2)
        #expect(exactGaps.isEmpty)
        let exactOverlap = CoverageIntervalsV1.findings([.init(id: "one", startSeconds: 0, endSeconds: 1),
            .init(id: "two", startSeconds: 0.99, endSeconds: 2)], mode: .section, rangeEndSeconds: 2)
        #expect(exactOverlap.isEmpty)
        let over = CoverageIntervalsV1.findings([.init(id: "one", startSeconds: 0, endSeconds: 1),
            .init(id: "two", startSeconds: 0.989, endSeconds: 2)], mode: .section, rangeEndSeconds: 2)
        #expect(over.map(\.level) == [.warn])
    }

    @Test func importedOnlyFramesRequireAnActuallyEmptyManifest() throws {
        let plan = projection()
        try ProductionPlanFramesV1.validate(.init(project: "fixture", generated: "fixture"), projection: plan)
        let invented = FramesManifest(project: "fixture", generated: "fixture", shots: [
            .init(shotId: shotID, keyframeStrategy: "start", frames: [])
        ])
        #expect(throws: ProductionPlanningError.self) { try ProductionPlanFramesV1.validate(invented, projection: plan) }
        #expect(try invented.reconciled(with: plan).shots.isEmpty)
    }

    @Test func endOnlyFrameUsesTheSameStrategyAsCanonicalValidation() throws {
        let base = projection(), imported = base.shots[0]
        let shot = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: imported.startState,
            endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
            renderability: .green, acceptance: imported.acceptance,
            generationRequirement: .init(modalityID: "video", modeIDs: ["keyframe"], visibleEntityCount: 0,
                requiresLastFrame: true))
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
            timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings,
            endFrameBoundaries: [shotID: .init(characterCount: 0, characterPositions: "", gaze: "", visibleZones: [])])
        let roles = plan.requiredFrameRoles(for: shotID)
        #expect(roles == ["end"])
        #expect(ProductionPlanFramesV1.strategy(roles) == "end")
        let frame = FrameEntry(role: "end", path: "frames/end.png", prompt: "A red square.",
            runwayModel: "fixture", providerPrompt: "A red square.")
        func manifest(_ strategy: String) -> FramesManifest {
            .init(project: "fixture", generated: "fixture", shots: [
                .init(shotId: shotID, keyframeStrategy: strategy, frames: [frame])])
        }
        try ProductionPlanFramesV1.validate(manifest(ProductionPlanFramesV1.strategy(roles)), projection: plan)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        object.removeValue(forKey: "endFrameBoundaries")
        let missing = try JSONDecoder().decode(ProductionPlanProjectionV1.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ProductionPlanningError.invalid("productionPlan.endFrameBoundaryCoverage")) {
            try ProductionPlanProjectionValidatorV1.validate(missing)
        }
        #expect(throws: ProductionPlanningError.invalid("frames.requiredRoles")) {
            try ProductionPlanFramesV1.validate(manifest("start"), projection: plan)
        }
    }

    @Test func animatedStillRequiresItsImageWithoutInventingVideoConditioning() throws {
        let base = projection(), imported = base.shots[0]
        let shot = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: imported.startState,
            endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
            renderability: .green, acceptance: imported.acceptance,
            generationRequirement: .init(modalityID: "image", modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID],
                                         visibleEntityCount: 0))
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
            timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        try ProductionPlanProjectionValidatorV1.validate(plan)
        #expect(plan.requiredFrameRoles(for: shotID) == ["start"])
        #expect(shot.generationRequirement?.requiresFirstFrame == false)
        let report = try ProductionPlanAuditV1.run(projection: plan, timing: timing(),
            profileIDs: [.generativeFilm], routes: .init(routesByShotID: [:]))
        #expect(report.errors.isEmpty)
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanFramesV1.validate(.init(project: "fixture", generated: "fixture"), projection: plan)
        }
    }

    @Test func animatedStillAssemblyUsesItsActualDeliveryReceiptWithoutAVideoTake() throws {
        let base = projection(), imported = base.shots[0]
        let shot = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: imported.startState,
            endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
            renderability: .green, acceptance: imported.acceptance,
            generationRequirement: .init(modalityID: "image", modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID],
                                         visibleEntityCount: 0))
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
            timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        let production = ref("production", ProductionPlanProjectionV1.versionPath(1)), review = ref("review", RenderReviewV1.currentPath)
        let image = ref("image", "frames/selected-start.png"), delivery = ref("still", "renders/still-deliveries/receipt.json")
        let frame = ref("frame", "frames/production-receipts/start.json")
        func proof(takeID: String? = nil, selection: Bool = true, frameProof: Bool = true,
                   submission: CanonicalArtifactReferenceV1? = nil) -> ProductionPlanAssemblyProofV1 {
            .init(header: header([production, review, delivery, frame]), productionPlan: production, renderReview: review,
                timebase: base.timebase, placements: [
                    .init(shotID: shotID, trackID: "video", clipID: "still", output: image, sourceKind: .stillImage,
                        startTicks: 0, durationTicks: 72, motion: .init(kind: .kenBurnsZoom, startScale: 1, endScale: 1.08),
                        takeID: takeID, selectionReceipt: selection ? delivery : nil, submissionBinding: submission,
                        deliveryProof: frameProof ? frame : nil)])
        }
        try ProductionPlanAssemblyV1.validate(proof(), projection: plan, timing: timing())
        #expect(proof().placements[0].takeID == nil)
        #expect(throws: ProductionPlanningError.invalid("assembly.noStillTake")) {
            try ProductionPlanAssemblyV1.validate(proof(takeID: delivery.sha256), projection: plan, timing: timing())
        }
        for invalid in [proof(selection: false), proof(frameProof: false), proof(submission: ref("submission", "renders/fake.json"))] {
            #expect(throws: ProductionPlanningError.self) { try ProductionPlanAssemblyV1.validate(invalid, projection: plan, timing: timing()) }
        }
    }

    @Test func stillRetainsSharedBlockingCheckWhileVideoStillRequiresItsRoute() throws {
        let base = projection(), imported = base.shots[0]
        func plan(still: Bool) -> ProductionPlanProjectionV1 {
            let shot = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: imported.startState,
                endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
                blocking: [.init(entityID: "shape", relation: "Beside the wall")],
                renderability: .green, acceptance: imported.acceptance,
                generationRequirement: .init(modalityID: still ? "image" : "video",
                    modeIDs: [still ? ShotDeliveryModeResolverV1.timelineAnimatedStillModeID : "text-to-video"], visibleEntityCount: 0))
            return .init(header: base.header, timebase: base.timebase, mode: base.mode,
                executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
                timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
                storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        }
        let still = try ProductionPlanAuditV1.run(projection: plan(still: true), timing: timing(),
            profileIDs: [.generativeFilm], routes: .init(routesByShotID: [:]))
        #expect(still.errors.map(\.code) == ["BLOCKING_ANCHOR_MISSING"])
        let video = try ProductionPlanAuditV1.run(projection: plan(still: false), timing: timing(),
            profileIDs: [.generativeFilm], routes: .init(routesByShotID: [:]))
        #expect(video.errors.map(\.code) == ["PRODUCTION_ROUTE_MISSING"])
    }

    @Test func unapprovedFrameManifestCanBeStructurallyValid() throws {
        let base = projection(), imported = base.shots[0]
        let shot = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: imported.startState,
            endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
            renderability: .green, acceptance: imported.acceptance,
            generationRequirement: .init(modalityID: "image", modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID], visibleEntityCount: 0))
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
            timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        let manifest = FramesManifest(project: "fixture", generated: "fixture", shots: [
            .init(shotId: shotID, keyframeStrategy: "start", frames: [
                .init(role: "start", path: "frames/fixture/start.png", runwayModel: "fixture-image-model", approved: false,
                    providerPrompt: "A static wide composition of a red geometric circle against a pale wall.")])])
        try ProductionPlanFramesV1.validate(manifest, projection: plan)
    }

    @Test func continuationConsumesPredecessorFrameWithoutGeneratingAnotherAnchor() throws {
        let base = projection(), imported = base.shots[0]
        let predecessorID = "shot-00000000-0000-0000-0000-000000000002"
        func shot(_ id: String, firstFrame: Bool) -> ExecutionShotV1 {
            .init(id: id, sourceMode: .generated, startState: imported.startState, endState: imported.endState,
                  primaryAction: imported.primaryAction, camera: .init(movementID: "static"), renderability: .green,
                  acceptance: imported.acceptance, generationRequirement: .init(modalityID: "video", modeIDs: ["keyframe"],
                    visibleEntityCount: 0, requiresFirstFrame: firstFrame))
        }
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext,
                                shots: [shot(predecessorID, firstFrame: false), shot(shotID, firstFrame: true)]),
            timings: [.init(shotID: predecessorID, startTicks: 0, durationTicks: 72),
                      .init(shotID: shotID, startTicks: 72, durationTicks: 72)], sourceBindings: [],
            draftReference: base.draftReference, storyboardReference: base.storyboardReference,
            editorialBindings: [.init(shotID: predecessorID, sceneID: "scene"), .init(shotID: shotID, sceneID: "scene")],
            chains: [.init(shotID: shotID, kind: .frameContinuation, predecessorShotID: predecessorID)])
        try ProductionPlanProjectionValidatorV1.validate(plan)
        #expect(plan.shots.last?.generationRequirement?.requiresFirstFrame == true)
        #expect(plan.requiredFrameRoles(for: shotID).isEmpty)
        try ProductionPlanFramesV1.validate(.init(project: "fixture", generated: "fixture"), projection: plan)
        let unchained = ProductionPlanProjectionV1(header: plan.header, timebase: plan.timebase, mode: plan.mode,
            executionPlan: plan.executionPlan, timings: plan.timings, sourceBindings: plan.sourceBindings,
            draftReference: plan.draftReference, storyboardReference: plan.storyboardReference,
            editorialBindings: plan.editorialBindings)
        #expect(unchained.requiredFrameRoles(for: shotID) == ["start"])
    }

    @Test func fractionalFrameRatePreservesExactFrameBoundaries() throws {
        let timebase = RationalTimebaseV1(ticksPerSecond: 24_000, fpsNumerator: 24_000, fpsDenominator: 1_001)
        #expect(try ProductionPlanAssemblyV1.frameIndex(for: 24_024, timebase: timebase) == 24)
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanAssemblyV1.frameIndex(for: 24_000, timebase: timebase)
        }
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanAssemblyV1.frameIndex(for: -1_001, timebase: timebase)
        }
    }

    @Test func coverageKeepsExistingInformationalGapPolicy() throws {
        let plan = projection(start: 24)
        let report = try ProductionPlanAuditV1.run(projection: plan, timing: timing(start: 24, range: 120),
                                                  profileIDs: [], routes: .init(routesByShotID: [:]))
        #expect(report.findings.filter { $0.code == "UNCOVERED_GAP" }.map(\.level) == [.info])
        #expect(report.findings.filter { $0.code == "UNCOVERED_TAIL" }.map(\.level) == [.info])
        #expect(report.errors.isEmpty)
        #expect(!report.findings.contains { $0.code == "SOURCE_MODE_NEEDS_FOOTAGE" })
    }

    @Test func narrativeProfileRejectsMissingExplicitBeat() throws {
        let report = try ProductionPlanAuditV1.run(projection: projection(), timing: timing(),
                                                  profileIDs: [.narrativeStorytelling], routes: .init(routesByShotID: [:]))
        #expect(report.errors.map(\.code) == ["NARRATIVE_BEAT_MISSING"])
    }

    @Test func assemblyRejectsSourceSubstitutionAndTruncatedVideo() throws {
        try ProductionPlanAssemblyV1.validate(assembly(), projection: projection(), timing: timing())
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanAssemblyV1.validate(assembly(output: ref("other", "import/other.mov")), projection: projection(), timing: timing())
        }
        #expect(throws: ProductionPlanningError.self) {
            try ProductionPlanAssemblyV1.validate(assembly(decodedDuration: 71), projection: projection(), timing: timing())
        }
    }

    @Test func assemblyEvidenceCannotBeSelfCertifiedByAgent() throws {
        #expect(throws: ProductionPlanningError.invalid("assembly.hostEvidenceVerifier")) {
            try ProductionPlanAssemblyV1.requireCurrent(projection: projection(), dataRoot: URL(fileURLWithPath: "/unused"))
        }
    }

    @Test func requiredObligationCannotBecomeNativeSkip() throws {
        let fixture = try promotionFixture(required: true)
        #expect(throws: ProductionPlanningError.self) {
            try ShotPlanningPromotionValidatorV1.validate(fixture.promotion, draft: fixture.draft, timing: timing(),
                bible: fixture.bible, assetGraph: fixture.graph, projection: projection())
        }
    }

    @Test func optionalSkipStillRequiresRealHostEvidence() throws {
        let fixture = try promotionFixture(required: false)
        try ShotPlanningPromotionValidatorV1.validate(fixture.promotion, draft: fixture.draft, timing: timing(),
            bible: fixture.bible, assetGraph: fixture.graph, projection: projection())
        #expect(throws: ProductionPlanningError.invalid("promotion.hostEvidenceVerifier")) {
            try fixture.promotion.requireCurrentEvidence(draft: fixture.draft, timing: timing(), bible: fixture.bible,
                assetGraph: fixture.graph, projection: projection(), dataRoot: URL(fileURLWithPath: "/unused"))
        }
    }

    @Test func importedRangeIsEditableBeforeItIsEligibleForApproval() throws {
        let board = timing()
        let source = ref("source", "import/source.mov")
        func draft(duration: Int64) -> ShotPlanningDraftV1 {
            .init(header: header([source]), storyboardRevision: 1, shots: [
                .init(shotID: shotID, sourceMode: .imported, source: source,
                    camera: .init(framing: board.shots[0].framing, movement: .static), obligations: [],
                    sourceInputRange: .init(source: source, timebase: .init(ticksPerSecond: 48, fpsNumerator: 24),
                                            startTicks: 24, durationTicks: duration))])
        }
        try ShotPlanningValidatorV1.validate(draft(duration: 240), timing: board)
        #expect(throws: ProductionPlanningError.invalid("shotPlanning.importedRangeMustMatchShotDuration")) {
            try ShotPlanningValidatorV1.validate(draft(duration: 240), timing: board, approval: true)
        }
        try ShotPlanningValidatorV1.validate(draft(duration: 144), timing: board, approval: true)
    }

    @Test func sourceTimeEqualityDoesNotRoundThroughFloatingPointOrFrames() {
        let base = RationalTimebaseV1(ticksPerSecond: 24, fpsNumerator: 24)
        let other = RationalTimebaseV1(ticksPerSecond: 48, fpsNumerator: 24)
        #expect(base.representsSameTime(1, as: 2, timebase: other))
        #expect(!base.representsSameTime(1, as: 3, timebase: other))
        let large = RationalTimebaseV1(ticksPerSecond: Int64(Int32.max), fpsNumerator: 1)
        #expect(large.representsSameTime(Int64.max, as: Int64.max, timebase: large))
        let fast = RationalTimebaseV1(ticksPerSecond: 2_000_000_000, fpsNumerator: 1)
        let slow = RationalTimebaseV1(ticksPerSecond: 1_000_000_000, fpsNumerator: 1)
        #expect(fast.representsSameTime(Int64.max - 1, as: (Int64.max - 1) / 2, timebase: slow))
        #expect(!fast.representsSameTime(Int64.max - 1, as: (Int64.max - 1) / 2 + 1, timebase: slow))
    }

    @Test func immutableContextAndGraphPathsDoNotBroadenLegacyValidators() throws {
        let plan = projection()
        #expect(throws: ExecutionPlanValidationError.invalidCreativeContextReference) {
            try ExecutionPlanValidator.validate(plan.executionPlan)
        }
        try ExecutionPlanValidator.validate(plan.executionPlan,
            creativeContextPath: ShotPlanningPromotionV1.creativeContextPath(revision: 1))
        let graph = AssetGraphV1(id: try AssetGraphContentAddressV1.graphID(projectID: "fixture", assets: []), projectID: "fixture", assets: [])
        let path = ShotPlanningPromotionV1.assetGraphPath(revision: 1)
        let demand = ReferenceDemandSetV1(id: "planned", projectID: "fixture", shotID: shotID,
            assetGraph: .init(id: graph.id, role: AssetGraphV1.artifactRole, path: path,
                             sha256: FileDigest.sha256(of: try AssetGraphCanonicalCodecV1.encode(graph))), demands: [])
        #expect(throws: AssetGraphValidationError.assetGraphMismatch) { try AssetGraphValidatorV1.validate(demand, against: graph) }
        try AssetGraphValidatorV1.validate(demand, against: graph, assetGraphPath: path)
    }

    @Test func aiEnhancedInputRangeCannotBeReplacedByAnOutputTrim() throws {
        let base = projection()
        let original = base.shots[0]
        let source = try #require(base.source(for: shotID))
        let shot = ExecutionShotV1(id: shotID, sourceMode: .aiEnhanced, sourceAssetID: source.id,
            startState: original.startState, endState: original.endState, primaryAction: original.primaryAction,
            camera: .init(movementID: "static"), renderability: .green, acceptance: original.acceptance,
            generationRequirement: .init(modalityID: "video", modeIDs: ["video-edit"], visibleEntityCount: 0, sourceVideoAssetID: source.id))
        func value(_ ranges: [ProductionPlanProjectionV1.SourceInputRange]) -> ProductionPlanProjectionV1 {
            .init(header: base.header, timebase: base.timebase, mode: base.mode,
                executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
                timings: base.timings, sourceBindings: [source], draftReference: base.draftReference,
                storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings, sourceInputRanges: ranges)
        }
        #expect(throws: ProductionPlanningError.invalid("productionPlan.inputRangeCoverage")) {
            try ProductionPlanProjectionValidatorV1.validate(value([]))
        }
        try ProductionPlanProjectionValidatorV1.validate(value([
            .init(shotID: shotID, source: source, timebase: base.timebase, startTicks: 24, durationTicks: 48)]))
    }

    @Test func exactSongEndUsesCoveringVisualFramesAndUnroundedAudioTicks() throws {
        let base = projection(), original = timing()
        let timebase = RationalTimebaseV1(ticksPerSecond: 48, fpsNumerator: 24)
        let source = try #require(base.source(for: shotID))
        let song = ref("audio", "track/song.wav")
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: timebase, mode: base.mode,
            executionPlan: base.executionPlan, timings: [.init(shotID: shotID, startTicks: 0, durationTicks: 119)],
            sourceBindings: base.sourceBindings, draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        func board(range: Int64) -> StoryboardTimingV1 {
            .init(header: header(), timebase: timebase, mode: .beat, rangeDurationTicks: range,
                audio: .init(source: song, durationTicks: 119), shots: [
                    .init(id: shotID, primaryStepID: original.shots[0].primaryStepID, startTicks: 0,
                        durationTicks: 119, framing: original.shots[0].framing, moments: [])])
        }
        let production = ref("production", ProductionPlanProjectionV1.versionPath(1))
        let review = ref("review", RenderReviewV1.currentPath)
        let proof = ProductionPlanAssemblyProofV1(header: header([production, review]), productionPlan: production,
            renderReview: review, timebase: timebase, placements: [
                .init(shotID: shotID, trackID: "picture", clipID: "clip", output: source, sourceKind: .video,
                    startTicks: 0, durationTicks: 119, decodedDurationTicks: 119)],
            audio: .init(trackID: "audio", clipID: "song", source: song, startTicks: 0, sourceInTicks: 0, durationTicks: 119))
        #expect(try ProductionPlanAssemblyV1.coveringFrameCount(for: 119, timebase: timebase) == 60)
        try ProductionPlanAssemblyV1.validate(proof, projection: plan, timing: board(range: 119))
        #expect(proof.audio?.durationTicks == 119)
        #expect(throws: ProductionPlanningError.invalid("assembly.frameBoundary")) {
            try ProductionPlanAssemblyV1.validate(proof, projection: plan, timing: board(range: 144))
        }
    }

    @Test func multicamExportsExactNativeExcerptWithoutTrimmingPlanningOrAudio() throws {
        let base = projection(), original = timing()
        let timebase = RationalTimebaseV1(ticksPerSecond: 48, fpsNumerator: 24)
        let source = try #require(base.source(for: shotID))
        let song = ref("audio", "track/song.wav")
        let board = StoryboardTimingV1(header: header(), timebase: timebase, mode: .multicam,
            rangeDurationTicks: 119, audio: .init(source: song, durationTicks: 119), shots: [
                .init(id: shotID, primaryStepID: "step", startTicks: 0, durationTicks: 119, cameraID: "camera-one",
                    framing: original.shots[0].framing, moments: [])])
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: timebase, mode: .multicam,
            executionPlan: base.executionPlan, timings: [.init(shotID: shotID, startTicks: 0, durationTicks: 119)],
            sourceBindings: base.sourceBindings, draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        let analysis = ref("analysis", "analysis/song.json"), receipt = ref("selection", "brief/playback-range-selections/native.v1.json")
        let range = PlaybackRangeV1(header: header([analysis, song, receipt]), kind: .excerpt, analysis: analysis,
            timebase: timebase, audioDurationTicks: 119, startTicks: 24, durationTicks: 47, selectionReceipt: receipt)
        let production = ref("production", ProductionPlanProjectionV1.versionPath(1)), review = ref("review", RenderReviewV1.currentPath)
        let outputReference = ref("output-range", PlaybackRangeV1.currentPath)
        func proof(range: PlaybackRangeV1?, bind: Bool = true) -> ProductionPlanAssemblyProofV1 {
            .init(header: header([production, review] + (bind ? [outputReference] : [])), productionPlan: production,
                renderReview: review, timebase: timebase, placements: [
                    .init(shotID: shotID, trackID: "camera-one", clipID: "clip", output: source, sourceKind: .video,
                        startTicks: 0, durationTicks: 119, decodedDurationTicks: 119)],
                audio: .init(trackID: "audio", clipID: "song", source: song, startTicks: 0, sourceInTicks: 0, durationTicks: 119),
                outputRange: range)
        }
        let value = proof(range: range)
        try ProductionPlanAssemblyV1.validate(value, projection: plan, timing: board)
        let output = try ProductionPlanAssemblyV1.outputInterval(proof: value, timing: board)
        #expect(output.startTicks == 24)
        #expect(output.durationTicks == 47)
        #expect(value.placements.first?.durationTicks == 119)
        #expect(value.audio?.durationTicks == 119)
        #expect(throws: ProductionPlanningError.invalid("assembly.multicamOutputRange")) {
            try ProductionPlanAssemblyV1.validate(proof(range: nil), projection: plan, timing: board)
        }
        #expect(throws: ProductionPlanningError.invalid("assembly.outputRangeBinding")) {
            try ProductionPlanAssemblyV1.validate(proof(range: range, bind: false), projection: plan, timing: board)
        }
    }

    @Test func generatedStillCannotSupplyAnInventedPredecessorVideoTake() throws {
        let base = projection(), imported = base.shots[0]
        let second = "shot-00000000-0000-0000-0000-000000000002"
        let still = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: imported.startState,
            endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
            renderability: .green, acceptance: imported.acceptance,
            generationRequirement: .init(modalityID: "image", modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID], visibleEntityCount: 0))
        let continuation = ExecutionShotV1(id: second, sourceMode: .generated, startState: imported.startState,
            endState: imported.endState, primaryAction: imported.primaryAction, camera: .init(movementID: "static"),
            renderability: .green, acceptance: imported.acceptance,
            generationRequirement: .init(modalityID: "video", modeIDs: ["keyframe"], visibleEntityCount: 0, requiresFirstFrame: true))
        let plan = ProductionPlanProjectionV1(header: base.header, timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext,
                shots: [still, continuation]), timings: [.init(shotID: shotID, startTicks: 0, durationTicks: 72),
                    .init(shotID: second, startTicks: 72, durationTicks: 72)], sourceBindings: [],
            draftReference: base.draftReference, storyboardReference: base.storyboardReference,
            editorialBindings: [.init(shotID: shotID, sceneID: "scene"), .init(shotID: second, sceneID: "scene")],
            chains: [.init(shotID: second, kind: .frameContinuation, predecessorShotID: shotID)])
        #expect(throws: ProductionPlanningError.invalid("productionPlan.chainPredecessorVideo")) {
            try ProductionPlanProjectionValidatorV1.validate(plan)
        }
    }

    private func promotionFixture(required: Bool) throws -> (promotion: ShotPlanningPromotionV1, draft: ShotPlanningDraftV1, bible: Bible, graph: AssetGraphV1) {
        let plan = projection(), board = timing()
        let obligation = ShotPlanningDraftV1.Obligation(id: "geometry", kind: .geometry, subject: "Set",
            requirement: "Persistent set geometry", required: required, allowedSkipReason: required ? nil : "Use selected footage")
        let draft = ShotPlanningDraftV1(header: header([ref("source", "import/source.mov")]), storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: .imported, source: ref("source", "import/source.mov"),
                  camera: .init(framing: board.shots[0].framing, movement: .static), obligations: [obligation])
        ])
        let bibleRef = ref("bible", PipelineLayout.bibleFile), graphRef = ref("graph", ShotPlanningPromotionV1.assetGraphPath(revision: 1))
        let projectionRef = ref("projection", ProductionPlanProjectionV1.versionPath(1))
        let refs = [plan.draftReference, plan.storyboardReference, bibleRef, graphRef, projectionRef]
        let promotion = ShotPlanningPromotionV1(header: header(refs), draft: plan.draftReference, timing: plan.storyboardReference,
            bible: bibleRef, assetGraph: graphRef, projection: projectionRef, routes: [], resolutions: [
                .init(shotID: shotID, obligationID: "geometry", outcome: .skipped(reason: "Use selected footage"),
                      confirmationReceipt: ref("receipt", "shot-planning/receipts/skip.json"))
            ])
        return (promotion, draft, try Bible(project: "fixture", generated: "fixture", generator: "fixture"),
                AssetGraphV1(id: try AssetGraphContentAddressV1.graphID(projectID: "fixture", assets: []), projectID: "fixture", assets: []))
    }

    private func ref(_ id: String, _ path: String) -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: "core.fixture", path: path, sha256: String(repeating: "0", count: 64))
    }

    private func header(_ refs: [CanonicalArtifactReferenceV1] = []) -> PlanningArtifactHeaderV1 {
        .init(projectID: "fixture", revision: 1, origin: .userRevision, inputs: refs)
    }

    private func projection(start: Int64 = 0) -> ProductionPlanProjectionV1 {
        let draft = ref("draft", ShotPlanningDraftV1.versionPath(1)), board = ref("board", StoryboardTimingV1.versionPath(1))
        let context = CanonicalArtifactReferenceV1(id: ExecutionPlanV1.creativeContextArtifactID,
            role: ExecutionPlanV1.creativeContextArtifactRole, path: ShotPlanningPromotionV1.creativeContextPath(revision: 1), sha256: String(repeating: "0", count: 64))
        let shot = ExecutionShotV1(id: shotID, sourceMode: .imported, sourceAssetID: "source",
            startState: .init(summary: "Start"), endState: .init(summary: "End"), primaryAction: "Use assigned footage",
            camera: .init(movementID: "core.source"), renderability: .green,
            acceptance: [.init(id: "source", requirement: "Use exact selected source", severity: "blocking")])
        return .init(header: header([draft, board]), timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), mode: .beat,
                     executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: context, shots: [shot]),
                     timings: [.init(shotID: shotID, startTicks: start, durationTicks: 72)],
                     sourceBindings: [ref("source", "import/source.mov")], draftReference: draft, storyboardReference: board,
                     editorialBindings: [.init(shotID: shotID, sceneID: "scene")])
    }

    private func timing(start: Int64 = 0, range: Int64 = 72) -> StoryboardTimingV1 {
        .init(header: header(), timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), mode: .beat,
              rangeDurationTicks: range, shots: [.init(id: shotID, primaryStepID: "step", startTicks: start, durationTicks: 72,
                framing: .init(scale: "wide", composition: "center", cameraView: "front"), moments: [])])
    }

    private func assembly(output: CanonicalArtifactReferenceV1? = nil, decodedDuration: Int64 = 72) -> ProductionPlanAssemblyProofV1 {
        let plan = ref("plan", ProductionPlanProjectionV1.versionPath(1)), review = ref("review", RenderReviewV1.versionPath(1))
        return .init(header: header([plan, review]), productionPlan: plan, renderReview: review,
            timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), placements: [
                .init(shotID: shotID, trackID: "video", clipID: "clip", output: output ?? ref("source", "import/source.mov"),
                      sourceKind: .video, startTicks: 0, durationTicks: 72, decodedDurationTicks: decodedDuration)
            ])
    }
}

extension ProductionPlanConsumerV1Tests {
    @Test func generatedOptionalSourceFootageUsesItsDeclaredSkipWithoutInventingASource() throws {
        let fixture = try promotionFixture(required: false), base = projection(), original = base.shots[0]
        let shot = ExecutionShotV1(id: shotID, sourceMode: .generated, startState: original.startState,
            endState: original.endState, primaryAction: "Use a generated still", camera: .init(movementID: "static"),
            renderability: .green, acceptance: [.init(id: "still", requirement: "Use the approved generated still", severity: "blocking")],
            generationRequirement: .init(modalityID: "image", modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID],
                visibleEntityCount: 0))
        let plannedInputs = [
            ref("input-template", ShotPlanningPromotionV1.inputTemplatePath(shotID: shotID, revision: 1)),
            ref("demand", ShotPlanningPromotionV1.demandPath(shotID: shotID, revision: 1)),
        ]
        let plan = ProductionPlanProjectionV1(header: header(base.header.inputs + plannedInputs), timebase: base.timebase, mode: base.mode,
            executionPlan: .init(id: "plan", projectID: "fixture", creativeContext: base.executionPlan.creativeContext, shots: [shot]),
            timings: base.timings, sourceBindings: [], draftReference: base.draftReference,
            storyboardReference: base.storyboardReference, editorialBindings: base.editorialBindings)
        let optional = ShotPlanningDraftV1.Obligation(id: "geometry", kind: .sourceFootage, subject: "Optional original footage",
            requirement: "Use original footage or the declared alternative", required: false, allowedSkipReason: "Use the generated image instead")
        let draft = ShotPlanningDraftV1(header: header(), storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: .generated,
                camera: .init(framing: timing().shots[0].framing, movement: .static), obligations: [optional])])
        let old = fixture.promotion
        let promotion = ShotPlanningPromotionV1(header: header(old.header.inputs + plannedInputs), draft: old.draft, timing: old.timing,
            bible: old.bible, assetGraph: old.assetGraph, projection: old.projection, routes: old.routes,
            resolutions: [.init(shotID: shotID, obligationID: optional.id,
                outcome: .skipped(reason: "Use the generated image instead"),
                confirmationReceipt: try #require(old.resolutions.first).confirmationReceipt)])
        try ShotPlanningPromotionValidatorV1.validate(promotion, draft: draft, timing: timing(),
            bible: fixture.bible, assetGraph: fixture.graph, projection: plan)
        #expect(plan.source(for: shotID) == nil)
    }
}
