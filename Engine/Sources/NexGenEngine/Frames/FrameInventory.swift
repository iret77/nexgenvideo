import Foundation
import Yams

/// Read-only inventory of generated frame candidates for the host UI. Port of
/// `engine/nexgen_engine/frames/inventory.py`.
///
/// Reports exactly what is on disk under `<data-root>/frames/`: one entry per
/// shot directory with its candidate images (sorted by name) and, when
/// present, a best-effort passthrough of the shot's `_frame_audit.yaml`. No
/// approval state is invented — the engine records none today; selection
/// happens through the agent workflow.
public enum FrameInventory {
    public static let imageSuffixes: Set<String> = ["png", "jpg", "jpeg", "webp"]
    public static let auditFilename = "_frame_audit.yaml"

    public enum InventoryError: Swift.Error, Sendable, Equatable {
        case noProject(String)
    }

    /// One frame candidate: display name + path relative to the project home
    /// (what the host resolves against).
    public struct FrameCandidate: Sendable, Equatable {
        public let name: String
        public let path: String
    }

    /// One shot's candidates plus its passthrough `_frame_audit.yaml`, if any.
    public struct ShotInventory: Sendable, Equatable {
        public let shotId: String
        public let frames: [FrameCandidate]
        public let audit: YAMLValue?
    }

    /// The full per-project inventory, mirroring `inventory.py::inventory`'s
    /// return dict shape (`project`, `shots`).
    public struct Result: Sendable, Equatable {
        public let project: String
        public let shots: [ShotInventory]
    }

    /// Frame candidates per shot, with paths relative to the project home.
    /// `projectDir` may be the project home or the data root itself (mirrors
    /// the Python `inventory()` entrypoint, which accepts either).
    public static func inventory(projectDir: URL) throws -> Result {
        guard let dataRoot = DataRootResolver.dataRoot(of: projectDir) else {
            throw InventoryError.noProject(projectDir.path)
        }
        let home = projectHome(of: dataRoot)
        let framesDir = dataRoot.appendingPathComponent(StudioLayout.framesDir, isDirectory: true)

        var shots: [ShotInventory] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: framesDir.path, isDirectory: &isDir), isDir.boolValue {
            let entries = (try? fm.contentsOfDirectory(
                at: framesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            let shotDirs = entries.filter { url in
                var d: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            for shotDir in shotDirs {
                let files = (try? fm.contentsOfDirectory(
                    at: shotDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                let images = files.filter { url in
                    var d: ObjCBool = false
                    let isFile = fm.fileExists(atPath: url.path, isDirectory: &d) && !d.boolValue
                    return isFile && imageSuffixes.contains(url.pathExtension.lowercased())
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }

                let audit = loadAudit(at: shotDir.appendingPathComponent(auditFilename))
                if images.isEmpty && audit == nil {
                    continue
                }
                let frames = images.map { url in
                    FrameCandidate(name: url.lastPathComponent, path: relativePath(of: url, to: home))
                }
                shots.append(ShotInventory(shotId: shotDir.lastPathComponent, frames: frames, audit: audit))
            }
        }

        return Result(project: projectName(of: dataRoot) ?? home.lastPathComponent, shots: shots)
    }

    /// Best-effort: a malformed or non-mapping audit file is treated as
    /// absent. Schema-less passthrough — mirrors the Python dict passthrough
    /// `inventory.py::_load_audit` hands to `read.py`.
    static func loadAudit(at path: URL) -> YAMLValue? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        guard let value = try? YAMLCoding.canonical(text) else { return nil }
        guard case .mapping = value else { return nil }
        return value
    }

    /// Port of `paths.project_home`: the user-facing project folder for a
    /// data root (parent of `_studio/`). Public so the app can lift a resolved
    /// data root back to the package where `ngv.json` lives.
    public static func projectHome(of dataRoot: URL) -> URL {
        dataRoot.lastPathComponent == DataRootResolver.studioDirname
            ? dataRoot.deletingLastPathComponent() : dataRoot
    }

    /// Port of `paths.project_name`: the `project` field from `project.yaml`,
    /// or nil if unreadable. Public so an out-of-module format pack can name the
    /// project for its artifacts.
    public static func projectName(of dataRoot: URL) -> String? {
        let marker = dataRoot.appendingPathComponent(DataRootResolver.projectMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let node = try? Yams.compose(yaml: text),
              case .mapping(let mapping) = node,
              let value = mapping["project"],
              case .scalar(let scalar) = value,
              scalar.tag != Tag(Tag.Name.null),
              !scalar.string.isEmpty
        else { return nil }
        return scalar.string
    }

    /// `url.relative_to(home)` equivalent for paths known to be inside `home`.
    /// Public so an out-of-module format pack can record project-relative paths.
    public static func relativePath(of url: URL, to home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(homePath) {
            var suffix = fullPath.dropFirst(homePath.count)
            if suffix.hasPrefix("/") { suffix = suffix.dropFirst() }
            return String(suffix)
        }
        return fullPath
    }
}
