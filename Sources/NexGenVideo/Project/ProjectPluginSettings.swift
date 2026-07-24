import Foundation

/// Persists per-project format settings in the package or live working copy.
enum ProjectPluginSettings {
    static let filename = "ngv.json"

    static func activePlugin(projectURL: URL?) -> String? {
        guard let projectURL else { return nil }
        let url = projectURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["activePlugin"] as? String, !name.isEmpty else { return nil }
        return name
    }

    static func setActivePlugin(_ name: String?, projectURL: URL) throws {
        let url = projectURL.appendingPathComponent(filename)
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            json = existing
        }
        if let name, !name.isEmpty {
            json["activePlugin"] = name
        } else {
            json.removeValue(forKey: "activePlugin")
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
