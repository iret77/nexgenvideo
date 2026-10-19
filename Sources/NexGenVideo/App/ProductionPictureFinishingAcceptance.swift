import AppKit
import NexGenEngine

@MainActor
enum ProductionPictureFinishingAcceptance {
    struct Receipt: Sendable {
        let clipID: String
        let beforeSHA256: String
        let afterSHA256: String
        let screenshot: String

        var evidence: [String: Any] {
            ["clipID": clipID, "beforeSHA256": beforeSHA256, "afterSHA256": afterSHA256,
             "before": "owner-v2-picture-before.json", "after": "owner-v2-picture-after.json", "screenshot": screenshot]
        }
    }

    static func run(context: ProductionPlanningAcceptanceFixture.Context, proof: ProductionPlanAssemblyProofV1,
                    driver: ProductionVisualSourcesDriver, output: URL) async throws -> Receipt {
        let editor = context.editor, window = driver.window
        let baseline = editor.timeline
        guard let placement = proof.placements.first,
              let track = baseline.tracks.firstIndex(where: { $0.clips.contains { $0.id == placement.clipID } }),
              let index = baseline.tracks[track].clips.firstIndex(where: { $0.id == placement.clipID }) else {
            throw failed("The actual assembly has no first picture to finish.")
        }
        let clip = baseline.tracks[track].clips[index]
        guard clip.mediaType == .video, clip.durationFrames > 1, clip.transform == Transform(),
              clip.opacity == 1, (clip.effects ?? []).isEmpty else {
            throw failed("The native picture-transform fixture needs its unchanged assembled video.")
        }
        let before = try PlanningWriterIO.json(baseline)
        try before.write(to: output.appendingPathComponent("owner-v2-picture-before.json"), options: .atomic)
        let beforeSHA = FileDigest.sha256(of: before)
        try await driver.click("editor.workspace.edit", in: window, enabled: false)
        try await driver.wait("native music video picture selection") { editor.workspaceFocus == .edit }
        try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
        let frame = clip.startFrame + max(1, clip.durationFrames / 5)
        try GenericNLEAcceptance.pointerOnRuler(frame: frame, window: window, driver: driver)
        try await driver.wait("native music video picture at its actual frame") {
            editor.selectedClipIds == [clip.id] && editor.currentFrame == frame && editor.activePreviewTab == .timeline
        }
        try await driver.click("editor.workspace.postproduction", in: window, enabled: false)
        try await driver.wait("actual music video picture inspector") { editor.workspaceFocus == .postproduction }
        try await driver.click("inspector.tab.Video", in: window, enabled: false)
        let control = "inspector.transform.arrow.left.and.right"
        try await driver.reveal(control, in: window)
        try driver.visible([control], in: window)
        let originalPixels = try await PostproductionControlsAcceptance.readablePreview(editor)
        try driver.capture("musicvideo-picture-before", target: window)
        try driver.record("native Music Video picture before", fields: ["clipID": clip.id, "timelineSHA256": beforeSHA])
        try await driver.click(control, in: window)
        var expected = baseline
        expected.tracks[track].clips[index].transform.flipHorizontal = true
        try await driver.wait("native music video picture flip retained") { editor.timeline == expected }
        let changedPixels = try await PostproductionControlsAcceptance.changedPreview(editor, from: originalPixels)
        let after = try PlanningWriterIO.json(editor.timeline)
        let afterSHA = FileDigest.sha256(of: after)
        guard beforeSHA != afterSHA else { throw failed("The native picture correction did not change the film.") }
        try after.write(to: output.appendingPathComponent("owner-v2-picture-after.json"), options: .atomic)
        try driver.capture("musicvideo-picture-finished", target: window)
        guard let screenshot = driver.screenshots.last else { throw failed("The retained picture correction has no native image.") }
        let receipt = Receipt(clipID: clip.id, beforeSHA256: beforeSHA, afterSHA256: afterSHA, screenshot: screenshot)
        try driver.record("native Music Video picture finishing", fields: receipt.evidence.merging([
            "previewDifference": PostproductionControlsAcceptance.difference(originalPixels, changedPixels), "frame": frame
        ]) { _, new in new })
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        try await driver.wait("production review after native finishing") { editor.workspaceFocus == .production }
        try await ProductionV2PlanningAcceptance.selectPhase("render", context: context, driver: driver)
        try await driver.wait("current film can be reviewed after native finishing") { driver.state("sequence.build", in: window) == true }
        guard editor.timeline == expected else { throw failed("Returning to film review discarded the native picture correction.") }
        return receipt
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native Music Video picture finishing: " + message) }
}
