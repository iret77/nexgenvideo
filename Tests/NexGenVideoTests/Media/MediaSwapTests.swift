import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Native source replacement preserves exact clip state")
struct MediaSwapTests {
    @Test func refusesShortOrSilentLinkedSourceAndPreservesTrimAndSpeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwapMedia-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorViewModel()
        var assets: [MediaAsset] = []
        for (name, duration, audio) in [("Original", 8.0, true), ("Short", 3.0, true), ("Silent", 8.0, false), ("Replacement", 8.0, true)] {
            let url = directory.appendingPathComponent(name + ".mov")
            try Data(name.utf8).write(to: url)
            let asset = MediaAsset(url: url, type: .video, name: name, duration: duration)
            asset.hasAudio = audio
            editor.importMediaAsset(asset); assets.append(asset)
        }
        var video = Fixtures.clip(id: "video", mediaRef: assets[0].id, start: 20, duration: 90)
        video.trimStartFrame = 60; video.speed = 2; video.linkGroupId = "linked"
        var audio = video; audio.id = "audio"; audio.mediaType = .audio
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [video]), Track(type: .audio, clips: [audio])])
        let before = editor.timeline
        editor.beginMediaSwap(clipId: video.id)
        for asset in [assets[1], assets[2]] {
            #expect(!editor.isAssetCompatibleWithPendingSwap(asset))
            editor.completeMediaSwap(with: asset)
            #expect(editor.timeline == before && editor.pendingSwapClipId == video.id)
        }
        editor.cancelMediaSwap()
        #expect(editor.timeline == before && editor.pendingSwapClipId == nil)
        let audioURL = directory.appendingPathComponent("Only audio.wav")
        try Data("audio only".utf8).write(to: audioURL)
        let audioOnly = MediaAsset(url: audioURL, type: .audio, name: "Only audio", duration: 8)
        editor.importMediaAsset(audioOnly)
        editor.beginMediaSwap(clipId: audio.id)
        #expect(!editor.isAssetCompatibleWithPendingSwap(audioOnly))
        editor.completeMediaSwap(with: audioOnly)
        #expect(editor.timeline == before && editor.pendingSwapClipId == audio.id)
        editor.cancelMediaSwap()
        editor.beginMediaSwap(clipId: video.id)
        #expect(editor.isAssetCompatibleWithPendingSwap(assets[3]))
        editor.completeMediaSwap(with: assets[3])
        var expected = before
        for ti in expected.tracks.indices { expected.tracks[ti].clips[0].mediaRef = assets[3].id }
        #expect(editor.timeline == expected && editor.pendingSwapClipId == nil)
    }
}
