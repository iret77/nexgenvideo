import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Reviewed media organization")
struct MediaOrganizationTests {
    @Test func selectionPreservesUnselectedAssetsSourcesTimelineAndOneUndoRedo() throws {
        let editor = try fixture()
        let before = editor.mediaManifest, timeline = editor.timeline
        let sourceURLs = editor.mediaAssets.map(\.url)
        let plan = try MediaOrganizationPlan.prepare([
            .init(assetID: "a", name: "Opening", folderPath: ["Shots", "Selected"]),
            .init(assetID: "b", name: "Rejected proposal", folderPath: ["Unused"])
        ], scope: .init(folderID: "scope"), editor: editor)
        #expect(editor.mediaManifest == before)
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        #expect(try plan.apply(selected: ["a"], editor: editor) == 1)
        let after = editor.mediaManifest
        #expect(editor.mediaAssets[0].name == "Opening")
        #expect(editor.folderPath(for: editor.mediaAssets[0].folderId).map(\.name) == ["Project", "Shots", "Selected"])
        #expect(editor.mediaAssets[1].name == "Second" && editor.mediaAssets[1].folderId == "scope")
        #expect(!editor.folders.contains { $0.name == "Unused" })
        #expect(editor.timeline == timeline && editor.mediaAssets.map(\.url) == sourceURLs)
        #expect(editor.mediaAssets[0].originalFilename == "Original.png")
        #expect(undo.undoActionName == "Organize Media")
        undo.undo()
        #expect(undo.redoActionName == "Organize Media")
        #expect(editor.mediaManifest == before && editor.timeline == timeline)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(undo.undoActionName == "Organize Media")
        #expect(editor.mediaManifest == after && editor.timeline == timeline)
    }

    @Test func stalePlanAndInvalidRowsCannotPartiallyMutateLibrary() throws {
        let editor = try fixture()
        let changes: [MediaOrganizationPlan.Change] = [.init(assetID: "a", name: "Opening", folderPath: ["Shots"])]
        let plan = try MediaOrganizationPlan.prepare(changes, scope: .init(folderID: "scope"), editor: editor)
        editor.mediaAssets[0].url = URL(fileURLWithPath: "/replacement.png")
        let before = editor.mediaManifest
        #expect(throws: (any Error).self) { try plan.apply(selected: ["a"], editor: editor) }
        #expect(editor.mediaManifest == before)
        #expect(throws: (any Error).self) { try plan.apply(selected: [], editor: editor) }
        #expect(throws: (any Error).self) {
            try MediaOrganizationPlan.prepare(changes + changes, scope: .init(folderID: "scope"), editor: editor)
        }
        for path in [[".."], ["/absolute"], ["nested/slash"], [" trailing "], ["bad\nfolder"]] {
            #expect(throws: (any Error).self) {
                try MediaOrganizationPlan.prepare([.init(assetID: "a", name: nil, folderPath: path)], scope: .init(folderID: "scope"), editor: editor)
            }
        }
        #expect(editor.mediaManifest == before)
    }

    @Test func folderScopeAndPersistedProposalRemainEnforced() throws {
        let editor = try fixture()
        #expect(throws: (any Error).self) {
            try MediaOrganizationPlan.prepare([.init(assetID: "outside", name: nil, folderPath: [])], scope: .init(folderID: "scope"), editor: editor)
        }
        let plan = try MediaOrganizationPlan.prepare([.init(assetID: "a", name: "Opening", folderPath: [])], scope: .init(folderID: "scope"), editor: editor)
        let restored = try JSONDecoder().decode(AgentDialog.self, from: JSONEncoder().encode(plan.dialog))
        #expect(restored.purpose == .mediaOrganization && restored.mediaOrganization == plan)
        #expect(try restored.mediaOrganization?.apply(selected: ["a"], editor: editor) == 1)
        #expect(editor.mediaAssets[0].name == "Opening" && editor.mediaAssets[0].folderId == "scope")
        editor.mediaManifest.folders += [.init(id: "x", name: "Duplicate", parentFolderId: "scope"), .init(id: "y", name: "Duplicate", parentFolderId: "scope")]
        #expect(throws: (any Error).self) {
            try MediaOrganizationPlan.prepare([.init(assetID: "a", name: nil, folderPath: ["Duplicate", "Child"])], scope: .init(folderID: "scope"), editor: editor)
        }
    }

    @Test func undoPreservesLaterUnregisteredAssetsAndTheirTimelineClips() throws {
        let editor = try fixture()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let plan = try MediaOrganizationPlan.prepare([.init(assetID: "a", name: "Opening", folderPath: ["Shots"])], scope: .init(folderID: "scope"), editor: editor)
        _ = try plan.apply(selected: ["a"], editor: editor)
        let destination = try #require(editor.mediaAssets[0].folderId)
        let later = MediaAsset(id: "later", url: URL(fileURLWithPath: "/later.mov"), type: .video, name: "Later result")
        later.folderId = destination
        editor.mediaAssets.append(later)
        editor.mediaManifest.entries.append(later.toManifestEntry(projectURL: try #require(editor.projectURL)))
        editor.timeline.tracks[0].clips.append(Fixtures.clip(id: "later-clip", mediaRef: later.id, start: 30, duration: 30))
        let timeline = editor.timeline
        undo.undo()
        #expect(editor.mediaAssets.contains { $0.id == later.id && $0.folderId == destination })
        #expect(editor.folder(id: destination) != nil && editor.timeline == timeline)
        #expect(editor.mediaAssets[0].name == "First" && editor.mediaAssets[0].folderId == "scope")
        undo.redo()
        #expect(editor.mediaAssets[0].folderId == destination && editor.mediaAssets[0].name == "Opening")
        #expect(editor.mediaAssets.contains { $0.id == later.id } && editor.timeline == timeline)
    }

    @Test func omittedFolderKeepsLocationEmptyFolderMovesToRootAndNoOpsAreOmitted() throws {
        let editor = try fixture()
        let plan = try MediaOrganizationPlan.prepare([
            .init(assetID: "a", name: "Renamed", folderPath: nil),
            .init(assetID: "b", name: nil, folderPath: nil)], scope: .init(folderID: nil), editor: editor)
        #expect(plan.rows.map(\.id) == ["a"])
        _ = try plan.apply(selected: ["a"], editor: editor)
        #expect(editor.mediaAssets[0].folderId == "scope")
        let root = try MediaOrganizationPlan.prepare([.init(assetID: "a", name: nil, folderPath: [])], scope: .init(folderID: nil), editor: editor)
        _ = try root.apply(selected: ["a"], editor: editor)
        #expect(editor.mediaAssets[0].folderId == nil)
        #expect(throws: (any Error).self) {
            try MediaOrganizationPlan.prepare([.init(assetID: "a", name: nil, folderPath: nil)], scope: .init(folderID: nil), editor: editor)
        }
    }

    @Test func sharedDestinationIsCreatedOnceExistingFoldersSurviveUndoAndProjectIdentityIsBound() throws {
        let editor = try fixture()
        let undo = UndoManager(); undo.groupsByEvent = false; editor.undoManager = undo
        let plan = try MediaOrganizationPlan.prepare([
            .init(assetID: "a", name: nil, folderPath: ["Shared"]),
            .init(assetID: "b", name: nil, folderPath: ["Shared"])], scope: .init(folderID: "scope"), editor: editor)
        _ = try plan.apply(selected: ["a", "b"], editor: editor)
        #expect(editor.folders.filter { $0.name == "Shared" }.count == 1)
        undo.undo()
        #expect(editor.folders.map(\.id) == ["scope"])
        let foreign = try fixture()
        #expect(throws: (any Error).self) { try plan.apply(selected: ["a"], editor: foreign) }
    }

    @Test func legacyDisplayFallbackStaysConsistentAndDecisionSurvivesSessionReload() throws {
        let editor = try fixture()
        editor.mediaAssets[0].name = String(repeating: "a", count: 64) + ".png"
        let plan = try MediaOrganizationPlan.prepare([.init(assetID: "a", name: nil, folderPath: ["Shots"])], scope: .init(folderID: "scope"), editor: editor)
        #expect(plan.rows[0].before == "Project / Original.png")
        #expect(plan.rows[0].after == "Project / Shots / Original.png")
        let home = try #require(editor.projectURL)
        let id = UUID()
        for origin in [ToolCallOrigin.inAppChat(sessionID: id), .embeddedRuntime(chatSessionID: id, runtimeGenerationID: UUID())] {
            var session = ChatSession(id: id)
            session.decision = .init(dialog: plan.dialog, origin: origin, draft: AgentDialogDraft(), selections: ["organization": ["a"]])
            let chat = home.appendingPathComponent(ChatSessionStore.dirName)
            try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
            try #require(ChatSessionStore.encodeSession(session)).write(to: chat.appendingPathComponent(id.uuidString + ".json"))
            let service = AgentService(refreshBackendStatusOnInit: false)
            service.loadSessions(from: home)
            #expect(service.pendingDialog?.mediaOrganization == plan)
            #expect(service.dialogChoiceSelections["organization"] == ["a"])
            #expect(!service.isStreaming)
        }
    }

    private func fixture() throws -> EditorViewModel {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("organize-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel(); editor.projectURL = package
        editor.mediaManifest.folders = [.init(id: "scope", name: "Project")]
        let assets = [
            MediaAsset(id: "a", url: package.appendingPathComponent("a.png"), type: .image, name: "First", originalFilename: "Original.png"),
            MediaAsset(id: "b", url: package.appendingPathComponent("b.png"), type: .image, name: "Second"),
            MediaAsset(id: "outside", url: package.appendingPathComponent("outside.png"), type: .image, name: "Outside")]
        assets[0].folderId = "scope"; assets[1].folderId = "scope"
        editor.mediaAssets = assets
        editor.mediaManifest.entries = assets.map { $0.toManifestEntry(projectURL: package) }
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "used", mediaRef: "a", start: 0, duration: 30)])])
        return editor
    }
}
