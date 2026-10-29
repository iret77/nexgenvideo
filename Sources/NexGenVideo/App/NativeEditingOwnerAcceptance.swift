import AppKit
import AVFoundation
import CryptoKit
import ImageIO
import NexGenEngine

@MainActor
enum NativeEditingOwnerAcceptance {
    static func run(editor: EditorViewModel, window: NSWindow, directory: URL,
                    driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let sourceA = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        let sourceB = directory.appendingPathComponent("Second moving source.mov")
        try await FullflowAcceptanceFixture.writeVideo(to: sourceB, duration: 8, fps: 30, warm: false)
        try await workspace(.media, editor: editor, window: window, driver: driver)
        for url in [sourceA, sourceB] {
            let before = editor.mediaAssets.count
            try await driver.chooseFile(url, in: window, trigger: "media.action.Import")
            try await driver.wait("native source import", seconds: 30) { editor.mediaAssets.count == before + 1 }
        }
        guard editor.timeline.tracks.flatMap(\.clips).isEmpty,
              let a = editor.mediaAssets.first(where: { $0.userFacingFilename == sourceA.lastPathComponent }), a.hasAudio,
              let b = editor.mediaAssets.first(where: { $0.userFacingFilename == sourceB.lastPathComponent }) else {
            throw GateBlocked("Native source import did not retain two independent media candidates and the actual audio stream.")
        }
        try await workspace(.edit, editor: editor, window: window, driver: driver)
        try await driver.click("media.asset." + a.id, in: window)
        let fps = editor.timeline.fps
        try await sourceSeek(fps, editor: editor, window: window, driver: driver)
        try await driver.click("source.in." + a.id, in: window)
        try await sourceSeek(5 * fps, editor: editor, window: window, driver: driver)
        try await driver.click("source.out." + a.id, in: window)
        try await driver.wait("actual first source range") { editor.sourceFrameRange(for: a) == fps..<(5 * fps) }
        try await sourceSeek(2 * fps, editor: editor, window: window, driver: driver)
        try await driver.click("media.asset." + b.id, in: window)
        try await sourceSeek(2 * fps, editor: editor, window: window, driver: driver)
        try await driver.click("source.in." + b.id, in: window)
        try await sourceSeek(3 * fps, editor: editor, window: window, driver: driver)
        try await driver.click("source.out." + b.id, in: window)
        try await driver.click("media.asset." + a.id, in: window)
        try await driver.wait("source identity, position and independent In/Out restored") {
            editor.sourcePlayheadFrame == 2 * fps && editor.sourceFrameRange(for: a) == fps..<(5 * fps)
                && editor.sourceFrameRange(for: b) == (2 * fps)..<(3 * fps)
                && editor.selectedMediaAssetIds == [a.id] && editor.activePreviewTab.id == PreviewTab.mediaAssetTabId(for: a.id)
        }
        try await driver.contextMenu("preview.history", path: ["Previous Preview"], in: window)
        try await driver.wait("native previous source") { editor.activePreviewTab.id == PreviewTab.mediaAssetTabId(for: b.id) && editor.sourcePlayheadFrame == 3 * fps }
        try await driver.contextMenu("preview.history", path: ["Next Preview"], in: window)
        try await driver.wait("native next source") { editor.activePreviewTab.id == PreviewTab.mediaAssetTabId(for: a.id) && editor.sourcePlayheadFrame == 2 * fps }
        try driver.capture("source-memory", target: window)
        let captured = try await captureSource(a, frame: 2 * fps, editor: editor, window: window, directory: directory, driver: driver)
        try await driver.click("media.asset." + a.id, in: window)
        try await driver.click("source.insert." + a.id, in: window)
        let mismatch = try await driver.sheet("project.mismatch.keep", parent: window)
        try driver.visible(["project.mismatch.keep", "project.mismatch.match"], in: mismatch)
        try driver.capture("source-format-mismatch", target: mismatch)
        try await driver.click("project.mismatch.keep", in: mismatch)
        try await driver.wait("native linked source insertion") { editor.timeline.tracks.flatMap(\.clips).count == 2 }
        let inserted = editor.timeline
        guard let videoTrack = inserted.tracks.first(where: { $0.type == .video }), let video = videoTrack.clips.first,
              let audioTrack = inserted.tracks.first(where: { $0.type == .audio }), let audio = audioTrack.clips.first,
              video.mediaRef == a.id, audio.mediaRef == a.id, video.linkGroupId != nil, video.linkGroupId == audio.linkGroupId,
              video.startFrame == 0, video.durationFrames == 4 * fps, video.trimStartFrame == fps,
              audio.startFrame == video.startFrame, audio.durationFrames == video.durationFrames,
              audio.trimStartFrame == video.trimStartFrame, editor.timeline.width == 720, editor.timeline.height == 1280 else {
            throw GateBlocked("Native Insert did not preserve portrait settings, exact source range and linked audio.")
        }
        let typography = try await textAndTimelineClipboard(asset: a, clip: video, editor: editor, window: window, driver: driver)
        try await trackControls(videoTrack: videoTrack.id, audioTrack: audioTrack.id, editor: editor, window: window, driver: driver)
        try GenericNLEAcceptance.pointerOnClip(video, editor: editor, window: window, driver: driver)
        try await driver.wait("actual linked clip selection") { editor.selectedClipIds == [video.id, audio.id] }
        try await clipMenu("Unlink", clip: video, editor: editor, window: window, driver: driver)
        try await driver.wait("native unlink") { editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.linkGroupId == nil } }
        let unlinked = editor.timeline
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("unlink Undo restores exact pair") { editor.timeline == inserted }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("unlink Redo") { editor.timeline == unlinked }
        try driver.pressKey(0, characters: "a", modifiers: .command, in: window)
        try await driver.wait("native select all clips") { editor.selectedClipIds == [video.id, audio.id] }
        try await clipMenu("Link", clip: video, editor: editor, window: window, driver: driver)
        try await driver.wait("native Link creates actual pair") {
            let clips = editor.timeline.tracks.flatMap(\.clips)
            return clips.count == 2 && clips[0].linkGroupId != nil && clips[0].linkGroupId == clips[1].linkGroupId
        }
        let relinked = editor.timeline
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("Link Undo") { editor.timeline == unlinked }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("Link Redo") { editor.timeline == relinked }
        try GenericNLEAcceptance.pointerOnClip(video, editor: editor, window: window, driver: driver)
        try await driver.wait("select pair for independent overwrite") { editor.selectedClipIds == [video.id, audio.id] }
        try await clipMenu("Unlink", clip: video, editor: editor, window: window, driver: driver)
        try await driver.wait("explicitly preserve independent source audio") { editor.timeline.tracks.flatMap(\.clips).allSatisfy { $0.linkGroupId == nil } }
        let independentAudio = editor.timeline
        try GenericNLEAcceptance.pointerOnRuler(frame: 2 * fps, window: window, driver: driver)
        try await driver.wait("native overwrite position") { editor.currentFrame == 2 * fps }
        try await driver.click("media.asset." + b.id, in: window)
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == videoTrack.id }) else { throw GateBlocked("The native target track disappeared.") }
        try await driver.picker("source.target." + b.id, title: editor.timelineTrackDisplayLabel(at: index), expected: videoTrack.id, in: window)
        try await driver.click("source.overwrite." + b.id, in: window)
        try await driver.wait("native range overwrite") { editor.timeline.tracks.first(where: { $0.id == videoTrack.id })?.clips.count == 3 }
        let overwritten = editor.timeline
        let cuts = overwritten.tracks.first(where: { $0.id == videoTrack.id })!.clips.sorted { $0.startFrame < $1.startFrame }
        guard cuts.map(\.startFrame) == [0, 2 * fps, 3 * fps], cuts.map(\.durationFrames) == [2 * fps, fps, fps],
              cuts.map(\.mediaRef) == [a.id, b.id, a.id], cuts[1].trimStartFrame == 2 * fps,
              overwritten.totalFrames == 4 * fps,
              overwritten.tracks.first(where: { $0.id == audioTrack.id }) == independentAudio.tracks.first(where: { $0.id == audioTrack.id }) else {
            throw GateBlocked("Overwrite shifted later content or changed the unrelated original audio track.")
        }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("Overwrite Undo exact timeline") { editor.timeline == independentAudio }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("Overwrite Redo exact timeline") { editor.timeline == overwritten }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("restore for Insert comparison") { editor.timeline == independentAudio }
        try await driver.click("source.insert." + b.id, in: window)
        try await driver.wait("native insert extends film") { editor.timeline.totalFrames == 5 * fps }
        let ripple = editor.timeline
        let insertedCuts = ripple.tracks.first(where: { $0.id == videoTrack.id })!.clips.sorted { $0.startFrame < $1.startFrame }
        guard insertedCuts.map(\.startFrame) == [0, 2 * fps, 3 * fps], insertedCuts.map(\.durationFrames) == [2 * fps, fps, 2 * fps],
              insertedCuts.map(\.mediaRef) == [a.id, b.id, a.id], insertedCuts[1].trimStartFrame == 2 * fps else {
            throw GateBlocked("Insert did not preserve the displaced source tail and exact chosen range.")
        }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("Insert Undo") { editor.timeline == independentAudio }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("Insert Redo") { editor.timeline == ripple }
        try driver.capture("insert-overwrite-linking", target: window)
        try await driver.click("media.asset." + b.id, in: window)
        try await driver.contextMenu("preview.history", path: ["Close Source"], in: window)
        try await driver.wait("native source close") { !editor.previewTabs.contains(where: { $0.id == PreviewTab.mediaAssetTabId(for: b.id) }) }
        try await driver.click("media.asset." + b.id, in: window)
        try await driver.wait("source close preserves remembered In/Out") { editor.sourceFrameRange(for: b) == (2 * fps)..<(3 * fps) }
        try await driver.click("source.clear." + b.id, in: window)
        try await driver.wait("native clear source range") { editor.sourceFrameRange(for: b) == 0..<(8 * fps) }
        try await driver.contextMenu("preview.history", path: ["Clear Source History"], in: window)
        try await driver.wait("native clear history leaves timeline unchanged") { editor.previewTabs == [.timeline] && editor.timeline == ripple }
        return ["sourceIDs": [a.id, b.id], "capture": captured, "typography": typography, "sourceMemoryAndHistory": true,
            "nativeRangeInsertOverwrite": true, "nativeLinkedAudioAndLinkUndo": true, "nativeTrackControls": true, "nativeTrackHeight": true,
            "sourceCloseAndClear": true, "textAndTimelineClipboard": true, "mismatchKeptPortrait": true, "fps": fps,
            "insertFrames": ripple.totalFrames, "overwriteFrames": overwritten.totalFrames,
            "timelineSHA256": try ExportArtwork.timelineHash(editor.timeline)]
    }

    static func workspace(_ focus: EditorViewModel.WorkspaceFocus, editor: EditorViewModel,
                          window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.click("editor.workspace." + focus.rawValue, in: window, enabled: false)
        try await driver.wait("actual workspace " + focus.rawValue) {
            editor.workspaceFocus == focus && driver.state("editor.workspace." + focus.rawValue, in: window) == true
        }
    }

    static func sourceSeek(_ frame: Int, editor: EditorViewModel, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        let duration = editor.activePreviewDurationFrames
        guard duration > frame, frame >= 0, editor.activePreviewTab != .timeline else { throw GateBlocked("The exact source seek is outside the selected source.") }
        try await driver.click("preview.scrubber", in: window, fraction: .init(x: (Double(frame) + 0.5) / Double(duration), y: 0.5))
        try await driver.wait("actual source frame \(frame)") { editor.sourcePlayheadFrame == frame }
    }

    private static func textAndTimelineClipboard(asset: MediaAsset, clip: Clip, editor: EditorViewModel,
                                                  window: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let before = editor.timeline, originalName = asset.libraryDisplayName
        try await driver.contextMenu("media.asset." + asset.id, path: ["Rename"], in: window)
        try await driver.click("media.rename." + asset.id, in: window)
        var typography: [String: Any] = [:]
        try await driver.wait("actual rename field owns keyboard and uses interface scale") {
            guard let field = window.firstResponder as? NSTextView, field.isEditable, field.string == originalName,
                  let root = window.contentView,
                  let frame = WorkspaceUIAcceptance.probeFrame(identifier: "media.rename." + asset.id, in: window) else { return false }
            let owners = AppNativeMenuAcceptance.views(root).compactMap { $0 as? NSTextField }.filter {
                let bounds = $0.convert($0.bounds, to: root)
                return $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.currentEditor() === field
                    && frame.insetBy(dx: -1, dy: -1).contains(bounds) && bounds.contains(NSPoint(x: frame.midX, y: frame.midY))
            }
            guard owners.count == 1, let ownerFont = owners[0].font, let editorFont = field.font else { return false }
            let scale = AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))
            typography = ["id": "media.rename." + asset.id, "effectiveScale": scale,
                "ownerFontPointSize": ownerFont.pointSize, "editorFontPointSize": editorFont.pointSize,
                "ownsEditor": true, "viewport": [root.bounds.width, root.bounds.height], "backingScale": window.backingScaleFactor]
            return abs(ownerFont.pointSize - AppTheme.Typography.ui * scale) < 0.5
                && abs(editorFont.pointSize - AppTheme.Typography.ui * scale) < 0.5
        }
        try driver.record("native-interface-typography", fields: typography)
        try driver.pressKey(0, characters: "a", modifiers: .command, in: window)
        try driver.pressKey(8, characters: "c", modifiers: .command, in: window)
        try driver.pressKey(7, characters: "x", modifiers: .command, in: window)
        try await driver.wait("native text Cut") { driver.text("media.rename." + asset.id, in: window) == "" && editor.timeline == before }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("field Undo leaves timeline intact") { driver.text("media.rename." + asset.id, in: window) == originalName && editor.timeline == before }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("field Redo leaves timeline intact") { driver.text("media.rename." + asset.id, in: window) == "" && editor.timeline == before }
        try driver.pressKey(9, characters: "v", modifiers: .command, in: window)
        try await driver.wait("native text Paste") { driver.text("media.rename." + asset.id, in: window) == originalName }
        try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
        try GenericNLEAcceptance.pointerOnRuler(frame: 0, window: window, driver: driver)
        try await driver.wait("actual linked timeline selection") { editor.selectedClipIds.count == 2 && editor.currentFrame == 0 && asset.libraryDisplayName == originalName }
        try driver.pressKey(7, characters: "x", modifiers: .command, in: window)
        try await driver.wait("native timeline Cut") { editor.timeline.tracks.flatMap(\.clips).isEmpty }
        let cut = editor.timeline
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("timeline Cut Undo") { editor.timeline == before }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("timeline Cut Redo") { editor.timeline == cut }
        try driver.pressKey(9, characters: "v", modifiers: .command, in: window)
        try await driver.wait("native timeline Paste") { editor.timeline.tracks.flatMap(\.clips).count == 2 }
        let pasted = editor.timeline.tracks.flatMap(\.clips), oldIDs = Set(before.tracks.flatMap(\.clips).map(\.id))
        guard pasted.allSatisfy({ !oldIDs.contains($0.id) && $0.mediaRef == asset.id && $0.durationFrames == clip.durationFrames
            && $0.trimStartFrame == clip.trimStartFrame }), pasted[0].linkGroupId != nil,
              pasted[0].linkGroupId == pasted[1].linkGroupId else { throw GateBlocked("Clipboard Paste lost source range, identity or linked audio.") }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("timeline Paste Undo") { editor.timeline == cut }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("restore cut original instances") { editor.timeline == before }
        try driver.record("text-versus-timeline-clipboard", fields: ["textUndoIsolated": true, "cutUndoRedo": true, "pastePreservedSourceAndLink": true])
        return typography
    }

    private static func trackControls(videoTrack: String, audioTrack: String, editor: EditorViewModel,
                                      window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let root = window.contentView,
              let header = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineHeaderView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
            throw GateBlocked("The real track header is unavailable.")
        }
        for (trackID, kind) in [(videoTrack, "hidden"), (audioTrack, "muted"), (audioTrack, "syncLocked")] {
            let before = editor.timeline
            guard let index = before.tracks.firstIndex(where: { $0.id == trackID }) else { throw GateBlocked("The target track is missing.") }
            header.displayIfNeeded()
            let rect = kind == "hidden" ? header.hideButtonRects[index] : kind == "muted" ? header.muteButtonRects[index] : header.syncLockButtonRects[index]
            guard let rect, header.visibleRect.contains(rect) else { throw GateBlocked("The actual track control is clipped: " + kind) }
            try AppNativeMenuAcceptance.pointer(NSPoint(x: rect.midX, y: rect.midY), in: header, window: window, driver: driver, label: "track." + kind)
            try await driver.wait("native track " + kind) {
                guard let changed = editor.timeline.tracks.first(where: { $0.id == trackID }) else { return false }
                return kind == "hidden" ? changed.hidden != before.tracks[index].hidden
                    : kind == "muted" ? changed.muted != before.tracks[index].muted : changed.syncLocked != before.tracks[index].syncLocked
            }
            let after = editor.timeline
            guard after.tracks.map(\.clips) == before.tracks.map(\.clips) else { throw GateBlocked("A track toggle modified media instances.") }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("track toggle Undo") { editor.timeline == before }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("track toggle Redo") { editor.timeline == after }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("restore track control") { editor.timeline == before }
        }
        let before = editor.timeline
        guard let index = before.tracks.firstIndex(where: { $0.id == videoTrack }) else { throw GateBlocked("The resize track disappeared.") }
        let geometry = TimelineGeometry(editor: editor, bounds: header.bounds)
        let point = NSPoint(x: header.bounds.midX, y: geometry.trackY(at: index) + geometry.trackHeight(at: index))
        try await AppNativeMenuAcceptance.drag(from: point, to: .init(x: point.x, y: point.y + 24), in: header,
            window: window, driver: driver, label: "track.height")
        try await driver.wait("actual track height drag") { editor.timeline.tracks[index].displayHeight > before.tracks[index].displayHeight + 20 }
        let resized = editor.timeline
        guard resized.tracks.map(\.clips) == before.tracks.map(\.clips) else { throw GateBlocked("Track resizing changed clip content.") }
        try driver.capture("track-resized", target: window)
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("track height Undo") { editor.timeline == before }
        try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
        try await driver.wait("track height Redo") { editor.timeline == resized }
        try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
        try await driver.wait("track height restored") { editor.timeline == before }
        try driver.record("native-track-controls", fields: ["visibility": true, "mute": true, "syncLock": true,
            "heightBefore": before.tracks[index].displayHeight, "heightAfter": resized.tracks[index].displayHeight, "exactUndoRedo": true])
    }

    private static func clipMenu(_ title: String, clip: Clip, editor: EditorViewModel,
                                  window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard let root = window.contentView,
              let view = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let index = editor.timeline.tracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clip.id }) }) else {
            throw GateBlocked("The actual clip context-menu target is unavailable.")
        }
        let rect = view.geometry.clipRect(for: clip, trackIndex: index)
        try await NativeOwnerContextMenu.choose(title, window: window, driver: driver) {
            try AppNativeMenuAcceptance.pointer(.init(x: rect.midX, y: rect.midY), in: view,
                window: window, driver: driver, label: "clip." + title, right: true)
        }
    }

    private static func captureSource(_ asset: MediaAsset, frame: Int, editor: EditorViewModel,
                                       window: NSWindow, directory: URL, driver: ProductionVisualSourcesDriver) async throws -> [String: Any] {
        let original = Set(editor.mediaAssets.map(\.id)), timeline = editor.timeline
        try await driver.click("preview.capture-frame", in: window)
        try await driver.wait("native exact frame capture", seconds: 30) { editor.mediaAssets.contains { !original.contains($0.id) && $0.type == .image } }
        guard let image = editor.mediaAssets.first(where: { !original.contains($0.id) }), editor.timeline == timeline else {
            throw GateBlocked("Capture Frame did not create a separate media identity.")
        }
        let source = asset.url, output = image.url, fps = editor.timeline.fps
        let pixels = try await Task.detached {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let expected = try await generator.image(at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            guard CMTimeCompare(expected.actualTime, CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) == 0,
                  let data = CGImageSourceCreateWithURL(output as CFURL, nil), let actual = CGImageSourceCreateImageAtIndex(data, 0, nil),
                  actual.width == expected.image.width, actual.height == expected.image.height else {
                throw GateBlocked("Captured frame dimensions or exact presentation time differ from the selected source.")
            }
            let left = try pixelHash(expected.image), right = try pixelHash(actual)
            guard left == right else { throw GateBlocked("Captured frame pixels differ from the displayed source frame.") }
            return right
        }.value
        let destination = directory.appendingPathComponent("captured-source.png")
        try FileManager.default.copyItem(at: output, to: destination)
        try driver.record("source-frame-capture", fields: ["frame": frame, "fps": fps, "sourceID": asset.id,
            "newAssetID": image.id, "pixelsSHA256": pixels, "file": destination.lastPathComponent])
        return ["frame": frame, "fps": fps, "sourceID": asset.id, "newAssetID": image.id,
            "pixelsSHA256": pixels, "file": destination.lastPathComponent, "fileSHA256": try FileDigest.sha256(of: destination)]
    }

    private nonisolated static func pixelHash(_ image: CGImage) throws -> String {
        var pixels = Data(count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard rendered else { throw GateBlocked("The independent frame pixel comparison could not render.") }
        return SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum NativeOwnerContextMenu {
    static func choose(_ title: String, window: NSWindow, driver: ProductionVisualSourcesDriver,
                       open: () throws -> Void) async throws {
        @MainActor final class Tracking { var menu: NSMenu?; var titles: [String] = []; var closed = false; var error: String? }
        let tracking = Tracking()
        let begin = NativeOwnerMenuObserver(name: NSMenu.didBeginTrackingNotification) { menu in
            guard tracking.menu == nil else { return }
            tracking.menu = menu
            let items = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.isEnabled }
            tracking.titles = items.map(\.title)
            guard let index = items.firstIndex(where: { $0.title == title }) else {
                tracking.error = "The native clip menu has no enabled " + title; menu.cancelTracking(); return
            }
            do {
                try driver.pressKey(115, characters: "\u{f729}", in: window)
                for _ in 0..<index { try driver.pressKey(125, characters: "\u{f701}", in: window) }
                try driver.pressKey(36, characters: "\r", in: window)
            } catch { tracking.error = error.localizedDescription; menu.cancelTracking() }
        }
        let end = NativeOwnerMenuObserver(name: NSMenu.didEndTrackingNotification) { menu in
            if menu === tracking.menu { tracking.closed = true }
        }
        defer { NotificationCenter.default.removeObserver(begin); NotificationCenter.default.removeObserver(end) }
        try open()
        try await driver.wait("actual clip menu " + title) { tracking.closed || tracking.error != nil }
        if let error = tracking.error { throw GateBlocked(error) }
        try driver.record("native-clip-menu", fields: ["item": title, "titles": tracking.titles, "closed": tracking.closed])
    }
}

@MainActor
final class NativeOwnerMenuObserver: NSObject {
    private let handle: @MainActor (NSMenu) -> Void

    init(name: Notification.Name, handle: @escaping @MainActor (NSMenu) -> Void) {
        self.handle = handle
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: name, object: nil)
    }

    @objc private func receive(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        handle(menu)
    }
}
