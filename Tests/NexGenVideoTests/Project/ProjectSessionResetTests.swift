import AppKit
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Project session resets")
@MainActor
struct ProjectSessionResetTests {
    @Test("A same-identity move retains the recovery decision and current drafts")
    func recoveredRename() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try ProjectWorkingCopy.open(key: fixture.key, packageURL: fixture.package)
        try ProjectWorkingCopy.markDirty(key: fixture.key)
        let editor = EditorViewModel()
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let generation = try #require(editor.openWorkingCopyGeneration)
        #expect(editor.recoveredUnsavedWork)
        let drafts = editor.storyPanelDrafts
        drafts.briefDraft = "Recovery decision is still pending"
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(id: "v", clips: [Fixtures.clip(id: "same-clip", mediaRef: "source", start: 0, duration: 30)])])
        editor.markPendingReplacement(clipId: "same-clip")
        let moved = fixture.root.appendingPathComponent("Moved.ngv")
        try FileManager.default.moveItem(at: fixture.package, to: moved)

        editor.projectURL = moved
        #expect(editor.workingRoot == first.home)
        #expect(editor.openWorkingCopyGeneration == generation)
        #expect(editor.recoveredUnsavedWork)
        #expect(editor.storyPanelDrafts === drafts)
        #expect(editor.pendingReplacements == ["same-clip"])
    }

    @Test("A new generation resets drafts, production selections and review acknowledgements")
    func freshGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = EditorViewModel()
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let oldGeneration = editor.openWorkingCopyGeneration
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(id: "v", clips: [Fixtures.clip(id: "same-clip", mediaRef: "source", start: 0, duration: 30)])])
        let snapshot = GenerationClipReplacement.Snapshot(clipID: "same-clip", resetTrim: false, editor: editor)
        let request = GenerationRequest(modality: .upscale, modelId: "callback-fixture", intent: "",
            placement: .replaceClip(id: "same-clip", resetTrim: false), origin: .panel,
            submission: .upscale { _, _, _, _, _, _ in "not-executed" })
        let oldFailure = try #require(GenerationController.failureHandler(request, editor: editor, snapshot: snapshot, then: nil))
        let oldCompletion = try #require(GenerationController.replacementOnComplete(request, editor: editor, snapshot: snapshot, then: nil))
        editor.markPendingReplacement(clipId: "same-clip")
        let story = editor.storyPanelDrafts
        let review = editor.renderReviewDraft
        story.briefDraft = "Previous generation"
        review.note = "Previous review"
        editor.productionSelectedPhase = "render_review"
        editor.cockpitPackSurfaceID = "old-pack-surface"
        editor.acknowledgedReviewRequests = ["old-review"]
        let reopened = try ProjectWorkingCopy.open(key: fixture.key, packageURL: fixture.package)

        editor.adoptWorkingCopy(reopened, key: fixture.key, packageURL: fixture.package)
        #expect(editor.openWorkingCopyGeneration != oldGeneration)
        #expect(editor.storyPanelDrafts !== story)
        #expect(editor.renderReviewDraft !== review)
        #expect(editor.storyPanelDrafts.briefDraft.isEmpty && editor.renderReviewDraft.note.isEmpty)
        #expect(editor.productionSelectedPhase == nil && editor.cockpitPackSurfaceID == nil)
        #expect(editor.acknowledgedReviewRequests.isEmpty)
        #expect(editor.pendingReplacements.isEmpty)
        editor.markPendingReplacement(clipId: "same-clip")
        let currentTimeline = editor.timeline
        oldFailure()
        oldCompletion(MediaAsset(id: "old-result", url: fixture.root.appendingPathComponent("unused.mov"),
            type: .video, name: "Old callback fixture", duration: 1))
        #expect(editor.pendingReplacements == ["same-clip"])
        #expect(editor.timeline == currentTimeline)
        editor.releaseWorkingCopy()
        #expect(editor.pendingReplacements.isEmpty)
    }

    @Test("Discard reload cannot publish an old read into a new generation at the same home")
    func staleReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = VideoProject()
        let editor = document.editorViewModel
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let replacement = try ProjectWorkingCopy.open(key: fixture.key, packageURL: fixture.package)
        let accepted = await document.reloadEditableContents(from: home, beforeApply: {
            editor.adoptWorkingCopy(replacement, key: fixture.key, packageURL: fixture.package)
            editor.timeline.width = 2048
        })
        #expect(!accepted)
        #expect(editor.workingRoot == home && editor.openWorkingCopyGeneration == replacement.generation)
        #expect(editor.timeline.width == 2048)
    }

    @Test("Prepared discard rejects a newer disk claim without replacing its bytes", arguments: [false, true])
    func staleDiscard(adoptInSameEditor: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = EditorViewModel()
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let generation = editor.openWorkingCopyGeneration
        let marker = home.appendingPathComponent("new-generation.txt")
        let bytes = Data("New owner's bytes must survive".utf8)
        let pendingTask = editor.discardRecoveredWork(beforeInstall: {
            let replacement = try ProjectWorkingCopy.open(key: fixture.key, packageURL: fixture.package)
            try bytes.write(to: marker)
            if adoptInSameEditor { editor.adoptWorkingCopy(replacement, key: fixture.key, packageURL: fixture.package) }
        })
        let task = try #require(pendingTask)
        await task.value
        #expect(try Data(contentsOf: marker) == bytes)
        #expect((editor.openWorkingCopyGeneration != generation) == adoptInSameEditor)
        #expect(!editor.pipelinePhaseRunCoordinator.hasRunningJobs)
        #expect(try fixture.stagingCopies().isEmpty)
    }

    @Test("Current discard restores actual saved bytes, reloads them and cleans its old home")
    func currentDiscard() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = VideoProject()
        let editor = document.editorViewModel
        editor.projectURL = fixture.package
        defer { editor.onWorkingCopyReset = nil; editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let generation = try #require(editor.openWorkingCopyGeneration)
        let saved = try Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename))
        editor.timeline.width = 2048
        let changed = try JSONEncoder().encode(editor.timeline)
        try changed.write(to: home.appendingPathComponent(Project.timelineFilename))
        try ProjectWorkingCopy.markDirty(key: fixture.key)
        editor.storyPanelDrafts.briefDraft = "Unsaved draft"
        editor.onWorkingCopyReset = { await document.reloadEditableContents(from: $0) }

        let task = try #require(editor.discardRecoveredWork())
        await task.value
        #expect(editor.timeline.width == 1280)
        #expect(editor.openWorkingCopyGeneration != generation)
        #expect(editor.storyPanelDrafts.briefDraft.isEmpty)
        #expect(try Data(contentsOf: home.appendingPathComponent(Project.timelineFilename)) == saved)
        #expect(try Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename)) == saved)
        #expect(!editor.pipelinePhaseRunCoordinator.hasRunningJobs)
        #expect(try fixture.stagingCopies().isEmpty)
        #expect(!ProjectWorkingCopy.discard(key: fixture.key, ifGeneration: generation))
    }

    @Test("Cancellation after the saved copy is prepared preserves the current unsaved bytes")
    func cancelledDiscard() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = EditorViewModel()
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let generation = editor.openWorkingCopyGeneration
        let marker = home.appendingPathComponent("unsaved.txt")
        let bytes = Data("Keep this unsaved work".utf8)
        try bytes.write(to: marker)
        let pendingTask = editor.discardRecoveredWork(beforeInstall: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = try #require(pendingTask)
        await task.value
        #expect(try Data(contentsOf: marker) == bytes)
        #expect(editor.openWorkingCopyGeneration == generation)
        #expect(!editor.pipelinePhaseRunCoordinator.hasRunningJobs)
        #expect(try fixture.stagingCopies().isEmpty)
    }

    @Test("A recovery discard cannot start inside another project mutation")
    func busyDiscard() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = EditorViewModel()
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let bytes = try Data(contentsOf: home.appendingPathComponent(Project.timelineFilename))
        let lease = try #require(editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: home, label: "Other action"))
        #expect(editor.discardRecoveredWork() == nil)
        #expect(editor.recoveredUnsavedWork)
        #expect(editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: home, id: lease))
        #expect(try Data(contentsOf: home.appendingPathComponent(Project.timelineFilename)) == bytes)
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: home, id: lease)
    }

    @Test("An unreadable saved timeline cannot replace the recoverable working copy")
    func invalidSavedCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = EditorViewModel()
        editor.projectURL = fixture.package
        defer { editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let generation = editor.openWorkingCopyGeneration
        let timelineURL = home.appendingPathComponent(Project.timelineFilename)
        let bytes = try Data(contentsOf: timelineURL)
        try Data("invalid timeline".utf8).write(to: fixture.package.appendingPathComponent(Project.timelineFilename))
        let task = try #require(editor.discardRecoveredWork())
        await task.value
        #expect(try Data(contentsOf: timelineURL) == bytes)
        #expect(editor.openWorkingCopyGeneration == generation)
        #expect(editor.recoveredUnsavedWork && editor.mediaPanelToast != nil)
        #expect(!editor.pipelinePhaseRunCoordinator.hasRunningJobs)
        #expect(try fixture.stagingCopies().isEmpty)
    }

    @Test("Discard prevents checkpoint, Save and direct write until the real reload applies")
    func discardBlocksOldEditorWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = VideoProject()
        let editor = document.editorViewModel
        editor.projectURL = fixture.package
        defer { editor.onWorkingCopyReset = nil; editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let saved = try Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename))
        editor.timeline.width = 2048
        var checked = false
        editor.onWorkingCopyReset = { home in
            checked = true
            #expect(editor.needsSavedProjectReload)
            #expect(throws: (any Error).self) { try document.checkpointForProductionUpgrade() }
            #expect(throws: (any Error).self) { try document.write(to: fixture.package, ofType: VideoProject.typeIdentifier) }
            let saveError: Error? = await withCheckedContinuation { continuation in
                document.save(to: fixture.package, ofType: VideoProject.typeIdentifier, for: .saveOperation) {
                    continuation.resume(returning: $0)
                }
            }
            #expect(saveError?.localizedDescription.contains("reloading before saving") == true)
            #expect((try? Data(contentsOf: home.appendingPathComponent(Project.timelineFilename))) == saved)
            #expect((try? Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename))) == saved)
            return await document.reloadEditableContents(from: home)
        }
        let task = try #require(editor.discardRecoveredWork())
        await task.value
        #expect(checked && editor.timeline.width == 1280)
        #expect(editor.workingCopyWriteBlockReason == nil)
        let lease = try #require(editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: home, label: "Owned migration checkpoint"))
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: home, id: lease) }
        try document.checkpointForProductionUpgrade()
        #expect(try JSONDecoder().decode(Timeline.self,
            from: Data(contentsOf: home.appendingPathComponent(Project.timelineFilename))).width == 1280)
        #expect(try Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename)) == saved)
    }

    @Test("The actual delayed chat checkpoint cannot write into a newly claimed generation")
    func oldDraftCheckpointCannotWriteNewGeneration() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = try await VideoProject.load(from: fixture.package)
        document.makeWindowControllers()
        defer { document.close() }
        await document.generationRestorationTask?.value
        let editor = document.editorViewModel
        editor.timeline.width = 2048
        let callback = try #require(editor.agentService.onDraftChanged)
        callback()
        let pending = try #require(document.draftCheckpointTask)
        let reopened = try ProjectWorkingCopy.open(key: fixture.key, packageURL: fixture.package)
        editor.adoptWorkingCopy(reopened, key: fixture.key, packageURL: fixture.package)
        let timelineURL = reopened.home.appendingPathComponent(Project.timelineFilename)
        let restored = try Data(contentsOf: timelineURL)
        await pending.value
        #expect(editor.openWorkingCopyGeneration == reopened.generation)
        #expect(try Data(contentsOf: timelineURL) == restored)
        #expect(editor.timeline.width == 2048)
    }

    @Test("A real reload failure keeps saved bytes protected until an explicit retry succeeds")
    func failedDiscardReloadCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = VideoProject()
        let editor = document.editorViewModel
        let manager = UndoManager()
        editor.undoManager = manager
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let controller = EditorWindowController(editorViewModel: editor, window: window)
        #expect(controller.windowWillReturnUndoManager(window) === manager)
        #expect(!editor.isProjectEditingPaused)
        editor.projectURL = fixture.package
        defer { editor.onWorkingCopyReset = nil; editor.releaseWorkingCopy() }
        let home = try #require(editor.workingRoot)
        let saved = try Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename))
        editor.timeline.width = 2048
        var attempts = 0
        editor.onWorkingCopyReset = { home in
            attempts += 1
            #expect(editor.recoveryDiscardInProgress && editor.isProjectEditingPaused)
            if attempts == 1 {
                try? Data("unreadable reload fixture".utf8).write(to: home.appendingPathComponent(Project.timelineFilename))
            }
            return await document.reloadEditableContents(from: home)
        }
        let first = try #require(editor.discardRecoveredWork())
        await first.value
        #expect(attempts == 1 && editor.needsSavedProjectReload && editor.recoveredUnsavedWork)
        #expect(!editor.recoveryDiscardInProgress && editor.isProjectEditingPaused)
        #expect(controller.windowWillReturnUndoManager(window) == nil)
        #expect(editor.timeline.width == 2048 && editor.mediaPanelToast != nil)
        #expect(throws: (any Error).self) { try document.checkpointForProductionUpgrade() }
        #expect(throws: (any Error).self) { try document.write(to: fixture.package, ofType: VideoProject.typeIdentifier) }
        editor.keepRecoveredWork()
        #expect(editor.needsSavedProjectReload && editor.recoveredUnsavedWork)
        #expect(try Data(contentsOf: fixture.package.appendingPathComponent(Project.timelineFilename)) == saved)
        editor.recoveredUnsavedWork = false
        #expect(editor.isProjectEditingPaused && editor.needsSavedProjectReload)
        #expect(controller.windowWillReturnUndoManager(window) == nil)
        let retry = try #require(editor.discardRecoveredWork())
        await retry.value
        #expect(attempts == 2 && editor.timeline.width == 1280)
        #expect(!editor.needsSavedProjectReload && !editor.recoveredUnsavedWork)
        #expect(editor.workingCopyWriteBlockReason == nil)
        #expect(!editor.isProjectEditingPaused && !editor.recoveryDiscardInProgress)
        #expect(controller.windowWillReturnUndoManager(window) === manager)
        #expect(try Data(contentsOf: home.appendingPathComponent(Project.timelineFilename)) == saved)
        #expect(try fixture.stagingCopies().isEmpty)
    }

    private struct Fixture: Sendable {
        let root: URL
        let package: URL
        let key: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            package = root.appendingPathComponent("Session.ngv")
            try FileManager.default.createDirectory(at: package.appendingPathComponent(Project.mediaDirectoryName),
                withIntermediateDirectories: true)
            var timeline = Timeline()
            timeline.width = 1280
            try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
            try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
            try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
            try ProjectPluginSettings.setActivePlugin(nil as String?, projectURL: package)
            key = try ProjectIdentity.key(for: package)
        }

        func stagingCopies() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: AppPaths.recovery, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".materialize-\(key)-") }
        }

        func remove() {
            ProjectWorkingCopy.discard(key: key)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
