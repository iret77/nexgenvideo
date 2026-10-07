import Foundation
import Testing
@testable import NexGenVideo

@Suite("Purpose-scoped media picker state")
@MainActor
struct MediaPickerStateTests {
    @Test("reopening a picker restores its state without changing source or pipeline assignment")
    func pickerIsolation() {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let asset = MediaAsset(id: "source", url: URL(fileURLWithPath: "/missing/source.mov"),
                               type: .video, name: "Source", duration: 10)
        editor.mediaAssets = [asset]
        editor.selectMediaAsset(asset, atSourceFrame: 30)
        let preview = editor.activePreviewTab
        let assignment = editor.mediaManifest.intakeRoleByAssetID
        let composer = editor.mediaPickerState(for: .composer)
        composer.query = "Reference"
        composer.type = .image
        composer.scrollAssetID = "remembered"
        composer.selectedAssetID = "selected"
        composer.sourceRanges[asset.id] = SourcePreviewState(positionSeconds: 2, inSeconds: 1, outSeconds: 3)

        let intake = editor.mediaPickerState(for: .intake("track"))
        #expect(intake.query.isEmpty)
        #expect(intake.type == nil)
        #expect(intake.selectedAssetID == nil)
        #expect(intake.sourceRanges.isEmpty)
        let reopened = editor.mediaPickerState(for: .composer)
        #expect(reopened === composer)
        #expect(reopened.query == "Reference")
        #expect(reopened.scrollAssetID == "remembered")
        #expect(reopened.sourceRanges[asset.id]?.inSeconds == 1)
        #expect(editor.activePreviewTab == preview)
        #expect(editor.sourcePlayheadFrame == 30)
        #expect(editor.mediaManifest.intakeRoleByAssetID == assignment)
        #expect(editor.timeline.tracks.isEmpty)
    }
}
