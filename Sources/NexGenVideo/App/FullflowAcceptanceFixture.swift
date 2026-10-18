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
        let nativeGateApprovals: [MusicvideoNativeAcceptance.GateEvidence]
        let nativeBibleBlocker: [String: Any]
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

    static func makeDocument(evidenceURL: URL, generatedShot: GeneratedShotScenario? = nil) async throws -> (document: VideoProject, receipt: Receipt) {
        guard let binding = PluginLoader.liveBinding(id: "musicvideo") else {
            throw Failure("The acceptance fixture requires the loaded Musicvideo pack.")
        }
        let song = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-song-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: song) }
        try writeTone(to: song, duration: 4.3)
        let flow = try await MusicvideoHostFlowAcceptance.start(track: song, lyrics: nil, binding: binding, evidenceURL: evidenceURL)
        try await flow.runAnalysis { $0.registerAudioDecoder(AVFoundationAudioDecoder()) }
        try verifyMeasuredAnalysis(dataRoot: flow.dataRoot, evidenceURL: evidenceURL)
        try await flow.finishPlanningIntake(sectionLabels: ["opening"], finalResolution: .res720p)
        return (flow.document, try await finishPlanning(editor: flow.editor, evidenceURL: evidenceURL,
            initialGateApprovals: flow.gateApprovals, generatedShot: generatedShot))
    }

    static func finishPlanning(editor: EditorViewModel, evidenceURL: URL,
                               initialGateApprovals: [MusicvideoNativeAcceptance.GateEvidence],
                               generatedShot: GeneratedShotScenario? = nil) async throws -> Receipt {
        let root = try dataRoot(editor)
        var nativeGateApprovals = initialGateApprovals
        func approve(_ phase: String, editor: EditorViewModel) async throws {
            nativeGateApprovals.append(try await MusicvideoNativeAcceptance.approve(phase, editor: editor, evidenceURL: evidenceURL))
        }
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
        let nativeBibleBlocker = try await WorkspaceUIAcceptance.captureBibleBlocker(editor: editor, evidenceURL: evidenceURL)
        let confirmed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root).entries.values.filter {
            $0.role == .location && $0.identitySlug == "stage"
        }
        guard confirmed.count == 1 else { throw Failure("Bible requires the stage image confirmed through native location intake.") }
        try await run("copy_project_file", ["from": confirmed[0].path, "to": "bible/stage.png"], editor: editor)
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
                let renderDuration = (end - start + 2).rounded(.up)
                try await writeVideo(to: projectHome.appendingPathComponent(path), duration: isGenerated ? renderDuration : end - start + 2, fps: fps,
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
                    "acceptance": [["id": "accept-\(id)", "requirement": "Preserve the moving composition.", "severity": "required"]]]
                if isGenerated, let generatedShot {
                    executionShot["generation_requirement"] = ["modality_id": "video", "mode_ids": [generatedShot.modeID],
                        "duration": ["minimum_seconds": renderDuration, "maximum_seconds": renderDuration, "allows_automatic": false],
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
                } else {
                    executionShot["primary_action"] = "The marker moves."
                    executionShot["camera"] = ["movement_id": "static"]
                    executionShot["continuity_locks"] = [] as [String]
                    executionShot["renderability"] = "green"
                    executionShot["risks"] = [] as [String]
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
        let sanityData = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.sanityReportFile))
        let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        try sanityData.write(to: evidenceURL.appendingPathComponent("scale-\(Int((scale * 100).rounded()))-fullflow-sanity.json"), options: .atomic)
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
        guard nativeGateApprovals.map(\.phase) == ["project_init", "analysis", "brief", "production_design", "treatment",
            "storyboard", "bible", "shotlist", "sanity", "frames", "render"] else {
            throw Failure("Native approval evidence does not cover the complete ordered Musicvideo workflow.")
        }
        return Receipt(shotIDs: assembly.plan.placements.map(\.shotID), totalFrames: totalFrames, fps: fps,
            dataRoot: root, projectHome: projectHome,
            canonicalArtifacts: [PipelineLayout.briefFile, PipelineLayout.productionDesignFile,
                PipelineLayout.treatmentCurrentFile, PipelineLayout.storyboardCurrentFile, PipelineLayout.bibleFile,
                PipelineLayout.executionPlanFile, AssemblyPlanV1.relativePath, "assembly.json", MusicAssemblyProofV1.relativePath],
            suppliedInputs: ["Creative decisions and local moving-color videos are deterministic fixture inputs.",
                generatedShot == nil ? "No content-generation provider is called; source mode is imported."
                    : "The first shot uses the real generation path against a deterministic HTTP simulator; later shots are imported.",
                "Agent phase handoffs use a recording transport; no live LLM is called."],
            nativeGateApprovals: nativeGateApprovals, nativeBibleBlocker: nativeBibleBlocker)
    }

    private struct Section { let id: String; let label: String; let start: Double; let end: Double }

    private static func dataRoot(_ editor: EditorViewModel) throws -> URL {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home) else {
            throw Failure("The acceptance document has no working pipeline.")
        }
        return root
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

    private static func verifyMeasuredAnalysis(dataRoot: URL, evidenceURL: URL) throws {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure("The real analysis runner did not write a readable canonical analysis object.")
        }
        let beats = object["beats"] as? [Double]
        let downbeats = object["downbeats"] as? [Double]
        let sections = object["sections"] as? [[String: Any]]
        let summary: [String: Any] = [
            "analysis_sha256": try FileDigest.sha256(of: url),
            "duration_s": object["duration_s"] ?? NSNull(), "bpm": object["bpm"] ?? NSNull(),
            "sample_rate": object["sample_rate"] ?? NSNull(),
            "beats_count": beats?.count ?? -1, "beats": Array((beats ?? []).prefix(16)),
            "downbeats_count": downbeats?.count ?? -1, "downbeats": Array((downbeats ?? []).prefix(8)),
            "sections_count": sections?.count ?? -1,
            "sections": Array((sections ?? []).prefix(4)).map { $0.filter { ["start", "end", "label", "source"].contains($0.key) } },
        ]
        let diagnostic = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
        try diagnostic.write(to: evidenceURL.appendingPathComponent("scale-\(Int((scale * 100).rounded()))-fullflow-analysis.json"), options: .atomic)
        func mismatch(_ expected: String) -> Failure {
            Failure("Real fixture analysis expected \(expected); measured \(String(decoding: diagnostic, as: UTF8.self))")
        }
        guard let duration = object["duration_s"] as? Double, abs(duration - 4.3) < 0.01 else {
            throw mismatch("4.3 seconds within 0.01 seconds")
        }
        guard let bpm = object["bpm"] as? Double, abs(bpm - 120) < 5 else {
            throw mismatch("120 BPM within 5 BPM")
        }
        guard let measuredBeats = beats, measuredBeats.count >= 6,
              let measuredDownbeats = downbeats, !measuredDownbeats.isEmpty else {
            throw mismatch("at least six measured beats and a nonempty downbeat grid")
        }
        guard let measuredSections = sections, measuredSections.count == 1 else {
            throw mismatch("one measured section")
        }
        guard let start = measuredSections[0]["start"] as? Double, abs(start) < 0.01,
              let end = measuredSections[0]["end"] as? Double, abs(end - 4.3) < 0.01 else {
            throw mismatch("a section covering 0–4.3 seconds within 0.01 seconds")
        }
        guard measuredSections[0]["label"] as? String != "opening" else {
            throw mismatch("no supplied opening label before interpretation")
        }
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
            let envelope = 0.012 + 0.008 * (0.5 + 0.5 * sin(2 * .pi * (0.31 * t + 0.017 * t * t)))
            let beatTime = t.truncatingRemainder(dividingBy: 0.5)
            let click = beatTime < 0.04 ? 0.6 * exp(-40 * beatTime) * sin(2 * .pi * 1000 * beatTime) : 0
            let fade = min(1, min(t, duration - t) / 0.01)
            samples[index] = Float((carrier * envelope + click) * fade)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func writeReference(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure("Reference allocation failed.") }
        // Fixture pixels must stay fixed when the app theme changes.
        let pixels = context.cgContext
        pixels.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        pixels.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        pixels.fill(CGRect(x: 140, y: 70, width: 40, height: 40))
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
