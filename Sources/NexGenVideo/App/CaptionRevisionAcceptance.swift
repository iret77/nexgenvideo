import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum CaptionRevisionAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Caption revision acceptance requires its isolated native process.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let package = output.appendingPathComponent("Caption revision.ngv", isDirectory: true)
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let videoURL = media.appendingPathComponent("Movement.mov"), audioURL = media.appendingPathComponent("Voice.wav")
        try await CaptionRevisionFrameFixture.write(to: videoURL)
        try FullflowAcceptanceFixture.writeTone(to: audioURL, duration: 6)
        let picture = MediaAsset(id: "picture", url: videoURL, type: .video, name: "Movement", duration: 6)
        picture.hasAudio = false
        let voice = MediaAsset(id: "voice", url: audioURL, type: .audio, name: "Voice", duration: 6)
        var timeline = Timeline(); timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        let video = Clip(id: "visual", mediaRef: picture.id, startFrame: 0, durationFrames: 180, linkGroupId: "speech-link")
        let audio = Clip(id: "voice-clip", mediaRef: voice.id, mediaType: .audio, sourceClipType: .audio,
            startFrame: 0, durationFrames: 180, linkGroupId: "speech-link")
        let first = Clip(id: "caption-one", mediaRef: "text:first", mediaType: .text, sourceClipType: .text,
            startFrame: 0, durationFrames: 90, transform: .init(centerX: 0.5, centerY: 0.7, width: 0.9, height: 0.15),
            captionGroupId: "existing-captions", textContent: "Hello um wurld", textStyle: .init(fontSize: 20))
        let second = Clip(id: "caption-two", mediaRef: "text:second", mediaType: .text, sourceClipType: .text,
            startFrame: 90, durationFrames: 30, transform: first.transform,
            captionGroupId: first.captionGroupId, textContent: "Fal cloud", textStyle: first.textStyle)
        timeline.tracks = [Track(id: "caption-track", type: .video, clips: [first, second]),
            Track(id: "picture-track", type: .video, clips: [video]), Track(id: "voice-track", type: .audio, clips: [audio])]
        var manifest = MediaManifest(); manifest.entries = [picture.toManifestEntry(projectURL: package), voice.toManifestEntry(projectURL: package)]
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let runtime = FixtureRuntime()
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil })
        let document = try await VideoProject.load(from: package, agentService: service)
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The caption revision project did not open.") }
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); window.setContentSize(AppTheme.Window.projectMin)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "caption-revision-owner")
        let speech = FixtureSpeech(expectedSHA256: try FileDigest.sha256(of: editor.mediaResolver.resolveURL(for: voice.id) ?? audioURL))
        editor.captionTranscriptionClient = .init(transcribe: { url, video, range, censor, locale in
            try speech.transcribe(url, video: video, range: range, censor: censor, locale: locale)
        }, supportedLocales: { [Locale(identifier: "en_US")] })
        var closed = false
        defer { service.cancel(); if !closed { document.close() } }
        func save(_ name: String, _ value: Timeline) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"))
        }
        func captions() async throws {
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            try await driver.click("media.tab.Captions", in: window, enabled: false)
            try await driver.wait("caption actions ready") { editor.mediaPanelTab(for: .edit) == .captions && !service.isStreaming && !service.isComposerBlocked }
        }
        func propose(_ kind: CaptionRevisionScope.Kind, suffix: String = "") async throws -> CaptionRevisionPlan {
            try await captions()
            runtime.arguments = kind == .captions
                ? ["kind": "captions", "changes": [["clipId": first.id, "text": "Hello um world" + suffix],
                    ["clipId": second.id, "text": "fal.ai" + suffix]]]
                : ["kind": "speech_cuts", "words": [1], "cutAggressiveness": "balanced"]
            runtime.kind = kind
            try await driver.menu("captions.actions", title: kind == .captions ? "Fix names & jargon" : "Propose speech cuts…", in: window)
            try await driver.wait("native caption task staged", seconds: 30) { service.pendingFunction?.captionRevisionScope?.kind == kind }
            try await driver.click("agent.task.run", in: window)
            try await driver.wait("actual bounded caption proposal", seconds: 30) { !service.isStreaming && service.pendingDialog?.purpose == .captionRevision }
            guard runtime.failure == nil, let plan = service.pendingDialog?.captionRevision,
                  plan.scope.kind == kind, driver.state("agent.dialog.confirm", in: window) == false,
                  service.dialogChoiceSelections["caption-revision"]?.isEmpty != false else {
                throw GateBlocked(runtime.failure ?? "Caption changes were preselected or applied before native review.")
            }
            for row in plan.rows {
                let id = "captions.revision.choice." + row.id
                try await driver.reveal(id, in: window)
                guard driver.text(id, in: window) == row.timeRange + " · " + row.before + " → " + row.after else {
                    throw GateBlocked("The native caption proposal did not show its exact before/after text and time.")
                }
                try driver.visible([id], in: window)
            }
            if kind == .speechCuts {
                guard plan.captionImpactRows.count == 2 else { throw GateBlocked("The spanning caption and its adjacent follower were not included in speech review.") }
                for row in plan.captionImpactRows {
                    let id = "captions.revision.impact." + row.id
                    try await driver.reveal(id, in: window)
                    guard driver.text(id, in: window) == row.timeRange + " · " + row.before + " → " + row.after else {
                        throw GateBlocked("Native speech review omitted a caption's exact before/after text or old/new interval.")
                    }
                    try driver.visible([id], in: window)
                }
                try driver.record("native speech caption impacts visible", fields: ["proposal": runtime.proposals,
                    "ids": plan.captionImpactRows.map(\.id), "before": plan.captionImpactRows.map(\.before),
                    "after": plan.captionImpactRows.map(\.after), "times": plan.captionImpactRows.map(\.timeRange)])
            }
            try driver.record("native caption proposal visible", fields: ["kind": kind.rawValue,
                "ids": plan.rows.map(\.id), "before": plan.rows.map(\.before), "after": plan.rows.map(\.after),
                "times": plan.rows.map(\.timeRange), "applyEnabled": driver.state("agent.dialog.confirm", in: window) == true,
                "selected": Array(service.dialogChoiceSelections["caption-revision"] ?? []).sorted()])
            try JSONEncoder().encode(plan).write(to: output.appendingPathComponent("proposal-\(runtime.proposals).json"))
            try driver.capture("proposal-\(runtime.proposals)", target: window)
            return plan
        }
        func dismiss() async throws {
            try await driver.click("agent.dialog.cancel", in: window)
            try await driver.wait("native caption proposal dismissed") { service.pendingDialog == nil && !service.isStreaming }
        }
        func choose(_ id: String) async throws {
            try await driver.click("captions.revision.choice." + id, in: window)
            try await driver.wait("explicit single caption choice") { service.dialogChoiceSelections["caption-revision"] == [id] }
        }
        func documentUndo(_ target: Timeline, redo: Bool = false) async throws {
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            guard let clip = editor.timeline.tracks.flatMap(\.clips).first(where: { $0.mediaType == .video }) else {
                throw GateBlocked("The native Undo target has no actual timeline picture.")
            }
            try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
            try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: window)
            try await driver.wait(redo ? "single native caption redo" : "single native caption undo") { editor.timeline == target }
        }
        do {
            try await driver.wait("actual caption viewport and scale") {
                window.contentView?.bounds.size == AppTheme.Window.projectMin
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            let baseline = editor.timeline
            try save("before", baseline)
            _ = try await propose(.captions)
            guard editor.timeline == baseline else { throw GateBlocked("Preparing caption changes mutated the timeline.") }
            try await dismiss()
            guard editor.timeline == baseline else { throw GateBlocked("Cancel applied caption changes.") }
            try save("after-cancel", editor.timeline)
            _ = try await propose(.captions)
            try await choose(first.id)
            try await driver.click("agent.dialog.confirm", in: window)
            try await driver.wait("selective caption changes applied") { service.pendingDialog == nil && !service.isStreaming }
            let applied = editor.timeline
            var expected = baseline
            expected.tracks[0].clips[0].textContent = "Hello um world"
            guard applied == expected else { throw GateBlocked("Caption revision changed an unselected row, timing, media or audio.") }
            try save("caption-applied", applied)
            try await documentUndo(baseline); try save("caption-undo", editor.timeline)
            try await documentUndo(applied, redo: true); try save("caption-redo", editor.timeline)
            _ = try await propose(.captions, suffix: "!")
            try await driver.click("editing.add-text", in: window)
            try await driver.wait("actual independent Add Text") { editor.timeline != applied }
            let changed = editor.timeline
            try save("stale-timeline-before-apply", changed)
            try await choose(first.id); try await driver.click("agent.dialog.confirm", in: window)
            try await driver.wait("visible stale caption timeline refusal") { driver.text("agent.dialog.error", in: window)?.contains("changed") == true }
            guard editor.timeline == changed else { throw GateBlocked("A stale caption proposal partially applied.") }
            try driver.record("stale caption timeline refused", fields: ["error": driver.text("agent.dialog.error", in: window) ?? ""])
            try driver.capture("stale-timeline-refused", target: window)
            try save("stale-timeline-refused", editor.timeline)
            try await dismiss(); try await documentUndo(applied)
            _ = try await propose(.speechCuts)
            guard let source = editor.mediaResolver.resolveURL(for: voice.id) else { throw GateBlocked("The actual voice source disappeared.") }
            let originalBytes = try await Task.detached { try Data(contentsOf: source) }.value
            let changedBytes = Data(originalBytes.reversed())
            try await Task.detached { try changedBytes.write(to: source, options: .atomic) }.value
            do {
                try await choose("speech-cuts"); try await driver.click("agent.dialog.confirm", in: window)
                try await driver.wait("visible stale caption source refusal") { driver.text("agent.dialog.error", in: window)?.contains("changed") == true }
                guard editor.timeline == applied else { throw GateBlocked("Caption changes applied against changed source bytes.") }
                try driver.record("stale caption source refused", fields: ["error": driver.text("agent.dialog.error", in: window) ?? "",
                    "changedSHA256": FileDigest.sha256(of: changedBytes), "originalSHA256": FileDigest.sha256(of: originalBytes)])
                try driver.capture("stale-source-refused", target: window)
                try save("stale-source-refused", editor.timeline)
                try await Task.detached { try originalBytes.write(to: source, options: .atomic) }.value
                try changedBytes.write(to: output.appendingPathComponent("changed-source.bin"))
            } catch {
                try? await Task.detached { try originalBytes.write(to: source, options: .atomic) }.value
                throw error
            }
            try await dismiss()
            let speechPlan = try await propose(.speechCuts)
            guard let removal = speechPlan.wordRemoval, removal.ranges == [.init(start: 30, end: 60)],
                  removal.before == "Hello um world", removal.after == "Hello world", removal.edits.removedTexts == ["um"] else {
                throw GateBlocked("The actual get_transcript indices did not produce exactly frames 30…60.")
            }
            let speechBefore = editor.timeline
            try save("speech-before", speechBefore)
            try await choose("speech-cuts"); try await driver.click("agent.dialog.confirm", in: window)
            try await driver.wait("native speech cut applied") { service.pendingDialog == nil && !service.isStreaming && editor.timeline != speechBefore }
            let cut = editor.timeline
            try requireCut(before: speechBefore, after: cut, captionEdits: removal.edits.captionEdits)
            try save("speech-after", cut)
            try await documentUndo(speechBefore); try save("speech-undo", editor.timeline)
            try await documentUndo(cut, redo: true); try save("speech-redo", editor.timeline)
            try driver.capture("linked-speech-cut-undo-redo", target: window)
            guard runtime.failure == nil, speech.calls >= 4 else { throw GateBlocked(runtime.failure ?? "The actual transcript boundary was not called.") }
            let movie = try await export(editor: editor, driver: driver, output: output)
            let decoded = try await decode(sourceVideo: editor.mediaResolver.resolveURL(for: picture.id) ?? videoURL,
                sourceAudio: source, movie: movie, output: output)
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("native revised project saved", seconds: 30) { !document.isDocumentEdited }
            let savedManifest = editor.mediaManifest
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened); reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == cut, reopened.editorViewModel.mediaManifest == savedManifest,
                  let reopenedSource = reopened.editorViewModel.mediaResolver.resolveURL(for: voice.id),
                  try FileDigest.sha256(of: reopenedSource) == speech.expectedSHA256 else { throw GateBlocked("Save/reopen changed the approved cut, source bytes or media identities.") }
            try JSONEncoder().encode(reopened.editorViewModel.timeline).write(to: output.appendingPathComponent("reopened.json"))
            try JSONEncoder().encode(savedManifest).write(to: output.appendingPathComponent("manifest.json"))
            try JSONSerialization.data(withJSONObject: runtime.calls, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("tools.json"))
            var result = driver.result()
            result.merge(["schema": "caption-revision-owner/v1", "nativeCancel": true, "nativeSelectiveApply": true,
                "nativeSingleUndoRedo": true, "nativeTimelineStaleRefusal": true, "nativeSourceStaleRefusal": true,
                "nativeSpeechCuts": true, "nativeSaveAndReopen": true, "liveAgent": false, "liveTranscription": false,
                "speechCalls": speech.calls, "sourceSHA256": speech.expectedSHA256,
                "proposalCount": runtime.proposals, "movie": movie.lastPathComponent,
                "decoded": try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))]) { _, new in new }
            result["translation"] = try await CaptionTranslationAcceptance.run(output: output.appendingPathComponent("translation"), scale: scale)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func requireCut(before: Timeline, after: Timeline, captionEdits: CaptionSpeechEdits.Plan) throws {
        guard before.totalFrames == 180, after.totalFrames == 150, after.fps == 30,
              before.tracks.map(\.id) == after.tracks.map(\.id), captionEdits.changes.count == 2,
              after.tracks[0].clips[0].textContent == "Hello world", after.tracks[0].clips[0].durationFrames == 60 else {
            throw GateBlocked("Speech removal failed to update the actual spanning caption or changed track identities.")
        }
        for index in 1...2 {
            let clips = after.tracks[index].clips.sorted { $0.startFrame < $1.startFrame }
            guard clips.count == 2, clips.map(\.startFrame) == [0, 30], clips.map(\.durationFrames) == [30, 120],
                  clips.map(\.trimStartFrame) == [0, 60], clips.map(\.trimEndFrame) == [150, 0],
                  clips.allSatisfy({ $0.mediaRef == before.tracks[index].clips[0].mediaRef
                    && $0.linkGroupId != nil && $0.speed == 1 && $0.volume == 1 }) else {
                throw GateBlocked("Speech cuts did not preserve both exact linked source ranges.")
            }
        }
        let visual = after.tracks[1].clips.sorted { $0.startFrame < $1.startFrame }
        let audio = after.tracks[2].clips.sorted { $0.startFrame < $1.startFrame }
        guard visual.map(\.linkGroupId) == audio.map(\.linkGroupId), visual[0].linkGroupId != visual[1].linkGroupId,
              visual[0].linkGroupId == before.tracks[1].clips[0].linkGroupId,
              audio[0].linkGroupId == before.tracks[2].clips[0].linkGroupId else {
            throw GateBlocked("The two surviving source ranges lost their actual paired video/audio links.")
        }
        var follower = before.tracks[0].clips[1]; follower.startFrame -= 30
        guard after.tracks[0].clips[1] == follower else { throw GateBlocked("Speech ripple changed a follower's content or failed to close its exact gap.") }
        for change in captionEdits.changes {
            guard before.tracks[0].clips.first(where: { $0.id == change.before.id }) == change.before,
                  after.tracks[0].clips.filter({ clip in change.after.contains(where: { $0.id == clip.id }) }) == change.after else {
                throw GateBlocked("The actual cut differs from the caption impacts reviewed before native approval.")
            }
        }
    }

    private static func export(editor: EditorViewModel, driver: ProductionVisualSourcesDriver, output: URL) async throws -> URL {
        let window = driver.window
        try await driver.click("editor.workspace.export", in: window, enabled: false)
        try await driver.wait("native caption export workspace") { editor.workspaceFocus == .export }
        if editor.activePreviewTab != .timeline { try await driver.click("export.artwork.show-film", in: window) }
        try await driver.click("export.artwork.frame", in: window)
        try await driver.wait("actual caption film poster") { driver.text("export.artwork.selection", in: window)?.hasPrefix("Film frame ") == true }
        let before = Set(ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).map(\.id))
        let destination = output.appendingPathComponent("Speech cut.mp4")
        try await driver.reveal("export.start", in: window)
        try driver.capture("caption-export-settings", target: window)
        try await driver.click("export.start", in: window); try await driver.saveFile(destination, in: window)
        try await driver.wait("actual caption film exported", seconds: 90) {
            ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).contains { !before.contains($0.id) && $0.status.isTerminal }
                || !(driver.text("export.error", in: window) ?? "").isEmpty
        }
        guard let job = ExportQueue.shared.jobs(ownerKey: editor.openWorkingCopyKey).first(where: { !before.contains($0.id) }),
              job.status == .completed, job.destinationURL?.standardizedFileURL == destination.standardizedFileURL,
              let home = editor.workingRoot else { throw GateBlocked("The actual speech cut did not export.") }
        let root = try ExportDataRoot.resolve(in: home)
        let receipt = try PipelineDeliveryStore.loadAttempt(id: job.id, dataRoot: root)
        guard receipt.probeQC?.passed == true, editor.declaredProductionContract == nil, editor.declaredPluginBinding == nil else {
            throw GateBlocked("The actual generic speech-cut export failed QC or enrolled a production contract.")
        }
        try await driver.reveal("export.qc", in: window)
        try await driver.wait("native speech-cut QC visible") { driver.text("export.qc", in: window) == "passed" }
        try driver.capture("caption-export-QC", target: window)
        try JSONEncoder().encode(receipt).write(to: output.appendingPathComponent("delivery.json"))
        return destination
    }

    private struct Decoded: Codable, Sendable {
        let originalVideoSHA256: String
        let originalAudioSHA256: String
        let movieSHA256: String
        let originalFrames: Int
        let movieFrames: Int
        let durationValue: Int64
        let durationTimescale: Int32
        let originalAudioSamples: Int
        let movieAudioSamples: Int
        let sampleRate: Int
        let originalCentersSHA256: String
        let movieCentersSHA256: String
        let originalPCMSHA256: String
        let moviePCMSHA256: String
        let originalRowWidth: Int
        let movieRowWidth: Int
        let originalRowsSHA256: String
        let movieRowsSHA256: String
        let originalIdentityRowsSHA256: String
        let movieIdentityRowsSHA256: String
        let originalFrameIDsSHA256: String
        let movieFrameIDsSHA256: String
    }

    private nonisolated static func decode(sourceVideo: URL, sourceAudio: URL, movie: URL, output: URL) async throws -> Decoded {
        try await Task.detached {
            let original = try await centers(sourceVideo), final = try await centers(movie)
            let originalPCM = try await pcm(sourceAudio), finalPCM = try await pcm(movie)
            let duration = try await AVURLAsset(url: movie).load(.duration)
            guard original.centers.count == 180, final.centers.count == 150, CMTimeCompare(duration, CMTime(value: 5, timescale: 1)) == 0,
                  originalPCM.count / 4 == 96_000, (79_000...81_024).contains(finalPCM.count / 4) else {
                throw GateBlocked("The actual exported speech cut does not have 150 picture frames and five seconds of sound.")
            }
            guard original.frameIDs == Array(0..<180), final.frameIDs == Array(0..<30) + Array(60..<180) else {
                throw GateBlocked("The actual decoded frame identities do not remove precisely original frames 30…59.")
            }
            let encoder = JSONEncoder()
            let originalIDs = try encoder.encode(original.frameIDs), finalIDs = try encoder.encode(final.frameIDs)
            try originalIDs.write(to: output.appendingPathComponent("original-frame-ids.json"))
            try finalIDs.write(to: output.appendingPathComponent("movie-frame-ids.json"))
            try original.identityRows.write(to: output.appendingPathComponent("original.frame-ids.bgra"))
            try final.identityRows.write(to: output.appendingPathComponent("movie.frame-ids.bgra"))
            let originalCenters = try encoder.encode(original.centers), finalCenters = try encoder.encode(final.centers)
            try originalCenters.write(to: output.appendingPathComponent("original-centers.json"))
            try finalCenters.write(to: output.appendingPathComponent("movie-centers.json"))
            try originalPCM.write(to: output.appendingPathComponent("original.f32le"))
            try finalPCM.write(to: output.appendingPathComponent("movie.f32le"))
            try original.rows.write(to: output.appendingPathComponent("original.rows.bgra"))
            try final.rows.write(to: output.appendingPathComponent("movie.rows.bgra"))
            let videoBytes = try Data(contentsOf: sourceVideo), audioBytes = try Data(contentsOf: sourceAudio)
            try videoBytes.write(to: output.appendingPathComponent("original-movement.mov"))
            try audioBytes.write(to: output.appendingPathComponent("original-voice.wav"))
            return Decoded(originalVideoSHA256: FileDigest.sha256(of: videoBytes), originalAudioSHA256: FileDigest.sha256(of: audioBytes),
                movieSHA256: try FileDigest.sha256(of: movie), originalFrames: original.centers.count, movieFrames: final.centers.count,
                durationValue: duration.value, durationTimescale: duration.timescale,
                originalAudioSamples: originalPCM.count / 4, movieAudioSamples: finalPCM.count / 4, sampleRate: 16_000,
                originalCentersSHA256: FileDigest.sha256(of: originalCenters), movieCentersSHA256: FileDigest.sha256(of: finalCenters),
                originalPCMSHA256: FileDigest.sha256(of: originalPCM), moviePCMSHA256: FileDigest.sha256(of: finalPCM),
                originalRowWidth: original.width, movieRowWidth: final.width,
                originalRowsSHA256: FileDigest.sha256(of: original.rows), movieRowsSHA256: FileDigest.sha256(of: final.rows),
                originalIdentityRowsSHA256: FileDigest.sha256(of: original.identityRows), movieIdentityRowsSHA256: FileDigest.sha256(of: final.identityRows),
                originalFrameIDsSHA256: FileDigest.sha256(of: originalIDs), movieFrameIDsSHA256: FileDigest.sha256(of: finalIDs))
        }.value
    }

    private struct Picture: Sendable { let centers: [Double]; let rows: Data; let width: Int; let identityRows: Data; let frameIDs: [Int] }

    private nonisolated static func centers(_ url: URL) async throws -> Picture {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GateBlocked("The actual speech-cut film has no picture.") }
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        guard reader.startReading() else { throw GateBlocked("The actual speech-cut picture cannot be decoded.") }
        var values: [Double] = [], pixels = Data(), identityRows = Data(), frameIDs: [Int] = [], rowWidth = 0
        while let sample = frames.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: Int64(values.count), timescale: 30),
                  let image = CMSampleBufferGetImageBuffer(sample) else { throw GateBlocked("A real picture frame lost its exact presentation clock or image buffer.") }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(image) else {
                CVPixelBufferUnlockBaseAddress(image, .readOnly); throw GateBlocked("Decoded picture pixels are missing.")
            }
            let width = CVPixelBufferGetWidth(image), y = CVPixelBufferGetHeight(image) / 2
            guard width == 320, CVPixelBufferGetHeight(image) == 180, rowWidth == 0 || rowWidth == width else {
                CVPixelBufferUnlockBaseAddress(image, .readOnly); throw GateBlocked("The actual frame width changed during decoding.")
            }
            rowWidth = width
            let row = base.assumingMemoryBound(to: UInt8.self).advanced(by: y * CVPixelBufferGetBytesPerRow(image))
            pixels.append(row, count: width * 4)
            var identityBytes = Data()
            for markerY in [16, 163] {
                identityBytes.append(base.assumingMemoryBound(to: UInt8.self).advanced(by: markerY * CVPixelBufferGetBytesPerRow(image)), count: width * 4)
            }
            let white = (0..<width).filter { row[$0 * 4] > 220 && row[$0 * 4 + 1] > 220 && row[$0 * 4 + 2] > 220 }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            frameIDs.append(try CaptionRevisionFrameFixture.identity(rows: identityBytes)); identityRows.append(identityBytes)
            guard !white.isEmpty else { throw GateBlocked("The actual known moving marker is absent from an exported frame.") }
            values.append(Double(white.reduce(0, +)) / Double(white.count * width))
        }
        guard reader.status == .completed else { throw GateBlocked("Actual picture decoding ended early.") }
        return .init(centers: values, rows: pixels, width: rowWidth, identityRows: identityRows, frameIDs: frameIDs)
    }

    private nonisolated static func pcm(_ url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw GateBlocked("The actual speech-cut film has no audio.") }
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(samples)
        guard reader.startReading() else { throw GateBlocked("The actual speech-cut sound cannot be decoded.") }
        var bytes = Data(), firstTime: CMTime?
        while let sample = samples.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw GateBlocked("Actual decoded sound has no sample bytes.") }
            var part = Data(count: CMBlockBufferGetDataLength(block))
            if part.isEmpty { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstTime == nil { firstTime = timestamp }
            guard let firstTime, timestamp.isNumeric, firstTime.isNumeric, part.count.isMultiple(of: 4),
                  CMSampleBufferGetNumSamples(sample) == part.count / 4 else { throw GateBlocked("Decoded PCM lost its actual sample clock.") }
            let expected = CMTimeAdd(firstTime, CMTime(value: Int64(bytes.count / 4), timescale: 16_000))
            let timingError = CMTimeAbsoluteValue(CMTimeSubtract(timestamp, expected))
            guard CMTimeCompare(timingError, CMTime(value: 1, timescale: 16_000)) <= 0 else {
                throw GateBlocked("Decoded PCM has a gap or changing offset instead of one contiguous sample stream.")
            }
            let status = part.withUnsafeMutableBytes { storage in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: storage.count, destination: storage.baseAddress!)
            }
            guard status == noErr else { throw GateBlocked("Actual decoded sound bytes are unreadable.") }
            bytes.append(part)
        }
        guard reader.status == .completed, !bytes.isEmpty, bytes.count.isMultiple(of: 4) else { throw GateBlocked("Actual sound decoding ended early.") }
        return bytes
    }

    @MainActor private final class FixtureSpeech {
        let expectedSHA256: String
        private(set) var calls = 0
        init(expectedSHA256: String) { self.expectedSHA256 = expectedSHA256 }
        func transcribe(_ url: URL, video: Bool, range: ClosedRange<Double>?, censor: Bool, locale: Locale?) throws -> TranscriptionResult {
            guard !video, range == nil, !censor, locale == nil, try FileDigest.sha256(of: url) == expectedSHA256 else {
                throw GateBlocked("The real transcript reader did not supply its exact frozen voice source.")
            }
            calls += 1
            return .init(text: "Hello um world", language: "en", words: [
                .init(text: "Hello", start: 0, end: 1), .init(text: "um", start: 1, end: 2), .init(text: "world", start: 2, end: 3)],
                segments: [.init(text: "Hello um world", start: 0, end: 3)])
        }
    }

    @MainActor private final class FixtureRuntime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        var arguments: [String: Any]?
        var kind: CaptionRevisionScope.Kind = .captions
        private(set) var proposals = 0
        private(set) var calls: [[String: Any]] = []
        private(set) var failure: String?
        private var execute: AgentRuntimeToolExecutor?
        private var task: Task<Void, Never>?
        func start(_ request: AgentRuntimeSessionRequest) throws { execute = request.executeTool; state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            let arguments = arguments; self.arguments = nil
            let kind = kind
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            task = Task { @MainActor in
                guard let execute else { failure = "The actual tool executor is unavailable."; pair.continuation.finish(); return }
                func call(_ label: String, _ tool: String, _ args: [String: Any]) async throws -> ToolResult {
                    let bytes = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                    let result = await execute(UUID().uuidString, tool, String(decoding: bytes, as: UTF8.self))
                    let text = result.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n")
                    self.calls.append(["label": label, "tool": tool, "args": args, "isError": result.isError, "result": text])
                    return result
                }
                do {
                    for (tool, args) in [("set_clip_properties", ["clipIds": ["caption-one"], "content": "Unapproved mutation"] as [String: Any]),
                        ("remove_words", ["words": [1]] as [String: Any])] {
                        let refused = try await call("direct-mutation", tool, args)
                        guard refused.isError, self.calls.last?["result"] as? String != nil,
                              (self.calls.last?["result"] as? String)?.contains("caption revision task") == true else {
                            throw GateBlocked("The actual caption task permitted direct agent mutation.")
                        }
                    }
                    if let arguments {
                        let wrong: [String: Any] = kind == .captions ? ["kind": "speech_cuts", "words": [1]]
                            : ["kind": "captions", "changes": [["clipId": "caption-one", "text": "Wrong kind"]]]
                        let refused = try await call("wrong-kind", "propose_caption_revision", wrong)
                        guard refused.isError, (self.calls.last?["result"] as? String)?.contains("kind must match") == true else {
                            throw GateBlocked("The actual caption task accepted another proposal kind.")
                        }
                        let timeline = try await call("read-timeline", "get_timeline", [:])
                        guard !timeline.isError else { throw GateBlocked("The scoped caption task could not read its actual timeline.") }
                        if kind == .speechCuts {
                            let transcript = try await call("real-transcript", "get_transcript", ["wordTimestamps": true])
                            guard !transcript.isError else { throw GateBlocked("The real source-bound transcript call failed.") }
                        }
                        let proposed = try await call("native-proposal", "propose_caption_revision", arguments)
                        guard !proposed.isError else { throw GateBlocked("The actual canonical caption proposal failed.") }
                        self.proposals += 1
                    } else {
                        let refused = try await call("completed-reproposal", "propose_caption_revision", ["kind": "captions", "changes": []])
                        guard refused.isError, (self.calls.last?["result"] as? String)?.contains("caption revision task") == true else {
                            throw GateBlocked("The completed caption task repeated its proposal.")
                        }
                    }
                } catch { self.failure = error.localizedDescription }
                pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
                pair.continuation.finish(); self.state = .ready(sessionID: request.sessionID)
            }
            return pair.stream
        }
        func cancel(sessionID: UUID) { task?.cancel(); state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { cancel(sessionID: sessionID); state = .ended(sessionID: sessionID) }
    }
}
