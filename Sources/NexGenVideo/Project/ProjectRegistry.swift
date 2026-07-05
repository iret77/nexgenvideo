import Foundation

struct ProjectEntry: Codable, Identifiable, Sendable {
    let id: UUID
    var url: URL
    var createdDate: Date
    var lastOpenedDate: Date

    var name: String { url.deletingPathExtension().lastPathComponent }
    var isAccessible: Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Observable
@MainActor
final class ProjectRegistry {
    static let shared = ProjectRegistry()

    private(set) var entries: [ProjectEntry] = []

    var sortedEntries: [ProjectEntry] {
        entries.sorted { $0.lastOpenedDate > $1.lastOpenedDate }
    }

    private var fileURL: URL
    private let disk = ProjectRegistryDisk()
    private var isLoading = false
    private var pendingMutations: [(inout [ProjectEntry]) -> Void] = []

    private init() {
        fileURL = Project.storageDirectory.appendingPathComponent(Project.registryFilename)
        load()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = Self.deduped(Self.loadEntries(from: fileURL))
    }

    // MARK: - Identity

    /// Canonical identity for dedupe. Comparing URLs directly treats `…/Debug.ngv` and
    /// `…/Debug.ngv/` as different projects — save panels return the file form while package
    /// documents carry the directory form — so the same project showed up twice on Home.
    private nonisolated static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Collapse entries that point at the same file under different URL spellings (heals
    /// registries that already contain such duplicates). Keeps first-seen order, the newest
    /// lastOpenedDate (and its URL spelling), and the earliest createdDate.
    private nonisolated static func deduped(_ entries: [ProjectEntry]) -> [ProjectEntry] {
        var indexByPath: [String: Int] = [:]
        var result: [ProjectEntry] = []
        for entry in entries {
            let key = canonicalPath(entry.url)
            if let i = indexByPath[key] {
                result[i].createdDate = min(result[i].createdDate, entry.createdDate)
                if entry.lastOpenedDate > result[i].lastOpenedDate {
                    result[i].lastOpenedDate = entry.lastOpenedDate
                    result[i].url = entry.url
                }
            } else {
                indexByPath[key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    /// Re-point at the registry inside the *current* projects folder and reload. The registry lives
    /// in the projects folder, so when the user changes that folder in Settings the Home overview must
    /// switch to the new location's project list — otherwise it keeps showing the old folder's projects.
    func relocateToCurrentStorage() {
        let newURL = Project.storageDirectory.appendingPathComponent(Project.registryFilename)
        guard newURL.standardizedFileURL != fileURL.standardizedFileURL else { return }
        fileURL = newURL
        load()
    }

    // MARK: - Mutations

    func register(_ url: URL) {
        let key = Self.canonicalPath(url)
        let resolved = url.standardizedFileURL
        mutate { entries in
            if let index = entries.firstIndex(where: { Self.canonicalPath($0.url) == key }) {
                entries[index].lastOpenedDate = Date()
            } else {
                entries.append(ProjectEntry(id: UUID(), url: resolved, createdDate: Date(), lastOpenedDate: Date()))
            }
        }
    }

    func remove(_ url: URL) {
        let key = Self.canonicalPath(url)
        mutate { entries in
            entries.removeAll { Self.canonicalPath($0.url) == key }
        }
    }

    func delete(_ url: URL) {
        Task { [weak self] in
            guard let self, await self.disk.trashIfPresent(url) else { return }
            self.remove(url)
        }
    }

    func updateURL(from oldURL: URL, to newURL: URL) {
        let oldKey = Self.canonicalPath(oldURL)
        let resolvedNew = newURL.standardizedFileURL
        mutate { entries in
            if let index = entries.firstIndex(where: { Self.canonicalPath($0.url) == oldKey }) {
                entries[index].url = resolvedNew
                entries[index].lastOpenedDate = Date()
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.disk.load(from: self.fileURL)
            self.finishLoading(loaded)
        }
    }

    private func save() {
        Self.saveEntries(entries, to: fileURL)
    }

    private func mutate(_ apply: @escaping (inout [ProjectEntry]) -> Void) {
        guard !isLoading else {
            pendingMutations.append(apply)
            return
        }
        apply(&entries)
        save()
    }

    private func finishLoading(_ loaded: [ProjectEntry]) {
        let cleaned = Self.deduped(loaded)
        entries = cleaned
        isLoading = false
        guard !pendingMutations.isEmpty else {
            // Heal a registry that already carried same-file duplicates on disk.
            if cleaned.count != loaded.count { save() }
            return
        }

        let mutations = pendingMutations
        pendingMutations.removeAll()
        for mutation in mutations {
            mutation(&entries)
        }
        save()
    }

    fileprivate nonisolated static func loadEntries(from fileURL: URL) -> [ProjectEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ProjectEntry].self, from: data) else { return [] }
        return decoded
    }

    fileprivate nonisolated static func saveEntries(_ entries: [ProjectEntry], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private actor ProjectRegistryDisk {
    func load(from fileURL: URL) -> [ProjectEntry] {
        Project.ensureStorageDirectory()
        return ProjectRegistry.loadEntries(from: fileURL)
    }

    func trashIfPresent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}
