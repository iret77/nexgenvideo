import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Project reference images")
struct ProjectReferenceImageTests {
    @Test("Bible data-root paths and home-relative frame paths load the same image", arguments: ["pipeline", "_studio", ""])
    @MainActor func pathRoots(_ directory: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = directory.isEmpty ? home : home.appendingPathComponent(directory, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bible"), withIntermediateDirectories: true)
        try Data("project: fixture\nmode: musicvideo\n".utf8).write(to: root.appendingPathComponent("project.yaml"))
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        let path = "bible/front.png"
        try bytes.write(to: root.appendingPathComponent(path))
        #expect(try ProjectReferenceImageLoader.bytes(projectHome: home, path: path) == bytes)
        #expect(try ProjectReferenceImageLoader.bytes(projectHome: root, path: path) == bytes)
        if directory == "pipeline" {
            #expect(try ProjectReferenceImageLoader.bytes(projectHome: home, path: "pipeline/" + path) == bytes)
        }
        let loaded = try ProjectReferenceImageLoader.bytes(projectHome: home, path: path)
        #expect(NSImage(data: loaded) != nil)
        let replacement = Data("changed bytes".utf8)
        try replacement.write(to: root.appendingPathComponent(path))
        #expect(try ProjectReferenceImageLoader.bytes(projectHome: home, path: path) == replacement)
        #expect(NSImage(data: replacement) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        #expect(throws: (any Error).self) { try ProjectReferenceImageLoader.bytes(projectHome: home, path: path) }
    }

    @Test("References cannot escape the project through paths or links")
    func containedFilesOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = home.appendingPathComponent("pipeline", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("project: fixture\nmode: musicvideo\n".utf8).write(to: root.appendingPathComponent("project.yaml"))
        try Data("outside data root".utf8).write(to: home.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.png"), withDestinationURL: home.appendingPathComponent("outside.png"))
        for path in ["../outside.png", home.appendingPathComponent("outside.png").path, "linked.png", "missing.png"] {
            #expect(throws: (any Error).self) { try ProjectReferenceImageLoader.bytes(projectHome: home, path: path) }
        }
    }

    @Test("Reference preview preserves the film and uses the entity Inspector")
    @MainActor func selectionAndHistory() throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ngv", isDirectory: true)
        defer {
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        try Fixtures.prepareProjectPackage(at: package)
        editor.projectURL = package
        let home = try #require(editor.workingRoot)
        editor.currentFrame = 48
        editor.selectedClipIds = ["remembered"]
        let timeline = editor.timeline
        let entity = BibleEntityRef(kind: .character, id: "mouse")
        let front = ProjectReferenceImage(projectHome: home, path: "bible/front.png", name: "Mouse — front", entity: entity)
        let side = ProjectReferenceImage(projectHome: home, path: "bible/side.png", name: "Mouse — side", entity: entity)
        let assets = editor.mediaAssets.map(\.id)
        editor.openReferencePreview(front)
        #expect(editor.activePreviewTab == .referenceImage(front))
        #expect(editor.inspectedObject == .entity(entity))
        #expect(editor.activePreviewDurationFrames == 0)
        editor.openReferencePreview(side)
        editor.goBackPreviewTab()
        #expect(editor.activePreviewTab == .referenceImage(front))
        #expect(editor.inspectedObject == .entity(entity))
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        #expect(editor.currentFrame == 48)
        #expect(editor.timeline == timeline)
        #expect(editor.selectedClipIds == ["remembered"])
        #expect(editor.mediaAssets.map(\.id) == assets)
        editor.openReferencePreview(front)
        editor.closePreviewTab(id: front.id)
        #expect(!editor.previewTabs.contains { $0.id == front.id })
        let current = editor.activePreviewTab
        editor.openReferencePreview(.init(projectHome: package, path: front.path, name: front.name, entity: entity))
        #expect(editor.activePreviewTab == current)
        editor.openReferencePreview(side)
        editor.projectURL = nil
        #expect(!editor.previewTabs.contains { if case .referenceImage = $0 { true } else { false } })
        #expect(editor.activePreviewTab == .timeline)
    }
}
