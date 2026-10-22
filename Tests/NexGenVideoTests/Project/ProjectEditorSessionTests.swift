import AppKit
import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Project editor session initialization", .serialized)
struct ProjectEditorSessionTests {
    @Test("Both presentations adopt saved state and install the real document callbacks",
        arguments: [VideoProject.SessionPresentation.nativeWindow, .editorSession])
    func sessionRetainsLoadedState(presentation: VideoProject.SessionPresentation) async throws {
        _ = NSApplication.shared
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("editor-session-\(UUID().uuidString).ngv")
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(id: "saved-picture")])
        timeline.width = 2048
        try Fixtures.prepareProjectPackage(at: package, timeline: timeline)
        defer { try? FileManager.default.removeItem(at: package) }
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "missing-source", name: "Original image.png", type: .image,
            source: .project(relativePath: "media/missing-image.png"), duration: 1)]
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(Project.manifestFilename))
        var log = GenerationLog()
        log.spendEvents = [
            .init(transactionId: "retained-settlement", kind: .reserved, model: "fixture",
                provider: .fal, transport: .api, endpoint: "fixture"),
            .init(transactionId: "retained-settlement", kind: .submitted, model: "fixture",
                provider: .fal, transport: .api, endpoint: "fixture",
                providerRequestId: "finished-fixture", providerRequestResumable: false),
            .init(transactionId: "retained-settlement", kind: .settled, model: "fixture",
                provider: .fal, transport: .api, endpoint: "fixture"),
        ]
        log.stampVersion()
        let savedLog = try JSONEncoder().encode(log)
        try savedLog.write(to: package.appendingPathComponent(Project.generationLogFilename))
        let expectedKey = try ProjectIdentity.key(for: package)
        let sourcePaths = [Project.timelineFilename, Project.manifestFilename,
            Project.generationLogFilename, ProjectPluginSettings.filename]
        let savedSource = try sourcePaths.map { try Data(contentsOf: package.appendingPathComponent($0)) }
        let editorState = package.appendingPathComponent(ProjectEditorState.filename)
        #expect(!FileManager.default.fileExists(atPath: editorState.path))
        let document = try await VideoProject.load(from: package,
            agentService: AgentService(refreshBackendStatusOnInit: false), configureEditor: { editor in
                editor.generationBatchCoordinator.catalogReadiness = { Issue.record("Session restoration requested the live model catalog.") }
                editor.generationService.reconciliation = .init(providerKey: { _ in
                    Issue.record("Session restoration requested a provider key.")
                    return nil
                }, falCharge: { _, _, _ in
                    Issue.record("Session restoration requested provider billing.")
                    return nil
                })
            })
        defer { document.close() }
        if presentation == .nativeWindow { document.makeWindowControllers() }
        else { document.prepareEditorSession(presentation: .editorSession) }
        let editor = document.editorViewModel
        let restoration = try #require(document.generationRestorationTask)
        await restoration.value
        #expect(editor.generationBatchCoordinator.error == nil)
        let home = try #require(editor.workingRoot)
        #expect(document.windowControllers.count == (presentation == .nativeWindow ? 1 : 0))
        #expect(editor.timeline == timeline)
        #expect(editor.mediaManifest == manifest)
        #expect(editor.mediaAssets.map(\.id) == ["missing-source"])
        #expect(editor.missingMediaRefs == ["missing-source"])
        #expect(editor.generationLog == log)
        #expect(editor.projectId == ProjectIdentity.existingUUID(for: package))
        #expect(editor.openWorkingCopyKey == expectedKey)
        #expect(editor.openWorkingCopyGeneration != nil && home != package)
        #expect(!editor.recoveredUnsavedWork)
        #expect(editor.undoManager === document.undoManager)
        #expect(editor.onWorkingCopyReset != nil && editor.onPipelineChanged != nil)
        #expect(editor.agentService.onSessionsChanged != nil && editor.agentService.onDraftChanged != nil)
        document.updateChangeCount(.changeCleared)
        #expect(!document.isDocumentEdited && !editor.isDocumentEdited)
        editor.onPipelineChanged?()
        #expect(document.isDocumentEdited && editor.isDocumentEdited)
        let currentSource = try sourcePaths.map { try Data(contentsOf: package.appendingPathComponent($0)) }
        #expect(currentSource == savedSource)
        #expect(!FileManager.default.fileExists(atPath: editorState.path))
    }
}
