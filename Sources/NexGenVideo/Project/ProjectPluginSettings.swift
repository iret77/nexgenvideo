import Foundation

/// Persists per-project format settings in the package or live working copy.
enum ProjectPluginSettings {
    static let filename = "ngv.json"

    enum Resolution: Equatable {
        case absent
        case active(String)
        case unreadable
    }

    static func resolution(projectURL: URL?) -> Resolution {
        guard let projectURL else { return .absent }
        let url = projectURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            return .unreadable
        }
        guard let value = json["activePlugin"] else {
            return .absent
        }
        guard let name = value as? String else {
            return .unreadable
        }
        let normalized = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return .unreadable }
        return .active(normalized)
    }

    static func activePlugin(projectURL: URL?) -> String? {
        guard case .active(let name) = resolution(
            projectURL: projectURL
        ) else { return nil }
        return name
    }

    static func resolvedPlugin(
        projectURL: URL?,
        declaredPack: String?
    ) throws -> String? {
        switch resolution(projectURL: projectURL) {
        case .absent:
            if let declaredPack {
                throw ProjectPluginResolutionError.missing(
                    declared: declaredPack
                )
            }
            return nil
        case .active(let name):
            if let declaredPack, declaredPack != name {
                throw ProjectPluginResolutionError.mismatch(
                    declared: declaredPack,
                    resolved: name
                )
            }
            return name
        case .unreadable:
            throw ProjectPluginResolutionError.unreadable
        }
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
        if let name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            json["activePlugin"] = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        } else {
            json.removeValue(forKey: "activePlugin")
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

enum ProjectPluginResolutionError: LocalizedError {
    case unreadable
    case missing(declared: String)
    case mismatch(declared: String, resolved: String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The project format settings are unreadable. Repair or restore ngv.json."
        case .missing(let declared):
            "The project declares the \(declared) format, but its live working copy "
                + "has no format settings. Reopen or restore the project."
        case .mismatch(let declared, let resolved):
            "The project declares the \(declared) format, but its live working copy "
                + "resolves \(resolved). Reopen or restore the project."
        }
    }
}
