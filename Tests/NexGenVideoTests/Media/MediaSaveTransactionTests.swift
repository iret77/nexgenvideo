import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Saved clip and range publication")
struct MediaSaveTransactionTests {
    @Test(arguments: ["project", "delete", "source"])
    func changedDestinationOrSourceDoesNotPublish(reason: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedMedia-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("Original.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel(); editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        let source = directory.appendingPathComponent("Original.mp4")
        let bytes = Data("source bytes before rendering".utf8)
        try bytes.write(to: source)
        let asset = MediaAsset(url: source, type: .video, name: "Original", duration: 4)
        editor.importMediaAsset(asset)
        let clip = Fixtures.clip(mediaRef: asset.id, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let before = editor.timeline
        let other = directory.appendingPathComponent("Other.ngv")
        try Fixtures.prepareProjectPackage(at: other)
        let rendered = directory.appendingPathComponent("Rendered.mp4")
        let task = try #require(editor.saveAsMedia(source: before, name: "Saved range", type: .video) { captured, resolver in
            #expect(captured == before)
            let frozen = try #require(resolver.resolveURL(for: asset.id))
            #expect(frozen != source && (try Data(contentsOf: frozen)) == bytes)
            try Data("rendered bytes".utf8).write(to: rendered)
            switch reason {
            case "project": editor.projectURL = other
            case "delete":
                let ids = Set(editor.mediaAssets.filter { $0.id != asset.id }.map(\.id))
                editor.deleteMediaAssets(ids: ids)
            default: try Data("different source bytes".utf8).write(to: source)
            }
            return rendered
        })
        let placeholder = try #require(editor.mediaAssets.first { $0.id != asset.id })
        await task.value
        #expect(!FileManager.default.fileExists(atPath: placeholder.url.path))
        #expect(!FileManager.default.fileExists(atPath: rendered.path))
        #expect(editor.timeline == before)
        #expect(placeholder.generationStatus != .none)
    }
}
