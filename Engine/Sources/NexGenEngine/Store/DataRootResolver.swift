import Foundation
import Yams

/// Project directory resolution — Swift port of
/// `engine/nexgen_engine/core/paths.py` (`data_root_of` + `_is_project_marker`).
///
/// A project's *data root* is the directory that holds
/// `project.yaml` / `gates.yaml` / `brief.yaml`:
/// - Current layout: `<project-home>/pipeline/`.
/// - Legacy: `<project-home>/_studio/` (pre-rename) or flat `<project-home>/`.
public enum DataRootResolver {
    /// The data-root subdirectory name.
    public static let pipelineDirname = "pipeline"
    /// Pre-rename data-root name; still recognized so older projects open and migrate.
    public static let legacyPipelineDirname = "_studio"
    /// The file whose presence (and validity) marks a project.
    public static let projectMarker = "project.yaml"

    /// Return the data root if `directory` is a project home or data root.
    ///
    /// Checks `<directory>/pipeline/project.yaml`, then the legacy `_studio/`, then the
    /// flat layout (`<directory>/project.yaml`). Returns `nil` if none marks a project.
    public static func dataRoot(of directory: URL) -> URL? {
        let base = directory.standardizedFileURL
        for name in [pipelineDirname, legacyPipelineDirname] {
            let marker = base.appendingPathComponent(name).appendingPathComponent(projectMarker)
            if isProjectMarker(marker) {
                return base.appendingPathComponent(name)
            }
        }
        let flatMarker = base.appendingPathComponent(projectMarker)
        if isProjectMarker(flatMarker) {
            return base
        }
        return nil
    }

    /// True if `path` is a readable project.yaml with both mandatory ProjectMeta
    /// fields (`project` and `mode`) — mirrors `paths._is_project_marker`. The
    /// two-field requirement stops an unrelated `project.yaml` from being
    /// mistaken for a project during an upward search.
    static func isProjectMarker(_ path: URL) -> Bool {
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              let node = try? Yams.compose(yaml: text),
              case .mapping(let mapping) = node
        else { return false }
        return hasNonEmptyString(mapping, key: "project")
            && hasNonEmptyString(mapping, key: "mode")
    }

    /// Python `bool(data.get(key))` for a YAML scalar: present, non-null,
    /// non-empty. A `false`/`0` scalar would also be falsy in Python, but the
    /// two guarded keys (`project`, `mode`) are always strings here.
    private static func hasNonEmptyString(_ mapping: Node.Mapping, key: String) -> Bool {
        guard let value = mapping[key], case .scalar(let scalar) = value else { return false }
        if scalar.tag == Tag(Tag.Name.null) { return false }
        return !scalar.string.isEmpty
    }
}
