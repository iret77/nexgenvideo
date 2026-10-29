import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Captions bind the actual source and editing state")
struct CaptionTransactionTests {
    @Test func frozenInputOptionsAndSourceClockSurviveUntilOneUndoablePlacement() async throws {
        let (editor, source) = try fixture()
        let before = editor.timeline
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let seen = Observation()
        editor.captionTranscriptionClient = .init(transcribe: { url, video, range, censor, locale in
            #expect(url != source && !video)
            #expect(try Data(contentsOf: url) == Data("original audio bytes".utf8))
            #expect(range == 0...5 && censor && locale?.identifier == "en_US")
            seen.url = url
            return transcript()
        }, supportedLocales: { [Locale(identifier: "en_US")] })
        let ids = try await editor.generateCaptions(for: .init(sourceClipIds: ["voice"], textCase: .upper,
            censorProfanity: true, locale: Locale(identifier: "en_US")))
        let captions = editor.timeline.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        #expect(!captions.isEmpty && captions.allSatisfy { $0.textContent == "HELLO WORLD." })
        #expect(captions.first?.startFrame == 75 && captions.first?.durationFrames == 30)
        #expect(editor.clipFor(id: "voice") == before.tracks[0].clips[0])
        let frozen = try #require(seen.url)
        #expect(!FileManager.default.fileExists(atPath: frozen.path))
        let after = editor.timeline
        undo.undo(); #expect(editor.timeline == before)
        undo.redo(); #expect(editor.timeline == after)
    }

    @Test func editingDuringTranscriptionRejectsAllLateCaptions() async throws {
        let (editor, _) = try fixture()
        editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in
            editor.timeline.width = 1080
            return transcript()
        }, supportedLocales: { [] })
        await #expect(throws: EditorViewModel.CaptionError.timelineChanged) {
            try await editor.generateCaptions(for: .init(sourceClipIds: ["voice"]))
        }
        #expect(editor.timeline.width == 1080 && editor.timeline.tracks.count == 1)
    }

    @Test func changedSourceAndCancellationNeverPublishPartialCaptions() async throws {
        for cancel in [false, true] {
            let (editor, source) = try fixture()
            let before = editor.timeline
            let seen = Observation()
            editor.captionTranscriptionClient = .init(transcribe: { url, _, _, _, _ in
                seen.url = url
                if cancel { throw CancellationError() }
                try Data("changed original".utf8).write(to: source, options: .atomic)
                #expect(try Data(contentsOf: url) == Data("original audio bytes".utf8))
                return transcript()
            }, supportedLocales: { [] })
            if cancel {
                await #expect(throws: CancellationError.self) {
                    try await editor.generateCaptions(for: .init(sourceClipIds: ["voice"]))
                }
            } else {
                await #expect(throws: EditorViewModel.CaptionError.sourceChanged) {
                    try await editor.generateCaptions(for: .init(sourceClipIds: ["voice"]))
                }
            }
            #expect(editor.timeline == before)
            let frozen = try #require(seen.url)
            #expect(!FileManager.default.fileExists(atPath: frozen.deletingLastPathComponent().path))
        }
    }

    @Test func nonzeroSourceRangeAtDoubleSpeedMapsToExactTimelineFrames() async throws {
        let (editor, _) = try fixture()
        editor.timeline.tracks[0].clips[0].trimStartFrame = 300
        editor.timeline.tracks[0].clips[0].speed = 2
        let before = editor.timeline
        editor.captionTranscriptionClient = .init(transcribe: { _, _, range, _, _ in
            #expect(range == 9...17)
            return .init(text: "Later phrase.", language: "en", words: [],
                segments: [.init(text: "Later phrase.", start: 11, end: 13)])
        }, supportedLocales: { [] })
        let ids = try await editor.generateCaptions(for: .init(sourceClipIds: ["voice"]))
        let caption = try #require(ids.first.flatMap { editor.clipFor(id: $0) })
        #expect(caption.startFrame == 75 && caption.durationFrames == 30)
        #expect(editor.clipFor(id: "voice") == before.tracks[0].clips[0])
    }

    @Test func overlappingSourcesPreserveBothCaptionsOnSeparateTracks() async throws {
        let (editor, source) = try fixture()
        let other = MediaAsset(id: "other", url: source, type: .audio, name: "Other", duration: 6)
        editor.mediaAssets.append(other); editor.mediaManifest.entries.append(other.toManifestEntry(projectURL: nil))
        var clip = editor.timeline.tracks[0].clips[0]; clip.id = "other-clip"; clip.mediaRef = other.id
        editor.timeline.tracks.append(Fixtures.audioTrack(clips: [clip]))
        let before = editor.timeline
        editor.captionTranscriptionClient = .init(transcribe: { _, _, _, _, _ in transcript() }, supportedLocales: { [] })
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let ids = try await editor.generateCaptions(for: .init(sourceClipIds: ["voice", "other-clip"]))
        #expect(ids.count == 2)
        #expect(ids.allSatisfy { editor.clipFor(id: $0)?.startFrame == 75 && editor.clipFor(id: $0)?.durationFrames == 30 })
        #expect(Set(ids.compactMap { editor.findClip(id: $0)?.trackIndex }).count == 2)
        undo.undo(); #expect(editor.timeline == before)
    }

    @Test func taskCancellationWhileTranscribingRemovesSnapshotAndPublishesNothing() async throws {
        let (editor, _) = try fixture()
        let before = editor.timeline, seen = Observation()
        editor.captionTranscriptionClient = .init(transcribe: { url, _, _, _, _ in
            seen.url = url
            try await Task.sleep(for: .seconds(30))
            return transcript()
        }, supportedLocales: { [] })
        let task = Task { try await editor.generateCaptions(for: .init(sourceClipIds: ["voice"])) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while seen.url == nil && ContinuousClock.now < deadline { await Task.yield() }
        _ = try #require(seen.url)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(editor.timeline == before)
        let url = try #require(seen.url)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func frozenCacheUsesBytesRangeAndOptionsInsteadOfTemporaryPath() async throws {
        let (editor, source) = try fixture()
        try Data(UUID().uuidString.utf8).write(to: source)
        let first = try CaptionInputSnapshot.freeze(["voice": source])
        let second = try CaptionInputSnapshot.freeze(["voice": source])
        defer { first.discard(); second.discard() }
        let calls = Observation()
        var client = CaptionTranscriptionClient(transcribe: { _, _, _, _, _ in
            calls.count += 1; return transcript()
        }, supportedLocales: { [] })
        client.cacheFrozenSources = true
        let a = try #require(first.sources["voice"]), b = try #require(second.sources["voice"])
        _ = try await client.transcribeFrozen(a, video: false, range: 0...5, censor: false, locale: nil)
        _ = try await client.transcribeFrozen(b, video: false, range: 0...5, censor: false, locale: nil)
        #expect(calls.count == 1 && a.frozen != b.frozen)
        _ = try await client.transcribeFrozen(b, video: false, range: 0...5, censor: true, locale: nil)
        _ = try await client.transcribeFrozen(b, video: false, range: 1...5, censor: true, locale: nil)
        _ = try await client.transcribeFrozen(b, video: false, range: 1...5, censor: true, locale: Locale(identifier: "fr"))
        #expect(calls.count == 4)
        #expect(editor.timeline.tracks.count == 1)
    }

    @MainActor private final class Observation { var url: URL?; var count = 0 }

    private func fixture() throws -> (EditorViewModel, URL) {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("caption-transaction-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let source = package.appendingPathComponent("Voice.wav")
        try Data("original audio bytes".utf8).write(to: source)
        let editor = EditorViewModel(); editor.projectURL = package
        let asset = MediaAsset(id: "voice-source", url: source, type: .audio, name: "Voice", duration: 6)
        editor.mediaAssets = [asset]
        editor.mediaManifest.entries = [asset.toManifestEntry(projectURL: nil)]
        var clip = Fixtures.clip(id: "voice", mediaRef: asset.id, mediaType: .audio, start: 60, duration: 90)
        clip.trimStartFrame = 30
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        return (editor, source)
    }
}

private func transcript() -> TranscriptionResult {
    .init(text: "Hello world.", language: "en", words: [
        .init(text: "Hello", start: 1.5, end: 2), .init(text: "world.", start: 2, end: 2.5)],
        segments: [.init(text: "Hello world.", start: 1.5, end: 2.5)])
}
