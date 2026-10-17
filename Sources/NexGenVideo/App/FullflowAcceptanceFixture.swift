import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum FullflowAcceptanceFixture {
    struct Receipt {
        let shotIDs: [String]
        let totalFrames: Int
        let fps: Int
        let dataRoot: URL
        let projectHome: URL
        let canonicalArtifacts: [String]
        let suppliedInputs: [String]
    }

    struct GeneratedShotScenario {
        let modeID: String
        let makeExecutor: @MainActor (EditorViewModel) -> ToolExecutor
        let render: @MainActor (EditorViewModel, URL) async throws -> Void
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func makeDocument(generatedShot: GeneratedShotScenario? = nil) async throws -> (document: VideoProject, receipt: Receipt) {
        guard let binding = PluginLoader.liveBinding(id: "musicvideo") else {
            throw Failure("The acceptance fixture requires the loaded Musicvideo pack.")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Musicvideo fullflow \(UUID().uuidString).ngv", isDirectory: true)
        _ = try ProjectScaffold.initProject(home: home, name: "Fullflow", mode: .section,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo"))
        var timeline = Timeline()
        timeline.fps = 30
        try JSONEncoder().encode(timeline).write(to: home.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: home.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: home.appendingPathComponent(Project.generationLogFilename))
        _ = try ProjectIdentity.uuid(for: home)
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
        let document = try await VideoProject.load(from: home)
        document.makeWindowControllers()
        let editor = document.editorViewModel
        let root = try dataRoot(editor)
        let song = home.appendingPathComponent("fixture-song.wav")
        try writeTone(to: song, duration: 4.3)
        _ = try await editor.attachProjectSong(from: song, dataRoot: root, replace: false,
            originalFilename: "song.wav", declaredPack: "musicvideo", declaredBinding: binding)
        guard let pack = PackCatalog.pack(named: "musicvideo"),
              let steps = HardStepManifest.load(pack: pack) else {
            throw Failure("Musicvideo intake contract unavailable.")
        }
        for step in steps.steps(for: "project_init") where !step.required {
            try IntakeLedger.recordDecline(step, dataRoot: root)
        }
        try await approve("project_init", editor: editor)
        try writeAnalysisFixture(dataRoot: root)
        try await run("write_analysis_interpretation", [
            "tempo_multiplier": 1.0,
            "section_labels": [["index": 0, "label": "opening", "confidence": 1.0]],
            "anomalies": [], "overall_character": "A steady pulse with an unquantized ending.",
        ], editor: editor)
        try await approve("analysis", editor: editor)
        for step in steps.steps(for: "brief") where !step.required {
            try IntakeLedger.recordDecline(step, dataRoot: root)
        }
        try await run("write_brief", [
            "mission": Mission.demo.rawValue, "target_platform": "YouTube",
            "aspect_ratio": AspectRatio.landscape16x9.rawValue, "project_mode": "section",
            "concept_type": ConceptType.narrative.rawValue,
            "visual_medium": VisualMedium.liveActionRealistic.rawValue,
            "figures": FigurePresence.none.rawValue, "lyrics_integration": LyricsIntegration.ignored.rawValue,
            "final_resolution": VideoResolution.res720p.rawValue,
        ], editor: editor)
        try await approve("brief", editor: editor)
        return (document, try await finishPlanning(editor: editor, generatedShot: generatedShot))
    }

    static func finishPlanning(editor: EditorViewModel, generatedShot: GeneratedShotScenario? = nil) async throws -> Receipt {
        let root = try dataRoot(editor)
        let brief = try YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile)
        guard let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root),
              let analysis = try JSONSerialization.jsonObject(with: Data(contentsOf: analysisURL)) as? [String: Any],
              let rawSections = analysis["sections"] as? [[String: Any]], !rawSections.isEmpty,
              let grid = BeatAssembly.loadBeatGrid(dataRoot: root), grid.durationS > 0 else {
            throw Failure("Fullflow requires the approved analysis and its complete measured sections.")
        }
        let executor = generatedShot?.makeExecutor(editor) ?? ToolExecutor(editor: editor)
        func run(_ name: String, _ args: [String: Any], editor: EditorViewModel) async throws {
            try await Self.run(name, args, editor: editor, executor: executor)
        }
        let fps = editor.timeline.fps
        let totalFrames = BeatAssembly.frame(seconds: grid.durationS, fps: fps)
        let projectHome = FrameInventory.projectHome(of: root)
        let sections = try rawSections.enumerated().map { index, raw -> Section in
            guard let start = raw["start"] as? Double, let end = raw["end"] as? Double,
                  let label = raw["label"] as? String, end > start else {
                throw Failure("The approved section \(index) is incomplete.")
            }
            return Section(id: "section\(index + 1)", label: label, start: start, end: end)
        }
        try await run("write_production_design", [
            "visual_medium": brief.visualMedium.rawValue,
            "visual_medium_notes": brief.visualMediumNotes ?? "",
            "refs": [], "color_script": sections.map { ["section": $0.label, "description": "Warm then cool color blocks."] },
            "style_selection": ["directorID": "director-wes-anderson-symmetry-deadpan",
                "signatureDimensions": [], "overrides": []],
        ], editor: editor)
        try await approve("production_design", editor: editor)
        let body = "A warm field changes into a cool field while a centered marker moves. "
            + (brief.visualMediumNotes ?? "")
        try await run("write_treatment", [
            "origin": "agent_proposal", "summary_oneline": "A warm field becomes cool.", "body_markdown": body,
            "causality_plan": [
                "mode": brief.conceptType.rawValue, "applicationReason": "A color and movement study follows the music.",
                "beats": [["id": "color-change", "sceneID": "stage", "excerpt": body, "elementIDs": []]],
                "chronology": ["color-change"], "edges": [], "elements": [], "stateChanges": [], "unresolvedDecisions": [],
                "changeReview": ["reviewer": "Acceptance fixture director", "upstreamCause": "Approved music timing.",
                    "downstreamConsequence": "Preserve the full song and every section.", "affectedBeatIDs": ["color-change"],
                    "checks": StoryCausalityDraftV1.ReviewQuestion.allCases.map {
                        ["question": $0.rawValue, "verdict": "notApplicable", "explanation": "The supplied single-beat study has no cross-beat dependencies."]
                    }],
            ],
        ], editor: editor)
        try await approve("treatment", editor: editor)
        var storyboardSections: [[String: Any]] = []
        var bindings: [[String: Any]] = []
        for section in sections {
            let steps: [[String: Any]] = (1...4).map { number in
                let id = "\(section.id).\(String(format: "%02d", number))"
                bindings.append(["stepID": id, "beatIDs": ["color-change"], "reason": "The color study develops across the complete section."])
                return ["id": id, "function": "story", "source_mode": generatedShot != nil && section.id == sections[0].id && number <= 2 ? "generated" : "imported",
                    "subject": "A centered marker moves across a colored field.", "camera": "Static wide composition.",
                    "setting_hint": "stage", "location_view_request": "wide", "character_view_request": [],
                    "prop_request": [], "framing": "wide", "visible_zones": [], "zone_introduces": [],
                    "camera_setup": ["height": "eye_level", "angle": "frontal", "lens_hint": "wide"],
                    "character_blocking": []]
            }
            storyboardSections.append(["id": section.id, "label": section.label, "time_start": section.start,
                "time_end": section.end, "energy": "low", "function": "aufbau", "steps": steps])
        }
        try await run("write_storyboard", ["origin": "agent_proposal", "summary_oneline": "Warm then cool fields follow the song.",
            "causality_bindings": bindings, "sections": storyboardSections], editor: editor)
        try await approve("storyboard", editor: editor)
        let reference = root.appendingPathComponent("bible/stage.png")
        try writeReference(to: reference)
        try ConfirmedIdentityAssetStoreV1.recordIntake(role: .location, identityName: "Stage", identitySlug: "stage",
            paths: ["bible/stage.png"], dataRoot: root)
        try await run("write_bible", ["look": ["style": brief.visualMediumNotes ?? "realistic"],
            "characters": [], "ensembles": [], "props": [], "locations": [[
                "id": "stage", "name": "Stage", "visual_prompt": "A centered marker on a colored field.",
                "attributes": [], "reference_images": [], "sheets": [["view": "wide", "path": "bible/stage.png"]],
                "view_purpose": [["view": "wide", "purpose": "establishing"]], "floorplan": "", "zones": [],
                "scene3d": ["panorama": "", "provider": "", "povs": []],
            ]]], editor: editor)
        try await approve("bible", editor: editor)
        var shots: [[String: Any]] = []
        var execution: [[String: Any]] = []
        var arcs: [[String: Any]] = []
        var generatedOutputURL: URL?
        for section in sections {
            let middle = grid.beats.filter { $0 > section.start && $0 < section.end }
                .min { abs($0 - (section.start + section.end) / 2) < abs($1 - (section.start + section.end) / 2) }
                ?? (section.start + section.end) / 2
            var sectionShotIDs: [String] = []
            for part in 0..<2 {
                let id = "s\(String(format: "%03d", shots.count + 1))"
                let start = part == 0 ? section.start : middle
                let end = part == 0 ? middle : section.end
                let isGenerated = generatedShot != nil && shots.isEmpty
                let path = "fullflow-sources/\(id).mov"
                if isGenerated { generatedOutputURL = projectHome.appendingPathComponent(path) }
                try await writeVideo(to: projectHome.appendingPathComponent(path), duration: end - start + 2, fps: fps,
                    warm: part == 0)
                let shot = try Shot(id: id, section: section.id, timeStart: start, timeEnd: end, durationS: end - start,
                    type: .performance, sourceMode: isGenerated ? .generated : .imported, description: "A centered marker moves across a colored field.",
                    visualPrompt: "Static wide frame of a colored field with a centered moving marker.", mood: "calm",
                    locationRef: "stage", locationView: "wide", keyframeStrategy: .none, sourcePath: isGenerated ? nil : path)
                var object = try dictionary(shot)
                object["character_views"] = []
                object["prop_views"] = []
                if isGenerated {
                    object["scene_video_provider"] = "fal"
                    object["seedance_input_mode"] = "reference"
                    object["reference_image_refs"] = ["bible/stage.png"]
                    object["production_plan"] = ["primary_action": "The marker moves.", "camera_movement": "static",
                        "narrative_beat": "establish", "renderability": "green", "risks": [],
                        "continuity_locks": [], "blocking_anchors": []]
                }
                shots.append(object)
                var executionShot: [String: Any] = ["id": id, "source_mode": isGenerated ? "generated" : "imported",
                    "storyboard_step_ids": (part * 2 + 1...part * 2 + 2).map { "\(section.id).\(String(format: "%02d", $0))" },
                    "start_state": ["summary": "The marker enters the field.", "entity_state_ids": []],
                    "end_state": ["summary": "The marker holds its final position.", "entity_state_ids": []],
                    "blocking": [], "timed_action_beats": [],
                    "acceptance": [["id": "accept-\(id)", "requirement": "Preserve the moving composition.", "severity": "required"]],
                    "primary_action": "The marker moves.", "camera": ["movement_id": "static"],
                    "continuity_locks": [], "renderability": "green", "risks": []]
                if isGenerated, let generatedShot {
                    executionShot["generation_requirement"] = ["modality_id": "video", "mode_ids": [generatedShot.modeID],
                        "duration": ["minimum_seconds": 4, "maximum_seconds": 4, "allows_automatic": false],
                        "requires_output_audio": false]
                    executionShot["core_inputs"] = [:] as [String: String]
                    let demand: [String: Any] = ["id": "stage-anchor", "asset_path": "bible/stage.png",
                        "modality": "image", "semantic_job_id": CoreReferenceSemanticJobIDV1.referenceAnchor,
                        "is_required": true, "priority": 0, "preservation_scope_ids": [], "exclusion_demand_ids": [],
                        "input_slot_id": CoreReferenceInputSlotIDV1.referenceImage, "mode_id": generatedShot.modeID,
                        "identity_lock": false, "entity_id": "stage", "canon_ids": [], "view_id": "wide"]
                    executionShot["reference_demands"] = [demand]
                    executionShot["conditioning"] = ["strategy": "reference_anchor", "rationale": "Retain the confirmed stage image.",
                        "mode_ids": [generatedShot.modeID], "anchor_demand_ids": ["stage-anchor"]]
                }
                execution.append(executionShot)
                sectionShotIDs.append(id)
            }
            arcs.append(["section_id": section.id, "musical_function": "development", "visual_function": "Warm becomes cool.",
                "motif_ids": ["color"], "shot_ids": sectionShotIDs,
                "constants": [["kind": "guidance", "target_id": sectionShotIDs[0], "value": "Keep the marker centered.",
                    "rationale": "A stable composition connects both sources."]], "variations": [],
                "lyrics_relation": "unused", "change_explanation": "The second source changes the color."])
        }
        try await run("write_shotlist", ["shots": shots, "execution_shots": execution,
            "musicvideo_plan": ["performance_segments": [],
                "final_mix": ["original_song_timeline_start_seconds": 0, "original_song_occurrences": 1,
                    "provider_song_audio_muted": true, "approved_additional_layer_ids": []],
                "visual_arc": ["concept": "Color follows the complete song.",
                    "motifs": [["id": "color", "description": "A centered moving marker.", "setup_ids": []]], "sections": arcs],
                "coverage": []]], editor: editor)
        try await approve("shotlist", editor: editor)
        try await run("run_sanity", [:], editor: editor)
        try await approve("sanity", editor: editor)
        try await run("run_phase", ["phase": "frames"], editor: editor)
        try await approve("frames", editor: editor)
        try await run("run_phase", ["phase": "render"], editor: editor)
        if let generatedShot, let generatedOutputURL {
            try await generatedShot.render(editor, generatedOutputURL)
        }
        try await run("assemble_timeline", [:], editor: editor)
        try await approve("render", editor: editor)
        await editor.refreshEngineState()
        guard let assembly = try PipelineAssemblyStore.load(dataRoot: root),
              assembly.plan.placements.map(\.shotID) == shots.compactMap({ $0["id"] as? String }),
              assembly.policy.requiredDurationFrames == totalFrames else {
            throw Failure("Assembly did not preserve every planned shot and the complete track.")
        }
        return Receipt(shotIDs: assembly.plan.placements.map(\.shotID), totalFrames: totalFrames, fps: fps,
            dataRoot: root, projectHome: projectHome,
            canonicalArtifacts: [PipelineLayout.briefFile, PipelineLayout.productionDesignFile,
                PipelineLayout.treatmentCurrentFile, PipelineLayout.storyboardCurrentFile, PipelineLayout.bibleFile,
                PipelineLayout.executionPlanFile, AssemblyPlanV1.relativePath, "assembly.json", MusicAssemblyProofV1.relativePath],
            suppliedInputs: ["Creative decisions and local moving-color videos are deterministic fixture inputs.",
                generatedShot == nil ? "No content-generation provider is called; source mode is imported."
                    : "The first shot uses the real generation path against a deterministic HTTP simulator; later shots are imported."])
    }

    private struct Section { let id: String; let label: String; let start: Double; let end: Double }

    private static func dataRoot(_ editor: EditorViewModel) throws -> URL {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
            throw Failure("The acceptance document has no working pipeline.")
        }
        return root
    }

    private static func approve(_ phase: String, editor: EditorViewModel) async throws {
        let root = try dataRoot(editor)
        try await NativeGateWriter.approve(projectDir: FrameInventory.projectHome(of: root), phase: phase,
            declaredPack: "musicvideo", declaredBinding: editor.declaredPluginBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator)
    }

    private static func run(_ name: String, _ args: [String: Any], editor: EditorViewModel, executor: ToolExecutor? = nil) async throws {
        let result = await (executor ?? ToolExecutor(editor: editor)).execute(name: name, args: args)
        guard !result.isError else {
            throw Failure("\(name): " + result.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n"))
        }
    }

    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw Failure("Fixture encoding failed.")
        }
        return object
    }

    private static func writeAnalysisFixture(dataRoot: URL) throws {
        let song = dataRoot.appendingPathComponent("audio/song.wav")
        let digest = try FileDigest.sha256(of: song)
        let section: [String: Any] = ["index": 0, "start": 0.0, "end": 4.3, "cluster": 0,
            "source": "measured_track_extent", "label": "opening", "confidence": 1.0]
        let object: [String: Any] = ["schema": "analysis/v3", "project": "Fullflow", "song_path": "audio/song.wav",
            "song_sha256": digest, "sample_rate": 48000, "duration_s": 4.3, "bpm": 120,
            "beats": stride(from: 0.0, through: 4.0, by: 0.5).map { $0 }, "downbeats": [0.0, 2.0, 4.0],
            "sections": [section], "downbeat_source": "librosa-heuristic", "pipeline_stages": ["structure"],
            "stage_diagnostics": [["stage": "native_dsp", "status": "succeeded", "detail": "Supplied deterministic analysis fixture; DSP is covered separately."]],
            "structure_candidates": ["librosa", "essentia"].map { ["source": $0, "sections": [section]] as [String: Any] },
            "structure_resolution": ["version": "adaptive-structure/v5", "status": "resolved", "method": "homogeneous_consensus",
                "minimum_section_bars": 8, "candidate_boundary_count": 0, "consensus_boundary_count": 0,
                "accepted_boundary_count": 0, "discarded_boundary_count": 0, "alignment_marker_count": 0,
                "resolved_alignment_marker_count": 0, "detector_sources": ["librosa", "essentia"], "boundary_evidence": []],
            "alignment": []]
        let dir = dataRoot.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: dir.appendingPathComponent("song.json"))
        try JSONSerialization.data(withJSONObject: ["schema": "analysis_measurement_proof/v1", "project": "Fullflow",
            "song_sha256": digest], options: [.sortedKeys]).write(to: dir.appendingPathComponent("song.measurement-proof.json"))
    }

    private static func writeTone(to url: URL, duration: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48000)),
              let samples = buffer.floatChannelData?[0] else { throw Failure("Audio fixture allocation failed.") }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let t = Double(index) / 48000
            let sweep = t * t / duration
            let carrier = 0.65 * sin(2 * .pi * (173 * t + 71 * sweep))
                + 0.25 * sin(2 * .pi * (421 * t + 137 * sweep))
                + 0.1 * sin(2 * .pi * (997 * t + 293 * sweep))
            let envelope = 0.12 + 0.08 * (0.5 + 0.5 * sin(2 * .pi * (0.31 * t + 0.017 * t * t)))
            let fade = min(1, min(t, duration - t) / 0.01)
            samples[index] = Float(carrier * envelope * fade)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func writeReference(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure("Reference allocation failed.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSColor.white.setFill()
        NSRect(x: 140, y: 70, width: 40, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Reference encoding failed.") }
        try data.write(to: url)
    }

    private static func writeVideo(to url: URL, duration: Double, fps: Int, warm: Bool) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure("Video fixture writer failed.") }
        writer.startSession(atSourceTime: .zero)
        let frameCount = Int(ceil(duration * Double(fps)))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? Failure("Video fixture writer stopped.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let pixel else { throw Failure("Video fixture pixel allocation failed.") }
            CVPixelBufferLockBaseAddress(pixel, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 180,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(pixel, [])
                throw Failure("Video fixture graphics allocation failed.")
            }
            context.setFillColor(warm ? CGColor(red: 0.85, green: 0.2, blue: 0.05, alpha: 1)
                : CGColor(red: 0.05, green: 0.2, blue: 0.85, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 80 + 120 * Double(frame) / Double(max(1, frameCount - 1)), y: 65, width: 50, height: 50))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                throw writer.error ?? Failure("Video fixture append failed.")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: Int32(fps)))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure("Video fixture completion failed.") }
    }
}
