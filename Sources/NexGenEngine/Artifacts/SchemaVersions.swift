import Foundation
import Yams

/// Central schema-version compatibility matrix. Port of
/// `core/schema_versions.py`.
///
/// Background: the skill is updated via `git pull`, but projects stay in
/// whatever state they were saved. If a skill encounters a project schema
/// version it doesn't know, silent data corruption is possible (new
/// mandatory fields missing, old fields misinterpreted). Three cases:
/// - project version <= skill version: skill knows the schema, can read
///   (migration possible if lower).
/// - project version == skill version: fine.
/// - project version > skill version: HARD STOP — skill must be updated.
public enum SchemaVersions {
    public struct Info: Sendable {
        public let current: String
        public let supported: [String]
    }

    /// Per schema: `current` is what the skill writes today; `supported` is
    /// what it can read (via migration / tolerant reader). `current` is
    /// always included in `supported`.
    public static let matrix: [String: Info] = [
        "bible": Info(current: "bible/v5", supported: ["bible/v4", "bible/v5"]),
        "shotlist": Info(current: "shotlist/v3", supported: ["shotlist/v1", "shotlist/v2", "shotlist/v3"]),
        "brief": Info(current: "brief/v1", supported: ["brief/v1"]),
        "ledger": Info(current: "ledger/v1", supported: ["ledger/v1"]),
        "frame_audit": Info(current: "frame_audit/v1", supported: ["frame_audit/v1"]),
        // Treatment has no versioned `schema` field (markdown + frontmatter),
        // so it is not in the matrix.
        "storyboard": Info(current: "storyboard/v1", supported: ["storyboard/v1"]),
    ]

    public enum Status: String, Sendable, Equatable {
        case match
        case behind
        case ahead
        case unknown
        case missing
    }

    public struct Finding: Sendable, Equatable {
        /// e.g. "bible.yaml", "shotlist/current.yaml", "brief.yaml".
        public let artifact: String
        /// Key in `matrix`, e.g. "bible".
        public let schemaField: String
        /// Version string from the project file, or nil if the file is missing.
        public let projectVersion: String?
        /// What the skill writes today.
        public let skillCurrent: String
        public let status: Status
        public let message: String
    }

    /// `"bible/v5"` -> `5`. `nil` if unparsable.
    static func parseVersion(_ s: String) -> Int? {
        guard !s.isEmpty, let range = s.range(of: "/v") else { return nil }
        return Int(s[range.upperBound...])
    }

    static func classify(projectVersion: String?, schemaKey: String) -> (Status, String) {
        guard let info = matrix[schemaKey] else {
            // Not reachable from `checkProjectVersions` (keys are fixed), but
            // keep a safe fallback for direct callers.
            return (.unknown, "unknown schema key \(schemaKey)")
        }
        let current = info.current
        let supported = info.supported
        guard let projectVersion else {
            return (.missing, "File fehlt — Skill schreibt '\(current)'.")
        }
        if projectVersion == current {
            return (.match, "OK — beide auf '\(current)'.")
        }
        if supported.contains(projectVersion) {
            return (
                .behind,
                "Projekt auf '\(projectVersion)', Skill aktuell '\(current)'. "
                    + "Migration empfohlen (siehe `<modul> migrate`)."
            )
        }
        let p = parseVersion(projectVersion)
        let c = parseVersion(current)
        if let p, let c, p > c {
            return (
                .ahead,
                "Projekt auf '\(projectVersion)', Skill kennt nur bis '\(current)'. "
                    + "Skill ist veraltet — HART STOP. "
                    + "Aktualisiere den Skill (`git pull` im Skill-Repo) und lies "
                    + "CLAUDE.md neu, bevor Du an diesem Projekt weiterarbeitest."
            )
        }
        return (
            .unknown,
            "Projekt deklariert '\(projectVersion)', aber das ist weder current "
                + "('\(current)') noch in supported \(supported). "
                + "Manuelle Klärung nötig."
        )
    }

    static func readSchemaField(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let node = try? Yams.compose(yaml: text),
              case .mapping(let mapping) = node,
              let value = mapping["schema"],
              case .scalar(let scalar) = value
        else { return nil }
        return scalar.string
    }

    /// Mapping of project file path (relative to the data root) -> schema key.
    /// Does not find `frame_audit/*.yaml` files automatically — those are
    /// written per-render and only appear dynamically; their schema stays v1.
    static let artifacts: [(path: String, schemaKey: String)] = [
        ("bible/bible.yaml", "bible"),
        ("shotlist/current.yaml", "shotlist"),
        ("brief.yaml", "brief"),
        ("storyboard/current.yaml", "storyboard"),
    ]

    /// Check all known project artifacts against the skill matrix.
    public static func checkProjectVersions(dataRoot: URL) -> [Finding] {
        artifacts.map { entry in
            let url = dataRoot.appendingPathComponent(entry.path)
            let projectVersion = readSchemaField(at: url)
            let (status, message) = classify(projectVersion: projectVersion, schemaKey: entry.schemaKey)
            return Finding(
                artifact: entry.path,
                schemaField: entry.schemaKey,
                projectVersion: projectVersion,
                skillCurrent: matrix[entry.schemaKey]!.current,
                status: status,
                message: message
            )
        }
    }

    /// At least one artifact declares a version the skill doesn't know —
    /// phase code should hard-stop.
    public static func anyAhead(_ findings: [Finding]) -> Bool {
        findings.contains { $0.status == .ahead }
    }
}
