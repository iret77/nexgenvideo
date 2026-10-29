import AppKit
import NexGenEngine

@MainActor
enum TextCaptionAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "text-captions-\(Int(scale * 100))"
        let package = output.appendingPathComponent(name + ".ngv", isDirectory: true)
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let picture = media.appendingPathComponent("Movement.mov"), sound = media.appendingPathComponent("Voice.wav")
        try await FullflowAcceptanceFixture.writeVideo(to: picture, duration: 6, fps: 30, warm: true)
        try FullflowAcceptanceFixture.writeTone(to: sound, duration: 6)
        let video = MediaAsset(id: "picture", url: picture, type: .video, name: "Movement", duration: 6)
        let audio = MediaAsset(id: "voice", url: sound, type: .audio, name: "Voice", duration: 6)
        video.hasAudio = false
        var timeline = Timeline()
        timeline.width = 640; timeline.height = 360; timeline.fps = 30; timeline.settingsConfigured = true
        let visual = Clip(id: "visual", mediaRef: video.id, startFrame: 0, durationFrames: 180)
        let voice = Clip(id: "voice-clip", mediaRef: audio.id, mediaType: .audio, sourceClipType: .audio, startFrame: 0, durationFrames: 180)
        timeline.tracks = [Track(type: .video, clips: [visual]), Track(type: .audio, clips: [voice])]
        var manifest = MediaManifest(); manifest.entries = [video.toManifestEntry(projectURL: package), audio.toManifestEntry(projectURL: package)]
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let document = try await VideoProject.load(from: package)
        document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The title and captions project did not open.") }
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        let speech = FixtureSpeech()
        editor.captionTranscriptionClient = .init(transcribe: { url, video, range, censor, locale in
            try await speech.transcribe(url, video: video, range: range, censor: censor, locale: locale)
        }, supportedLocales: { [Locale(identifier: "en_US")] })
        var closed = false
        defer { if !closed { document.close() } }
        func undo(_ expected: Timeline, redo: Bool = false) async throws {
            try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: window)
            try await driver.wait(redo ? "native title redo" : "native title undo") { editor.timeline == expected }
        }
        func addTitle() async throws -> Clip {
            let oldIDs = Set(editor.timeline.tracks.flatMap(\.clips).map(\.id))
            try await driver.click("editing.add-text", in: window)
            try await driver.wait("native title insertion") { editor.timeline.tracks.flatMap(\.clips).contains { !oldIDs.contains($0.id) && $0.mediaType == .text } }
            guard let clip = editor.timeline.tracks.flatMap(\.clips).first(where: { !oldIDs.contains($0.id) && $0.mediaType == .text }) else {
                throw GateBlocked("Add Text did not create a title.")
            }
            return clip
        }
        do {
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            try await driver.wait("title editing workspace") { editor.workspaceFocus == .edit }
            let baseline = try await PostproductionControlsAcceptance.readablePreview(editor)
            let title = try await addTitle()
            let added = editor.timeline
            try await undo(timeline); try await undo(added, redo: true)
            try GenericNLEAcceptance.pointerOnClip(title, editor: editor, window: window, driver: driver)
            try await driver.click("inspector.tab.Text", in: window, enabled: false)
            try await driver.fill("text.content", value: "Release title", in: window, requireFocusExit: true)
            try await driver.click("text.content", in: window)
            try driver.pressKey(124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: .command, in: window)
            try driver.pressKey(0, characters: "X", in: window)
            try await driver.wait("native text typing") { editor.clipFor(id: title.id)?.textContent == "Release titleX" }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("text undo preserves title") { editor.clipFor(id: title.id)?.textContent == "Release title" }
            try driver.pressKey(48, characters: "\t", in: window)
            try await driver.fill("inspector.value.Text size", value: "72", in: window, requireFocusExit: true)
            try await driver.fill("inspector.value.Text opacity", value: "60", in: window, requireFocusExit: true)
            for control in ["Background", "Border", "Shadow"] { try await driver.click("text.toggle." + control, in: window) }
            try await driver.click("text.alignment", in: window, fraction: .init(x: 5.0 / 6.0, y: 0.5))
            try await driver.wait("native title style") {
                guard let clip = editor.clipFor(id: title.id), let style = clip.textStyle else { return false }
                return style.fontSize == 72 && clip.opacity == 0.6 && style.background.enabled && style.border.enabled
                    && !style.shadow.enabled && style.alignment == .right
            }
            _ = try await PostproductionControlsAcceptance.changedPreview(editor, from: baseline)
            try driver.capture("styled-title", target: window)
            let second = try await addTitle()
            try await driver.click("inspector.tab.Text", in: window, enabled: false)
            try await driver.fill("text.content", value: "Second layer", in: window, requireFocusExit: true)
            guard editor.clipFor(id: title.id)?.textContent == "Release title", editor.clipFor(id: second.id)?.textContent == "Second layer" else {
                throw GateBlocked("Editing the second title changed the first layer.")
            }
            try driver.capture("two-title-layers", target: window)
            try GenericNLEAcceptance.pointerOnClip(voice, editor: editor, window: window, driver: driver)
            try await driver.wait("native caption source clip") { editor.selectedClipIds == [voice.id] }
            try await driver.click("media.tab.Captions", in: window, enabled: false)
            try await driver.wait("native caption workspace") { editor.mediaPanelTab(for: .edit) == .captions }
            try await driver.menu("captions.language", title: "English (United States)", in: window)
            try await driver.menu("captions.case", title: "UPPERCASE", in: window)
            try await driver.click("captions.censor", in: window)
            try await driver.fill("inspector.value.Caption size", value: "36", in: window, requireFocusExit: true)
            let titles = editor.timeline
            speech.waiting = true
            try await driver.click("captions.generate", in: window)
            try await driver.wait("isolated speech request") { speech.calls == 1 }
            try await driver.click("captions.cancel", in: window)
            try await driver.wait("visible caption cancellation") { driver.text("captions.note", in: window) == "Caption generation cancelled." }
            guard editor.timeline == titles else { throw GateBlocked("Cancelling captions changed the film.") }
            try driver.capture("caption-cancel", target: window)
            try await driver.click("captions.generate", in: window)
            try await driver.wait("second isolated speech request") { speech.calls == 2 }
            _ = try await addTitle()
            let changedTimeline = editor.timeline
            speech.waiting = false
            try await driver.wait("late caption source refusal") { driver.text("captions.note", in: window)?.contains("project or timeline changed") == true }
            guard editor.timeline == changedTimeline else { throw GateBlocked("Late captions modified the edited film.") }
            try driver.capture("caption-stale", target: window)
            try await undo(titles)
            try await driver.click("captions.generate", in: window)
            try await driver.wait("native caption placement", seconds: 30) { editor.timeline.tracks.flatMap(\.clips).contains { $0.captionGroupId != nil } }
            let generated = editor.timeline
            let captions = generated.tracks.flatMap(\.clips).filter { $0.captionGroupId != nil }
            guard speech.calls == 3, captions.count == 1, captions[0].textContent == "UM HELLO WORLD.",
                  captions[0].startFrame == 30, captions[0].durationFrames == 45,
                  captions[0].textStyle?.fontSize == 36, editor.clipFor(id: voice.id) == voice else {
                throw GateBlocked("The actual caption controls or original source timing did not reach placement.")
            }
            try driver.capture("generated-captions", target: window)
            try await driver.menu("captions.actions", title: "Remove filler words", in: window)
            try await driver.wait("native filler removal") { editor.clipFor(id: captions[0].id)?.textContent == "HELLO WORLD." }
            guard let cleaned = editor.clipFor(id: captions[0].id), cleaned.startFrame == 30, cleaned.durationFrames == 45,
                  editor.clipFor(id: title.id)?.textContent == "Release title" else { throw GateBlocked("Caption cleanup changed timing or titles.") }
            let finished = editor.timeline
            try await undo(generated); try await undo(finished, redo: true)
            try driver.capture("caption-cleanup-undo-redo", target: window)
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("save title and captions", seconds: 30) { !document.isDocumentEdited }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package)
            reopened.makeWindowControllers(); defer { reopened.close() }
            guard reopened.editorViewModel.timeline == finished else { throw GateBlocked("Title or caption edits were lost on reopen.") }
            var result = driver.result()
            result.merge(["viewport": [960, 640], "nativeTitleCreationUndoRedo": true, "nativeTextUndo": true,
                "nativeTitleStyle": true, "playerItemCompositionTitle": true, "independentTextLayers": true,
                "nativeCaptionOptions": true, "nativeCaptionCancel": true, "nativeCaptionStaleRefusal": true,
                "nativeCaptionPlacement": true, "nativeFillerUndoRedo": true, "nativeSaveAndReopen": true,
                "liveTranscription": false, "isolatedSpeechRequests": speech.calls, "captionStart": 30, "captionDuration": 45]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }

    private final class FixtureSpeech {
        var calls = 0
        var waiting = false
        func transcribe(_ url: URL, video: Bool, range: ClosedRange<Double>?, censor: Bool, locale: Locale?) async throws -> TranscriptionResult {
            calls += 1
            guard !video, range == 0...7, censor, locale?.identifier == "en_US", FileManager.default.fileExists(atPath: url.path) else {
                throw GateBlocked("The caption UI supplied different source, locale or censor options.")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while waiting {
                guard ContinuousClock.now < deadline else { throw GateBlocked("The controlled speech response was not released.") }
                try await Task.sleep(for: .milliseconds(25))
            }
            return .init(text: "um hello world.", language: "en", words: [
                .init(text: "um", start: 1, end: 1.3), .init(text: "hello", start: 1.3, end: 1.9), .init(text: "world.", start: 1.9, end: 2.5)],
                segments: [.init(text: "um hello world.", start: 1, end: 2.5)])
        }
    }
}
