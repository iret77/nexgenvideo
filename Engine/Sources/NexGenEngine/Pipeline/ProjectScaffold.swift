import Foundation

/// Project folder layout — fresh init + in-place flat→`_studio` migration. The
/// generic mechanism; a pack contributes its own subdirs via `extraDirs`. Port
/// of `core/layout.py`. Reuses `StudioLayout` (core subdirs, user dirs) and the
/// Gates / ProjectMeta artifact types.
public enum ProjectScaffold {
    /// Home entries kept in place during migration (user zones + `_studio` +
    /// `studio.html`). Port of `layout.py::_HOME_ENTRIES`
    /// (`{*USER_DIRS, STUDIO_DIRNAME, "studio.html"}`).
    static let homeEntries: Set<String> = Set(
        StudioLayout.userDirs + [DataRootResolver.studioDirname, "studio.html"]
    )

    public enum ScaffoldError: Swift.Error, Sendable, Equatable {
        /// `home` already contains a project. Port of the `FileExistsError` in `init_project`.
        case alreadyAProject(URL)
        /// `home` already has a `_studio/`. Port of the `migrate_layout` guard.
        case alreadyMigrated(URL)
        /// `home` is not a flat legacy project. Port of the `FileNotFoundError` guard.
        case notFlatLegacy(URL)
        /// A move failed mid-migration and was rolled back. Port of the rewrapped `OSError`.
        case migrationFailed(entry: String, underlying: String)
    }

    /// Create each subdir under `base` and drop a `.gitkeep` in it. Port of
    /// `layout.py::_make_dirs`.
    private static func makeDirs(_ base: URL, _ subdirs: [String]) throws {
        for sub in subdirs {
            let dir = base.appendingPathComponent(sub)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let gitkeep = dir.appendingPathComponent(".gitkeep")
            if !FileManager.default.fileExists(atPath: gitkeep.path) {
                FileManager.default.createFile(atPath: gitkeep.path, contents: nil)
            }
        }
    }

    /// Create a fresh project below `home` and return its data root
    /// (`home/_studio`). `extraDirs` are the active pack's subdirs. Fails if
    /// `home` already holds a project. Port of `layout.py::init_project`.
    @discardableResult
    public static func initProject(
        home: URL, name: String, mode: Mode = .beat, budgetEur: Double = 50.0,
        extraDirs: [String] = [], today: () -> String = ProjectScaffold.todayISODate
    ) throws -> URL {
        let home = home.standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if DataRootResolver.dataRoot(of: home) != nil {
            throw ScaffoldError.alreadyAProject(home)
        }

        let dataRoot = home.appendingPathComponent(DataRootResolver.studioDirname)
        try makeDirs(dataRoot, StudioLayout.coreSubdirs + extraDirs)
        try makeDirs(home, StudioLayout.userDirs)

        let store = YAMLArtifactStore(dataRoot: dataRoot)
        try store.save(
            ProjectMeta(project: name, mode: mode, budgetEur: budgetEur, created: today()),
            to: StudioLayout.projectFile
        )
        try store.save(Gates(project: name), to: StudioLayout.gatesFile)
        return dataRoot
    }

    /// Migrate a flat legacy project folder in place into `_studio/`. Port of
    /// `layout.py::migrate_layout`.
    @discardableResult
    public static func migrateLayout(home: URL) throws -> URL {
        let home = home.standardizedFileURL
        let fm = FileManager.default
        let studio = home.appendingPathComponent(DataRootResolver.studioDirname)
        if fm.fileExists(atPath: studio.path) {
            throw ScaffoldError.alreadyMigrated(home)
        }
        // A flat legacy project has its data root AT home itself.
        guard DataRootResolver.dataRoot(of: home) == home else {
            throw ScaffoldError.notFlatLegacy(home)
        }

        let contents = (try? fm.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: []
        )) ?? []
        let toMove = contents
            .filter { !homeEntries.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        try fm.createDirectory(at: studio, withIntermediateDirectories: false)
        var moved: [URL] = []
        do {
            for entry in toMove {
                let target = studio.appendingPathComponent(entry.lastPathComponent)
                try fm.moveItem(at: entry, to: target)
                moved.append(target)
            }
        } catch {
            // Roll back: move each already-moved entry back, then drop _studio.
            for target in moved.reversed() {
                try? fm.moveItem(at: target, to: home.appendingPathComponent(target.lastPathComponent))
            }
            try? fm.removeItem(at: studio)
            throw ScaffoldError.migrationFailed(
                entry: (moved.count < toMove.count ? toMove[moved.count].lastPathComponent : "?"),
                underlying: String(describing: error)
            )
        }

        try makeDirs(home, StudioLayout.userDirs)
        return studio
    }

    /// `date.today().isoformat()` — local calendar date as `YYYY-MM-DD`.
    public static func todayISODate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
