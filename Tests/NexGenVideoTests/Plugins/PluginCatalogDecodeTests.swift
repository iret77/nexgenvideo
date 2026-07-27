import Foundation
import Testing

@testable import NexGenVideo

@Suite("Plugin catalog decode")
struct PluginCatalogDecodeTests {

    @Test func decodesCatalog() throws {
        let json = """
        {
          "schema": "plugins/v1",
          "plugins": [
            {
              "id": "musicvideo",
              "displayName": "Music Video Studio",
              "tagline": "Structured AI music-video production.",
              "version": "0.0.1",
              "minAppVersion": "0.1.0",
              "url": "https://github.com/iret77/nexgenvideo/releases/download/plugins/musicvideo-0.0.1.ngvpack.zip",
              "sha256": "abc123"
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try PluginCatalogService.decode(json)
        #expect(catalog.plugins.count == 1)
        let entry = try #require(catalog.plugins.first)
        #expect(entry.id == "musicvideo")
        #expect(entry.displayName == "Music Video Studio")
        #expect(entry.version == "0.0.1")
        #expect(entry.projectSchema == "musicvideo/legacy")
        #expect(entry.migratesFrom.isEmpty)
        #expect(entry.minAppVersion == "0.1.0")
        #expect(entry.sha256 == "abc123")
        #expect(entry.url.lastPathComponent == "musicvideo-0.0.1.ngvpack.zip")
    }

    @Test func decodesProjectSchemaAndMigrationContract() throws {
        let catalog = try PluginCatalogService.decode("""
        {"plugins":[{"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.6",
          "projectSchema":"musicvideo/2.0.0",
          "migratesFrom":["musicvideo/legacy","musicvideo/1.0.0"],
          "minAppVersion":"1.0.0","url":"https://ex.com/mv.ngvpack.zip","sha256":"abc"}]}
        """.data(using: .utf8)!)
        let entry = try #require(catalog.plugins.first)
        #expect(entry.projectSchema == "musicvideo/2.0.0")
        #expect(entry.migratesFrom == ["musicvideo/legacy", "musicvideo/1.0.0"])
    }

    /// #168: the app must read the STABLE `plugins` channel. `dev-latest` is delete+recreated on
    /// every push to main, so pointing here again would resurrect the 0.7.7 failure where a
    /// released pack fix never reached the app. Cheap guard against an innocent-looking revert.
    @Test func catalogURLIsTheStableChannelNotDevLatest() {
        let url = PluginCatalogService.catalogURL
        #expect(url.scheme == "https")
        #expect(!url.absoluteString.contains("dev-latest"))
        #expect(url.absoluteString.hasSuffix("/releases/download/plugins/catalog.json"))
    }

    @Test func signedBundleCanSelectAnIsolatedPreviewCatalog() {
        let preview = PluginCatalogService.resolvedCatalogURL(
            configuredValue: "https://github.com/iret77/nexgenvideo/releases/download/preview-123/catalog.json"
        )
        #expect(preview.absoluteString.hasSuffix("/releases/download/preview-123/catalog.json"))
    }

    @Test func invalidConfiguredCatalogFallsBackToStable() {
        #expect(
            PluginCatalogService.resolvedCatalogURL(configuredValue: "http://example.com/catalog.json")
                == PluginCatalogService.stableCatalogURL
        )
        #expect(
            PluginCatalogService.resolvedCatalogURL(configuredValue: nil)
                == PluginCatalogService.stableCatalogURL
        )
    }

    /// The channel lists SEVERAL versions per pack; decoding must keep them all (the app, not the
    /// decoder, narrows to the newest compatible one).
    @Test func decodesMultipleVersionsOfOnePack() throws {
        let catalog = try PluginCatalogService.decode("""
        {"schema":"plugins/v2","plugins":[
          {"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.3","minAppVersion":"0.2.0",
           "url":"https://ex.com/musicvideo-0.0.3.ngvpack.zip","sha256":"a"},
          {"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.1","minAppVersion":"0.1.0",
           "url":"https://ex.com/musicvideo-0.0.1.ngvpack.zip","sha256":"b"}]}
        """.data(using: .utf8)!)
        #expect(catalog.plugins.count == 2)
        #expect(catalog.plugins.map(\.version) == ["0.0.3", "0.0.1"])
    }

    @Test func emptyCatalogDecodes() throws {
        let catalog = try PluginCatalogService.decode(#"{"plugins":[]}"#.data(using: .utf8)!)
        #expect(catalog.plugins.isEmpty)
    }

    /// The optional `badge` URL decodes when present and is nil when absent — the
    /// catalog can carry a pre-install badge, but older entries without one still load.
    @Test func badgeIsOptional() throws {
        let withBadge = try PluginCatalogService.decode("""
        {"plugins":[{"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.1",
          "minAppVersion":"0.1.0","url":"https://ex.com/mv.ngvpack.zip","sha256":"abc",
          "badge":"https://ex.com/musicvideo.badge.png"}]}
        """.data(using: .utf8)!)
        #expect(withBadge.plugins.first?.badge == URL(string: "https://ex.com/musicvideo.badge.png"))

        let withoutBadge = try PluginCatalogService.decode("""
        {"plugins":[{"id":"musicvideo","displayName":"MV","tagline":"t","version":"0.0.1",
          "minAppVersion":"0.1.0","url":"https://ex.com/mv.ngvpack.zip","sha256":"abc"}]}
        """.data(using: .utf8)!)
        #expect(withoutBadge.plugins.first?.badge == nil)
    }

    @Test func malformedCatalogThrows() {
        #expect(throws: (any Error).self) {
            _ = try PluginCatalogService.decode(#"{"plugins":[{"id":"x"}]}"#.data(using: .utf8)!)
        }
    }

    /// An installed pack is "updatable" when the catalog offers a newer version —
    /// a straight SemanticVersion compare, the same the picker uses.
    @Test func updateDetection() {
        #expect(SemanticVersion("0.0.2")! > SemanticVersion("0.0.1")!)
        #expect(!(SemanticVersion("0.0.1")! > SemanticVersion("0.0.1")!))
    }
}
