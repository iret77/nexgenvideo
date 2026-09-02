import Foundation

public struct ProductionKnowledgeVersionV1: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

extension ProductionKnowledgeVersionV1: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProductionProfileDescriptorIDV1: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

extension ProductionProfileDescriptorIDV1: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CreativeKnowledgeLibraryIDV1: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

extension CreativeKnowledgeLibraryIDV1: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CreativeKnowledgeEntryIDV1: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

extension CreativeKnowledgeEntryIDV1: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProductionKnowledgeApplicabilityV1: Codable, Sendable, Equatable {
    public let packIDs: [String]
    public let phases: [String]
    public let intentTags: [String]
    public let activeProfileIDs: [ProductionProfileDescriptorIDV1]

    public init(
        packIDs: [String],
        phases: [String],
        intentTags: [String],
        activeProfileIDs: [ProductionProfileDescriptorIDV1]
    ) {
        self.packIDs = packIDs
        self.phases = phases
        self.intentTags = intentTags
        self.activeProfileIDs = activeProfileIDs
    }
}

public struct ProductionKnowledgeInputV1: Codable, Sendable, Equatable {
    public let role: String
    public let purpose: String
    public let required: Bool

    public init(role: String, purpose: String, required: Bool) {
        self.role = role
        self.purpose = purpose
        self.required = required
    }
}

public struct ProductionKnowledgeProvenanceV1: Codable, Sendable, Equatable {
    public let sourceURL: String
    public let sourceCommit: String
    public let sourceSections: [String]
    public let adaptation: String

    public init(
        sourceURL: String,
        sourceCommit: String,
        sourceSections: [String],
        adaptation: String
    ) {
        self.sourceURL = sourceURL
        self.sourceCommit = sourceCommit
        self.sourceSections = sourceSections
        self.adaptation = adaptation
    }
}

public struct ProductionKnowledgeLicenseV1: Codable, Sendable, Equatable {
    public let spdxIdentifier: String
    public let copyrightNotice: String
    public let sourceURL: String

    public init(spdxIdentifier: String, copyrightNotice: String, sourceURL: String) {
        self.spdxIdentifier = spdxIdentifier
        self.copyrightNotice = copyrightNotice
        self.sourceURL = sourceURL
    }
}

public enum ProductionKnowledgeResourceKindV1: String, Codable, Sendable, Equatable {
    case profile
    case library
}

public struct ProductionKnowledgeResourceReferenceV1: Codable, Sendable, Equatable {
    public let kind: ProductionKnowledgeResourceKindV1
    public let id: String
    public let version: ProductionKnowledgeVersionV1
    public let path: String
    public let sha256: String

    public init(
        kind: ProductionKnowledgeResourceKindV1,
        id: String,
        version: ProductionKnowledgeVersionV1,
        path: String,
        sha256: String
    ) {
        self.kind = kind
        self.id = id
        self.version = version
        self.path = path
        self.sha256 = sha256
    }
}

public struct ProductionKnowledgeManifestV1: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let resources: [ProductionKnowledgeResourceReferenceV1]

    public init(schemaVersion: String, resources: [ProductionKnowledgeResourceReferenceV1]) {
        self.schemaVersion = schemaVersion
        self.resources = resources
    }
}

public struct ProductionPhaseGuidanceV1: Codable, Sendable, Equatable {
    public let phase: String
    public let instructions: [String]

    public init(phase: String, instructions: [String]) {
        self.phase = phase
        self.instructions = instructions
    }
}

public enum ProductionMachineRuleSeverityV1: String, Codable, Sendable, Equatable {
    case error
    case warning
}

public struct ProductionMachineRuleV1: Codable, Sendable, Equatable {
    public let id: String
    public let phase: String
    public let severity: ProductionMachineRuleSeverityV1
    public let predicateID: String
    public let message: String

    public init(
        id: String,
        phase: String,
        severity: ProductionMachineRuleSeverityV1,
        predicateID: String,
        message: String
    ) {
        self.id = id
        self.phase = phase
        self.severity = severity
        self.predicateID = predicateID
        self.message = message
    }
}

public struct ProductionProfileDescriptorV1: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let id: ProductionProfileDescriptorIDV1
    public let version: ProductionKnowledgeVersionV1
    public let applicability: ProductionKnowledgeApplicabilityV1
    public let phaseGuidance: [ProductionPhaseGuidanceV1]
    public let machineRules: [ProductionMachineRuleV1]
    public let provenance: ProductionKnowledgeProvenanceV1
    public let license: ProductionKnowledgeLicenseV1

    public init(
        schemaVersion: String,
        id: ProductionProfileDescriptorIDV1,
        version: ProductionKnowledgeVersionV1,
        applicability: ProductionKnowledgeApplicabilityV1,
        phaseGuidance: [ProductionPhaseGuidanceV1],
        machineRules: [ProductionMachineRuleV1],
        provenance: ProductionKnowledgeProvenanceV1,
        license: ProductionKnowledgeLicenseV1
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.applicability = applicability
        self.phaseGuidance = phaseGuidance
        self.machineRules = machineRules
        self.provenance = provenance
        self.license = license
    }
}

public struct EffectiveProductionProfileV1: Sendable, Equatable {
    public let descriptors: [ProductionProfileDescriptorV1]
    public let phaseGuidance: [ProductionPhaseGuidanceV1]
    public let machineRules: [ProductionMachineRuleV1]

    public init(descriptors: [ProductionProfileDescriptorV1]) throws {
        for (id, matches) in Dictionary(grouping: descriptors, by: { $0.id.rawValue })
            where matches.count > 1 {
            throw ProductionKnowledgeErrorV1.conflictingResource(
                kind: "profile",
                id: id,
                versions: matches.map { $0.version.rawValue }.sorted()
            )
        }
        let ordered = descriptors.sorted {
            if $0.id.rawValue == $1.id.rawValue {
                return $0.version.rawValue < $1.version.rawValue
            }
            return $0.id.rawValue < $1.id.rawValue
        }
        let rules = ordered.flatMap(\.machineRules)
        let duplicateRuleIDs = Dictionary(grouping: rules, by: \.id)
            .filter { $0.value.count > 1 }
            .map { $0.key }
            .sorted()
        guard duplicateRuleIDs.isEmpty else {
            throw ProductionKnowledgeErrorV1.invalidValue(
                path: "effectiveProfile.machineRules.id",
                reason: "duplicate rule identifiers: \(duplicateRuleIDs.joined(separator: ", "))"
            )
        }
        self.descriptors = ordered
        phaseGuidance = ordered.flatMap(\.phaseGuidance)
        machineRules = rules
    }
}

public struct CreativeKnowledgeEntryV1: Codable, Sendable, Equatable {
    public let id: CreativeKnowledgeEntryIDV1
    public let title: String
    public let applicability: ProductionKnowledgeApplicabilityV1
    public let inputs: [ProductionKnowledgeInputV1]
    public let outputIntent: String
    public let guidance: [String]
    public let verifyCriteria: [String]
    public let incompatibilities: [String]

    public init(
        id: CreativeKnowledgeEntryIDV1,
        title: String,
        applicability: ProductionKnowledgeApplicabilityV1,
        inputs: [ProductionKnowledgeInputV1],
        outputIntent: String,
        guidance: [String],
        verifyCriteria: [String],
        incompatibilities: [String]
    ) {
        self.id = id
        self.title = title
        self.applicability = applicability
        self.inputs = inputs
        self.outputIntent = outputIntent
        self.guidance = guidance
        self.verifyCriteria = verifyCriteria
        self.incompatibilities = incompatibilities
    }
}

public struct CreativeKnowledgeLibraryV1: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let id: CreativeKnowledgeLibraryIDV1
    public let version: ProductionKnowledgeVersionV1
    public let applicability: ProductionKnowledgeApplicabilityV1
    public let entries: [CreativeKnowledgeEntryV1]
    public let provenance: ProductionKnowledgeProvenanceV1
    public let license: ProductionKnowledgeLicenseV1

    public init(
        schemaVersion: String,
        id: CreativeKnowledgeLibraryIDV1,
        version: ProductionKnowledgeVersionV1,
        applicability: ProductionKnowledgeApplicabilityV1,
        entries: [CreativeKnowledgeEntryV1],
        provenance: ProductionKnowledgeProvenanceV1,
        license: ProductionKnowledgeLicenseV1
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.applicability = applicability
        self.entries = entries
        self.provenance = provenance
        self.license = license
    }
}
