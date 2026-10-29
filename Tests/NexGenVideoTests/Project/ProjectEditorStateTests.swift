import Foundation
import Testing
@testable import NexGenVideo

@Suite("Project editor state")
struct ProjectEditorStateTests {
    @Test func heightIsPortableWithoutChangingFilmBytes() throws {
        var timeline = Timeline()
        timeline.tracks = [Track(id: "picture", type: .video), Track(id: "sound", type: .audio)]
        let canonical = try PipelineAssemblyStore.canonical(timeline)
        let originalHash = try ExportArtwork.timelineHash(timeline)
        timeline.tracks[0].displayHeight = AppTheme.Timeline.trackMaxHeight
        timeline.tracks[1].displayHeight = AppTheme.Timeline.trackMinHeight
        let data = try ProjectEditorState.capture(timeline)
        #expect(try PipelineAssemblyStore.canonical(timeline) == canonical)
        #expect(try ExportArtwork.timelineHash(timeline) == originalHash)
        let decoded = try JSONDecoder().decode(Timeline.self, from: canonical)
        #expect(ProjectEditorState.restoring(data, to: decoded) == timeline)
        var replacement = decoded
        replacement.tracks[0].id = "replacement"
        let restored = ProjectEditorState.restoring(data, to: replacement)
        #expect(restored.tracks[0].displayHeight == AppTheme.Layout.trackHeight)
        #expect(restored.tracks[1].displayHeight == AppTheme.Timeline.trackMinHeight)
    }

    @Test func missingCorruptUnknownAndInvalidHeightsUseLegacyDefault() throws {
        var timeline = Timeline(); timeline.tracks = [Track(id: "picture", type: .video), Track(id: "sound", type: .audio)]
        let cases: [Data?] = [nil, Data("broken".utf8), Data(#"{"schema":2,"trackHeights":{"picture":100}}"#.utf8)]
        for data in cases {
            #expect(ProjectEditorState.restoring(data, to: timeline) == timeline)
        }
        for invalid in ["null", "true", "\"80\"", "-1", "1e99"] {
            let data = Data("{\"schema\":1,\"trackHeights\":{\"picture\":\(invalid),\"sound\":80}}".utf8)
            let restored = ProjectEditorState.restoring(data, to: timeline)
            #expect(restored.tracks[0].displayHeight == AppTheme.Layout.trackHeight)
            #expect(restored.tracks[1].displayHeight == 80)
        }
        timeline.tracks[0].displayHeight = .infinity
        let restored = ProjectEditorState.restoring(try ProjectEditorState.capture(timeline), to: timeline)
        #expect(restored.tracks[0].displayHeight == AppTheme.Layout.trackHeight)
    }

    @Test @MainActor func recoverySaveAsAndReopenKeepHeightAndSourcePackage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Original.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let document = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
        document.makeWindowControllers()
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = document.editorViewModel
        editor.timeline.tracks = [Track(id: "picture", type: .video)]
        editor.setTrackHeight(trackIndex: 0, height: AppTheme.Timeline.trackMaxHeight)
        try document.checkpointForProductionUpgrade()
        let home = try #require(editor.workingRoot)
        let encoded = try Data(contentsOf: home.appendingPathComponent(Project.timelineFilename))
        let canonical = try JSONDecoder().decode(Timeline.self, from: encoded)
        #expect(canonical.tracks[0].displayHeight == AppTheme.Layout.trackHeight)
        #expect(ProjectEditorState.restoring(ProjectEditorState.read(in: home), to: canonical) == editor.timeline)
        let saved = directory.appendingPathComponent("Copy.ngv")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: saved, ofType: VideoProject.typeIdentifier, for: .saveToOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #expect(ProjectIdentity.existingUUID(for: saved) != ProjectIdentity.existingUUID(for: package))
        #expect(ProjectEditorState.read(in: package) == nil)
        let copy = try await VideoProject.load(from: saved, agentService: AgentService(refreshBackendStatusOnInit: false))
        copy.makeWindowControllers(); defer { copy.close() }
        #expect(copy.editorViewModel.timeline == editor.timeline)
        #expect(try ExportArtwork.timelineHash(copy.editorViewModel.timeline) == ExportArtwork.timelineHash(canonical))
    }

    @Test func actualRecoveryCarriesLayoutWithoutTouchingSavedPackage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Recover.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let key = try ProjectIdentity.key(for: package)
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: directory) }
        _ = try ProjectWorkingCopy.open(key: key, packageURL: package)
        var timeline = Timeline(); timeline.tracks = [Track(id: "picture", type: .video)]
        timeline.tracks[0].displayHeight = AppTheme.Timeline.trackMaxHeight
        try ProjectWorkingCopy.checkpoint(key: key, snapshot: .init(timeline: JSONEncoder().encode(timeline),
            manifest: JSONEncoder().encode(MediaManifest()), generationLog: JSONEncoder().encode(GenerationLog()),
            thumbnail: nil, chatSessionFiles: [], editorState: ProjectEditorState.capture(timeline)))
        let recovered = try ProjectWorkingCopy.open(key: key, packageURL: package)
        #expect(recovered.recoveredUnsaved)
        let canonical = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: recovered.home.appendingPathComponent(Project.timelineFilename)))
        #expect(ProjectEditorState.restoring(ProjectEditorState.read(in: recovered.home), to: canonical) == timeline)
        #expect(ProjectEditorState.read(in: package) == nil)
    }

    @Test func packageExportUsesCurrentLayoutInsteadOfCopiedOldState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("Source.ngv")
        try Fixtures.prepareProjectPackage(at: source)
        defer { try? FileManager.default.removeItem(at: directory) }
        var timeline = Timeline(); timeline.tracks = [Track(id: "picture", type: .video)]
        try ProjectEditorState.capture(timeline).write(to: source.appendingPathComponent(ProjectEditorState.filename))
        timeline.tracks[0].displayHeight = AppTheme.Timeline.trackMaxHeight
        let destination = directory.appendingPathComponent("Export.ngv")
        try ProjectPackageExporter.export(timeline: timeline, manifest: MediaManifest(), generationLog: GenerationLog(),
            sourceProjectURL: source, to: destination)
        let canonical = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: destination.appendingPathComponent(Project.timelineFilename)))
        #expect(ProjectEditorState.restoring(ProjectEditorState.read(in: destination), to: canonical) == timeline)
        #expect(canonical.tracks[0].displayHeight == AppTheme.Layout.trackHeight)
        #expect(ProjectEditorState.restoring(ProjectEditorState.read(in: source), to: canonical).tracks[0].displayHeight == AppTheme.Layout.trackHeight)
    }

    @Test func editorStateDoesNotReadASymlinkTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Project.ngv")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appendingPathComponent("external.json")
        try Data(#"{"schema":1,"trackHeights":{"picture":100}}"#.utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent(ProjectEditorState.filename), withDestinationURL: external)
        #expect(ProjectEditorState.read(in: package) == nil)
    }
}
