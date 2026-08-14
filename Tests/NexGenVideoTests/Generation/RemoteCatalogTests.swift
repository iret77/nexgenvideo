import Foundation
import Testing

@testable import NexGenVideo

@Suite("Remote model catalog authority")
struct RemoteCatalogTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func checkedInCatalogCarriesAllSeedance25Endpoints() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("catalog/models.json"))
        let entries = try JSONDecoder().decode([CatalogEntry].self, from: data)
        #expect(Set(entries.map(\.id)) == [
            "bytedance/seedance-2.5/text-to-video",
            "bytedance/seedance-2.5/image-to-video",
            "bytedance/seedance-2.5/reference-to-video",
        ])
        for entry in entries {
            guard case .video(let caps) = entry.uiCapabilities else {
                Issue.record("expected video entry for \(entry.id)")
                continue
            }
            #expect(caps.duration.range == .init(min: 4, max: 30))
            #expect(caps.duration.supportsAuto)
            #expect(caps.resolutions == ["480p", "720p"])
            #expect(entry.offers?.first?.provider == .fal)
        }
    }

    @Test func remoteEntryWinsWithoutDroppingSeedRouting() throws {
        let seed = try #require(FalModelRegistry.entries.first {
            $0.id == "bytedance/seedance-2.5/text-to-video"
        })
        let json = #"""
        [{
          "id":"bytedance/seedance-2.5/text-to-video",
          "kind":"video",
          "displayName":"Remote Seedance 2.5",
          "allowedEndpoints":[],
          "responseShape":"video",
          "uiCapabilities":{
            "duration":{"discrete":[],"range":{"min":4,"max":30},"supportsAuto":true},
            "resolutions":["480p","720p"],"aspectRatios":["16:9"],
            "supportsFirstFrame":false,"supportsLastFrame":false,
            "maxReferenceImages":0,"maxReferenceVideos":0,"maxReferenceAudios":0,
            "framesAndReferencesExclusive":false,"referenceTagNoun":"reference",
            "requiresSourceVideo":false,"requiresReferenceImage":false
          }
        }]
        """#
        let remote = try JSONDecoder().decode([CatalogEntry].self, from: Data(json.utf8))
        let result = RemoteCatalog.overlay(remote, on: [seed])
        let entry = try #require(result.first)
        #expect(entry.displayName == "Remote Seedance 2.5")
        #expect(entry.allowedEndpoints == seed.allowedEndpoints)
        #expect(entry.offers == seed.offers)
        #expect(FalModelRegistry.model(for: entry.id)?.videoDuration == .secondsOrAuto)
    }
}
