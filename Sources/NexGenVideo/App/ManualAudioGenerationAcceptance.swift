import AppKit
import AVFoundation
import MCP
import NexGenEngine

@MainActor
enum ManualAudioGenerationAcceptance {
    static func run(editor: EditorViewModel, sourceVideo: MediaAsset, baseServices: GenerationPanelServices,
                    driver: ProductionVisualSourcesDriver) async throws {
        guard WorkspaceUIAcceptance.isRequested,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }),
              let window = document.windowControllers.compactMap(\.window).first(where: \.isVisible) else {
            throw GateBlocked("Native audio generation requires the actual document window.")
        }
        let output = try await Task.detached { try ManualAudioGenerationTransport.wave() }.value
        let transport = ManualAudioGenerationTransport(output: output)
        let catalog = ModelCatalog()
        catalog.load(entries: ModelCatalog.launchEntries + (try ManualAudioGenerationTransport.entries()))
        let services = GenerationPanelServices(catalog: catalog, preferences: baseServices.preferences,
            activation: { .init(active: [.init(provider: .fal, transport: .api), .init(provider: .higgsfield, transport: .mcp)]) },
            quoteLoader: baseServices.quoteLoader)
        let previousServices = editor.generationPanelServicesOverride
        let previousReconciliation = editor.generationService.reconciliation
        editor.generationPanelServicesOverride = services
        editor.generationService.reconciliation.mcpClient = { $0 == .higgsfield ? transport : nil }
        editor.generationService.reconciliation.mcpReferenceUploader = { url, type in try await transport.upload(url, type: type) }
        defer {
            editor.generationPanelServicesOverride = previousServices
            editor.generationService.reconciliation = previousReconciliation
        }
        let fps = editor.timeline.fps
        var video = Clip(mediaRef: sourceVideo.id, startFrame: 0, durationFrames: fps * 2)
        video.trimStartFrame = fps
        video.trimEndFrame = fps * 5
        editor.timeline.tracks = [Track(type: .video, clips: [video])]
        editor.selectedClipIds = []; editor.selectedTimelineRange = nil
        editor.showGenerationPanel = true
        window.makeKeyAndOrderFront(nil)
        try await driver.click("editor.workspace.edit", in: window, enabled: false)
        try GenericNLEAcceptance.pointerOnClip(video, editor: editor, window: window, driver: driver)
        try await driver.wait("real video clip selection") { editor.selectedClipIds == [video.id] }
        try await driver.click("inspector.tab.AI Edit", in: window, enabled: false)
        try await driver.wait("native source-range and audio-placement scopes") {
            driver.text("ai-edit.scope.Use trimmed portion only", in: window) == "on"
                && driver.text("ai-edit.scope.Place on timeline", in: window) == "on"
                && driver.state("ai-edit.generateSFX", in: window) == true
        }
        try await driver.click("ai-edit.generateSFX", in: window)
        let prefix = "generation.edit."
        try await driver.wait("source-aware audio request in the actual generator") {
            driver.text(prefix + "model", in: window) == "native-acceptance-video-sfx"
                && driver.text(prefix + "slot.Source Video", in: window) == sourceVideo.id
        }
        try await driver.fill(prefix + "intent", value: "A brief soft mechanical click matching the visible movement.", in: window)
        let initialSpend = editor.generationLog.spendEvents.count
        let sfx = try await prepare(prefix: prefix, driver: driver, window: window)
        guard sfx.payload.generationInput.sourceRange?.trim?.trimStartFrame == fps,
              sfx.payload.generationInput.sourceRange?.trim?.sourceFramesConsumed == fps * 2,
              sfx.payload.references.map(\.assetID) == [sourceVideo.id],
              sfx.payload.destination.kind == "timeline", sfx.payload.destination.startFrame == 0,
              sfx.payload.destination.durationSeconds == 2,
              await transport.calls.isEmpty, editor.generationLog.spendEvents.count == initialSpend else {
            throw GateBlocked("The visible SFX package did not preserve the clip range and additional-track destination before approval.")
        }
        try driver.capture("audio-sfx-native-review", target: window)
        try await driver.click(prefix + "discard", in: window)
        let discardStart = ProcessInfo.processInfo.systemUptime
        var discardChecks = 0
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            guard await transport.calls.isEmpty, await transport.uploads.isEmpty,
                  editor.generationLog.spendEvents.count == initialSpend else {
                throw GateBlocked("Discarding the SFX package uploaded, submitted or spent money.")
            }
            discardChecks += 1
        } while ProcessInfo.processInfo.systemUptime - discardStart < 1
        let discardSeconds = ProcessInfo.processInfo.systemUptime - discardStart
        guard driver.state(prefix + "approve", in: window) != true else {
            throw GateBlocked("Discard did not dismiss the prepared SFX approval.")
        }
        let approvedSFX = try await prepare(prefix: prefix, driver: driver, window: window)
        guard approvedSFX.payload.generationInput.sourceRange == sfx.payload.generationInput.sourceRange,
              approvedSFX.payload.destination == sfx.payload.destination else {
            throw GateBlocked("Preparing SFX again changed its reviewed source range or destination.")
        }
        try await driver.click(prefix + "approve", in: window)
        let sfxAsset = try await completed(approvedSFX, editor: editor, driver: driver)
        let sfxCalls = await transport.calls, sfxUploads = await transport.uploads
        guard sfxCalls.count == 1, sfxCalls[0]["model"] == .string("native-acceptance-video-sfx"),
              sfxCalls[0]["prompt"] == .string(approvedSFX.payload.prompt), sfxCalls[0]["duration_seconds"] == .int(2),
              sfxCalls[0]["instrumental"] == .bool(approvedSFX.payload.generationInput.instrumental ?? false),
              sfxCalls[0]["video_url"] == .string("https://media.invalid/native-audio-input.mov"),
              sfxUploads.count == 1, sfxUploads[0].type == "video",
              approvedSFX.payload.references.first?.submittedSHA256 == FileDigest.sha256(of: sfxUploads[0].bytes),
              try FileDigest.sha256(of: sfxAsset.url) == FileDigest.sha256(of: output),
              editor.clipFor(id: video.id) == video,
              editor.timeline.tracks.contains(where: { $0.type == .audio && $0.clips.contains { $0.mediaRef == sfxAsset.id && $0.startFrame == 0 } }) else {
            throw GateBlocked("The actual SFX transport/output/placement differs from the reviewed clip request.")
        }
        guard let retainedSFXTrack = editor.timeline.tracks.first(where: { $0.type == .audio && $0.clips.contains { $0.mediaRef == sfxAsset.id } }) else {
            throw GateBlocked("The native SFX result has no actual audio track to retain.")
        }
        let sfxSourceDuration = try await verifyDuration(sfxUploads[0].bytes, expected: 2, suffix: "mov")
        try await verifyDuration(output, expected: 2, suffix: "wav")
        let sfxArtifacts = try ManualGenerationArtifacts.save(name: "audio-sfx", package: approvedSFX,
            submit: canonicalArguments(sfxCalls[0]), input: sfxUploads[0].bytes,
            output: Data(contentsOf: sfxAsset.url), directory: driver.output)
        try driver.record("native clip to SFX exact source range", fields: ["packageID": approvedSFX.id, "artifacts": sfxArtifacts,
            "inputSHA256": FileDigest.sha256(of: sfxUploads[0].bytes), "outputSHA256": FileDigest.sha256(of: output),
            "sourceTrimStartFrames": fps, "sourceFramesConsumed": fps * 2, "sourceFPS": fps,
            "decodedSourceDurationSeconds": sfxSourceDuration, "submitFormat": "canonical-mcp-arguments",
            "discardQuiescenceSeconds": discardSeconds, "discardQuiescenceChecks": discardChecks,
            "discardCallsAfter": 0, "discardUploadsAfter": 0, "nativeDiscardAndApproval": true,
            "originalClipRetained": true, "scope": "Actual discovery, compiler, MCP argument adapter and native controls with isolated MCP/upload simulation; no live provider claim."])

        try GenericNLEAcceptance.pointerOnClip(video, editor: editor, window: window, driver: driver)
        try await driver.wait("original clip for native video-to-music") { editor.selectedClipIds == [video.id] }
        try await driver.click("inspector.tab.AI Edit", in: window, enabled: false)
        try await driver.click("ai-edit.generateMusic", in: window)
        try await driver.wait("native lyrics-capable video-to-music request") {
            driver.text(prefix + "model", in: window) == "native-acceptance-video-music"
                && driver.text(prefix + "slot.Source Video", in: window) == sourceVideo.id
        }
        let lyricBody = "The city wakes in morning light."
        let lyrics = "[Verse] " + lyricBody
        try await driver.fill(prefix + "intent", value: "A quiet voice and sparse accompaniment matching this gesture.", in: window)
        try await driver.fill(prefix + "lyrics", value: lyrics, in: window)
        let lyrical = try await prepare(prefix: prefix, driver: driver, window: window)
        guard lyrical.payload.generationInput.lyrics == lyrics, !lyrical.payload.prompt.localizedCaseInsensitiveContains(lyricBody),
              lyrical.payload.generationInput.sourceRange?.trim?.trimStartFrame == fps,
              lyrical.payload.generationInput.sourceRange?.trim?.sourceFramesConsumed == fps * 2,
              lyrical.payload.destination.kind == "timeline" else {
            throw GateBlocked("The native lyrics or additional-track scope disappeared from video-to-music review.")
        }
        try driver.capture("native-video-music-lyrics-review", target: window)
        try await driver.click(prefix + "approve", in: window)
        let lyricalAsset = try await completed(lyrical, editor: editor, driver: driver)
        let lyricalCalls = await transport.calls
        guard lyricalCalls.count == 2, lyricalCalls[1]["lyrics"] == .string(lyrics),
              lyricalCalls[1]["model"] == .string("native-acceptance-video-music"),
              lyricalCalls[1]["video_url"] == .string("https://media.invalid/native-audio-input.mov"),
              lyricalCalls[1]["duration_seconds"] == .int(2), lyricalCalls[1]["instrumental"] == .bool(false),
              lyricalCalls[1]["prompt"] == .string(lyrical.payload.prompt), !lyrical.payload.prompt.localizedCaseInsensitiveContains(lyricBody),
              try FileDigest.sha256(of: lyricalAsset.url) == FileDigest.sha256(of: output), editor.clipFor(id: video.id) == video,
              editor.timeline.tracks.first(where: { $0.id == retainedSFXTrack.id }) == retainedSFXTrack,
              editor.timeline.tracks.contains(where: { $0.type == .audio && $0.id != retainedSFXTrack.id
                  && $0.clips.contains { $0.mediaRef == lyricalAsset.id && $0.startFrame == 0 } }) else {
            throw GateBlocked("Native video-to-music did not submit the exact approved lyrics and compiled direction.")
        }
        let lyricalUploads = await transport.uploads
        guard lyricalUploads.count == 2, lyricalUploads[1].type == "video",
              lyrical.payload.references.first?.submittedSHA256 == FileDigest.sha256(of: lyricalUploads[1].bytes) else {
            throw GateBlocked("The native video-to-music request has no exact second uploaded source-video receipt.")
        }
        let lyricalSourceDuration = try await verifyDuration(lyricalUploads[1].bytes, expected: 2, suffix: "mov")
        let lyricalArtifacts = try ManualGenerationArtifacts.save(name: "audio-lyrics", package: lyrical,
            submit: canonicalArguments(lyricalCalls[1]), input: lyricalUploads[1].bytes,
            output: Data(contentsOf: lyricalAsset.url), directory: driver.output)
        try driver.record("native video music preserves separate lyrics", fields: ["packageID": lyrical.id, "artifacts": lyricalArtifacts,
            "lyricsPreserved": true, "compiledDirectionMatched": true, "originalRetained": true,
            "sourceFPS": fps, "sourceTrimStartFrames": fps, "sourceFramesConsumed": fps * 2,
            "decodedSourceDurationSeconds": lyricalSourceDuration, "submitFormat": "canonical-mcp-arguments",
            "additionalAudioTrack": true])

        try await driver.click("media.tab.Music", in: window, enabled: false)
        try await driver.picker("music.model", title: "Acceptance video music", expected: "native-acceptance-video-music", in: window)
        let retainedTimeline = editor.timeline
        var availability: [[String: Any]] = []
        for kind in ["empty", "audioOnly"] {
            editor.timeline.tracks = kind == "empty" ? [] : [Track(type: .audio, clips: [
                Clip(mediaRef: sfxAsset.id, mediaType: .audio, sourceClipType: .audio, startFrame: 0, durationFrames: fps * 2)])]
            try await driver.wait("actual music video unavailable " + kind) {
                driver.text("music.source", in: window) == "No video" && driver.state("music.prepare", in: window) == false
            }
            let menu = try await inspectMusicMenu(driver: driver, window: window)
            guard menu["Use Timeline Video"] == false, menu["Mood"] == false,
                  driver.text("music.input", in: window) == "Video to Music",
                  MusicSourcePreparation.timelineSpan(editor: editor) == nil, await transport.calls.count == 2 else {
                throw GateBlocked("An empty or audio-only timeline enabled video scoring or Mood.")
            }
            availability.append(["kind": kind, "trackTypes": editor.timeline.tracks.map { $0.type.rawValue },
                "inputMode": driver.text("music.input", in: window) ?? "",
                "useTimelineVideoEnabled": menu["Use Timeline Video"]!, "moodEnabled": menu["Mood"]!,
                "prepareEnabled": driver.state("music.prepare", in: window) == true])
        }
        editor.timeline = retainedTimeline
        try await driver.picker("music.input", title: "Text to Music", expected: "Text to Music", in: window)
        try await driver.menu("music.actions", title: "Use Timeline Video", in: window)
        try await driver.wait("actual Use Timeline Video action") {
            driver.text("music.input", in: window) == "Video to Music" && driver.state("music.prepare", in: window) == true
        }
        let panelDirection = "Solo piano for the visible movement."
        let direction = panelDirection + " A quiet rhythmic pulse for the actual two-second cut."
        try await driver.fill("music.intent", value: panelDirection, in: window, requireFocusExit: true)
        try await driver.menu("music.actions", path: ["Mood", "Ambient"], in: window)
        try await driver.wait("actual retained panel direction and locked input") {
            driver.text("agent.dialog.direction", in: window) == panelDirection
                && driver.state("music.model", in: window) == false && driver.state("music.input", in: window) == false
        }
        try await driver.click("editing.add-text", in: window)
        try await driver.wait("actual later music source binding change") { editor.timeline != retainedTimeline }
        let staleTimeline = editor.timeline
        try await driver.click("agent.dialog.confirm", in: window)
        try await driver.wait("visible changed music input refusal") {
            driver.text("music.result", in: window)?.contains("input changed") == true
        }
        guard editor.timeline == staleTimeline, await transport.calls.count == 2, window.attachedSheet == nil,
              driver.text("music.intent", in: window) == panelDirection else {
            throw GateBlocked("A later input change submitted music or discarded the original direction.")
        }
        let staleError = driver.text("music.result", in: window) ?? ""
        try GenericNLEAcceptance.pointerOnClip(video, editor: editor, window: window, driver: driver)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("native music source edit undo") { editor.timeline == retainedTimeline }
        try await driver.menu("music.actions", path: ["Mood", "Ambient"], in: window)
        try await driver.wait("actual preselected music direction") {
            driver.text("agent.dialog.choice.mood.ambient", in: window) == "selected"
                && driver.text("agent.dialog.direction", in: window) == panelDirection
                && driver.state("music.model", in: window) == false && driver.state("music.input", in: window) == false
        }
        try await driver.click("agent.dialog.choice.character.sparse", in: window)
        try await driver.click("agent.dialog.choice.character.warm", in: window)
        try await driver.fill("agent.dialog.direction", value: direction, in: window, requireFocusExit: true)
        guard driver.text("agent.dialog.choice.character.sparse", in: window) == "selected",
              driver.text("agent.dialog.choice.character.warm", in: window) == "selected" else {
            throw GateBlocked("The actual music direction did not retain both character choices.")
        }
        try driver.capture("native-music-mood-direction", target: window)
        let timelineBeforeMusic = editor.timeline
        try await driver.click("agent.dialog.confirm", in: window)
        let sheet = try await reviewSheet(window: window, driver: driver)
        let music = try await copyPackage(prefix: "generation.review.", driver: driver, window: sheet)
        let composed = music.payload.intent
        guard composed == (["Ambient", "Sparse", "Warm"] + [direction]).joined(separator: ", "),
              music.payload.prompt.hasPrefix(composed),
              music.payload.generationInput.intent == composed,
              music.payload.operation == "music", music.payload.target.modelId == "native-acceptance-video-music",
              music.payload.references.count == 1, music.payload.generationInput.duration == 2,
              music.payload.destination.kind == "timeline", music.payload.destination.startFrame == 0,
              await transport.calls.count == 2, editor.timeline == timelineBeforeMusic else {
            throw GateBlocked("Timeline Music did not freeze its real video before the visible approval.")
        }
        try driver.capture("timeline-music-native-review", target: sheet)
        try await driver.click("generation.review.approve", in: sheet)
        let musicAsset = try await completed(music, editor: editor, driver: driver)
        let musicCalls = await transport.calls, musicUploads = await transport.uploads
        guard musicCalls.count == 3, musicCalls[2]["prompt"] == .string(music.payload.prompt),
              musicCalls[2]["duration_seconds"] == .int(2), musicUploads.count == 3,
              music.payload.references[0].submittedSHA256 == FileDigest.sha256(of: musicUploads[2].bytes),
              try FileDigest.sha256(of: musicAsset.url) == FileDigest.sha256(of: output),
              editor.clipFor(id: video.id) == video,
              editor.timeline.tracks.flatMap(\.clips).contains(where: { $0.mediaRef == sfxAsset.id }),
              editor.timeline.tracks.contains(where: { $0.type == .audio && $0.clips.contains { $0.mediaRef == musicAsset.id && $0.startFrame == 0 } }) else {
            throw GateBlocked("Timeline Music lost the approved preview or replaced an existing clip.")
        }
        let previewDuration = try await verifyDuration(musicUploads[2].bytes, expected: 2, suffix: "mov", requireSilent: true)
        try driver.capture("native-audio-results-on-timeline", target: window)
        let musicArtifacts = try ManualGenerationArtifacts.save(name: "audio-timeline", package: music,
            submit: canonicalArguments(musicCalls[2]), input: musicUploads[2].bytes,
            output: Data(contentsOf: musicAsset.url), directory: driver.output)
        try driver.record("native timeline video to music", fields: ["packageID": music.id, "artifacts": musicArtifacts,
            "previewSHA256": FileDigest.sha256(of: musicUploads[2].bytes), "previewDurationSeconds": previewDuration,
            "previewHasNoAudio": true, "sourceAndPriorSFXRetained": true, "outputID": musicAsset.id,
            "submitFormat": "canonical-mcp-arguments",
            "direction": direction, "panelDirection": panelDirection, "composedIntent": composed,
            "mood": "Ambient", "character": ["Sparse", "Warm"], "menuAvailability": availability,
            "dialogModelAndInputDisabled": true, "staleBindingError": staleError,
            "nativeStaleBindingUndo": true, "compiledDirectionMatched": true])
        try await ManualAudioOptionsAcceptance.run(editor: editor, services: services, driver: driver, window: window, output: output)
    }

    private static func inspectMusicMenu(driver: ProductionVisualSourcesDriver, window: NSWindow) async throws -> [String: Bool] {
        @MainActor final class Inspection {
            var menu: NSMenu?
            var values: [String: Bool] = [:]
            var closed = false
        }
        let inspection = Inspection()
        let begin = NativeOwnerMenuObserver(name: NSMenu.didBeginTrackingNotification) { menu in
            guard inspection.menu == nil else { return }
            inspection.menu = menu
            menu.update()
            for item in menu.items where ["Use Timeline Video", "Mood"].contains(item.title) {
                inspection.values[item.title] = item.isEnabled
            }
            try? driver.pressKey(53, characters: "\u{1b}", in: window)
            menu.cancelTracking()
        }
        let end = NativeOwnerMenuObserver(name: NSMenu.didEndTrackingNotification) { menu in
            if menu === inspection.menu { inspection.closed = true }
        }
        defer { NotificationCenter.default.removeObserver(begin); NotificationCenter.default.removeObserver(end) }
        try await driver.click("music.actions", in: window)
        try await driver.wait("actual disabled Music menu inspected") { inspection.closed }
        guard Set(inspection.values.keys) == ["Use Timeline Video", "Mood"] else { throw GateBlocked("The actual Music menu items were not inspected.") }
        return inspection.values
    }

    private static func prepare(prefix: String, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws -> GenerationPackageV1 {
        try await driver.click(prefix + "review", in: window)
        try await driver.wait("actual compiled audio package") { driver.state(prefix + "approve", in: window) == true }
        return try await copyPackage(prefix: prefix, driver: driver, window: window)
    }

    private static func copyPackage(prefix: String, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws -> GenerationPackageV1 {
        try await driver.click(prefix + "package.details", in: window)
        try await driver.click(prefix + "package.copy-package", in: window)
        guard let text = NSPasteboard.general.string(forType: .string) else { throw GateBlocked("The actual audio package was not copied.") }
        return try JSONDecoder().decode(GenerationPackageV1.self, from: Data(text.utf8))
    }

    private static func reviewSheet(window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("actual Music review sheet", seconds: 60) {
            window.attachedSheet.map { driver.state("generation.review.approve", in: $0) == true } == true
        }
        guard let sheet = window.attachedSheet, sheet.isKeyWindow else { throw GateBlocked("The Music review sheet has no native keyboard focus.") }
        return sheet
    }

    private static func completed(_ package: GenerationPackageV1, editor: EditorViewModel,
                                  driver: ProductionVisualSourcesDriver) async throws -> MediaAsset {
        try await driver.wait("actual generated audio file", seconds: 60) {
            editor.mediaAssets.contains { $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none }
        }
        guard let asset = editor.mediaAssets.first(where: { $0.generationInput?.generationPackageID == package.id && $0.generationStatus == .none }),
              asset.type == .audio else { throw GateBlocked("The reviewed audio did not produce a real library asset.") }
        return asset
    }

    private static func canonicalArguments(_ arguments: [String: Value]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Value.object(arguments))
    }

    @discardableResult
    private static func verifyDuration(_ bytes: Data, expected: Double, suffix: String, requireSilent: Bool = false) async throws -> Double {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
            defer { try? FileManager.default.removeItem(at: url) }
            try bytes.write(to: url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, abs(duration - expected) < 0.02 else { throw GateBlocked("The actual decoded generation input/output duration is wrong.") }
            if requireSilent {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard audioTracks.isEmpty else { throw GateBlocked("The frozen Timeline Music preview still contains audio.") }
            }
            return duration
        }.value
    }
}
