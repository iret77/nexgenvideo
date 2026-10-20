import AppKit
import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum ProductionPlanningAcceptanceFixture {
    private static var diagnosticTestName: String?

    static func beginDiagnostic(_ test: String) {
        guard ProcessInfo.processInfo.environment["NGV_RENDER_REVIEW_TEST_DIAGNOSTIC"] == "1" else { return }
        diagnosticTestName = test
        diagnosticStage("method.enter")
    }

    static func endDiagnostic() {
        diagnosticStage("method.exit")
        diagnosticTestName = nil
    }

    static func diagnosticStage(_ stage: String) {
        guard let test = diagnosticTestName,
              let data = try? JSONSerialization.data(withJSONObject: ["test": test, "stage": stage,
                "pid": ProcessInfo.processInfo.processIdentifier, "uptime": ProcessInfo.processInfo.systemUptime], options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardError.write(Data(("[render-review-test-stage] " + text + "\n").utf8))
    }

    static let projectName = "Light and shadow"
    static let timebase = RationalTimebaseV1(ticksPerSecond: 600, fpsNumerator: 30)
    static let actions = ["A red circle crosses a pale wall.", "A blue square fills the empty frame."]

    struct Context {
        let document: VideoProject
        let packageURL: URL
        let dataRoot: URL
        let executor: ToolExecutor
        var editor: EditorViewModel { document.editorViewModel }
    }

    static func makeScript(agentService: AgentService? = nil, beforeDesignApproval: (@MainActor (Context) async throws -> Void)? = nil,
                           beforeBriefApproval: (@MainActor (Context) async throws -> Void)? = nil) async throws -> Context {
        diagnosticStage("makeScript.enter")
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Production planning \(UUID().uuidString).ngv")
        diagnosticStage("scaffold.before")
        let root = try ProjectScaffold.initProject(home: home, name: projectName, mode: .generic)
        diagnosticStage("scaffold.after")
        try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: home.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: home.appendingPathComponent(Project.generationLogFilename))
        _ = try ProjectIdentity.uuid(for: home)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        try PhaseContractRuntime.initializeWorkflowState(dataRoot: root, workflow: HostWorkflowKey.core(.current))
        diagnosticStage("load.before")
        let document = try await VideoProject.load(from: home, agentService: agentService)
        diagnosticStage("load.after")
        var ready = false
        defer {
            if !ready {
                diagnosticStage("makeScript.failure-close.before")
                document.close()
                diagnosticStage("makeScript.failure-close.returned")
            }
        }
        diagnosticStage("window.before")
        _ = NSApplication.shared
        document.makeWindowControllers()
        diagnosticStage("window.after")
        diagnosticStage("restoration.before")
        await document.generationRestorationTask?.value
        diagnosticStage("restoration.after")
        let editor = document.editorViewModel
        editor.undoManager = document.undoManager
        guard let working = editor.workingRoot, let workingRoot = DataRootResolver.dataRoot(of: working),
              editor.declaredProductionContract == .current else { throw GateBlocked("The production fixture did not open its trusted working copy.") }
        let context = Context(document: document, packageURL: home, dataRoot: workingRoot,
            executor: ToolExecutor(editor: editor))
        try await approve("project_init", in: context)
        try PipelineStorySourceWriter.confirmGreenfield(editor: editor)
        try await run("write_brief", args: [
            "mission": "single_release", "target_platform": "Native acceptance film", "aspect_ratio": "16:9",
            "project_mode": "generic", "concept_type": "abstract", "visual_medium": "live_action_realistic",
            "figures": "none", "lyrics_integration": "literal",
        ], in: context)
        try await beforeBriefApproval?(context)
        try await approve("brief", in: context)
        let image = "production_design/refs/lighting.png"
        _ = try ProjectLocalFile.ensureDirectory("production_design/refs", dataRoot: workingRoot)
        try imageBytes(index: 0).write(to: workingRoot.appendingPathComponent(image))
        try await run("write_production_design", args: [
            "visual_medium": "live_action_realistic", "visual_medium_notes": "",
            "refs": [["path": image, "note": "Hard side light and a pale neutral background."]],
            "color_script": [], "lighting_anchor": "",
        ], in: context)
        try await beforeDesignApproval?(context)
        try await approve("production_design", in: context)
        try await writeTreatmentAndScript(in: context)
        ready = true
        return context
    }

    static func writeTreatmentAndScript(in context: Context) async throws {
        try await writeTreatment(in: context)
        try await approve("treatment", in: context)
        try await writeScript(in: context)
    }

    static func writeTreatment(in context: Context) async throws {
        let brief = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        guard brief.conceptType == .abstract else { throw GateBlocked("Choose the fixture's abstract visual concept in Brief before writing its independent compositions.") }
        let review = StoryCausalityDraftV1.ChangeReview(reviewer: "Acceptance fixture",
            upstreamCause: "Two independent abstract images chosen in Brief.",
            downstreamConsequence: "Both images remain independent; no causal event is invented.",
            affectedBeatIDs: ["beat-red", "beat-blue"],
            checks: StoryCausalityDraftV1.ReviewQuestion.allCases.map {
                .init(question: $0, verdict: .satisfied, explanation: "The two independent compositions preserve the Brief's abstract intent.")
            })
        let causality = PipelineTreatmentWriterV2.CausalityProposal(mode: .abstract,
            applicationReason: "Independent visual compositions without story causality.",
            beats: [
                .init(id: "beat-red", sceneID: "red", excerpt: actions[0], elementIDs: []),
                .init(id: "beat-blue", sceneID: "blue", excerpt: actions[1], elementIDs: []),
            ], edges: [], temporalRelations: [], elements: [], stateChanges: [], unresolvedDecisions: [], changeReview: review)
        try await run("write_treatment", args: [
            "origin": "agent_proposal", "summary_oneline": "Two contrasting compositions in light and shadow.",
            "body_markdown": actions.joined(separator: "\n\n"), "causality_plan": try object(causality),
        ], in: context)
    }

    static func writeScript(in context: Context) async throws {
        let scenes: [ScriptV1.Scene] = [
            .init(id: "red", title: "Red circle", adaptation: "A single movement across a pale surface.",
                events: [.init(id: "event-red", action: actions[0], treatmentBeatIDs: ["beat-red"])]),
            .init(id: "blue", title: "Blue square", adaptation: "A still, full-frame composition.",
                events: [.init(id: "event-blue", action: actions[1], treatmentBeatIDs: ["beat-blue"])]),
        ]
        try await run("write_script", args: ["origin": "agentProposal",
            "summary": "Light and shadow in two independent compositions.", "scenes": try object(scenes)], in: context)
    }

    static func writeStoryboard(in context: Context) async throws -> StoryboardBundleSnapshot {
        let script = try PlanningWriterIO.script(dataRoot: context.dataRoot)
        let steps = script.scenes.flatMap { scene in
            scene.events.map { StoryboardV2.StoryStep(id: "step-\($0.id)", sceneID: scene.id,
                eventIDs: [$0.id], function: .story, action: $0.action) }
        }
        let bindings = script.events.map { StoryboardCausalityV2.Binding(stepID: "step-\($0.id)",
            beatIDs: $0.treatmentBeatIDs, reason: "Shows the same composition without adding an event.") }
        let project = try YAMLArtifactStore(dataRoot: context.dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let selectedRange: PlaybackRangeV1?
        if context.editor.declaredPluginBinding?.id == "musicvideo" {
            let range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: context.dataRoot)
            try PipelinePlaybackRangeWriter.requireCanonicalCurrent(range, dataRoot: context.dataRoot, workflowID: HostWorkflowKey.musicvideoV2Contract)
            selectedRange = range
        } else { selectedRange = nil }
        let clock = selectedRange?.timebase ?? timebase
        let start: Int64 = project.mode == .multicam ? 0 : (selectedRange?.startTicks ?? 0)
        let duration = project.mode == .multicam ? (selectedRange?.audioDurationTicks ?? 4_800) : (selectedRange?.durationTicks ?? 4_800)
        try clock.validate()
        let frameTicks = clock.ticksPerSecond * clock.fpsDenominator / clock.fpsNumerator
        let half = duration / 2 / frameTicks * frameTicks
        guard half > 0, duration > half, steps.count == 2 else { throw GateBlocked("This acceptance fixture needs two planned compositions in the actual playback range.") }
        let shots = steps.enumerated().map { index, step in
            PipelineStoryboardBundleWriter.ShotProposal(id: nil, primaryStepID: step.id, additionalStepIDs: [],
                startTicks: project.mode == .multicam ? 0 : start + (index == 0 ? 0 : half),
                durationTicks: project.mode == .multicam ? duration : (index == 0 ? half : duration - half),
                cameraID: project.mode == .multicam ? "camera-\(index + 1)" : nil,
                framing: .init(scale: "wide", composition: "Shape centered against an uncluttered pale background.", cameraView: "frontal"),
                moments: [.init(id: "moment-\(index + 1)", offsetTicks: 0, intent: step.action)])
        }
        let proposal = PipelineStoryboardBundleWriter.Proposal(summary: script.summary, steps: steps, bindings: bindings,
            timebase: clock, mode: project.mode, rangeStartTicks: start, rangeDurationTicks: duration, audio: nil, shots: shots)
        try await run("write_storyboard_bundle", args: ["origin": "agentProposal", "proposal": try object(proposal)], in: context)
        return try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
    }

    static func attachSketches(in context: Context) async throws -> StoryboardBundleSnapshot {
        var board = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot, requireVisuals: false)
        let targets = board.timing.shots.enumerated().flatMap { index, shot in shot.moments.map { (index, shot.id, $0.id) } }
        for (index, shotID, momentID) in targets {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("Sketch-\(UUID().uuidString).png")
            try imageBytes(index: index).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            board = try await PipelineStoryboardEditor.attachImage(from: source, shotID: shotID, momentID: momentID,
                expectedFingerprint: board.fingerprint, editor: context.editor)
        }
        await context.editor.refreshEngineState()
        return try PlanningWriterIO.storyboard(dataRoot: context.dataRoot)
    }

    static func writeShotPlanning(in context: Context) async throws -> ShotPlanningDraftV1 {
        let board = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot)
        let shots = board.timing.shots.map { ShotPlanningDraftV1.ShotIntent(shotID: $0.id, sourceMode: .generated,
            camera: .init(framing: $0.framing, movement: .static), obligations: []) }
        try await run("write_shot_planning_draft", args: ["origin": "agentProposal", "shots": try object(shots)], in: context)
        return try ProductionPlanningStoreV1.readShotPlanning(dataRoot: context.dataRoot, storyboard: board)
    }

    static func makePromotion(withLookObligation: Bool = false, agentService: AgentService? = nil) async throws -> Context {
        let context = try await makeScript(agentService: agentService)
        var ready = false
        defer { if !ready { context.document.close() } }
        try await approve("script", in: context)
        _ = try await writeStoryboard(in: context)
        _ = try await attachSketches(in: context)
        try await approve("storyboard", in: context)
        let initialDraft = try await writeShotPlanning(in: context)
        if withLookObligation {
            let intents = initialDraft.shots.map { shot in
                ShotPlanningDraftV1.ShotIntent(shotID: shot.shotID, sourceMode: shot.sourceMode, camera: shot.camera,
                    obligations: [.init(id: "look", kind: .look, subject: "Approved side lighting",
                        requirement: "Use the actual approved Production Design reference.", required: true)])
            }
            try await run("write_shot_planning_draft", args: ["origin": "agentRevision", "shots": try object(intents)], in: context)
        }
        try await approve("shot_planning", in: context)
        try await writeBible(in: context)
        let preparation = try await prepareAssets(in: context, includeDesignReference: withLookObligation)
        if withLookObligation {
            for shot in initialDraft.shots {
                let shown = try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: context.dataRoot)
                guard shown.canAssign, let asset = shown.eligibleAssets(shotID: shot.shotID, obligationID: "look").first else {
                    throw GateBlocked("The fixture's approved Design reference is not assignable in Bible.")
                }
                try await PipelineShotPlanningPromotionStore.recordResolution(shotID: shot.shotID, obligationID: "look",
                    assetID: asset.id, skipReason: nil, expectedDraftFingerprint: shown.preparation.draft.sha256,
                    expectedPreparationFingerprint: shown.fingerprint, editor: context.editor)
            }
        }
        try await approve("bible", in: context)
        let board = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot)
        let steps = Dictionary(uniqueKeysWithValues: board.storyboard.steps.map { ($0.id, $0) })
        let referenceAsset = try PipelineShotPlanningPromotionStore.availableAssets(dataRoot: context.dataRoot).first
        let shots = try board.timing.shots.map { planned -> PipelineProductionPlanWriter.ShotProposal in
            let action = try planned.stepIDs.map { id -> String in
                guard let step = steps[id] else { throw GateBlocked("The fixture lost a canonical story step.") }
                return step.action
            }.joined(separator: "\n")
            let demands: [ReferenceDemandV1]
            if withLookObligation, let referenceAsset {
                demands = [.init(id: "look-" + planned.id, assetID: referenceAsset.id, modality: .image,
                    semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, isRequired: true, priority: 0,
                    inputSlotID: CoreReferenceInputSlotIDV1.referenceImage,
                    modeID: ShotDeliveryModeResolverV1.timelineAnimatedStillModeID)]
            } else { demands = [] }
            let shot = ExecutionShotV1(id: planned.id, sourceMode: .generated,
                startState: .init(summary: "The pale background is unobstructed."),
                endState: .init(summary: "The approved coloured shape fills its planned composition."),
                primaryAction: action, camera: .init(movementID: "static", framingID: planned.framing.scale),
                renderability: .green,
                acceptance: [.init(id: "composition", requirement: "Preserve the approved shape, colour and framing.", severity: "error")],
                generationRequirement: .init(modalityID: "image", modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID],
                    visibleEntityCount: 0, referenceDemandIDs: demands.map(\.id)))
            return .init(execution: shot, nativeDurationTicks: nil, sourceInTicks: 0, sourceInputRange: nil,
                coreInputs: .init(), referenceDemands: demands, selectedModelID: nil, selectedOffering: nil)
        }
        let proposal = PipelineProductionPlanWriter.Proposal(expectedDraftFingerprint: preparation.draft.sha256,
            expectedAssetGraphFingerprint: preparation.graph.sha256, shots: shots)
        try await run("write_shotlist", args: ["origin": "agentProposal", "proposal": try object(proposal)], in: context)
        ready = true
        return context
    }

    static func prepareImportedAssets(in context: Context) async throws -> PipelineShotPlanningPromotionStore.Preparation {
        let board = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: context.dataRoot, storyboard: board)
        let imported = draft.shots.filter { $0.sourceMode != .generated }
        guard !imported.isEmpty, imported.allSatisfy({ $0.source != nil && $0.sourceInputRange != nil }) else {
            throw GateBlocked("Assign and confirm every imported shot's actual source range first.")
        }
        let paths = Set(draft.shots.compactMap { $0.source?.path }).sorted()
        try await run("prepare_production_assets", args: ["assets": paths.map {
            ["path": $0, "modality": "video", "allowed_use_ids": []] as [String: Any]
        }], in: context)
        return try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: context.dataRoot)
    }

    @discardableResult
    static func promoteImported(in context: Context, generatedShots: [PipelineProductionPlanWriter.ShotProposal] = [],
                                musicvideoPlan: MusicvideoProductionPlanDraftV1? = nil) async throws -> ProductionPlanProjectionV1 {
        let proposal = try productionProposal(in: context, generatedShots: generatedShots, musicvideoPlan: musicvideoPlan)
        try await run("write_shotlist", args: ["origin": "agentProposal", "proposal": try object(proposal)], in: context)
        return try ProductionPlanningLineageV2.projection(dataRoot: context.dataRoot)
    }

    static func musicvideoPlan(in context: Context) async throws -> MusicvideoProductionPlanDraftV1 {
        guard context.editor.declaredPluginBinding?.id == "musicvideo" else { throw GateBlocked("Use the actual Music Video project for its acceptance plan.") }
        let root = context.dataRoot
        return try await Task.detached(priority: .userInitiated) {
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            let brief = try YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile)
            guard brief.conceptType == .abstract, let audio = board.timing.audio, audio.offsetTicks == 0,
                  let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root) else {
                throw GateBlocked("This instrumental acceptance plan needs the actual abstract brief, original song and verified analysis.")
            }
            let analysis = try PlanningWriterIO.reference(FrameInventory.relativePath(of: url, to: root),
                id: "music-analysis", role: "musicvideo.analysis", dataRoot: root)
            let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board)
            let intents = Dictionary(uniqueKeysWithValues: draft.shots.map { ($0.shotID, $0) })
            let sections = try MusicvideoProductionExtensionStoreV2.sections(analysis: analysis, timing: board.timing, dataRoot: root)
            let arc = try sections.map { section in
                let constants = try section.shotIDs.map { id -> MusicArcParameterV1 in
                    guard let intent = intents[id] else { throw GateBlocked("The actual Music Video camera intent is missing.") }
                    return .init(kind: .camera, targetID: id, value: intent.camera.movement.rawValue,
                        rationale: "Preserve the actual abstract Shot Planning camera intent.")
                }
                return MusicArcSectionV1(sectionID: section.id, musicalFunction: "Use the approved analysis section without inventing performance cues.",
                    visualFunction: "Present the planned light and shape compositions.", motifIDs: [], shotIDs: section.shotIDs,
                    constants: constants, variations: [], lyricsRelation: .unused,
                    changeExplanation: "The canonical shot boundaries determine the visible change within this actual song section.")
            }
            let result = MusicvideoProductionPlanDraftV1(performanceSegments: [],
                finalMix: .init(originalSongTimelineStartSeconds: 0, originalSongOccurrences: 1, providerSongAudioMuted: true,
                    approvedAdditionalLayerIDs: []),
                visualArc: .init(concept: board.storyboard.summary, motifs: [], sections: arc), coverage: [])
            try MusicvideoProductionValidatorV1.validate(result)
            return result
        }.value
    }

    static func productionProposal(in context: Context, generatedShots: [PipelineProductionPlanWriter.ShotProposal] = [],
                                   musicvideoPlan: MusicvideoProductionPlanDraftV1? = nil) throws -> PipelineProductionPlanWriter.Proposal {
        let board = try PlanningWriterIO.storyboard(dataRoot: context.dataRoot)
        let draft = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: context.dataRoot, storyboard: board)
        let prepared = try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: context.dataRoot)
        let steps = Dictionary(uniqueKeysWithValues: board.storyboard.steps.map { ($0.id, $0) })
        let shots = try draft.shots.map { intent -> PipelineProductionPlanWriter.ShotProposal in
            if intent.sourceMode != .imported {
                guard let selected = generatedShots.first(where: { $0.execution.id == intent.shotID }),
                      selected.execution.sourceMode.rawValue == intent.sourceMode.rawValue else {
                    throw GateBlocked("Supply actual current generated-shot production details for the natively selected generated source mode.")
                }
                return selected
            }
            guard intent.sourceMode == .imported, let range = intent.sourceInputRange,
                  range.timebase == board.timing.timebase else { throw GateBlocked("Keep this imported fixture's exact native source range.") }
            guard let planned = board.timing.shots.first(where: { $0.id == intent.shotID }) else { throw GateBlocked("The planned imported shot is missing.") }
            let action = try planned.stepIDs.map { id -> String in
                guard let step = steps[id] else { throw GateBlocked("The imported action is missing.") }
                return step.action
            }.joined(separator: "\n")
            let shot = ExecutionShotV1(id: intent.shotID, sourceMode: .imported,
                startState: .init(summary: "The native source range begins."), endState: .init(summary: "The selected source range ends."),
                primaryAction: action, camera: .init(movementID: intent.camera.movement.rawValue,
                    movementDetail: intent.camera.movementDetail, framingID: intent.camera.framing.scale),
                renderability: .green, acceptance: [.init(id: "native-source", requirement: "Use the exact natively selected source range.", severity: "error")])
            return .init(execution: shot, nativeDurationTicks: nil, sourceInTicks: range.startTicks, sourceInputRange: nil,
                coreInputs: nil, referenceDemands: [], selectedModelID: nil, selectedOffering: nil)
        }
        return PipelineProductionPlanWriter.Proposal(expectedDraftFingerprint: prepared.draft.sha256,
            expectedAssetGraphFingerprint: prepared.graph.sha256, shots: shots, musicvideoPlan: musicvideoPlan)
    }

    static func prepareImportedSanity(in context: Context) async throws {
        try await run("run_sanity", args: [:], in: context)
    }

    static func prepareEmptyFrames(in context: Context) async throws {
        try await run("run_phase", args: ["phase": "frames"], in: context)
        guard try loadFramesManifest(dataRoot: context.dataRoot).shots.isEmpty else {
            throw GateBlocked("An imported-only plan must have an actually empty Frames manifest.")
        }
    }

    @discardableResult
    static func assembleImported(in context: Context) async throws -> ProductionPlanAssemblyProofV1 {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: context.dataRoot)
        guard projection.shots.allSatisfy({ $0.sourceMode == .imported }) else { throw GateBlocked("This helper only assembles actual imported sources.") }
        try await run("next_render_shot", args: ["phase": "final"], in: context)
        try await run("assemble_timeline", args: ["phase": "final"], in: context)
        return try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: context.dataRoot)
    }

    static func makeImportedAssembly(agentService: AgentService? = nil,
        beforeRenderReview: (@MainActor (Context) async throws -> Void)? = nil) async throws -> Context {
        diagnosticStage("makeImportedAssembly.enter")
        let context = try await makeScript(agentService: agentService)
        diagnosticStage("makeImportedAssembly.script-returned")
        var ready = false
        defer {
            if !ready {
                diagnosticStage("makeImportedAssembly.failure-close.before")
                context.document.close()
                diagnosticStage("makeImportedAssembly.failure-close.returned")
            }
        }
        try await approve("script", in: context)
        _ = try await writeStoryboard(in: context)
        _ = try await attachSketches(in: context)
        try await approve("storyboard", in: context)
        var draft = try await writeShotPlanning(in: context)
        let video = try await makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let targets = draft.shots.map(\.shotID)
        for (index, id) in targets.enumerated() {
            guard let original = draft.shots.first(where: { $0.shotID == id }) else { throw GateBlocked("The imported fixture lost a shot.") }
            let candidate = ShotPlanningDraftV1.ShotIntent(shotID: id, sourceMode: .imported, camera: original.camera, obligations: [])
            draft = try await PipelineShotPlanningEditor.attachSource(from: video, to: candidate, in: draft, editor: context.editor)
            guard let imported = draft.shots.first(where: { $0.shotID == id }), let source = imported.source else { throw GateBlocked("The native source assignment failed.") }
            draft = try await PipelineShotPlanningEditor.replace(.init(shotID: id, sourceMode: .imported, source: source,
                camera: imported.camera, obligations: [], sourceInputRange: .init(source: source, timebase: timebase,
                    startTicks: Int64(index) * 2_400, durationTicks: 2_400)), in: draft, editor: context.editor)
        }
        try await approve("shot_planning", in: context)
        try await writeBible(in: context)
        _ = try await prepareImportedAssets(in: context)
        try await approve("bible", in: context)
        _ = try await promoteImported(in: context)
        try await approve("shotlist", in: context)
        try await prepareImportedSanity(in: context)
        try await approve("sanity", in: context)
        try await prepareEmptyFrames(in: context)
        try await approve("frames", in: context)
        try await beforeRenderReview?(context)
        let review = try await PipelineRenderReviewWriter.capture(editor: context.editor)
        _ = try await PipelineRenderReviewWriter.recordNativeReview(snapshot: review, findings: [], editor: context.editor)
        try await approve("render_review", in: context)
        _ = try await assembleImported(in: context)
        try await approve("render", in: context)
        ready = true
        return context
    }

    static func makeSourceVideo(durationSeconds: Double = 8) async throws -> URL {
        guard durationSeconds.isFinite, durationSeconds >= 8, durationSeconds <= 60 else { throw GateBlocked("Choose a short acceptance source of at least eight seconds.") }
        return try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Silent shapes " + UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            let width = 160, height = 90, fps = 30
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            let frames = Int((durationSeconds * Double(fps)).rounded(.up))
            for frame in 0..<frames {
                var waits = 0
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation(); waits += 1
                    guard waits < 1_000, writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(5))
                }
                var created: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess,
                      let buffer = created else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                guard let bytes = CVPixelBufferGetBaseAddress(buffer), let image = CGContext(data: bytes, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw CocoaError(.fileWriteUnknown) }
                image.setFillColor(CGColor(gray: 0.9, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: width, height: height))
                image.setFillColor(CGColor(red: 0.8, green: 0.05, blue: 0.05, alpha: 1))
                image.fillEllipse(in: CGRect(x: 8 + (frame % 120), y: 30, width: 24, height: 24))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: Int32(fps)))
            input.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            let wave = FileManager.default.temporaryDirectory.appendingPathComponent("Acceptance tone " + UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: wave) }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames * 1_600)),
                  let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            buffer.frameLength = buffer.frameCapacity
            for sample in 0..<Int(buffer.frameLength) { samples[sample] = Float(sin(Double(sample) * 2 * .pi * 440 / 48_000) * 0.15) }
            do {
                let audio = try AVAudioFile(forWriting: wave, settings: format.settings)
                try audio.write(from: buffer)
            }
            let videoAsset = AVURLAsset(url: url), audioAsset = AVURLAsset(url: wave)
            guard let video = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let audio = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
            let composition = AVMutableComposition()
            guard let visual = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let soundtrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileWriteUnknown) }
            let duration = CMTime(value: Int64(frames), timescale: Int32(fps))
            try visual.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
            try soundtrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audio, at: .zero)
            let result = FileManager.default.temporaryDirectory.appendingPathComponent("Moving shapes with tone " + UUID().uuidString + ".mov")
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
            do {
                try await exporter.export(to: result, as: .mov)
                let actual = AVURLAsset(url: result)
                guard !(try await actual.loadTracks(withMediaType: .audio)).isEmpty,
                      CMTimeCompare(try await actual.load(.duration), duration) == 0 else { throw CocoaError(.fileReadCorruptFile) }
                return result
            } catch { try? FileManager.default.removeItem(at: result); throw error }
        }.value
    }

    static func makeStateVariantBible() async throws -> Context {
        let context = try await makeScript()
        var ready = false
        defer { if !ready { context.document.close() } }
        try await approve("script", in: context)
        _ = try await writeStoryboard(in: context)
        let board = try await attachSketches(in: context)
        try await approve("storyboard", in: context)
        let intents = board.timing.shots.map { shot in
            ShotPlanningDraftV1.ShotIntent(shotID: shot.id, sourceMode: .generated,
                camera: .init(framing: shot.framing, movement: .static),
                obligations: [.init(id: "blue-state", kind: .stateVariant, subject: "Shape in its blue square state",
                    requirement: "Use the explicitly declared blue state of the same geometric symbol.", required: true)])
        }
        try await run("write_shot_planning_draft", args: ["origin": "agentProposal", "shots": try object(intents)], in: context)
        try await approve("shot_planning", in: context)
        var destinations: [String] = []
        for (index, identity) in [("shape", "Shape"), ("shape_blue", "Shape blue")].enumerated() {
            let original = "import/characters/" + identity.0 + "/front.png"
            _ = try ProjectLocalFile.ensureDirectory((original as NSString).deletingLastPathComponent, dataRoot: context.dataRoot)
            try imageBytes(index: index).write(to: context.dataRoot.appendingPathComponent(original))
            try ConfirmedIdentityAssetStoreV1.recordIntake(role: .character, identityName: identity.1,
                identitySlug: identity.0, paths: [original], dataRoot: context.dataRoot)
            let destination = try ProductionWorkflowRecoveryMigration.outputPath(area: "bible",
                leaf: "refs/" + identity.0 + "/front.png", dataRoot: context.dataRoot)
            try await run("copy_project_file", args: ["from": original, "to": destination], in: context)
            destinations.append(destination)
        }
        let design = try YAMLArtifactStore(dataRoot: context.dataRoot).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
        let characters: [[String: Any]] = [("shape", "Shape", "red", "circle"), ("shape_blue", "Shape blue", "blue", "square")].enumerated().map { index, identity in
            ["id": identity.0, "name": identity.1, "visual_prompt": "A " + identity.2 + " " + identity.3 + " geometric symbol.",
             "attributes": [["key": "kind", "value": "geometric symbol"], ["key": "colour", "value": identity.2], ["key": "shape", "value": identity.3]],
             "reference_images": [], "sheets": [["view": "front", "path": destinations[index]]]]
        }
        try await run("write_bible", args: ["look": try object(LookGuide(style: "Minimal abstract compositions", lightingAnchor: design.lightingAnchor)),
            "characters": characters, "ensembles": [], "props": [], "locations": [],
            "identity_variants": [["base_entity_id": "shape", "variant_entity_id": "shape_blue",
                "changed_attributes": [["attribute": "colour", "value": "blue"], ["attribute": "shape", "value": "square"]],
                "inherited_identity_paths": [destinations[0]]]]], in: context)
        try await run("prepare_production_assets", args: ["assets": [["path": destinations[1], "modality": "image",
            "entity_id": "shape", "state_id": "shape_blue", "view_id": "front",
            "allowed_use_ids": [CoreReferenceSemanticJobIDV1.referenceAnchor]]]], in: context)
        ready = true
        return context
    }

    static func writeBible(in context: Context) async throws {
        let design = try YAMLArtifactStore(dataRoot: context.dataRoot).load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
        let look = LookGuide(style: "Minimal abstract compositions", palette: "Red, blue and pale white",
            lighting: "Hard side lighting", lens: "Static frontal view", motionStyle: "One restrained movement per composition",
            lightingAnchor: design.lightingAnchor)
        try await run("write_bible", args: ["look": try object(look), "characters": [], "ensembles": [], "props": [], "locations": []], in: context)
    }

    static func prepareAssets(in context: Context, includeDesignReference: Bool = false) async throws -> PipelineShotPlanningPromotionStore.Preparation {
        let assets: [[String: Any]] = includeDesignReference ? [["path": "production_design/refs/lighting.png",
            "modality": "image", "allowed_use_ids": [CoreReferenceSemanticJobIDV1.styleReference]]] : []
        try await run("prepare_production_assets", args: ["assets": assets], in: context)
        return try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: context.dataRoot)
    }

    static func approve(_ phase: String, in context: Context) async throws {
        guard let home = context.editor.workingRoot else { throw GateBlocked("The acceptance working copy closed.") }
        try await NativeGateWriter.approve(projectDir: home, phase: phase, declaredPack: context.editor.declaredPluginName,
            declaredBinding: context.editor.declaredPluginBinding, declaredProductionContract: context.editor.declaredProductionContract, editor: context.editor, executionCoordinator: context.editor.pipelinePhaseRunCoordinator)
        await context.editor.refreshEngineState()
    }

    static func run(_ tool: String, args: [String: Any], in context: Context) async throws {
        diagnosticStage("tool." + tool + ".before")
        let result = await context.executor.execute(name: tool, args: args)
        diagnosticStage("tool." + tool + ".after")
        guard !result.isError, result.turnDisposition == .continueTurn else {
            let text = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            let diagnostic = "[acceptance] writer failed name=\(tool) content=\(text)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            throw GateBlocked("Acceptance writer \(tool) failed: \(text)")
        }
        await context.editor.refreshEngineState()
    }

    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func imageBytes(index: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 320 * 4, bitsPerPixel: 32), let pixels = bitmap.bitmapData else { throw CocoaError(.fileWriteUnknown) }
        guard let foreground = (index == 0 ? AppTheme.Acceptance.fixtureCircleColor : AppTheme.Acceptance.fixtureSquareColor).usingColorSpace(.deviceRGB),
              let background = AppTheme.Acceptance.fixtureShapeBackgroundColor.usingColorSpace(.deviceRGB) else {
            throw GateBlocked("The production fixture colors could not be converted to its bitmap color space.")
        }
        let foregroundComponents = [foreground.redComponent, foreground.greenComponent, foreground.blueComponent, foreground.alphaComponent]
        let backgroundComponents = [background.redComponent, background.greenComponent, background.blueComponent, background.alphaComponent]
        guard (foregroundComponents + backgroundComponents).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw GateBlocked("The production fixture colors have invalid RGBA components.")
        }
        let foregroundSamples = foregroundComponents.map { UInt8(($0 * 255).rounded()) }
        let backgroundSamples = backgroundComponents.map { UInt8(($0 * 255).rounded()) }
        for y in 0..<180 {
            for x in 0..<320 {
                let dx = x - 160, dy = y - 90
                let shape = index == 0 ? dx * dx + dy * dy < 3_600 : abs(dx) < 60 && abs(dy) < 60
                let samples = shape ? foregroundSamples : backgroundSamples
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = samples[0]
                pixels[offset + 1] = samples[1]
                pixels[offset + 2] = samples[2]
                pixels[offset + 3] = samples[3]
            }
        }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return bytes
    }
}
