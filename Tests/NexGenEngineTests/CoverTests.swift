import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/test_cover.py`.
@Suite("Musicvideo Cover", .serialized)
struct CoverTests {
    @Test("schema version")
    func schemaVersion() {
        #expect(coverSchemaVersion == "cover/v2")
    }

    @Test("format aspect map")
    func formatAspectMap() {
        #expect(coverFormatAspect["square"] == "1:1")
        #expect(coverFormatAspect["landscape"] == "16:9")
        #expect(coverFormatAspect["portrait"] == "9:16")
    }

    @Test("manifest defaults")
    func manifestDefaults() {
        let m = CoverManifest(project: "demo", generated: "2026-06-29")
        #expect(m.schema == coverSchemaVersion)
        #expect(m.format == .square)
    }

    @Test("save/load round-trip")
    func saveLoadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = CoverManifest(
            project: "demo", format: .landscape, generated: "2026-06-29",
            clean: CoverClean(
                path: "cover/clean.png", prompt: "moody album art", providerPrompt: "moody album art, cinematic",
                modelId: "gpt_image_2"
            ),
            text: CoverText(path: "cover/text.png", overlay: TextOverlay(artist: "Artist", title: "Title"))
        )
        let written = try Cover.save(projectDir: tmp, manifest: manifest)
        #expect(written == tmp.appendingPathComponent("cover").appendingPathComponent("landscape.yaml"))

        let loaded = try Cover.load(projectDir: tmp, format: "landscape")
        #expect(loaded == manifest)
    }

    @Test("load falls back to the legacy square cover.yaml path")
    func loadFallsBackToLegacyPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coverDir = tmp.appendingPathComponent("cover")
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let legacyYAML = """
            project: demo
            generated: '2026-06-29'
            """
        try legacyYAML.write(to: coverDir.appendingPathComponent("cover.yaml"), atomically: true, encoding: .utf8)

        let loaded = try Cover.load(projectDir: tmp, format: "square")
        #expect(loaded?.project == "demo")
        #expect(loaded?.format == .square)
        #expect(loaded?.schema == coverSchemaVersion)
    }

    @Test("load returns nil when nothing is on disk")
    func loadReturnsNilWhenMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try Cover.load(projectDir: tmp, format: "square") == nil)
    }
}
