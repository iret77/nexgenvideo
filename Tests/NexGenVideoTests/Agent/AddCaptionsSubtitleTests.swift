import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("add_captions caption files")
struct AddCaptionsSubtitleTests {
    private func fixture(
        id: String,
        name: String = "dialogue.en.srt",
        contents: String
    ) throws -> (directory: URL, asset: MediaAsset) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ngv-agent-caption-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file, options: .atomic)
        return (
            directory,
            MediaAsset(
                id: id,
                url: file,
                type: .subtitle,
                name: "Dialogue",
                duration: 4,
                originalFilename: name
            )
        )
    }

    @Test func resolvesShortAssetIDAndUsesCanonicalCaptionPlacement() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let source = try fixture(
            id: "AB107A6F-155C-417C-8776-41BFA1C3DF07",
            contents: "1\n00:00:01,000 --> 00:00:02,000\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld.\n"
        )
        defer { try? FileManager.default.removeItem(at: source.directory) }
        h.editor.mediaAssets.append(source.asset)

        _ = try await h.runOK(
            "add_captions",
            args: ["subtitleMediaRef": "AB107A6F"]
        )

        let clips = h.editor.timeline.tracks.flatMap(\.clips)
        #expect(clips.map(\.textContent) == ["Hello.", "World."])
        #expect(clips.map(\.startFrame) == [30, 90])
        #expect(clips.allSatisfy {
            $0.captionProvenance?.sourceFilename == "dialogue.en.srt"
                && $0.captionProvenance?.languageIdentifier == "en"
        })
    }

    @Test func rejectsMixedArgumentsWrongAssetTypesAndMalformedFilesAtomically() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        h.addAsset(id: "video", type: .video)
        let malformed = try fixture(id: "broken", contents: "not a cue\n")
        defer { try? FileManager.default.removeItem(at: malformed.directory) }
        h.editor.mediaAssets.append(malformed.asset)
        let before = h.editor.timeline

        let mixed = await h.runRaw(
            "add_captions",
            args: ["subtitleMediaRef": "broken", "fontName": "Helvetica"]
        )
        #expect(ToolHarness.textOf(mixed).contains("fontName"))

        let wrongType = await h.runRaw(
            "add_captions",
            args: ["subtitleMediaRef": "video"]
        )
        #expect(ToolHarness.textOf(wrongType).contains("not a caption file"))

        let invalid = await h.runRaw(
            "add_captions",
            args: ["subtitleMediaRef": "broken"]
        )
        #expect(invalid.isError)
        #expect(ToolHarness.textOf(invalid).contains("malformed"))
        #expect(h.editor.timeline == before)
    }
}
