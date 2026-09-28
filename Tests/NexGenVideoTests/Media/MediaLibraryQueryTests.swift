import Foundation
import Testing
@testable import NexGenVideo

@Suite("Media library query")
@MainActor
struct MediaLibraryQueryTests {
    @Test("500 mixed sources are filtered without selecting or opening a preview")
    func mixedLibrary() {
        let types: [ClipType] = [.video, .audio, .image, .document, .lottie]
        let assets = (0..<500).map { index in
            MediaAsset(id: "asset-\(index)", url: URL(fileURLWithPath: "/missing/\(index)"),
                       type: types[index % types.count], name: "Source \(index)", duration: Double(index))
        }
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        editor.mediaAssets = assets
        editor.selectMediaAsset(assets[0], atSourceFrame: 12)
        let preview = editor.activePreviewTab
        let selected = editor.selectedMediaAssetIds
        let results = MediaLibraryQuery(types: [.document, .audio], sort: .duration).apply(to: assets)
        #expect(results.count == 200)
        #expect(results.allSatisfy { $0.type == .document || $0.type == .audio })
        #expect(results.first?.duration == 498)
        #expect(editor.activePreviewTab == preview)
        #expect(editor.selectedMediaAssetIds == selected)
        #expect(editor.sourcePlayheadFrame == 12)
        #expect(assets.allSatisfy { $0.thumbnail == nil })
    }

    @Test("search retains both a renamed title and the original import filename")
    func originalFilenameAndRename() {
        let hash = String(repeating: "a", count: 64)
        let asset = MediaAsset(id: "source", url: URL(fileURLWithPath: "/media/\(hash).txt"),
                               type: .document, name: "Director notes")
        asset.originalFilename = "Treatment-v3.txt"
        #expect(MediaLibraryQuery(text: "treatment", types: [.document]).apply(to: [asset]).map(\.id) == [asset.id])
        #expect(MediaLibraryQuery(text: "director").apply(to: [asset]).map(\.id) == [asset.id])
        #expect(MediaLibraryQuery(text: hash).apply(to: [asset]).isEmpty)
        asset.name = hash
        #expect(asset.libraryDisplayName == "Treatment-v3.txt")
    }
}
