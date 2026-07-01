import Foundation

// Auto-discovers installed format plugins on disk so the embedded `claude -p` runtime loads each as a
// `--plugin-dir` and the engine venv installs its Python pack — without the user pointing at a folder.
//
// A plugin on disk is a folder `<root>/<name>/` containing a Python pack (`pyproject.toml` at its root,
// declaring the `nexgen.packs` entry-point) plus a Claude-Code layer at `<name>/plugin/.claude-plugin/
// plugin.json`. Two halves, two consumers:
//   • `pluginDir` (`<name>/plugin/`) → passed to claude as `--plugin-dir`.
//   • `installRoot` (`<name>/`, the folder with `pyproject.toml`) → `uv pip install -e`-ed into the venv.
//
// Scanned roots, in priority order: the user import dir (Application Support) first, then the bundled
// plugins dir. De-duped by `name` so an imported newer copy overrides the bundled one. Everything
// degrades gracefully: missing roots, no plugins, a plugin missing its pyproject — all just yield fewer
// entries, never an error.
enum PluginManager {

    struct Plugin: Sendable, Equatable {
        let name: String
        /// `<root>/<name>/` — the folder carrying `pyproject.toml` (the pip install target).
        let installRoot: URL
        /// `<root>/<name>/plugin/` — the loadable Claude-Code layer (the `--plugin-dir`).
        let pluginDir: URL
    }

    /// `~/Library/Application Support/NexGenVideo/plugins/` — where users drop imported plugins.
    /// Not created here; absent → simply skipped during discovery.
    static var userPluginsDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("NexGenVideo/plugins", isDirectory: true)
    }

    /// Discovery roots, highest priority first (user import dir wins over bundled on a name clash).
    static func discoveryRoots() -> [URL] {
        var roots = [userPluginsDir]
        if let bundled = EngineRuntime.bundledPluginsDir { roots.append(bundled) }
        return roots
    }

    /// Every discovered plugin (`plugin.json` present), de-duped by name across all roots in priority
    /// order. A plugin without a `pyproject.toml` is still returned (so it can load as a `--plugin-dir`)
    /// — install consumers filter those out via `installablePlugins()`.
    static func discoverPlugins() -> [Plugin] {
        let fm = FileManager.default
        var result: [Plugin] = []
        var seen = Set<String>()
        for root in discoveryRoots() {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            for installRoot in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = installRoot.lastPathComponent
                guard !seen.contains(name) else { continue }
                let pluginDir = installRoot.appendingPathComponent("plugin", isDirectory: true)
                let manifest = pluginDir.appendingPathComponent(".claude-plugin/plugin.json")
                guard fm.fileExists(atPath: manifest.path) else { continue }
                seen.insert(name)
                result.append(Plugin(name: name, installRoot: installRoot, pluginDir: pluginDir))
            }
        }
        return result
    }

    /// Loadable `--plugin-dir` URLs for the discovered plugins (each `<name>/plugin/`).
    static func discoveredPluginDirectories() -> [URL] {
        discoverPlugins().map(\.pluginDir)
    }

    /// Discovered plugins whose install root actually carries a `pyproject.toml` — the ones the engine
    /// venv can `uv pip install -e`. The rest (claude-only plugins) are skipped for install.
    static func installablePlugins() -> [Plugin] {
        let fm = FileManager.default
        return discoverPlugins().filter {
            fm.fileExists(atPath: $0.installRoot.appendingPathComponent("pyproject.toml").path)
        }
    }

    /// Installable plugins whose `pyproject.toml` declares an `audio` extra under
    /// `[project.optional-dependencies]` — i.e. plugins carrying a heavy optional DSP stack the user can
    /// opt into. Convention: a plugin exposing heavy DSP names its extra `audio`. Detected by a
    /// lightweight line scan (no TOML parser): the section header followed by an `audio = [` (or
    /// `audio=[`) key. Plugins without the extra, or with an unreadable manifest, are simply omitted.
    static func audioExtraPlugins() -> [Plugin] {
        installablePlugins().filter {
            let manifest = $0.installRoot.appendingPathComponent("pyproject.toml")
            guard let toml = try? String(contentsOf: manifest, encoding: .utf8) else { return false }
            return declaresAudioExtra(in: toml)
        }
    }

    /// True iff `toml` contains an `audio` key under the `[project.optional-dependencies]` table.
    /// Scans line-by-line: enters the table on its header, leaves on the next `[...]` header, and matches
    /// an `audio` assignment inside it. Tolerant of whitespace; ignores `audio` mentions elsewhere.
    static func declaresAudioExtra(in toml: String) -> Bool {
        var inOptionalDeps = false
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOptionalDeps = (line == "[project.optional-dependencies]")
                continue
            }
            guard inOptionalDeps else { continue }
            let key = line.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
            if key == "audio" { return true }
        }
        return false
    }
}
