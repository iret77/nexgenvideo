import Foundation

public enum ResolvedCapabilityOriginKindV1: String, Codable, Hashable, Sendable {
    case exact
    case inherited
    case defensive
    case endpointOverlay = "endpoint_overlay"
}

public struct ResolvedCapabilityOriginV1: Codable, Sendable, Equatable {
    public let kind: ResolvedCapabilityOriginKindV1
    public let profileID: String
    public let versionID: ModelVersionID?
    public let endpointID: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case profileID = "profile_id"
        case versionID = "version_id"
        case endpointID = "endpoint_id"
    }

    public init(
        kind: ResolvedCapabilityOriginKindV1,
        profileID: String,
        versionID: ModelVersionID? = nil,
        endpointID: String? = nil
    ) {
        self.kind = kind
        self.profileID = profileID
        self.versionID = versionID
        self.endpointID = endpointID
    }
}

public struct ResolvedCapabilityValueV1<Value>: Codable, Sendable, Equatable
where Value: Codable & Sendable & Equatable {
    public let value: Value
    public let semantics: CapabilityValueSemanticsV1
    public let origin: ResolvedCapabilityOriginV1
    public let evidence: [CapabilityEvidenceV1]

    public init(
        value: Value,
        semantics: CapabilityValueSemanticsV1,
        origin: ResolvedCapabilityOriginV1,
        evidence: [CapabilityEvidenceV1]
    ) {
        self.value = value
        self.semantics = semantics
        self.origin = origin
        self.evidence = evidence
    }
}

public struct ResolvedCapabilityFieldsV1: Codable, Sendable, Equatable {
    public var integers: [String: ResolvedCapabilityValueV1<Int>]
    public var decimals: [String: ResolvedCapabilityValueV1<Double>]
    public var booleans: [String: ResolvedCapabilityValueV1<Bool>]
    public var strings: [String: ResolvedCapabilityValueV1<[String]>]
    public var integerLists: [String: ResolvedCapabilityValueV1<[Int]>]

    private enum CodingKeys: String, CodingKey {
        case integers
        case decimals
        case booleans
        case strings
        case integerLists = "integer_lists"
    }

    public init(
        integers: [String: ResolvedCapabilityValueV1<Int>] = [:],
        decimals: [String: ResolvedCapabilityValueV1<Double>] = [:],
        booleans: [String: ResolvedCapabilityValueV1<Bool>] = [:],
        strings: [String: ResolvedCapabilityValueV1<[String]>] = [:],
        integerLists: [String: ResolvedCapabilityValueV1<[Int]>] = [:]
    ) {
        self.integers = integers
        self.decimals = decimals
        self.booleans = booleans
        self.strings = strings
        self.integerLists = integerLists
    }
}

public struct ResolvedCapabilityProfileV1: Codable, Sendable, Equatable {
    public let requestedIdentity: ModelCapabilityIdentityV1?
    public let resolvedIdentity: ModelCapabilityIdentityV1?
    public let defensiveProfileID: String?
    public let researchNeeded: Bool
    public let fields: ResolvedCapabilityFieldsV1

    private enum CodingKeys: String, CodingKey {
        case requestedIdentity = "requested_identity"
        case resolvedIdentity = "resolved_identity"
        case defensiveProfileID = "defensive_profile_id"
        case researchNeeded = "research_needed"
        case fields
    }

    public init(
        requestedIdentity: ModelCapabilityIdentityV1?,
        resolvedIdentity: ModelCapabilityIdentityV1?,
        defensiveProfileID: String?,
        researchNeeded: Bool,
        fields: ResolvedCapabilityFieldsV1
    ) {
        self.requestedIdentity = requestedIdentity
        self.resolvedIdentity = resolvedIdentity
        self.defensiveProfileID = defensiveProfileID
        self.researchNeeded = researchNeeded
        self.fields = fields
    }
}

public struct CapabilityOfferingIdentityV1: Codable, Hashable, Sendable, Equatable {
    public let providerID: String
    public let offeringID: String
    public let endpointID: String
    public let catalogModelID: String
    public let modality: CapabilityModalityV1

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case offeringID = "offering_id"
        case endpointID = "endpoint_id"
        case catalogModelID = "catalog_model_id"
        case modality
    }

    public init(
        providerID: String,
        offeringID: String,
        endpointID: String,
        catalogModelID: String,
        modality: CapabilityModalityV1
    ) {
        self.providerID = providerID
        self.offeringID = offeringID
        self.endpointID = endpointID
        self.catalogModelID = catalogModelID
        self.modality = modality
    }
}

public struct ResolvedOfferingCapabilityProfileV1: Codable, Sendable, Equatable {
    public let offering: CapabilityOfferingIdentityV1
    public let intrinsic: ResolvedCapabilityProfileV1
    public let effective: ResolvedCapabilityProfileV1

    public init(
        offering: CapabilityOfferingIdentityV1,
        intrinsic: ResolvedCapabilityProfileV1,
        effective: ResolvedCapabilityProfileV1
    ) {
        self.offering = offering
        self.intrinsic = intrinsic
        self.effective = effective
    }
}

public struct EndpointArrayConstraintV1: Codable, Sendable, Equatable {
    public let isPresent: Bool
    public let maxItems: Int?

    private enum CodingKeys: String, CodingKey {
        case isPresent = "is_present"
        case maxItems = "max_items"
    }

    public init(isPresent: Bool, maxItems: Int? = nil) {
        self.isPresent = isPresent
        self.maxItems = maxItems
    }
}

public enum EndpointNumericRestrictionOperationV1: String, Codable, Sendable, Equatable {
    case minimum
    case maximum
}

public struct EndpointIntegerRestrictionV1: Codable, Sendable, Equatable {
    public let value: Int
    public let operation: EndpointNumericRestrictionOperationV1
    public let evidence: [CapabilityEvidenceV1]

    public init(
        value: Int,
        operation: EndpointNumericRestrictionOperationV1,
        evidence: [CapabilityEvidenceV1]
    ) {
        self.value = value
        self.operation = operation
        self.evidence = evidence
    }
}

public struct EndpointDecimalRestrictionV1: Codable, Sendable, Equatable {
    public let value: Double
    public let operation: EndpointNumericRestrictionOperationV1
    public let evidence: [CapabilityEvidenceV1]

    public init(
        value: Double,
        operation: EndpointNumericRestrictionOperationV1,
        evidence: [CapabilityEvidenceV1]
    ) {
        self.value = value
        self.operation = operation
        self.evidence = evidence
    }
}

public struct EndpointBooleanRestrictionV1: Codable, Sendable, Equatable {
    public let value: Bool
    public let evidence: [CapabilityEvidenceV1]

    public init(value: Bool, evidence: [CapabilityEvidenceV1]) {
        self.value = value
        self.evidence = evidence
    }
}

public struct EndpointStringListRestrictionV1: Codable, Sendable, Equatable {
    public let values: [String]
    public let evidence: [CapabilityEvidenceV1]

    public init(values: [String], evidence: [CapabilityEvidenceV1]) {
        self.values = values
        self.evidence = evidence
    }
}

public struct EndpointIntegerListRestrictionV1: Codable, Sendable, Equatable {
    public let values: [Int]
    public let evidence: [CapabilityEvidenceV1]

    public init(values: [Int], evidence: [CapabilityEvidenceV1]) {
        self.values = values
        self.evidence = evidence
    }
}

public struct EndpointCapabilityRestrictionsV1: Codable, Sendable, Equatable {
    public let integers: [String: EndpointIntegerRestrictionV1]
    public let decimals: [String: EndpointDecimalRestrictionV1]
    public let booleans: [String: EndpointBooleanRestrictionV1]
    public let strings: [String: EndpointStringListRestrictionV1]
    public let integerLists: [String: EndpointIntegerListRestrictionV1]

    private enum CodingKeys: String, CodingKey {
        case integers
        case decimals
        case booleans
        case strings
        case integerLists = "integer_lists"
    }

    public init(
        integers: [String: EndpointIntegerRestrictionV1] = [:],
        decimals: [String: EndpointDecimalRestrictionV1] = [:],
        booleans: [String: EndpointBooleanRestrictionV1] = [:],
        strings: [String: EndpointStringListRestrictionV1] = [:],
        integerLists: [String: EndpointIntegerListRestrictionV1] = [:]
    ) {
        self.integers = integers
        self.decimals = decimals
        self.booleans = booleans
        self.strings = strings
        self.integerLists = integerLists
    }
}

public struct EndpointCapabilityOverlayV1: Codable, Sendable, Equatable {
    public let offering: CapabilityOfferingIdentityV1
    public let schemaEvidence: [CapabilityEvidenceV1]
    public let restrictions: EndpointCapabilityRestrictionsV1
    public let arrayConstraints: [String: EndpointArrayConstraintV1]

    private enum CodingKeys: String, CodingKey {
        case offering
        case schemaEvidence = "schema_evidence"
        case restrictions
        case arrayConstraints = "array_constraints"
    }

    public init(
        offering: CapabilityOfferingIdentityV1,
        schemaEvidence: [CapabilityEvidenceV1],
        restrictions: EndpointCapabilityRestrictionsV1 = EndpointCapabilityRestrictionsV1(),
        arrayConstraints: [String: EndpointArrayConstraintV1] = [:]
    ) {
        self.offering = offering
        self.schemaEvidence = schemaEvidence
        self.restrictions = restrictions
        self.arrayConstraints = arrayConstraints
    }
}
