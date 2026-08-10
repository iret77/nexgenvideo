import Foundation

/// Lifts a project's artifacts to the schema the engine writes today. This is the mechanism behind the
/// storage model's "auto-migrate" mandate: `SchemaVersions` could only ever *report* a mismatch and
/// pointed at a `<modul> migrate` CLI that was never ported, so a schema bump would have stranded
/// existing `.ngv` projects with a warning (#202).
///
/// Port of the Python migration model, extended through `bible/v5` and `shotlist/v4`,
/// but built on the seam Python lacked: the Swift readers already decode the older versions tolerantly
/// (new fields are `decodeIfPresent` with empty defaults) and the writers emit the current shape. So a
/// migration is a decode → re-stamp → `validate()` → encode round-trip rather than hand-written field
/// surgery, and it cannot write a file the reader would reject. As in Python, no heuristics: fields
/// added by a newer schema stay empty and the sanity pass asks the user to fill them.
///
/// Runs on the working copy, never on the `.ngv` package — the package is only ever written by ⌘S.
public enum SchemaMigrator {

    public struct Result: Sendable, Equatable {
        /// Path relative to the data root, e.g. "bible/bible.yaml".
        public let artifact: String
        public let from: String
        public let to: String
        /// The pre-migration copy kept next to the file; nil on a dry run.
        public let backup: URL?
    }

    public enum MigrationError: Swift.Error, Sendable, Equatable {
        /// The project was written by a NEWER engine — migrating down would destroy data. Hard stop.
        case projectAheadOfEngine(artifact: String, projectVersion: String, engineCurrent: String)
        case unreadable(artifact: String, reason: String)
    }

    /// Migrate every known artifact under `dataRoot` that is behind the engine. Idempotent: an artifact
    /// already on the current schema yields no result and no write. Artifacts that are missing, current,
    /// or carry an unknown version are left untouched — an unknown version is not something to guess at,
    /// and the reader rejects it loudly.
    ///
    /// Throws `projectAheadOfEngine` on the hard-stop case rather than touching the file.
    @discardableResult
    public static func migrateProject(dataRoot: URL, dryRun: Bool = false) throws -> [Result] {
        var results: [Result] = []
        for finding in SchemaVersions.checkProjectVersions(dataRoot: dataRoot) {
            guard let projectVersion = finding.projectVersion else { continue }
            switch finding.status {
            case .ahead:
                throw MigrationError.projectAheadOfEngine(
                    artifact: finding.artifact,
                    projectVersion: projectVersion,
                    engineCurrent: finding.skillCurrent)
            case .behind:
                let url = dataRoot.appendingPathComponent(finding.artifact)
                let migrated = try migrateFile(
                    at: url, schemaKey: finding.schemaField, from: projectVersion, dryRun: dryRun)
                results.append(
                    Result(artifact: finding.artifact, from: projectVersion,
                           to: finding.skillCurrent, backup: migrated))
            case .match, .missing, .unknown:
                continue
            }
        }
        return results
    }

    /// Re-stamp one artifact to the current schema. Returns the backup URL (nil on a dry run).
    private static func migrateFile(
        at url: URL, schemaKey: String, from: String, dryRun: Bool
    ) throws -> URL? {
        let yaml: String
        do {
            yaml = try encodeMigrated(at: url, schemaKey: schemaKey)
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.unreadable(artifact: url.lastPathComponent, reason: "\(error)")
        }
        guard !dryRun else { return nil }
        // The pre-migration file stays next to the original, so a bad migration is always inspectable.
        let backup = backupURL(for: url, from: from)
        try FileManager.default.copyItem(at: url, to: backup)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return backup
    }

    /// Decode with the tolerant reader, stamp the current schema, and re-encode. `validate()` runs inside
    /// both the decode and the re-stamp, so a file that would not load again is never written.
    private static func encodeMigrated(at url: URL, schemaKey: String) throws -> String {
        switch schemaKey {
        case "bible":
            var bible = try YAMLCoding.decode(Bible.self, from: url)
            bible.schema = bibleSchemaVersion
            try bible.validate()
            return try YAMLCoding.encode(bible)
        case "shotlist":
            var shotlist = try YAMLCoding.decode(Shotlist.self, from: url)
            shotlist.schema_ = shotlistSchemaVersion
            try shotlist.validate()
            return try YAMLCoding.encode(shotlist)
        default:
            // Every other artifact in the matrix has current == its only supported version, so it can
            // never be `.behind`. Reaching here means the matrix grew a migratable schema without a
            // migration — fail loudly instead of silently leaving the project behind.
            throw MigrationError.unreadable(
                artifact: url.lastPathComponent, reason: "no migration for schema '\(schemaKey)'")
        }
    }

    /// `bible/bible.yaml` + "bible/v4" -> `bible/bible.pre-bible-v4.<timestamp>.yaml`. Port of the
    /// Python `_backup_path`, but stamped with the version left BEHIND rather than the one migrated to —
    /// that is the thing you need to identify when looking for a pre-migration copy.
    static func backupURL(for url: URL, from: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let slug = from.replacingOccurrences(of: "/", with: "-")
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).pre-\(slug).\(formatter.string(from: Date())).yaml")
    }
}
