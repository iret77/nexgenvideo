import Foundation
import NexGenEngine

struct ProjectPackBinding: Codable, Equatable, Sendable {
    let id: String
    let version: String
    let projectSchema: String

    private enum CodingKeys: String, CodingKey {
        case id, version, projectSchema
    }

    init?(id: String, version: String, projectSchema: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSchema = projectSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemaParts = normalizedSchema.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard PluginPaths.isValidID(normalizedID),
              SemanticVersion(normalizedVersion) != nil,
              schemaParts.count == 2,
              schemaParts[0] == Substring(normalizedID),
              (
                  schemaParts[1] == "legacy"
                      || SemanticVersion(String(schemaParts[1])) != nil
              ) else {
            return nil
        }
        self.id = normalizedID
        self.version = normalizedVersion
        self.projectSchema = normalizedSchema
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let version = try values.decode(String.self, forKey: .version)
        let schema = try values.decode(String.self, forKey: .projectSchema)
        guard let valid = Self(
            id: id,
            version: version,
            projectSchema: schema
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid project pack binding"
                )
            )
        }
        self = valid
    }
}

/// Persists per-project format settings in the package or live working copy.
enum ProjectPluginSettings {
    static let filename = "ngv.json"
    private static let pluginKey = "activePlugin"
    private static let versionKey = "activePluginVersion"
    private static let schemaKey = "activePluginProjectSchema"

    enum Resolution: Equatable {
        case absent
        case active(String)
        case unreadable
    }

    enum BindingResolution: Equatable {
        case absent
        case legacy(String)
        case bound(ProjectPackBinding)
        case unreadable
    }

    static func bindingResolution(projectURL: URL?) -> BindingResolution {
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
        guard let value = json[pluginKey] else {
            return .absent
        }
        guard let name = value as? String else {
            return .unreadable
        }
        let normalized = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return .unreadable }
        let version = json[versionKey]
        let schema = json[schemaKey]
        if version == nil, schema == nil {
            return PluginPaths.isValidID(normalized) ? .legacy(normalized) : .unreadable
        }
        guard let version = version as? String,
              let schema = schema as? String,
              let binding = ProjectPackBinding(
                  id: normalized,
                  version: version,
                  projectSchema: schema
              ) else {
            return .unreadable
        }
        return .bound(binding)
    }

    static func resolution(projectURL: URL?) -> Resolution {
        switch bindingResolution(projectURL: projectURL) {
        case .absent:
            return .absent
        case .legacy(let id):
            return .active(id)
        case .bound(let binding):
            return .active(binding.id)
        case .unreadable:
            return .unreadable
        }
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
        try writePlugin(name, binding: nil, projectURL: projectURL)
    }

    static func setActivePlugin(
        _ binding: ProjectPackBinding?,
        projectURL: URL
    ) throws {
        try writePlugin(binding?.id, binding: binding, projectURL: projectURL)
    }

    private static func writePlugin(
        _ name: String?,
        binding: ProjectPackBinding?,
        projectURL: URL
    ) throws {
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
            json[pluginKey] = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let binding {
                json[versionKey] = binding.version
                json[schemaKey] = binding.projectSchema
            } else {
                json.removeValue(forKey: versionKey)
                json.removeValue(forKey: schemaKey)
            }
        } else {
            json.removeValue(forKey: pluginKey)
            json.removeValue(forKey: versionKey)
            json.removeValue(forKey: schemaKey)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .projectPackBindingChanged,
                object: projectURL
            )
        }
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
