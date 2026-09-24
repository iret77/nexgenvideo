import Foundation
import Testing
@testable import NexGenVideo

@Suite("Media workspace")
@MainActor
struct MediaWorkspaceTests {
    @Test func projectsMoreThanFiveHundredMixedAssetsWithoutLoadingPreviews() {
        let editor = EditorViewModel()
        let root = editor.createFolder(name: "Shoot")
        let nested = editor.createFolder(name: "Day 1", in: root)
        let types: [ClipType] = [.video, .audio, .image, .document, .lottie]
        editor.mediaAssets = (0..<520).map { index in
            let type = types[index % types.count]
            let asset = MediaAsset(
                id: "asset-\(index)",
                url: URL(fileURLWithPath: "/tmp/\(String(repeating: "a", count: 64)).\(type == .document ? "md" : "mp4")"),
                type: type,
                name: "storage-\(index)",
                duration: Double(index),
                originalFilename: "Take \(index).\(type == .document ? "md" : "mp4")"
            )
            asset.folderId = index.isMultiple(of: 2) ? nested : root
            if index.isMultiple(of: 7) {
                asset.generationInput = GenerationInput(
                    prompt: "compiled",
                    model: "fixture",
                    duration: 4,
                    aspectRatio: "16:9"
                )
            }
            return asset
        }
        let session = editor.mediaLibrarySession(for: .workspace)
        session.folderID = nested
        session.filterTypes = [.video, .document]
        session.aiOnly = true
        session.sort = .name

        let projected = MediaLibraryProjection.assets(from: editor.mediaAssets, session: session)

        #expect(projected.count > 0)
        #expect(projected.allSatisfy { $0.folderId == nested })
        #expect(projected.allSatisfy { $0.type == .video || $0.type == .document })
        #expect(projected.allSatisfy(\.isGenerated))
        #expect(editor.mediaAssets.allSatisfy { $0.thumbnail == nil })
        #expect(editor.activePreviewTab == .timeline)
    }

    @Test func pickerPurposesKeepFilterScrollSelectionAndSourceRangeSeparate() {
        let editor = EditorViewModel()
        let edit = editor.mediaLibrarySession(for: .editSource)
        let production = editor.mediaLibrarySession(for: .productionSource)
        edit.query = "close"
        edit.folderID = "rushes"
        edit.scrollAnchorID = "asset-edit"
        edit.selectedAssetIDs = ["asset-edit"]
        edit.rememberSourceState(
            SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72),
            for: "asset-edit"
        )

        production.query = "wide"
        production.folderID = "plates"
        production.scrollAnchorID = "asset-production"
        production.selectedAssetIDs = ["asset-production"]

        #expect(edit.query == "close")
        #expect(edit.folderID == "rushes")
        #expect(edit.scrollAnchorID == "asset-edit")
        #expect(edit.selectedAssetIDs == ["asset-edit"])
        #expect(edit.sourceState(for: "asset-edit") == SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72))
        #expect(production.query == "wide")
        #expect(production.folderID == "plates")
        #expect(production.scrollAnchorID == "asset-production")
        #expect(production.selectedAssetIDs == ["asset-production"])
        #expect(production.sourceState(for: "asset-edit") == SourcePreviewState())
    }

    @Test func pickerStateChangesDoNotMutateTimelinePreviewOrIntakeAssignments() {
        let editor = EditorViewModel()
        let timeline = editor.timeline
        let session = editor.mediaLibrarySession(for: .generationInput("first-frame"))
        session.query = "hero"
        session.selectedAssetIDs = ["candidate"]
        session.activeAssetID = "candidate"

        #expect(editor.timeline == timeline)
        #expect(editor.activePreviewTab == .timeline)
        #expect(editor.mediaManifest.intakeRoleByAssetID.isEmpty)
        #expect(editor.selectedMediaAssetIds.isEmpty)
    }

    @Test func selectingTheSameSourceRestoresEachPurposesOwnRange() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let source = MediaAsset(
            id: "shared-source",
            url: URL(fileURLWithPath: "/tmp/shared.mov"),
            type: .video,
            name: "Shared",
            duration: 10,
            originalFilename: "Shared.mov"
        )
        editor.mediaAssets = [source]
        let editState = SourcePreviewState(playheadFrame: 42, inFrame: 18, outFrame: 72)
        let productionState = SourcePreviewState(playheadFrame: 9, inFrame: 3, outFrame: 21)
        editor.mediaLibrarySession(for: .editSource).rememberSourceState(editState, for: source.id)
        editor.mediaLibrarySession(for: .productionSource).rememberSourceState(productionState, for: source.id)

        editor.selectMediaAsset(source, for: .editSource)
        #expect(editor.activeSourcePreviewState == editState)
        editor.selectMediaAsset(source, for: .productionSource)
        #expect(editor.activeSourcePreviewState == productionState)
        #expect(editor.mediaLibrarySession(for: .editSource).sourceState(for: source.id) == editState)
    }

    @Test func sourceRangeSurvivesTimelineInspectionAndAnotherPicker() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let source = MediaAsset(
            id: "shared-range-source",
            url: URL(fileURLWithPath: "/tmp/shared-range.mov"),
            type: .video,
            name: "Shared Range",
            duration: 10,
            originalFilename: "Shared Range.mov"
        )
        editor.mediaAssets = [source]
        let timeline = editor.timeline

        editor.selectMediaAsset(source, for: .editSource)
        editor.seekSourceToFrame(42)
        editor.markSourceIn()
        editor.seekSourceToFrame(72)
        editor.markSourceOut()
        editor.activateTimelineSelection()

        editor.selectMediaAsset(source, for: .productionSource)
        #expect(editor.activeSourcePreviewState == SourcePreviewState())
        editor.selectMediaAsset(source, for: .editSource)

        #expect(editor.activeSourcePreviewState == SourcePreviewState(playheadFrame: 72, inFrame: 42, outFrame: 72))
        #expect(editor.timeline == timeline)
    }

    @Test func filenameProjectionUsesOriginalNameInsteadOfStorageHash() {
        let editor = EditorViewModel()
        let hash = String(repeating: "b", count: 64)
        let asset = MediaAsset(
            id: "original-name",
            url: URL(fileURLWithPath: "/tmp/\(hash).mov"),
            type: .video,
            name: hash,
            originalFilename: "Interview A.mov"
        )
        let session = editor.mediaLibrarySession(for: .agentReference)
        session.query = "interview"
        session.searchScope = .filename

        let projected = MediaLibraryProjection.assets(from: [asset], session: session)

        #expect(projected.map(\.id) == [asset.id])
        #expect(projected.first?.userFacingFilename == "Interview A.mov")
        #expect(asset.userFacingFilename != asset.url.lastPathComponent)
        #expect(asset.libraryDisplayName == "Interview A.mov")
        #expect(asset.mentionDisplayName.contains("Interview"))
        #expect(!asset.mentionDisplayName.contains(hash))
    }

    @Test func libraryImportRemainsAnUnassignedCandidate() {
        let editor = EditorViewModel()
        let track = MediaAsset(
            id: "candidate-track",
            url: URL(fileURLWithPath: "/tmp/track.wav"),
            type: .audio,
            name: "Track",
            originalFilename: "Track.wav"
        )

        editor.importMediaAsset(track)

        #expect(editor.mediaAssets.contains { $0.id == track.id })
        #expect(editor.mediaManifest.intakeRoleByAssetID[track.id] == nil)
        #expect(editor.mediaManifest.songAnchorAssetId == nil)
    }

    @Test func textAssetsRemainReadOnlySourcesNotTitleClips() {
        let document = MediaAsset(
            id: "story",
            url: URL(fileURLWithPath: "/tmp/story.md"),
            type: .document,
            name: "story",
            originalFilename: "Story.md"
        )

        #expect(document.type == .document)
        #expect(!document.type.isPlaceable)
        #expect(document.type != .text)
    }
}
