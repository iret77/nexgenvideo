import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum ProductionV2AudioAcceptance {
    struct Selection: Sendable {
        let path: String
        let sha256: String
        let mediaID: String
        let trackID: String
        let clip: Clip
    }

    static func insert(context: ProductionPlanningAcceptanceFixture.Context,
                       driver: ProductionVisualSourcesDriver) async throws -> Selection {
        let editor = context.editor, window = driver.window, root = context.dataRoot
        let path = "bible/refs/native-effect.wav"
        _ = try ProjectLocalFile.ensureDirectory("bible/refs", dataRoot: root)
        let url = root.appendingPathComponent(path)
        try writeAudioFixture(to: url)
        let hash = try await Task.detached { try FileDigest.sha256(of: url) }.value
        let existing = Set(editor.mediaAssets.map(\.id))
        try await driver.click("editor.workspace.media", in: window, enabled: false)
        try await driver.wait("audio import workspace") { editor.workspaceFocus == .media }
        try await driver.chooseFile(url, in: window, trigger: "media.action.Import")
        try await driver.wait("actual effect audio imported", seconds: 30) {
            editor.mediaAssets.contains { !existing.contains($0.id) && $0.type == .audio && $0.userFacingFilename == url.lastPathComponent }
        }
        let imported = editor.mediaAssets.filter { !existing.contains($0.id) }
        let importedURL = imported.first?.url
        guard imported.count == 1, let asset = imported.first, let importedURL,
              try await Task.detached(operation: { try FileDigest.sha256(of: importedURL) }).value == hash else {
            throw GateBlocked("Native effect import did not preserve exactly one actual audio source.")
        }
        try await driver.click("editor.workspace.edit", in: window, enabled: false)
        try await driver.wait("audio editing workspace") { editor.workspaceFocus == .edit }
        try GenericNLEAcceptance.pointerOnRuler(frame: 0, window: window, driver: driver)
        try await driver.wait("additional audio starts at intended film frame") { editor.currentFrame == 0 }
        try await driver.click("media.asset." + asset.id, in: window)
        try await driver.wait("actual audio source range controls") { driver.state("source.insert." + asset.id, in: window) == true }
        let total = editor.timeline.fps * 2, first = editor.timeline.fps / 2, end = editor.timeline.fps * 3 / 2
        for (frame, mark) in [(first, "in"), (end, "out")] {
            try await driver.click("preview.scrubber", in: window,
                fraction: .init(x: (Double(frame) + 0.5) / Double(total), y: 0.5))
            try await driver.wait("native source frame \(frame)") { driver.text("preview.timecode", in: window) == String(frame) }
            try await driver.click("source." + mark + "." + asset.id, in: window)
            try await driver.wait("native source " + mark) { driver.text("source." + mark + "." + asset.id, in: window) == String(frame) }
        }
        let before = Set(editor.timeline.tracks.flatMap(\.clips).map(\.id))
        try await driver.click("source.insert." + asset.id, in: window)
        try await driver.wait("additional native audio inserted") {
            editor.timeline.tracks.flatMap(\.clips).contains { !before.contains($0.id) && $0.mediaRef == asset.id }
        }
        guard let track = editor.timeline.tracks.first(where: { $0.type == .audio && $0.clips.contains { !before.contains($0.id) && $0.mediaRef == asset.id } }),
              let clip = track.clips.first(where: { !before.contains($0.id) && $0.mediaRef == asset.id }),
              clip.startFrame == 0, clip.trimStartFrame == first, clip.durationFrames == end - first else {
            throw GateBlocked("The native audio insert differs from the marked source range or timeline position.")
        }
        try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
        try await driver.wait("actual audio clip selected") { editor.selectedClipIds == [clip.id] }
        try await driver.click("editor.workspace.postproduction", in: window, enabled: false)
        try await driver.wait("native audio level editor") { editor.workspaceFocus == .postproduction }
        try await driver.fill("inspector.value.Volume", value: "-6.0", in: window, requireFocusExit: true)
        let expectedVolume = pow(10.0, -6.0 / 20.0)
        try await driver.wait("typed audio level committed") {
            guard let value = editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }) else { return false }
            return abs(value.volume - expectedVolume) < 0.000001
        }
        guard let final = editor.timeline.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }),
              final.startFrame == clip.startFrame, final.trimStartFrame == clip.trimStartFrame,
              final.durationFrames == clip.durationFrames else { throw GateBlocked("The native level edit changed source timing.") }
        try driver.capture("additional-audio-native-range-and-level", target: window)
        try driver.record("native additional Music Video audio", fields: ["mediaID": asset.id, "trackID": track.id,
            "clipID": final.id, "sourceSHA256": hash, "firstFrame": first, "endFrame": end,
            "startFrame": final.startFrame, "volume": final.volume])
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        try await driver.wait("return to approved audio planning") { editor.workspaceFocus == .production }
        return .init(path: path, sha256: hash, mediaID: asset.id, trackID: track.id, clip: final)
    }

    static func bind(_ selection: Selection, in base: MusicvideoProductionPlanDraftV1,
                     context: ProductionPlanningAcceptanceFixture.Context) async throws -> MusicvideoProductionPlanDraftV1 {
        let root = context.dataRoot
        let assets = try await Task.detached { try PipelineShotPlanningPromotionStore.availableAssets(dataRoot: root) }.value
        guard let asset = assets.first(where: { $0.path == selection.path && $0.sha256 == selection.sha256 && $0.modality == .audio }) else {
            throw GateBlocked("The natively inserted audio is missing from the actual prepared planning graph.")
        }
        return .init(performanceSegments: base.performanceSegments,
            finalMix: .init(originalSongTimelineStartSeconds: base.finalMix.originalSongTimelineStartSeconds,
                originalSongOccurrences: base.finalMix.originalSongOccurrences, providerSongAudioMuted: base.finalMix.providerSongAudioMuted,
                approvedAdditionalLayerIDs: [asset.id], creditAndUsageNote: "Native acceptance's generated test tone."),
            visualArc: base.visualArc, coverage: base.coverage)
    }

    private static func writeAudioFixture(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000),
              let samples = buffer.floatChannelData?[0] else { throw GateBlocked("The audio source fixture could not be allocated.") }
        buffer.frameLength = 96_000
        for index in 0..<96_000 { samples[index] = Float(0.15 * sin(2 * .pi * 997 * Double(index) / 48_000)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
