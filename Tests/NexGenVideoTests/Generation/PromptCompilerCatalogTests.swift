import Foundation
import Testing

@testable import NexGenVideo

@Suite("Prompt compiler catalog")
@MainActor
struct PromptCompilerCatalogTests {
    @Test func modalityUsesTheAdmissionCatalogWithoutChangingTheSharedCatalog() throws {
        let imageID = "catalog-image-\(UUID().uuidString)"
        let audioID = "catalog-audio-\(UUID().uuidString)"
        let image = try #require(ModelCatalog.launchEntries.first { $0.kind == .image })
        let audio = try #require(ModelCatalog.launchEntries.first { $0.kind == .audio })
        let catalog = ModelCatalog()
        catalog.load(entries: [
            CatalogEntry(id: imageID, kind: .image, displayName: "Isolated image",
                allowedEndpoints: image.allowedEndpoints, responseShape: image.responseShape,
                uiCapabilities: image.uiCapabilities),
            CatalogEntry(id: audioID, kind: .audio, displayName: "Isolated audio",
                allowedEndpoints: audio.allowedEndpoints, responseShape: audio.responseShape,
                uiCapabilities: audio.uiCapabilities)
        ])

        #expect(ModelCatalog.shared.byId[imageID] == nil)
        #expect(ModelCatalog.shared.byId[audioID] == nil)
        #expect(PromptCompiler.modalityForModel(imageID, modelCatalog: catalog) == .image)
        #expect(PromptCompiler.modalityForModel(audioID, modelCatalog: catalog) == .audio)
        #expect(PromptCompiler.modalityForModel(imageID) == .video)
        #expect(PromptCompiler.modalityForModel(audioID) == .video)
        catalog.load(entries: [])
        #expect(PromptCompiler.modalityForModel(imageID, modelCatalog: catalog) == .video)
    }
}
