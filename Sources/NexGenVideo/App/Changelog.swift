import Foundation

struct ChangelogFeed: Decodable {
    let changelogURL: String?
    let entries: [ChangelogEntry]
}

struct ChangelogEntry: Decodable, Identifiable {
    let version: String
    let date: String?
    let sections: [ChangelogSection]

    var id: String { version }
}

struct ChangelogSection: Decodable {
    let heading: String?
    let items: [String]
}

enum WhatsNewPolicy {
    static func shouldPresent(current: String, lastSeen: String?, availableVersions: Set<String>) -> Bool {
        guard !current.isEmpty,
              let lastSeen,
              !lastSeen.isEmpty,
              lastSeen != current else { return false }
        return availableVersions.contains(current)
    }
}

@MainActor @Observable
final class ChangelogStore {
    static let shared = ChangelogStore()

    private(set) var pending: ChangelogEntry?
    private(set) var changelogURL: URL?

    private let lastSeenKey = "lastSeenVersion"

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Show the overlay only on a genuine version change, never on a fresh install
    func checkForWhatsNew() {
        guard let feed = loadFeed() else { return }
        changelogURL = feed.changelogURL.flatMap { URL(string: $0) }

        let current = currentVersion
        guard !current.isEmpty else { return }
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenKey)
        guard let lastSeen, !lastSeen.isEmpty else {
            UserDefaults.standard.set(current, forKey: lastSeenKey)
            return
        }
        guard WhatsNewPolicy.shouldPresent(
            current: current,
            lastSeen: lastSeen,
            availableVersions: Set(feed.entries.map(\.version))
        ) else { return }
        pending = feed.entries.first { $0.version == current }
    }

    func dismiss() {
        if pending != nil { UserDefaults.standard.set(currentVersion, forKey: lastSeenKey) }
        pending = nil
    }

    private func loadFeed() -> ChangelogFeed? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Changelog/changelog.json"),
            root.appendingPathComponent("NexGenVideo_NexGenVideo.bundle/Changelog/changelog.json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            return try? JSONDecoder().decode(ChangelogFeed.self, from: data)
        }
        return nil
    }
}
