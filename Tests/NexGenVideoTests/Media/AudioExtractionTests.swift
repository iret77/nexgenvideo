import AVFoundation
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Audio extraction")
@MainActor
struct AudioExtractionTests {
    private struct StubFailure: LocalizedError, Sendable {
        var errorDescription: String? { "The selected track could not be decoded." }
    }

    @Test("a single track becomes a content-addressed project asset without assignment")
    func singleTrackExtraction() async throws {
        let setup = try makeSavedEditor()
        let editor = setup.editor
        defer { cleanup(editor: editor, directory: setup.cleanup) }
        let source = try makeSourceAsset(editor: editor, in: setup.cleanup)
        let timelineBefore = editor.timeline
        let rolesBefore = editor.mediaManifest.intakeRoleByAssetID
        editor.audioTrackExtractionClient = stubClient(
            tracks: [AudioTrackDescriptor(id: 0, number: 1, channelCount: 2)]
        )

        editor.beginAudioExtraction(from: source.id)
        await editor.audioExtractionTask?.value

        let extracted = try #require(editor.mediaAssets.first { $0.id != source.id })
        let entry = try #require(editor.mediaManifest.entries.first { $0.id == extracted.id })
        let root = try #require(editor.workingRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        let stored = extracted.url.standardizedFileURL.resolvingSymlinksInPath()
        #expect(extracted.type == .audio)
        #expect(extracted.name == "Camera A 001 - Audio")
        #expect(extracted.originalFilename == "Camera A 001 - Audio.m4a")
        #expect(extracted.folderId == source.folderId)
        #expect(stored.path.hasPrefix(root.path + "/media/"))
        #expect(stored.pathExtension == "m4a")
        #expect(stored.deletingPathExtension().lastPathComponent.count == 64)
        #expect(entry.origin == MediaAssetOrigin(
            kind: .extractedAudio,
            sourceAssetID: source.id,
            sourceFilename: "Camera A 001.mov",
            audioTrackNumber: 1,
            audioTrackLabel: "Track 1 (Stereo)"
        ))
        #expect(editor.timeline == timelineBefore)
        #expect(editor.mediaManifest.intakeRoleByAssetID == rolesBefore)
        #expect(editor.mediaManifest.intakeRoleByAssetID[extracted.id] == nil)
        #expect(editor.mediaPanelToast?.kind == .success)
    }

    @Test("multiple tracks require an explicit selection")
    func multipleTracksRequireSelection() async throws {
        let setup = try makeSavedEditor()
        let editor = setup.editor
        defer { cleanup(editor: editor, directory: setup.cleanup) }
        let source = try makeSourceAsset(editor: editor, in: setup.cleanup)
        editor.audioTrackExtractionClient = stubClient(tracks: [
            AudioTrackDescriptor(id: 0, number: 1, channelCount: 1),
            AudioTrackDescriptor(id: 1, number: 2, channelCount: 2),
        ])

        editor.beginAudioExtraction(from: source.id)
        await editor.audioExtractionTask?.value

        let request = try #require(editor.pendingAudioTrackSelection)
        #expect(editor.mediaAssets.count == 1)
        #expect(request.tracks.map(\.label) == ["Track 1 (Mono)", "Track 2 (Stereo)"])

        editor.selectAudioTrack(request.tracks[1])
        await editor.audioExtractionTask?.value

        let extracted = try #require(editor.mediaAssets.first { $0.id != source.id })
        #expect(extracted.originalFilename == "Camera A 001 - Audio Track 2.m4a")
        #expect(extracted.origin?.audioTrackNumber == 2)
        #expect(extracted.origin?.audioTrackLabel == "Track 2 (Stereo)")
    }

    @Test("export failure is visible and does not register a partial asset")
    func exportFailure() async throws {
        let setup = try makeSavedEditor()
        let editor = setup.editor
        defer { cleanup(editor: editor, directory: setup.cleanup) }
        let source = try makeSourceAsset(editor: editor, in: setup.cleanup)
        editor.audioTrackExtractionClient = AudioTrackExtractionClient(
            tracks: { _ in [AudioTrackDescriptor(id: 0, number: 1, channelCount: 2)] },
            extract: { _, _, _ in throw StubFailure() }
        )

        editor.beginAudioExtraction(from: source.id)
        await editor.audioExtractionTask?.value

        #expect(editor.mediaAssets.map(\.id) == [source.id])
        #expect(editor.audioExtractionProgress == nil)
        #expect(editor.mediaPanelToast?.message == "The selected track could not be decoded.")
    }

    @Test("cancellation is visible and does not register a partial asset")
    func cancellation() async throws {
        let setup = try makeSavedEditor()
        let editor = setup.editor
        defer { cleanup(editor: editor, directory: setup.cleanup) }
        let source = try makeSourceAsset(editor: editor, in: setup.cleanup)
        editor.audioTrackExtractionClient = AudioTrackExtractionClient(
            tracks: { _ in [AudioTrackDescriptor(id: 0, number: 1, channelCount: 2)] },
            extract: { _, _, destination in
                try Data("partial".utf8).write(to: destination)
                try await Task.sleep(for: .seconds(30))
            }
        )

        editor.beginAudioExtraction(from: source.id)
        let task = try #require(editor.audioExtractionTask)
        for _ in 0..<100 where editor.audioExtractionProgress?.stage == .inspecting {
            await Task.yield()
        }
        editor.cancelAudioExtraction()
        await task.value

        #expect(editor.mediaAssets.map(\.id) == [source.id])
        #expect(editor.audioExtractionProgress == nil)
        #expect(editor.mediaPanelToast?.message == "Audio extraction canceled.")
    }

    @Test("a symlinked media folder cannot escape the working copy")
    func symlinkEscapeIsRejected() async throws {
        let setup = try makeSavedEditor()
        let editor = setup.editor
        let outside = setup.cleanup.appendingPathComponent("outside", isDirectory: true)
        defer { cleanup(editor: editor, directory: setup.cleanup) }
        let source = try makeSourceAsset(editor: editor, in: setup.cleanup)
        let root = try #require(editor.workingRoot)
        let media = root.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        editor.audioTrackExtractionClient = stubClient(
            tracks: [AudioTrackDescriptor(id: 0, number: 1, channelCount: 2)]
        )

        editor.beginAudioExtraction(from: source.id)
        await editor.audioExtractionTask?.value

        #expect(editor.mediaAssets.map(\.id) == [source.id])
        #expect(editor.mediaPanelToast?.message.contains("resolves outside") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("derived filenames preserve the source stem and identify selected tracks")
    func filenameDerivation() {
        #expect(EditorViewModel.extractedAudioFilename(
            sourceFilename: "/ignored/Camera A.001.MOV",
            trackNumber: 1,
            trackCount: 1
        ) == "Camera A.001 - Audio.m4a")
        #expect(EditorViewModel.extractedAudioFilename(
            sourceFilename: "Interview.mov",
            trackNumber: 3,
            trackCount: 4
        ) == "Interview - Audio Track 3.m4a")
    }

    @Test("the live extractor writes one playable M4A audio track")
    func liveExtractorWritesM4A() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-source-\(UUID().uuidString).mp4")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-result-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try await writeVideoWithAudio(to: source)

        let tracks = try await AudioTrackExtractor.tracks(sourceURL: source)
        let track = try #require(tracks.first)
        try await AudioTrackExtractor.extract(
            sourceURL: source,
            trackIndex: track.id,
            destinationURL: destination
        )

        let output = AVURLAsset(url: destination)
        #expect(try await output.loadTracks(withMediaType: .audio).count == 1)
        #expect(try await output.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await output.load(.duration).seconds > 0)
    }

    private func makeSavedEditor() throws -> (editor: EditorViewModel, cleanup: URL) {
        let cleanup = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-extraction-\(UUID().uuidString)", isDirectory: true)
        let package = cleanup.appendingPathComponent("Project.ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline()
        editor.projectURL = package
        return (editor, cleanup)
    }

    private func makeSourceAsset(
        editor: EditorViewModel,
        in directory: URL
    ) throws -> MediaAsset {
        let sourceURL = directory.appendingPathComponent("Camera A 001.mov")
        try Data("source video".utf8).write(to: sourceURL)
        let folderID = editor.createFolder(name: "Interviews")
        let source = MediaAsset(
            url: sourceURL,
            type: .video,
            name: "Camera A 001",
            originalFilename: sourceURL.lastPathComponent
        )
        source.hasAudio = true
        source.folderId = folderID
        editor.importMediaAsset(source)
        return source
    }

    private func stubClient(tracks: [AudioTrackDescriptor]) -> AudioTrackExtractionClient {
        AudioTrackExtractionClient(
            tracks: { _ in tracks },
            extract: { _, trackIndex, destination in
                try Data("audio track \(trackIndex)".utf8).write(to: destination)
            }
        )
    }

    private func cleanup(editor: EditorViewModel, directory: URL) {
        editor.releaseWorkingCopy()
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeVideoWithAudio(to url: URL) async throws {
        let videoURL = try await FixtureVideo.write(scenes: [
            .init(rgb: (20, 40, 80), seconds: 1),
        ])
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-audio-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        try writeSilentAudio(to: audioURL)

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTrack = try #require(
            try await videoAsset.loadTracks(withMediaType: .video).first
        )
        let audioTrack = try #require(
            try await audioAsset.loadTracks(withMediaType: .audio).first
        )
        let duration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        let compositionVideo = try #require(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let compositionAudio = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        try compositionAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        let session = try #require(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ))
        try await session.export(to: url, as: .mp4)
    }

    private func writeSilentAudio(to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)
        )
        buffer.frameLength = 44_100
        try file.write(from: buffer)
    }
}
