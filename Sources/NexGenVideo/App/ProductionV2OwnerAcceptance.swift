import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionV2OwnerAcceptance {
    enum Kind: String { case core, musicvideo }

    static func run(kind: Kind, output: URL, continuing flow: MusicvideoHostFlowAcceptance? = nil,
                    privateSongSHA256: String? = nil) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested || (MusicvideoHostFlowAcceptance.isRequested && flow != nil) else { throw GateBlocked("The owner driver requires explicit native acceptance.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard flow == nil || (kind == .musicvideo && privateSongSHA256?.count == 64) else {
            throw GateBlocked("Continue the actual private Music Video document with its verified original song digest.")
        }
        let mixed = flow == nil
        let generation = try ProductionV2GenerationAcceptance()
        defer { generation.close() }
        let coreRuntime = ProductionV2RecordingRuntime()
        let original: ProductionPlanningAcceptanceFixture.Context
        let startup: MusicvideoHostFlowAcceptance?
        switch kind {
        case .core:
            original = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: coreRuntime.service())
            startup = nil
        case .musicvideo:
            let actualFlow: MusicvideoHostFlowAcceptance
            if let flow { actualFlow = flow } else { actualFlow = try await musicvideoStart(output: output) }
            let flow = actualFlow
            startup = flow
            original = .init(document: flow.document, packageURL: flow.projectURL, dataRoot: flow.dataRoot,
                executor: generation.executor(editor: flow.editor))
        }
        let editor = original.editor
        generation.configure(editor: editor)
        let context = ProductionPlanningAcceptanceFixture.Context(document: original.document, packageURL: original.packageURL,
            dataRoot: original.dataRoot, executor: generation.executor(editor: editor))
        if context.document.windowControllers.isEmpty { context.document.makeWindowControllers() }
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw GateBlocked("The V2 acceptance has no actual document window.")
        }
        window.setContentSize(AppTheme.Window.projectMin)
        window.appearance = NSAppearance(named: .darkAqua)
        context.document.showWindows(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "owner-v2-" + kind.rawValue)
        var documentOpen = true
        defer { if documentOpen { context.document.close() } }
        do {
            await editor.refreshEngineState()
            let viewport = try actualViewport(window)
            let expectedPhases = ["project_init"] + (kind == .musicvideo ? ["analysis"] : [])
                + ["brief", "production_design", "treatment", "script", "storyboard", "shot_planning", "bible",
                   "shotlist", "sanity", "frames", "render_review", "render"]
            guard editor.projectState?.phases.map(\.phase) == expectedPhases else {
                throw GateBlocked("The actual owner workflow differs from the independent V2 phase sequence.")
            }
            if kind == .musicvideo {
                try await seedMusicvideoScript(context: context, driver: driver)
            } else {
                guard editor.agentService.send(text: "Acceptance transport: retain the current Core phase context.", mentions: [], hidden: true) else {
                    throw GateBlocked("The real Core recording runtime could not start its document session.")
                }
                try await driver.wait("recording Core context ready") {
                    !editor.agentService.isStreaming && coreRuntime.phases == ["script"] && editor.agentService.currentSessionId != nil
                }
            }
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            try await driver.wait("production owner workspace") { editor.workspaceFocus == .production }
            let privateBinding = try await preservedSong(context: context, expectedSHA256: privateSongSHA256)
            let source: URL
            if mixed { source = try await ProductionPlanningAcceptanceFixture.makeSourceVideo(durationSeconds: 8) }
            else {
                let root = context.dataRoot
                let seconds = try await Task.detached {
                    let range = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: root)
                    return range.timebase.seconds(for: range.audioDurationTicks)
                }.value
                guard seconds.isFinite, seconds > 0, seconds * 30 < Double(Int.max) else { throw GateBlocked("The private source song has an invalid full duration.") }
                source = output.appendingPathComponent("private-song-moving-source.mov")
                try await FullflowAcceptanceFixture.writeVideo(to: source, duration: seconds, fps: 30, warm: true)
            }
            _ = try await ProductionV2PlanningAcceptance.run(context: context, sourceVideo: source, driver: driver, generatedFirstShot: mixed)
            let additionalAudio = kind == .musicvideo ? try await ProductionV2AudioAcceptance.insert(context: context, driver: driver) : nil
            try await ProductionV2PreRenderAcceptance.references(context: context, driver: driver, additionalAudioPath: additionalAudio?.path, requiresNativeLook: mixed)
            let generated: PipelineProductionPlanWriter.ShotProposal?
            if mixed { generated = try await generation.proposal(context: context) } else { generated = nil }
            let music: MusicvideoProductionPlanDraftV1?
            if let additionalAudio {
                let base = try await ProductionPlanningAcceptanceFixture.musicvideoPlan(in: context)
                music = try await ProductionV2AudioAcceptance.bind(additionalAudio, in: base, context: context)
            } else { music = nil }
            _ = try await ProductionPlanningAcceptanceFixture.promoteImported(in: context, generatedShots: generated.map { [$0] } ?? [], musicvideoPlan: music)
            try await ProductionV2PreRenderAcceptance.review(context: context, driver: driver)
            var selectedTakeID: String?, selectedRangeID: String?
            if mixed {
                let takeID = try await generation.render(context: context, sourceVideo: source, driver: driver)
                let range = try await ProductionV2TakeAcceptance.run(takeID: takeID, context: context, driver: driver)
                selectedTakeID = takeID; selectedRangeID = range.id
            } else {
                try await ProductionPlanningAcceptanceFixture.run("next_render_shot", args: ["phase": "final"], in: context)
            }
            let delivery = try await ProductionV2FilmAcceptance.run(context: context, driver: driver, output: output,
                additionalAudio: additionalAudio, requiresReviewedTake: mixed)
            let cover = kind == .musicvideo
                ? try await ProductionV2CoverAcceptance.run(context: context, generation: generation, driver: driver, output: output) : nil
            let before = try await canonicalEvidence(context: context)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                context.document.save(to: context.packageURL, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            context.document.close()
            documentOpen = false
            let reopenedRuntime = ProductionV2RecordingRuntime()
            let reopenedService: AgentService
            if kind == .core { reopenedService = reopenedRuntime.service() }
            else {
                let runtime = MusicvideoHostFlowAcceptance.RecordingRuntime(backend: .claudeCode)
                reopenedService = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
                    runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil })
            }
            let reopened = try await VideoProject.load(from: context.packageURL, agentService: reopenedService)
            defer { reopened.close() }
            guard let home = reopened.editorViewModel.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
                throw GateBlocked("The completed film could not reopen its working copy.")
            }
            let restored = ProductionPlanningAcceptanceFixture.Context(document: reopened, packageURL: context.packageURL,
                dataRoot: root, executor: generation.executor(editor: reopened.editorViewModel))
            await reopened.editorViewModel.refreshEngineState()
            let after = try await canonicalEvidence(context: restored)
            guard try await preservedSong(context: restored, expectedSHA256: privateSongSHA256) == privateBinding else {
                throw GateBlocked("The private song, analysis or playback range changed during the complete owner workflow.")
            }
            guard before == after else { throw GateBlocked("Save and reopen changed the canonical planning, selection, film review or delivery evidence.") }
            if let cover, let id = cover["assetID"] as? String, let hash = cover["sha256"] as? String {
                guard let asset = reopened.editorViewModel.mediaAssets.first(where: { $0.id == id }),
                      try await Task.detached(operation: { try FileDigest.sha256(of: asset.url) }).value == hash else {
                    throw GateBlocked("The kept cover did not survive project save and reopen.")
                }
            }
            if let generated {
                let selected = try await Task.detached { try PipelineProductionRenderWriter.requireSelected(shotID: generated.execution.id, dataRoot: root) }.value
                guard selected.selection.takeID == selectedTakeID, selected.selection.nativeRange?.id == selectedRangeID else {
                    throw GateBlocked("The reopened film lost its actual native take-range selection.")
                }
            }
            let timeline = reopened.editorViewModel.timeline, resolver = reopened.editorViewModel.mediaResolver.snapshot()
            _ = try await Task.detached { try PipelineProductionSequenceReviewStore.requireCurrent(dataRoot: root, timeline: timeline, resolver: resolver) }.value
            guard reopened.editorViewModel.projectState?.isComplete == true,
                  reopened.editorViewModel.projectState?.phases.map(\.phase) == expectedPhases,
                  reopened.editorViewModel.projectState?.phases.allSatisfy(\.approved) == true else {
                throw GateBlocked("The saved film has not completed every actual V2 phase.")
            }
            let nativeGates = driver.interactions.compactMap { row -> [String: Any]? in
                guard row["kind"] as? String == "verified-state",
                      (row["label"] as? String)?.hasPrefix("native approval ") == true else { return nil }
                return row["evidence"] as? [String: Any]
            }
            let startupGates = try startup?.gateApprovals.map { gate -> [String: Any] in
                guard var row = try ProductionPlanningAcceptanceFixture.object(gate) as? [String: Any] else {
                    throw GateBlocked("Startup gate evidence is not an object.")
                }
                row["screenshots"] = gate.screenshots.map { (mixed ? "startup/" : "") + $0 }
                return row
            } ?? []
            let result: [String: Any] = ["workflow": kind.rawValue, "phases": expectedPhases,
                "nativeGateApprovals": startupGates + nativeGates, "allPhasesApproved": true,
                "viewport": viewport, "executionFixture": mixed ? "mixed_generated_imported" : "private_song_imported",
                "privateSongBinding": privateBinding, "nativeScriptEdit": true, "nativeMultipleMoments": true,
                "nativeStoryboardUndoRedo": true, "nativeMomentAssignments": true, "nativeAnimaticMomentChange": true,
                "nativeShotSourceAndRange": true, "nativeShotUndoRedo": true, "nativeReferences": mixed,
                "nativePreRenderReview": true, "realCompilerAndHTTPGeneration": mixed, "nativeTakeReview": mixed,
                "nativeRangeReviewAndInsertUndo": mixed, "savedAndReopened": true, "canonicalSHA256": before,
                "delivery": delivery, "cover": cover as Any? ?? NSNull(), "nativeEvidence": driver.result(),
                "startup": try startup.map { try ProductionPlanningAcceptanceFixture.object($0.report()) } ?? NSNull()]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("owner-v2-result.json"), options: .atomic)
            return result
        } catch {
            driver.failure(error)
            throw error
        }
    }

    private static func actualViewport(_ window: NSWindow) throws -> [String: Double] {
        guard let view = window.contentView else { throw GateBlocked("The owner window has no visible content.") }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        guard abs(bounds.width - AppTheme.Window.projectMin.width) < 0.5,
              abs(bounds.height - AppTheme.Window.projectMin.height) < 0.5,
              [AppTheme.Typography.standardScale, AppTheme.Typography.largeScale, AppTheme.Typography.largestScale].contains(scale) else {
            throw GateBlocked("The actual owner window is not at its minimum size and requested supported text scale.")
        }
        return ["width": bounds.width, "height": bounds.height, "textScale": scale]
    }

    private static func preservedSong(context: ProductionPlanningAcceptanceFixture.Context, expectedSHA256: String?) async throws -> [String: String] {
        guard let expectedSHA256 else { return [:] }
        let root = context.dataRoot
        return try await Task.detached {
            let songs = AudioProjectLayout.songFiles(dataRoot: root)
            guard songs.count == 1, let song = songs.first,
                  try FileDigest.sha256(of: song) == expectedSHA256,
                  let analysis = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root) else {
                throw GateBlocked("The complete private owner path lost its exact analyzed source song.")
            }
            return ["songSHA256": expectedSHA256, "analysisSHA256": try FileDigest.sha256(of: analysis),
                "playbackRangeSHA256": try FileDigest.sha256(of: root.appendingPathComponent(PlaybackRangeV1.currentPath))]
        }.value
    }

    private static func musicvideoStart(output: URL) async throws -> MusicvideoHostFlowAcceptance {
        guard let binding = PluginLoader.liveBinding(id: "musicvideo"), binding.version == HostWorkflowKey.musicvideoV2Version,
              binding.projectSchema == HostWorkflowKey.musicvideoV2Schema else { throw GateBlocked("Load the exact actual Music Video V2 pack for its owner acceptance.") }
        let song = output.appendingPathComponent("owner-song.wav")
        try writeSong(to: song, duration: 8)
        let flow = try await MusicvideoHostFlowAcceptance.start(track: song, lyrics: nil, binding: binding,
            evidenceURL: output.appendingPathComponent("startup"))
        try await flow.runAnalysis { $0.registerAudioDecoder(AVFoundationAudioDecoder()) }
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: flow.dataRoot),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let sections = object["sections"] as? [[String: Any]], !sections.isEmpty else { throw GateBlocked("The actual song analysis contains no measured sections.") }
        try await flow.finishPlanningIntake(sectionLabels: sections.indices.map { "section\($0 + 1)" },
            finalResolution: .res720p, conceptType: .abstract)
        return flow
    }

    private static func seedMusicvideoScript(context: ProductionPlanningAcceptanceFixture.Context,
                                            driver: ProductionVisualSourcesDriver) async throws {
        let root = context.dataRoot
        let path = "production_design/refs/lighting.png"
        _ = try ProjectLocalFile.ensureDirectory("production_design/refs", dataRoot: root)
        try FullflowAcceptanceFixture.writeReference(to: root.appendingPathComponent(path))
        try await ProductionPlanningAcceptanceFixture.run("write_production_design", args: [
            "visual_medium": "live_action_realistic", "visual_medium_notes": "",
            "refs": [["path": path, "note": "Hard side light and a pale neutral background."]],
            "color_script": [], "lighting_anchor": ""], in: context)
        try await ProductionV2PlanningAcceptance.approve("production_design", artifact: PipelineLayout.productionDesignFile,
            next: "treatment", context: context, driver: driver)
        try await ProductionPlanningAcceptanceFixture.writeTreatment(in: context)
        try await ProductionV2PlanningAcceptance.approve("treatment", artifact: PipelineLayout.treatmentCurrentFile,
            next: "script", context: context, driver: driver)
        try await ProductionPlanningAcceptanceFixture.writeScript(in: context)
    }

    private static func canonicalEvidence(context: ProductionPlanningAcceptanceFixture.Context) async throws -> [String: String] {
        let root = context.dataRoot
        return try await Task.detached {
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            let paths = [ScriptV1.currentPath, StoryboardV2.currentPath, StoryboardTimingV1.currentPath,
                ShotPlanningDraftV1.currentPath, ProductionPlanProjectionV1.versionPath(projection.header.revision),
                RenderReviewV1.currentPath, ProductionPlanAssemblyProofV1.relativePath, ProductionSequenceReviewV2.relativePath,
                PipelineLayout.gatesFile, TimelineStyleReview.relativePath] + board.timing.shots.flatMap { $0.moments.compactMap(\.asset).flatMap { [$0.image.path, $0.proof.path] } }
            return try Dictionary(uniqueKeysWithValues: Set(paths).map { ($0, try FileDigest.sha256(of: ProjectLocalFile.resolve($0, dataRoot: root))) })
        }.value
    }

    private static func writeSong(to url: URL, duration: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48_000)),
              let samples = buffer.floatChannelData?[0] else { throw GateBlocked("The synthetic source song could not be allocated.") }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let t = Double(index) / 48_000, sweep = t * t / duration
            let carrier = 0.65 * sin(2 * .pi * (173 * t + 71 * sweep)) + 0.25 * sin(2 * .pi * (421 * t + 137 * sweep))
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let click = beat < 0.04 ? 0.6 * exp(-40 * beat) * sin(2 * .pi * 1000 * beat) : 0
            samples[index] = Float((carrier * 0.02 + click) * min(1, min(t, duration - t) / 0.01))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
