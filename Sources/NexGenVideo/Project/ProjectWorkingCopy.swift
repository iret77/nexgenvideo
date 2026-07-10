import Foundation
import NexGenEngine

/// The live editing copy of a project's pipeline data root, kept in the Recovery store (Application
/// Support) — NOT inside the `.ngv` package. The engine and agent write here during a session; ⌘S
/// syncs it back into the package; a clean close discards it. If the app crashes, the working copy
/// survives, so the next open can offer to restore the unsaved work (ACE Studio model).
/// See `docs/PROJECT_STORAGE.md`.
enum ProjectWorkingCopy {
    private static let pipelineDir = DataRootResolver.pipelineDirname   // "pipeline"
    /// Written only after a materialize fully completes. Its presence proves the working copy is a
    /// COMPLETE mirror — a partial/interrupted copy (or one from an older direct-copy build) lacks it
    /// and is never treated as recoverable, so a partial tree can't be persisted over the package.
    private static let completeSentinel = ".ngv-materialized"

    /// The working-copy home for a project; its `pipeline/` data root lives directly under it.
    static func home(_ key: String) -> URL { AppPaths.workingCopy(projectId: key) }

    /// A stable, filesystem-safe key for a project derived from its location — the same project
    /// yields the same working copy across launches (so a crash's working copy is found again).
    static func stableKey(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "p-" + String(hash, radix: 16)
    }

    struct OpenResult: Sendable { let home: URL; let recoveredUnsaved: Bool }

    /// Prepare the working copy for an opening project. If one already exists, the previous session
    /// ended without a clean close (a crash) — keep it untouched and flag it for a restore prompt.
    /// Otherwise materialize a fresh copy from the package's stored pipeline.
    @discardableResult
    static func open(key: String, packageURL: URL?) throws -> OpenResult {
        // Recovered only if the surviving working copy fully materialized (completion sentinel) AND is
        // a valid data root (has project.yaml). A partial/interrupted copy is rebuilt from the package,
        // never persisted over it.
        let fm = FileManager.default
        let sentinel = home(key).appendingPathComponent(completeSentinel)
        let marker = home(key).appendingPathComponent(pipelineDir)
            .appendingPathComponent(DataRootResolver.projectMarker)
        if fm.fileExists(atPath: sentinel.path), fm.fileExists(atPath: marker.path) {
            return OpenResult(home: home(key), recoveredUnsaved: true)
        }
        return OpenResult(home: try materialize(key: key, packageURL: packageURL), recoveredUnsaved: false)
    }

    /// Throw away any working copy and re-materialize from the package (the "discard unsaved" path).
    @discardableResult
    static func rematerialize(key: String, packageURL: URL?) throws -> URL {
        discard(key: key)
        return try materialize(key: key, packageURL: packageURL)
    }

    /// Copy the package's stored data root (current `pipeline/`, or legacy `_studio/`) into a fresh
    /// working copy. A project with no pipeline yet yields an empty working-copy home.
    @discardableResult
    static func materialize(key: String, packageURL: URL?) throws -> URL {
        let fm = FileManager.default
        let dstHome = AppPaths.ensure(home(key))
        let dstPipeline = dstHome.appendingPathComponent(pipelineDir)
        let sentinel = dstHome.appendingPathComponent(completeSentinel)
        // Clear the completion sentinel FIRST: while the copy is in flight the working copy is partial
        // and must not read as recoverable if the app dies mid-materialize.
        try? fm.removeItem(at: sentinel)
        // Never destroy a possibly-real working copy: if an existing pipeline is a valid data root but
        // lacks the sentinel (a legacy/interrupted copy), move it OUT of this home — a later clean-close
        // discard removes home(key), so an in-home quarantine wouldn't survive. If it can't be moved
        // aside, throw rather than delete it (fail-safe: never lose unsaved work).
        let existingMarker = dstPipeline.appendingPathComponent(DataRootResolver.projectMarker)
        if fm.fileExists(atPath: existingMarker.path) {
            let quarantineRoot = AppPaths.ensure(
                AppPaths.recovery.appendingPathComponent(".quarantine", isDirectory: true))
            let quarantine = quarantineRoot.appendingPathComponent("\(key)-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: dstPipeline, to: quarantine)
            Log.project.notice("quarantined an unsentineled working copy to \(quarantine.lastPathComponent)")
        }
        try? fm.removeItem(at: dstPipeline)
        if let packageURL, let srcPipeline = packagePipeline(in: packageURL) {
            // Copy to a staging dir, then atomic-move into place: a mid-copy failure can never leave a
            // partial `pipeline`.
            let staging = dstHome.appendingPathComponent(".materialize-\(UUID().uuidString)", isDirectory: true)
            try? fm.removeItem(at: staging)
            do {
                try fm.copyItem(at: srcPipeline, to: staging)
                try fm.moveItem(at: staging, to: dstPipeline)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
        // Materialize is complete (empty home for a new project, or a full pipeline copy).
        try? Data().write(to: sentinel)
        return dstHome
    }

    /// Sync the working copy's `pipeline/` into the `.ngv` package at `packageURL` (atomic replace).
    /// Also removes a legacy `_studio/` from the package so the migrated project carries only `pipeline/`.
    static func persist(key: String, to packageURL: URL) throws {
        let fm = FileManager.default
        let src = home(key).appendingPathComponent(pipelineDir)
        guard fm.fileExists(atPath: src.path) else { return }
        let dst = packageURL.appendingPathComponent(pipelineDir)
        let staged = packageURL.appendingPathComponent(".pipeline.staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: src, to: staged)
        do {
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: dst)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        // A migrated project must not keep the pre-rename directory around.
        let legacy = packageURL.appendingPathComponent(DataRootResolver.legacyPipelineDirname)
        if legacy.lastPathComponent != pipelineDir { try? fm.removeItem(at: legacy) }
    }

    /// Remove the working copy — a clean close, so no crash-recovery prompt next time.
    static func discard(key: String) {
        try? FileManager.default.removeItem(at: home(key))
    }

    /// The package's stored data root, current or legacy, if present.
    private static func packagePipeline(in packageURL: URL) -> URL? {
        let fm = FileManager.default
        for name in [pipelineDir, DataRootResolver.legacyPipelineDirname] {
            let candidate = packageURL.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.appendingPathComponent(DataRootResolver.projectMarker).path) {
                return candidate
            }
        }
        return nil
    }
}
