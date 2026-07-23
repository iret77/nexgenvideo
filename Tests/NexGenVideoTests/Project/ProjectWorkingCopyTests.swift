import Foundation
import Testing
import NexGenEngine
import MusicvideoPlugin

@testable import NexGenVideo

@MainActor
@Suite("ProjectWorkingCopy")
struct ProjectWorkingCopyTests {
    private func tempPackage(
        pipelineName: String? = DataRootResolver.pipelineDirname
    ) throws -> URL {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-wc-\(UUID().uuidString).ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try JSONEncoder().encode(Timeline()).write(
            to: pkg.appendingPathComponent(Project.timelineFilename)
        )
        try JSONEncoder().encode(MediaManifest()).write(
            to: pkg.appendingPathComponent(Project.manifestFilename)
        )
        try JSONEncoder().encode(GenerationLog()).write(
            to: pkg.appendingPathComponent(Project.generationLogFilename)
        )
        let media = pkg.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("saved-media".utf8).write(to: media.appendingPathComponent("saved.mov"))
        let chat = pkg.appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try Data("{\"saved\":true}".utf8).write(to: chat.appendingPathComponent("saved.json"))
        if let pipelineName {
            let pipeline = pkg.appendingPathComponent(pipelineName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: pipeline,
                withIntermediateDirectories: true
            )
            try "project: demo\nmode: beat\n".write(
                to: pipeline.appendingPathComponent("project.yaml"),
                atomically: true,
                encoding: .utf8
            )
            try "hello".write(
                to: pipeline.appendingPathComponent("bible.yaml"),
                atomically: true,
                encoding: .utf8
            )
        }
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: pkg)
        _ = try ProjectIdentity.uuid(for: pkg)
        return pkg
    }

    private func uniqueKey() -> String { "test-\(UUID().uuidString)" }

    @Test("open with no working copy materializes from the package (no recovery)")
    func materializesFresh() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let result = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        #expect(result.recoveredUnsaved == false)
        let copied = result.home.appendingPathComponent(DataRootResolver.pipelineDirname)
            .appendingPathComponent("bible.yaml")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(
            atPath: result.home.appendingPathComponent(Project.timelineFilename).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.home.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent("saved.mov").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.home.appendingPathComponent(ChatSessionStore.dirName)
                .appendingPathComponent("saved.json").path
        ))
    }

    @Test("a surviving working copy is reported as recovered unsaved work")
    func detectsCrashCopy() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        _ = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        try ProjectWorkingCopy.markDirty(key: key)
        let second = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        #expect(second.recoveredUnsaved == true)
    }

    @Test("a working copy missing the completion sentinel is rebuilt, not recovered")
    func partialCopyNotRecovered() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let home = try ProjectWorkingCopy.materialize(key: key, packageURL: pkg)
        // Simulate a partial/old copy: valid project.yaml present, but no completion sentinel.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".ngv-materialized"))
        let result = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        #expect(result.recoveredUnsaved == false)
    }

    @Test("legacy _studio in the package is materialized into pipeline")
    func materializesLegacy() throws {
        let pkg = try tempPackage(pipelineName: DataRootResolver.legacyPipelineDirname)
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let result = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        let copied = result.home.appendingPathComponent(DataRootResolver.pipelineDirname)
            .appendingPathComponent("project.yaml")
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    @Test("persist syncs the working copy into the package and retires legacy _studio")
    func persistRoundTrip() throws {
        let pkg = try tempPackage(pipelineName: DataRootResolver.legacyPipelineDirname)
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let home = try ProjectWorkingCopy.materialize(key: key, packageURL: pkg)
        // Edit the working copy, then persist.
        try "edited".write(
            to: home.appendingPathComponent(DataRootResolver.pipelineDirname).appendingPathComponent("bible.yaml"),
            atomically: true, encoding: .utf8)
        try ProjectWorkingCopy.persist(key: key, to: pkg)

        let persisted = pkg.appendingPathComponent(DataRootResolver.pipelineDirname)
            .appendingPathComponent("bible.yaml")
        #expect((try? String(contentsOf: persisted, encoding: .utf8)) == "edited")
        // The legacy dir is gone; the project carries only `pipeline/`.
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(DataRootResolver.legacyPipelineDirname).path))
    }

    @Test("materialize mirrors ngv.json so the pack + its analysis gate load in-session")
    func materializeMirrorsActivePackForRuntime() throws {
        PackCatalog.register(MusicvideoPack())
        let pkg = try tempPackage()
        // The active pack lives in the PACKAGE's ngv.json (app metadata, sibling of pipeline/).
        try ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: pkg)
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let home = try ProjectWorkingCopy.materialize(key: key, packageURL: pkg)

        // The runtime resolves the pack from the WORKING COPY (cockpit, gate enforcement, run_phase).
        // Before the mirror this returned nil → the pack silently never loaded in a session, disabling
        // the analysis DSP runner and its hard gate — letting the agent improvise the analysis.
        #expect(ProjectPluginSettings.activePlugin(projectURL: home) == "musicvideo")
        // …and the resolved pack actually wires the hard analysis gate that forces measured analysis.
        #expect(PackCatalog.registry(activePack: "musicvideo").gateRequirements["analysis"] != nil)
    }

    @Test("checkpoint keeps the saved package untouched and recovers every editable tier")
    func checkpointRecoversFullWorkingState() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let savedTimeline = try Data(
            contentsOf: pkg.appendingPathComponent(Project.timelineFilename)
        )
        let home = try ProjectWorkingCopy.open(key: key, packageURL: pkg).home
        var editedTimeline = Timeline()
        editedTimeline.width = 4096
        let editedData = try JSONEncoder().encode(editedTimeline)
        let unsavedMedia = home.appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("unsaved.mov")
        try Data("unsaved-media".utf8).write(to: unsavedMedia)

        try ProjectWorkingCopy.checkpoint(
            key: key,
            snapshot: .init(
                timeline: editedData,
                manifest: try JSONEncoder().encode(MediaManifest()),
                generationLog: try JSONEncoder().encode(GenerationLog()),
                thumbnail: Data("thumbnail".utf8),
                chatSessionFiles: [("unsaved.json", Data("{\"unsaved\":true}".utf8))]
            )
        )

        #expect(try Data(
            contentsOf: pkg.appendingPathComponent(Project.timelineFilename)
        ) == savedTimeline)
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent("unsaved.mov").path
        ))

        let recovered = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        #expect(recovered.recoveredUnsaved)
        #expect(try JSONDecoder().decode(
            Timeline.self,
            from: Data(contentsOf: recovered.home.appendingPathComponent(Project.timelineFilename))
        ).width == 4096)
        #expect(FileManager.default.fileExists(atPath: unsavedMedia.path))
        #expect(FileManager.default.fileExists(
            atPath: recovered.home.appendingPathComponent(ChatSessionStore.dirName)
                .appendingPathComponent("unsaved.json").path
        ))
        #expect(try Data(
            contentsOf: recovered.home.appendingPathComponent(Project.thumbnailFilename)
        ) == Data("thumbnail".utf8))
    }

    @Test("checkpoint marks recovery dirty before a later component write can fail")
    func failedCheckpointRemainsRecoverable() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        _ = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        var editedTimeline = Timeline()
        editedTimeline.width = 3000

        #expect(throws: (any Error).self) {
            try ProjectWorkingCopy.checkpoint(
                key: key,
                snapshot: .init(
                    timeline: try JSONEncoder().encode(editedTimeline),
                    manifest: try JSONEncoder().encode(MediaManifest()),
                    generationLog: try JSONEncoder().encode(GenerationLog()),
                    thumbnail: nil,
                    chatSessionFiles: [("missing-parent/session.json", Data())]
                )
            )
        }

        let recovered = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        #expect(recovered.recoveredUnsaved)
        #expect(try JSONDecoder().decode(
            Timeline.self,
            from: Data(contentsOf: recovered.home.appendingPathComponent(Project.timelineFilename))
        ).width == 3000)
    }

    @Test("persist replaces the package with the complete working state and no recovery metadata")
    func persistFullWorkingState() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let home = try ProjectWorkingCopy.open(key: key, packageURL: pkg).home
        let unsavedMedia = home.appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("new.mov")
        try Data("new-media".utf8).write(to: unsavedMedia)
        try Data("partial".utf8).write(
            to: home.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent(".import-crashed.partial")
        )
        let songSwap = home.appendingPathComponent(DataRootResolver.pipelineDirname)
            .appendingPathComponent(".song-crashed.partial", isDirectory: true)
        try FileManager.default.createDirectory(
            at: songSwap,
            withIntermediateDirectories: true
        )
        try Data("partial-song".utf8).write(
            to: songSwap.appendingPathComponent("replacement.wav")
        )
        try ProjectWorkingCopy.markDirty(key: key)
        try ProjectWorkingCopy.persist(key: key, to: pkg)

        #expect(try Data(
            contentsOf: pkg.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent("new.mov")
        ) == Data("new-media".utf8))
        #expect(FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(ChatSessionStore.dirName)
                .appendingPathComponent("saved.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(DataRootResolver.pipelineDirname)
                .appendingPathComponent("bible.yaml").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(".ngv-materialized").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(".ngv-dirty").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent(".import-crashed.partial").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(DataRootResolver.pipelineDirname)
                .appendingPathComponent(".song-crashed.partial").path
        ))
    }

    @Test("a successful save clears crash recovery and refreshes stale clean state")
    func savedCopyIsNotRecovered() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let home = try ProjectWorkingCopy.open(key: key, packageURL: pkg).home
        try ProjectWorkingCopy.markDirty(key: key)
        try ProjectWorkingCopy.persist(key: key, to: pkg)
        ProjectWorkingCopy.markSaved(key: key)
        let stale = home.appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("stale-after-save.mov")
        try Data("stale".utf8).write(to: stale)

        let reopened = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        #expect(!reopened.recoveredUnsaved)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("discard recovery atomically restores the last saved full package")
    func discardRecoveryRestoresSavedState() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        let home = try ProjectWorkingCopy.open(key: key, packageURL: pkg).home
        let unsaved = home.appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("discard-me.mov")
        try Data("unsaved".utf8).write(to: unsaved)
        try ProjectWorkingCopy.markDirty(key: key)

        let restored = try ProjectWorkingCopy.rematerialize(key: key, packageURL: pkg)
        #expect(!FileManager.default.fileExists(atPath: unsaved.path))
        #expect(FileManager.default.fileExists(
            atPath: restored.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent("saved.mov").path
        ))
        #expect(!ProjectWorkingCopy.open(key: key, packageURL: pkg).recoveredUnsaved)
    }

    @Test("Save As copies the complete working state and mints an independent identity")
    func saveAsCopiesFullStateWithNewIdentity() throws {
        let source = try tempPackage()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-save-as-\(UUID().uuidString).ngv", isDirectory: true)
        let key = uniqueKey()
        defer {
            ProjectWorkingCopy.discard(key: key)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let sourceID = try ProjectIdentity.uuid(for: source)
        let home = try ProjectWorkingCopy.open(key: key, packageURL: source).home
        let unsaved = home.appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("save-as.mov")
        try Data("save-as".utf8).write(to: unsaved)
        try ProjectWorkingCopy.markDirty(key: key)

        try ProjectWorkingCopy.persist(
            key: key,
            to: destination,
            mintNewIdentity: true
        )

        #expect(try ProjectIdentity.uuid(for: destination) != sourceID)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent("save-as.mov").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(DataRootResolver.pipelineDirname)
                .appendingPathComponent("bible.yaml").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: source.appendingPathComponent(Project.mediaDirectoryName)
                .appendingPathComponent("save-as.mov").path
        ))
    }

    @Test("an incomplete working copy cannot damage the last saved package")
    func incompletePersistLeavesPackageUntouched() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }
        let original = try Data(
            contentsOf: pkg.appendingPathComponent(Project.timelineFilename)
        )
        let home = try ProjectWorkingCopy.open(key: key, packageURL: pkg).home
        try FileManager.default.removeItem(
            at: home.appendingPathComponent(Project.timelineFilename)
        )

        #expect(throws: ProjectWorkingCopy.PersistError.self) {
            try ProjectWorkingCopy.persist(key: key, to: pkg)
        }
        #expect(try Data(
            contentsOf: pkg.appendingPathComponent(Project.timelineFilename)
        ) == original)
    }

    @Test("a package symlink is rejected instead of escaping the working copy")
    func packageSymlinkIsRejected() throws {
        let pkg = try tempPackage()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-outside-\(UUID().uuidString)")
        let key = uniqueKey()
        defer {
            ProjectWorkingCopy.discard(key: key)
            try? FileManager.default.removeItem(at: pkg)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let link = pkg.appendingPathComponent(Project.mediaDirectoryName)
            .appendingPathComponent("linked.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: ProjectWorkingCopy.PersistError.self) {
            try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    // MARK: - Idle-data sweep

    /// Build a throwaway store; entries are added by `makeHome`.
    private func tempStore() throws -> URL {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        return store
    }

    /// Create a `p-…` entry in `store`; `ageDays` back-dates BOTH access and modification time (via
    /// utimes) so the idle gate — which uses the later of the two — can be exercised. Set the times
    /// LAST so creating contents can't refresh them.
    @discardableResult
    private func makeHome(in store: URL, key: String, ageDays: Double = 0) throws -> URL {
        let home = store.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if ageDays > 0 {
            let secs = Date(timeIntervalSinceNow: -ageDays * 24 * 3600).timeIntervalSince1970
            var times = [timeval(tv_sec: Int(secs), tv_usec: 0), timeval(tv_sec: Int(secs), tv_usec: 0)]
            _ = utimes(home.path, &times)   // [atime, mtime]
        }
        return home
    }

    @Test("sweep retires a stale entry nobody reopened")
    func sweepRetiresStaleCopy() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let stale = try makeHome(in: store, key: "p-stale", ageDays: 30)

        ProjectWorkingCopy.purgeKeyedStore(store, liveKeys: [], graceInterval: 14 * 24 * 3600)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("sweep keeps a freshly-touched entry")
    func sweepKeepsFreshCopy() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let fresh = try makeHome(in: store, key: "p-fresh", ageDays: 1)

        ProjectWorkingCopy.purgeKeyedStore(store, liveKeys: [], graceInterval: 14 * 24 * 3600)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("sweep spares an open/recent project's entry even when stale")
    func sweepSparesLiveKey() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let live = try makeHome(in: store, key: "p-open", ageDays: 30)   // idle, but the project is open

        ProjectWorkingCopy.purgeKeyedStore(store, liveKeys: ["p-open"], graceInterval: 14 * 24 * 3600)
        #expect(FileManager.default.fileExists(atPath: live.path))
    }

    @Test("sweep ignores non-project strays")
    func sweepIgnoresStrays() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let stray = try makeHome(in: store, key: "notes-scratch", ageDays: 30)   // no p- prefix

        ProjectWorkingCopy.purgeKeyedStore(store, liveKeys: [], graceInterval: 14 * 24 * 3600)
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: - Field incident: a save that reported success and wrote no pipeline

    @Test("persisting a key with no working copy FAILS instead of silently writing nothing")
    func persistWithUnknownKeyThrows() throws {
        // The incident: mid-save the package's id was momentarily unreadable, so the key was re-derived
        // and came back as a FRESH identity. `persist` found no such working copy, returned quietly, and
        // the save reported success — the package went to disk without bible/shotlist/analysis/renders
        // while the real data sat under the previous key. Failing loudly keeps the last good package.
        let pkg = try tempPackage()
        defer { try? FileManager.default.removeItem(at: pkg) }
        try FileManager.default.removeItem(at: pkg.appendingPathComponent(DataRootResolver.pipelineDirname))

        #expect(throws: ProjectWorkingCopy.PersistError.self) {
            try ProjectWorkingCopy.persist(key: uniqueKey(), to: pkg)   // key names no working copy
        }
        // …and it must not have left a half-written pipeline behind.
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(DataRootResolver.pipelineDirname).path))
    }

    @Test("a working copy with no pipeline yet is not an error — nothing to sync")
    func persistWithoutPipelineIsFine() throws {
        let pkg = try tempPackage(pipelineName: nil)
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }
        _ = try ProjectWorkingCopy.open(key: key, packageURL: pkg)

        try ProjectWorkingCopy.persist(key: key, to: pkg)
        #expect(FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(Project.timelineFilename).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: pkg.appendingPathComponent(DataRootResolver.pipelineDirname).path
        ))
    }

    @Test("a successful persist really lands the pipeline in the package")
    func persistLandsInPackage() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        _ = try ProjectWorkingCopy.open(key: key, packageURL: pkg)
        let live = ProjectWorkingCopy.home(key).appendingPathComponent(DataRootResolver.pipelineDirname)
        try "measured".write(
            to: live.appendingPathComponent("analysis.json"), atomically: true, encoding: .utf8)

        try ProjectWorkingCopy.persist(key: key, to: pkg)

        let landed = pkg.appendingPathComponent(DataRootResolver.pipelineDirname)
            .appendingPathComponent("analysis.json")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(try String(contentsOf: landed, encoding: .utf8) == "measured")
    }
}
