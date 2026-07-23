import Foundation

/// A project's stable identity — a UUID stored inside the package (`ngv.json`, alongside the active
/// format). Everything per-project keys off THIS, not the file path: the working copy, the caches,
/// telemetry. Because it travels inside the package, moving or renaming the `.ngv` keeps the same
/// identity, while a brand-new project (even one saved to a path a deleted project once occupied) gets
/// a fresh UUID — so their pipeline data can never cross-wire. Pre-UUID projects are migrated on first
/// access (a UUID is generated and written). See `docs/PROJECT_STORAGE.md`.
enum ProjectIdentity {
    private static let idKey = "id"

    /// The project's UUID, generating + persisting one on first access (migration for older packages).
    static func uuid(for packageURL: URL) throws -> String {
        if let existing = read(packageURL) { return existing }
        let fresh = UUID().uuidString
        try write(fresh, to: packageURL)
        return fresh
    }

    /// The filesystem key for this project's per-project stores (working copy, caches): `p-<uuid>`.
    static func key(for packageURL: URL) throws -> String {
        "p-" + (try uuid(for: packageURL))
    }

    /// The store key IF the package already carries an identity — without minting one. Use where a
    /// missing id should read as "not a known project" (e.g. the sweep's keep-set), not trigger a write.
    static func existingKey(for packageURL: URL) -> String? { read(packageURL).map { "p-" + $0 } }

    static func existingUUID(for packageURL: URL) -> String? { read(packageURL) }

    private static func read(_ packageURL: URL) -> String? {
        let url = packageURL.appendingPathComponent(ProjectPluginSettings.filename)
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json[idKey] as? String,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private static func write(_ id: String, to packageURL: URL) throws {
        let url = packageURL.appendingPathComponent(ProjectPluginSettings.filename)
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            json = existing
        }
        json[idKey] = id
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        guard read(packageURL) == id else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Force a new identity onto a package — used when a Save As / duplicate creates a distinct project
    /// from an existing one (the copied `ngv.json` would otherwise carry the source's UUID).
    @discardableResult
    static func regenerate(at packageURL: URL) throws -> String {
        let id = UUID().uuidString
        try write(id, to: packageURL)
        return id
    }
}
