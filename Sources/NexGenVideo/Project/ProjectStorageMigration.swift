import Foundation
import NexGenEngine

/// One-time cleanup of the pre-model layout: older builds scaffolded a project's pipeline (`_studio`)
/// and vestigial `inbox`/`review`/`final` zones loose in the projects folder, next to the `.ngv`
/// packages. They belong to no project under the new model. Move them to the Trash (recoverable, never
/// a hard delete) so the projects folder holds only project files. See `docs/PROJECT_STORAGE.md`.
enum ProjectStorageMigration {
    /// Vestigial zone dirs the app never used — always safe to retire (they never hold user data).
    private static let vestigialNames = ["inbox", "review", "final"]

    static func cleanUpProjectsFolder() {
        let fm = FileManager.default
        let root = Project.storageDirectory
        for name in vestigialNames { trashIfDirectory(root.appendingPathComponent(name, isDirectory: true), fm) }

        // A loose `_studio` is retired ONLY when it is NOT a valid data root — a flat legacy project
        // whose data root is a loose `_studio` (has project.yaml) holds real work; never trash that.
        let legacy = root.appendingPathComponent(DataRootResolver.legacyPipelineDirname, isDirectory: true)
        let hasMarker = fm.fileExists(
            atPath: legacy.appendingPathComponent(DataRootResolver.projectMarker).path)
        if !hasMarker { trashIfDirectory(legacy, fm) }
    }

    private static func trashIfDirectory(_ url: URL, _ fm: FileManager) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            Log.project.notice("moved orphaned '\(url.lastPathComponent)' out of the projects folder to Trash")
        } catch {
            Log.project.error("couldn't trash orphaned '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
    }
}
