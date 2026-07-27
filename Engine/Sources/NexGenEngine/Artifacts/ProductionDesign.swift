import Foundation

public let productionDesignSchemaVersion = "production_design/v1"

public struct ProductionDesignReference: Codable, Sendable, Equatable {
    public var path: String
    public var note: String

    public init(path: String, note: String = "") {
        self.path = path
        self.note = note
    }
}

public struct ProductionDesign: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    public var generated: String
    public var generator: String
    public var visualMedium: VisualMedium
    public var visualMediumNotes: String
    public var refs: [ProductionDesignReference]
    public var colorScript: [String: String]
    public var lightingAnchor: String
    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case generated
        case generator
        case visualMedium = "visual_medium"
        case visualMediumNotes = "visual_medium_notes"
        case refs
        case colorScript = "color_script"
        case lightingAnchor = "lighting_anchor"
        case notes
    }

    public init(
        schema: String = productionDesignSchemaVersion,
        project: String,
        generated: String,
        generator: String,
        visualMedium: VisualMedium,
        visualMediumNotes: String = "",
        refs: [ProductionDesignReference] = [],
        colorScript: [String: String] = [:],
        lightingAnchor: String = "",
        notes: String? = nil
    ) throws {
        self.schema = schema
        self.project = project
        self.generated = generated
        self.generator = generator
        self.visualMedium = visualMedium
        self.visualMediumNotes = visualMediumNotes
        self.refs = refs
        self.colorScript = colorScript
        self.lightingAnchor = lightingAnchor
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
            ?? productionDesignSchemaVersion
        project = try container.decode(String.self, forKey: .project)
        generated = try container.decode(String.self, forKey: .generated)
        generator = try container.decode(String.self, forKey: .generator)
        visualMedium = try container.decode(VisualMedium.self, forKey: .visualMedium)
        visualMediumNotes = try container.decodeIfPresent(
            String.self,
            forKey: .visualMediumNotes
        ) ?? ""
        refs = try container.decodeIfPresent(
            [ProductionDesignReference].self,
            forKey: .refs
        ) ?? []
        colorScript = try container.decodeIfPresent(
            [String: String].self,
            forKey: .colorScript
        ) ?? [:]
        lightingAnchor = try container.decodeIfPresent(
            String.self,
            forKey: .lightingAnchor
        ) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case wrongSchema(String)
        case emptyProject
        case emptyReferencePath
        case emptyStyleLayer
    }

    public func validate() throws {
        guard schema == productionDesignSchemaVersion else {
            throw ValidationError.wrongSchema(schema)
        }
        guard !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProject
        }
        guard refs.allSatisfy({
            !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ValidationError.emptyReferencePath
        }
        guard !refs.isEmpty
            || !colorScript.isEmpty
            || !lightingAnchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyStyleLayer
        }
    }
}
