import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum AnimationAudioAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        let name = "animation-audio-\(Int(scale * 100))"
        let package = output.appendingPathComponent(name + ".ngv", isDirectory: true)
        let media = package.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let videoURL = media.appendingPathComponent("Movement.mov")
        let toneURL = media.appendingPathComponent("Tone.wav")
        try await FullflowAcceptanceFixture.writeVideo(to: videoURL, duration: 4, fps: 30, warm: true)
        try FullflowAcceptanceFixture.writeTone(to: toneURL, duration: 4)
        let video = MediaAsset(id: "video", url: videoURL, type: .video, name: "Movement", originalFilename: "Movement.mov")
        let tone = MediaAsset(id: "tone", url: toneURL, type: .audio, name: "Tone", originalFilename: "Tone.wav")
        await video.loadMetadata(); await tone.loadMetadata()
        let visual = Clip(id: "visual", mediaRef: video.id, startFrame: 0, durationFrames: 120)
        let audio = Clip(id: "audio", mediaRef: tone.id, mediaType: .audio, sourceClipType: .audio, startFrame: 0, durationFrames: 120)
        let secondAudio = Clip(id: "second-audio", mediaRef: tone.id, mediaType: .audio, sourceClipType: .audio, startFrame: 0,
                               durationFrames: 120, volume: 0.4)
        var timeline = Timeline()
        timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
        timeline.tracks = [Track(type: .video, clips: [visual]), Track(type: .audio, clips: [audio]), Track(type: .audio, muted: true, clips: [secondAudio])]
        var manifest = MediaManifest()
        manifest.entries = [video.toManifestEntry(projectURL: package), tone.toManifestEntry(projectURL: package)]
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The animation and audio project did not open.") }
        document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var screenshotEvidence: [[String: Any]] = []
        func capture(_ label: String) throws {
            guard let content = window.contentView else { throw GateBlocked("The native capture surface is unavailable.") }
            let bounds = content.bounds.size
            let backing = content.convertToBacking(content.bounds).size
            try driver.capture(label, target: window)
            guard let filename = (driver.result()["screenshots"] as? [String])?.last else {
                throw GateBlocked("The native capture was not recorded.")
            }
            let bytes = try Data(contentsOf: output.appendingPathComponent(filename))
            guard let bitmap = NSBitmapImageRep(data: bytes),
                  bitmap.pixelsWide == Int(backing.width.rounded()), bitmap.pixelsHigh == Int(backing.height.rounded()) else {
                throw GateBlocked("The native capture does not match its actual backing dimensions.")
            }
            screenshotEvidence.append(["filename": filename, "sha256": FileDigest.sha256(of: bytes),
                "bounds": [bounds.width, bounds.height], "backingScale": window.backingScaleFactor,
                "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh]])
        }
        var closed = false
        defer { if !closed { document.close() } }
        func seek(_ frame: Int) async throws {
            try await driver.click("editing.keyframe-ruler", in: window, fraction: .init(x: Double(frame) / 120, y: 0.5))
            try await driver.wait("native keyframe seek \(frame)") { editor.activeFrame == frame }
        }
        func undo(_ expected: Timeline, _ label: String) async throws {
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait(label) { editor.timeline == expected }
        }
        func inspect(_ clip: Clip, tab: String) async throws {
            try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
            try await driver.wait("select actual timeline clip " + clip.id) { editor.selectedClipIds == [clip.id] }
            if driver.state("inspector.tab." + tab, in: window) != nil {
                try await driver.click("inspector.tab." + tab, in: window, enabled: false)
            }
            if !editor.keyframesPanelVisible {
                try await driver.click("inspector.keyframes", in: window, enabled: false)
                try await driver.wait("show native keyframe lanes") { editor.keyframesPanelVisible }
            }
        }
        do {
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            try await driver.wait("editing workspace") { editor.workspaceFocus == .edit }
            try await inspect(visual, tab: "Video")
            for (frame, value) in [(30, "25"), (90, "75")] {
                try await seek(frame)
                try await driver.click("editing.keyframe.opacity.stamp", in: window)
                try await driver.fill("inspector.value.Opacity", value: value, in: window, requireFocusExit: true)
                try await driver.wait("actual opacity keyframe") {
                    editor.clipFor(id: visual.id)?.opacityTrack?.keyframes.first(where: { $0.frame == frame })?.value == Double(value)! / 100
                }
            }
            let opacity = editor.timeline
            for (label, expected) in [("Hold", 0.25), ("Linear", 0.375), ("Smooth", 0.328125)] {
                try await driver.contextMenu("editing.keyframe.opacity.30", path: [label], in: window)
                try await driver.wait("actual opacity " + label) {
                    guard let clip = editor.clipFor(id: visual.id) else { return false }
                    return abs(clip.rawOpacityAt(frame: 45) - expected) < 0.00001
                }
            }
            try await seek(60)
            try await driver.click("editing.keyframe.opacity.previous", in: window)
            try await driver.wait("native previous keyframe") { editor.activeFrame == 30 }
            try await driver.click("editing.keyframe.opacity.next", in: window)
            try await driver.wait("native next keyframe") { editor.activeFrame == 90 }
            let beforeMove = editor.timeline
            try await driver.drag("editing.keyframe-lane.opacity", from: .init(x: 0.75, y: 0.5), to: .init(x: 0.5, y: 0.5), in: window)
            try await driver.wait("native keyframe move") { editor.clipFor(id: visual.id)?.keyframeFrames(for: .opacity) == [30, 60] }
            try await undo(beforeMove, "native keyframe move undo")
            try await driver.contextMenu("editing.keyframe.opacity.90", path: ["Delete Keyframe"], in: window)
            try await driver.wait("native keyframe deletion") { editor.clipFor(id: visual.id)?.keyframeFrames(for: .opacity) == [30] }
            try await undo(beforeMove, "native keyframe delete undo")
            try await driver.contextMenu("editing.keyframe.opacity.30", path: ["Clear Animation"], in: window)
            try await driver.wait("native clear opacity animation") { editor.clipFor(id: visual.id)?.opacityTrack?.isActive != true }
            try await undo(beforeMove, "native clear animation undo")
            guard editor.timeline == opacity else { throw GateBlocked("Native keyframe navigation or Undo changed unrelated values.") }
            try capture("opacity-keyframes")
            try await driver.click("inspector.tab.Adjust", in: window, enabled: false)
            try await driver.wait("actual animated adjustment") { driver.state("inspector.tab.Adjust", in: window) == true }
            for (frame, value) in [(30, "-1.00"), (90, "1.00")] {
                try await seek(frame)
                try await driver.click("editing.effect.color.exposure.ev.stamp", in: window)
                try await driver.fill("inspector.adjust.value.color.exposure.ev", value: value, in: window, requireFocusExit: true)
                try await driver.wait("actual effect keyframe") {
                    editor.clipFor(id: visual.id)?.effects?.first(where: { $0.type == "color.exposure" })?.params["ev"]?.track?.keyframes
                        .first(where: { $0.frame == frame })?.value == Double(value)
                }
            }
            try await seek(60)
            try await driver.click("editing.effect.color.exposure.ev.previous", in: window)
            try await driver.wait("native previous effect keyframe") { editor.activeFrame == 30 }
            try await driver.click("editing.effect.color.exposure.ev.next", in: window)
            try await driver.wait("native next effect keyframe") { editor.activeFrame == 90 }
            let beforeEffectMove = editor.timeline
            try await driver.drag("editing.keyframe-lane.effect.color.exposure.ev", from: .init(x: 0.75, y: 0.5), to: .init(x: 0.5, y: 0.5), in: window)
            try await driver.wait("native effect keyframe move") {
                guard let clip = editor.clipFor(id: visual.id) else { return false }
                return InspectorKeyframeTarget.effect(type: "color.exposure", key: "ev").frames(in: clip) == [30, 60]
            }
            try await undo(beforeEffectMove, "native effect move undo")
            try await driver.contextMenu("editing.keyframe.effect.color.exposure.ev.90", path: ["Delete Keyframe"], in: window)
            try await driver.wait("native effect keyframe deletion") {
                guard let clip = editor.clipFor(id: visual.id) else { return false }
                return InspectorKeyframeTarget.effect(type: "color.exposure", key: "ev").frames(in: clip) == [30]
            }
            try await undo(beforeEffectMove, "native effect delete undo")
            try await driver.contextMenu("editing.keyframe.effect.color.exposure.ev.30", path: ["Clear Animation"], in: window)
            try await driver.wait("native effect clear") {
                editor.clipFor(id: visual.id)?.effects?.first(where: { $0.type == "color.exposure" })?.params["ev"]?.track?.isActive != true
            }
            try await undo(beforeEffectMove, "native effect clear undo")
            try await driver.contextMenu("editing.keyframe.effect.color.exposure.ev.30", path: ["Hold"], in: window)
            try await seek(60)
            try await driver.wait("effect field follows actual playhead") { driver.text("inspector.adjust.value.color.exposure.ev", in: window) == "-1.00" }
            let held = try await PostproductionControlsAcceptance.readablePreview(editor)
            try await driver.contextMenu("editing.keyframe.effect.color.exposure.ev.30", path: ["Linear"], in: window)
            try await driver.wait("effect field follows interpolated value") { driver.text("inspector.adjust.value.color.exposure.ev", in: window) == "0.00" }
            _ = try await PostproductionControlsAcceptance.changedPreview(editor, from: held)
            try await driver.fill("inspector.adjust.value.color.exposure.ev", value: "1.50", in: window, requireFocusExit: true)
            try await driver.wait("editing animated effect preserves earlier and later keys") {
                let keys = editor.clipFor(id: visual.id)?.effects?.first(where: { $0.type == "color.exposure" })?.params["ev"]?.track?.keyframes
                return keys?.map(\.frame) == [30, 60, 90] && keys?.map(\.value) == [-1, 1.5, 1]
            }
            try capture("effect-keyframes")
            try await inspect(audio, tab: "Audio")
            for (frame, value) in [(30, "-12.0"), (90, "-6.0")] {
                try await seek(frame)
                try await driver.click("editing.keyframe.volume.stamp", in: window)
                try await driver.fill("editing.audio.volume", value: value, in: window, requireFocusExit: true)
                try await driver.wait("actual volume keyframe") {
                    editor.clipFor(id: audio.id)?.volumeTrack?.keyframes.first(where: { $0.frame == frame })?.value == Double(value)
                }
            }
            try await driver.contextMenu("editing.keyframe.volume.30", path: ["Linear"], in: window)
            try await driver.wait("native audio interpolation") {
                guard let clip = editor.clipFor(id: audio.id) else { return false }
                return clip.interpolation(for: .volume, atFrame: 30) == .linear
                    && clip.volumeTrack?.sample(at: 60, fallback: 0) == -9
            }
            try await driver.fill("editing.audio.fade-in", value: "0.50", in: window, requireFocusExit: true)
            try await driver.fill("editing.audio.fade-out", value: "1.00", in: window, requireFocusExit: true)
            try await driver.wait("native independent audio fades") {
                editor.clipFor(id: audio.id)?.fadeInFrames == 15 && editor.clipFor(id: audio.id)?.fadeOutFrames == 30
                    && editor.clipFor(id: secondAudio.id) == secondAudio
            }
            let beforeSpeed = editor.timeline
            try await driver.fill("inspector.value.Speed", value: "2.00", in: window, requireFocusExit: true)
            try await driver.wait("native audio tempo") { editor.clipFor(id: audio.id)?.speed == 2 && editor.clipFor(id: audio.id)?.durationFrames == 60 }
            try await undo(beforeSpeed, "native tempo undo")
            try capture("volume-and-fades")
            let completed = editor.timeline
            guard document.isDocumentEdited else { throw GateBlocked("Animation and audio edits did not mark the document unsaved.") }
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("save native animation and audio", seconds: 30) {
                guard !document.isDocumentEdited, let bytes = try? Data(contentsOf: package.appendingPathComponent(Project.timelineFilename)),
                      let saved = try? JSONDecoder().decode(Timeline.self, from: bytes) else { return false }
                return saved == completed
            }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened)
            reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == completed else { throw GateBlocked("Native animation or audio edits were lost on reopen.") }
            var result = driver.result()
            result.merge(["scale": scale, "effectiveScale": AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)),
                "viewport": [960, 640], "screenshotEvidence": screenshotEvidence, "nativeOpacityKeys": true, "nativeInterpolation": true,
                "nativePreviousNext": true, "nativeMoveDeleteClearUndo": true, "nativeEffectKeys": true,
                "nativeEffectMoveDeleteClearUndo": true, "nativeEffectPreviousNext": true, "nativeAudioInterpolation": true,
                "playerItemCompositionAnimation": true, "nativeVolumeKeys": true, "nativeFadesAndTempoUndo": true,
                "unselectedAudioPreserved": true, "nativeSaveAndReopen": true]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }
}
