import Foundation

/// The app's own storage locations, kept OUT of the user's projects folder. Durable app state
/// (registry, config, unsaved-work recovery) lives under Application Support; recreatable/transient
/// data under Caches. The projects folder (`Project.storageDirectory`) holds only `.ngv` packages.
/// See `docs/PROJECT_STORAGE.md`.
enum AppPaths {
    static let appDirName = "NexGenVideo"

    /// `~/Library/Application Support/NexGenVideo` — durable app state (registry, recovery, config).
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appDirName, isDirectory: true)
    }

    /// `~/Library/Caches/NexGenVideo` — recreatable, expendable data (not backed up by Time Machine).
    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(appDirName, isDirectory: true)
    }

    /// Recovery store — the live working copy of each open project, so unsaved work survives a crash.
    static var recovery: URL { applicationSupport.appendingPathComponent("Recovery", isDirectory: true) }

    /// Host-owned single-use authority for approved paid generation jobs.
    static var approvedGenerationExecutions: URL {
        applicationSupport.appendingPathComponent("ApprovedGenerationExecutions", isDirectory: true)
    }

    static var executionHostIdentity: URL {
        applicationSupport.appendingPathComponent("execution-host.json", isDirectory: false)
    }

    /// A project's working copy (editing target; synced into the `.ngv` package on save).
    static func workingCopy(projectId: String) -> URL {
        recovery.appendingPathComponent(projectId, isDirectory: true)
    }

    /// Root of the per-project Caches tier (`~/Library/Caches/NexGenVideo/projects`). Project-keyed
    /// (`p-…`) subdirs live here; the launch idle-sweep purges stale ones.
    static var projectCachesRoot: URL { caches.appendingPathComponent("projects", isDirectory: true) }

    /// A project's transient cache (render scratch, decode caches, proxies) — safe to purge.
    static func projectCache(projectId: String) -> URL {
        projectCachesRoot.appendingPathComponent(projectId, isDirectory: true)
    }

    /// In-flight generation staging for a project — where a download lands before it's finalized into
    /// the durable package `media/`. Recreatable + expendable, so it belongs in the Caches tier, not
    /// `NSTemporaryDirectory` (per-project + swept, so an interrupted download is discoverable and
    /// purged rather than orphaned in system temp).
    static func projectStaging(projectId: String) -> URL {
        projectCache(projectId: projectId).appendingPathComponent("staging", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
