import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Media workspace")
@MainActor
struct MediaWorkspaceTests {
    @Test func projectionFiltersMoreThanFiveHundredMixedAssetsWithoutChangingPreview() {
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
        #expect(editor.activePreviewTab == .timeline)
    }

    @Test func workspaceSwitchPreservesCompactPickerStateAndPerPurposeSourceRange() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let productionFolder = editor.createFolder(name: "Production")
        let source = MediaAsset(
            id: "shared-purpose-source",
            url: URL(fileURLWithPath: "/tmp/shared-purpose.mov"),
            type: .video,
            name: "Shared Purpose",
            duration: 10,
            originalFilename: "Shared Purpose.mov"
        )
        editor.mediaAssets = [source]
        let production = editor.mediaLibrarySession(for: .productionSource)
        production.folderID = productionFolder
        editor.selectMediaAsset(source, for: .productionSource)
        editor.seekSourceToFrame(42)
        editor.markSourceIn()
        editor.seekSourceToFrame(72)
        editor.markSourceOut()

        editor.setWorkspaceFocus(.edit)
        editor.selectMediaAsset(source, for: .editSource)
        editor.seekSourceToFrame(9)
        editor.markSourceIn()
        editor.seekSourceToFrame(21)
        editor.markSourceOut()
        editor.setWorkspaceFocus(.production)

        #expect(production.folderID == productionFolder)
        #expect(production.selectedAssetIDs == [source.id])
        #expect(editor.activeSourcePreviewState == SourcePreviewState(playheadFrame: 72, inFrame: 42, outFrame: 72))
        #expect(editor.mediaLibrarySession(for: .editSource).sourceState(for: source.id)
            == SourcePreviewState(playheadFrame: 21, inFrame: 9, outFrame: 21))
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

    @Test func workspaceRestoreDoesNotBorrowAnotherPurposesRange() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let source = MediaAsset(
            id: "purpose-restore-source",
            url: URL(fileURLWithPath: "/tmp/purpose-restore.mov"),
            type: .video,
            name: "Purpose Restore",
            duration: 10,
            originalFilename: "Purpose Restore.mov"
        )
        editor.mediaAssets = [source]

        editor.setWorkspaceFocus(.postproduction)
        editor.selectMediaAsset(source)
        editor.setWorkspaceFocus(.production)
        editor.mediaLibrarySession(for: .postproductionSource).sourceStates[source.id] = nil
        editor.selectMediaAsset(source, for: .productionSource)
        editor.seekSourceToFrame(18)
        editor.markSourceIn()
        editor.seekSourceToFrame(72)
        editor.markSourceOut()

        editor.setWorkspaceFocus(.postproduction)

        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.activeSourcePreviewState == SourcePreviewState())
        #expect(editor.mediaLibrarySession(for: .postproductionSource).sourceState(for: source.id)
            == SourcePreviewState())
    }

    @Test func workspaceRestoreDoesNotBorrowARangeThroughExport() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let source = MediaAsset(
            id: "export-intermediary-source",
            url: URL(fileURLWithPath: "/tmp/export-intermediary.mov"),
            type: .video,
            name: "Export Intermediary",
            duration: 10,
            originalFilename: "Export Intermediary.mov"
        )
        editor.mediaAssets = [source]

        editor.setWorkspaceFocus(.postproduction)
        editor.selectMediaAsset(source)
        editor.setWorkspaceFocus(.production)
        editor.mediaLibrarySession(for: .postproductionSource).sourceStates[source.id] = nil
        editor.selectMediaAsset(source, for: .productionSource)
        editor.seekSourceToFrame(18)
        editor.markSourceIn()
        editor.seekSourceToFrame(72)
        editor.markSourceOut()

        editor.setWorkspaceFocus(.export)
        editor.setWorkspaceFocus(.postproduction)

        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.activeSourcePreviewState == SourcePreviewState())
        #expect(editor.mediaLibrarySession(for: .postproductionSource).sourceState(for: source.id)
            == SourcePreviewState())
    }

    @Test func workspaceRestoreDoesNotBorrowARangeThroughATimelineWorkspace() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let source = MediaAsset(
            id: "timeline-intermediary-source",
            url: URL(fileURLWithPath: "/tmp/timeline-intermediary.mov"),
            type: .video,
            name: "Timeline Intermediary",
            duration: 10,
            originalFilename: "Timeline Intermediary.mov"
        )
        editor.mediaAssets = [source]

        editor.setWorkspaceFocus(.postproduction)
        editor.selectMediaAsset(source)
        editor.setWorkspaceFocus(.production)
        editor.mediaLibrarySession(for: .postproductionSource).sourceStates[source.id] = nil
        editor.selectMediaAsset(source, for: .productionSource)
        editor.seekSourceToFrame(18)
        editor.markSourceIn()
        editor.seekSourceToFrame(72)
        editor.markSourceOut()

        editor.setWorkspaceFocus(.edit)
        #expect(editor.isTimelinePreviewActive)
        editor.setWorkspaceFocus(.postproduction)

        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.activeSourcePreviewState == SourcePreviewState())
        #expect(editor.mediaLibrarySession(for: .postproductionSource).sourceState(for: source.id)
            == SourcePreviewState())
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

    @Test func globalSourceRangeFallsBackIntoWorkspacePurpose() {
        let editor = EditorViewModel()
        editor.timeline.fps = 30
        let source = MediaAsset(
            id: "global-source",
            url: URL(fileURLWithPath: "/tmp/global-source.mov"),
            type: .video,
            name: "Global Source",
            duration: 10,
            originalFilename: "Global Source.mov"
        )
        editor.mediaAssets = [source]
        editor.selectMediaAsset(source)
        editor.seekSourceToFrame(30)
        editor.markSourceIn()
        editor.seekSourceToFrame(60)
        editor.markSourceOut()

        editor.setWorkspaceFocus(.edit)
        editor.setWorkspaceFocus(.production)

        #expect(editor.activeSourcePreviewState
            == SourcePreviewState(playheadFrame: 60, inFrame: 30, outFrame: 60))
        #expect(editor.mediaLibrarySession(for: .productionSource).sourceState(for: source.id)
            == SourcePreviewState(playheadFrame: 60, inFrame: 30, outFrame: 60))
    }

    @Test func deletingFolderNormalizesEveryPickerSession() {
        let editor = EditorViewModel()
        let folderID = editor.createFolder(name: "Temporary")
        editor.mediaLibrarySession(for: .productionSource).folderID = folderID
        editor.mediaLibrarySession(for: .generationInput("first-frame")).folderID = folderID

        editor.deleteFolders(ids: [folderID])

        #expect(editor.mediaLibrarySession(for: .productionSource).folderID == nil)
        #expect(editor.mediaLibrarySession(for: .generationInput("first-frame")).folderID == nil)
    }

    @Test func revealSelectsTheSameAssetAndPrimesItsWorkspaceLocation() {
        let editor = EditorViewModel()
        let folderID = editor.createFolder(name: "Reveal")
        let source = MediaAsset(
            id: "reveal-source",
            url: URL(fileURLWithPath: "/tmp/reveal.mov"),
            type: .video,
            name: "Reveal",
            duration: 4,
            originalFilename: "Reveal.mov"
        )
        source.folderId = folderID
        editor.mediaAssets = [source]

        editor.revealMediaAsset(id: source.id)

        let session = editor.mediaLibrarySession(for: .workspace)
        #expect(editor.workspaceFocus == .media)
        #expect(editor.activeSourceAsset?.id == source.id)
        #expect(editor.selectedMediaAssetIds == [source.id])
        #expect(editor.focusedPanel == .preview)
        #expect(editor.mediaCommandFocus == .browser)
        #expect(session.folderID == folderID)
        #expect(session.scrollAnchorID == nil)
        #expect(editor.mediaPanelRevealAssetId == source.id)
    }

    @Test func selectionDoesNotOverwriteObservedScrollPosition() {
        let editor = EditorViewModel()
        let source = MediaAsset(
            id: "scroll-independent-source",
            url: URL(fileURLWithPath: "/tmp/scroll-independent.mov"),
            type: .video,
            name: "Scroll Independent"
        )
        editor.mediaAssets = [source]
        let session = editor.mediaLibrarySession(for: .workspace)
        session.scrollAnchorID = "observed-anchor"

        editor.selectMediaAsset(source, for: .workspace)

        #expect(session.scrollAnchorID == "observed-anchor")
    }

    @Test func intentionalRootFolderDoesNotFallBackToAWorkspaceFolder() {
        let session = MediaLibrarySession(purpose: .workspace)
        session.folderID = nil

        session.initializeFolderIfNeeded("stale-workspace-folder")

        #expect(session.folderID == nil)
    }

    @Test func librarySearchFiltersDoNotImplicitlyApplyTheBrowserFolder() {
        let asset = MediaAsset(
            id: "global-search-asset",
            url: URL(fileURLWithPath: "/tmp/global-search.mov"),
            type: .video,
            name: "Interview",
            originalFilename: "Interview.mov"
        )
        asset.folderId = "another-folder"

        let matches = MediaLibraryProjection.matchesFilters(
            asset,
            query: "interview",
            searchScope: .filename,
            filterTypes: [.video],
            aiOnly: false
        )

        #expect(matches)
    }

    @Test func documentSearchUsesOriginalStringIndicesAroundUnicodeCaseMappings() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-document-search-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("İ prefix K TARGET suffix".utf8).write(to: url)

        let hits = await DocumentSearch.search(query: "target", assets: [(id: "unicode", url: url)])

        #expect(hits.count == 1)
        #expect(hits.first?.assetID == "unicode")
        #expect(hits.first?.snippet.contains("TARGET") == true)
    }

    @Test func boundedUTF8ReadDropsOnlyAnIncompleteTrailingSequence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-bounded-text-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("1234ärest".utf8).write(to: url)

        let read = try BoundedTextFileReader.readUTF8Prefix(from: url, maximumBytes: 5)

        #expect(read.text == "1234")
        #expect(read.isTruncated)
    }

    @Test func nativeGenerationDropTargetHandlesClickAndRemainsRegisteredForDrops() throws {
        let view = DropTargetNSView()
        var clickCount = 0
        view.onClick = { clickCount += 1 }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        view.mouseDown(with: event)

        #expect(clickCount == 1)
        #expect(view.registeredDraggedTypes.contains(.string))
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
