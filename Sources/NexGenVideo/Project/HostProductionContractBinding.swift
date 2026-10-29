import Foundation
import NexGenEngine

struct HostProductionContractBinding: Codable, Equatable, Sendable {
    let id: String
    let version: String

    static let current = HostProductionContractBinding(id: "core.production.v2", version: "2.0.0")!

    init?(id: String, version: String) {
        guard !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || [45, 46].contains($0) }),
              SemanticVersion(version) != nil else { return nil }
        self.id = id
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case id, version }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(id: try values.decode(String.self, forKey: .id),
                               version: try values.decode(String.self, forKey: .version)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid production contract binding"))
        }
        self = value
    }
}

extension ProjectPluginSettings {
    enum ProductionContractResolution: Equatable, Sendable {
        case absent
        case bound(HostProductionContractBinding)
        case unreadable
    }

    static func productionContractResolution(projectURL: URL?) -> ProductionContractResolution {
        guard let projectURL else { return .absent }
        let url = projectURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        guard let raw = json["productionContract"] else { return .absent }
        guard let object = raw as? [String: Any], Set(object.keys) == ["id", "version"],
              let id = object["id"] as? String, let version = object["version"] as? String,
              let value = HostProductionContractBinding(id: id, version: version) else { return .unreadable }
        return .bound(value)
    }

    static func setProductionContract(_ binding: HostProductionContractBinding?, projectURL: URL) throws {
        let url = projectURL.appendingPathComponent(filename)
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            json = existing
        }
        if let binding {
            guard binding == .current, case .absent = bindingResolution(projectURL: projectURL) else {
                throw ProjectFormatSettingsUnavailableError(problem: "conflict with the selected production workflow")
            }
            json["productionContract"] = ["id": binding.id, "version": binding.version]
        } else { json.removeValue(forKey: "productionContract") }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    static func requireProductionContract(projectURL: URL, declared: HostProductionContractBinding?,
                                          declaredPack: String?) throws {
        let expected: ProductionContractResolution = declared.map(ProductionContractResolution.bound) ?? .absent
        let actual = productionContractResolution(projectURL: projectURL)
        if actual == .unreadable { throw ProjectFormatSettingsUnavailableError() }
        guard actual == expected,
              declared == nil || (declared == .current && declaredPack == nil) else {
            throw ProjectFormatSettingsUnavailableError(problem: "do not match the production workflow trusted by this session")
        }
    }

    static func validateProductionContractForOpen(projectURL: URL) throws {
        switch productionContractResolution(projectURL: projectURL) {
        case .absent: return
        case .unreadable: throw ProjectFormatSettingsUnavailableError()
        case .bound(let binding):
            guard binding == .current, case .absent = bindingResolution(projectURL: projectURL) else {
                throw ProjectFormatSettingsUnavailableError(problem: "declare an unavailable or conflicting production workflow")
            }
        }
    }
}
