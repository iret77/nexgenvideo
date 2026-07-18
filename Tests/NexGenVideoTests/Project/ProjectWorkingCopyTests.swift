import Foundation
import Testing
import NexGenEngine
import MusicvideoPlugin

@testable import NexGenVideo

/// The crash-safe working-copy round trip: materialize from the package, detect a crash-surviving
/// copy, persist back into the package, and recognize/retire the legacy `_studio` layout.
@MainActor
@Suite("ProjectWorkingCopy")
struct ProjectWorkingCopyTests {
    private func tempPackage(pipelineName: String = DataRootResolver.pipelineDirname) throws -> URL {
        let pkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-wc-\(UUID().uuidString).ngv", isDirectory: true)
        let pipeline = pkg.appendingPathComponent(pipelineName, isDirectory: true)
        try FileManager.default.createDirectory(at: pipeline, withIntermediateDirectories: true)
        try "project: demo\nmode: beat\n".write(
            to: pipeline.appendingPathComponent("project.yaml"), atomically: true, encoding: .utf8)
        try "hello".write(
            to: pipeline.appendingPathComponent("bible.yaml"), atomically: true, encoding: .utf8)
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
    }

    @Test("a surviving working copy is reported as recovered unsaved work")
    func detectsCrashCopy() throws {
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }

        _ = try ProjectWorkingCopy.open(key: key, packageURL: pkg)   // first session materializes
        let second = try ProjectWorkingCopy.open(key: key, packageURL: pkg)   // crash → copy survives
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
        ProjectPluginSettings.setActivePlugin("musicvideo", projectURL: pkg)
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
        // A project whose engine has never run legitimately has no pipeline. That must stay a no-op,
        // or every save before the first phase would fail.
        let pkg = try tempPackage()
        let key = uniqueKey()
        defer { ProjectWorkingCopy.discard(key: key); try? FileManager.default.removeItem(at: pkg) }
        try FileManager.default.createDirectory(
            at: ProjectWorkingCopy.home(key), withIntermediateDirectories: true)

        try ProjectWorkingCopy.persist(key: key, to: pkg)   // must not throw
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
