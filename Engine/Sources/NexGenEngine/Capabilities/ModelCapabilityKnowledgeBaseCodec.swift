import Foundation

public enum ModelCapabilityKnowledgeBaseCodec {
    public static func decode(_ data: Data) throws -> ModelCapabilityKnowledgeBaseV1 {
        let knowledgeBase = try JSONDecoder().decode(ModelCapabilityKnowledgeBaseV1.self, from: data)
        try ModelCapabilityResolver.validate(knowledgeBase)
        return knowledgeBase
    }

    public static func encode(_ knowledgeBase: ModelCapabilityKnowledgeBaseV1) throws -> Data {
        try ModelCapabilityResolver.validate(knowledgeBase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(knowledgeBase)
    }
}

public enum CapabilityProfileResolutionV1: String, Codable, Sendable, Equatable {
    case exact
    case inherited
    case defensive
}

public struct CatalogCapabilityAuditInputV1: Codable, Sendable, Equatable {
    public let catalogModelID: String
    public let modality: CapabilityModalityV1
    public let familyID: ModelFamilyID?
    public let variantID: ModelVariantID?
    public let versionID: ModelVersionID?

    private enum CodingKeys: String, CodingKey {
        case catalogModelID = "catalog_model_id"
        case modality
        case familyID = "family_id"
        case variantID = "variant_id"
        case versionID = "version_id"
    }

    public init(
        catalogModelID: String,
        modality: CapabilityModalityV1,
        familyID: ModelFamilyID? = nil,
        variantID: ModelVariantID? = nil,
        versionID: ModelVersionID? = nil
    ) {
        self.catalogModelID = catalogModelID
        self.modality = modality
        self.familyID = familyID
        self.variantID = variantID
        self.versionID = versionID
    }
}

public struct CatalogCapabilityAuditRecordV1: Codable, Sendable, Equatable {
    public let catalogModelID: String
    public let resolution: CapabilityProfileResolutionV1
    public let requestedIdentity: ModelCapabilityIdentityV1?
    public let resolvedIdentity: ModelCapabilityIdentityV1?
    public let defensiveProfileID: String?
    public let researchNeeded: Bool
    public let fieldOrigins: [String: ResolvedCapabilityOriginV1]

    private enum CodingKeys: String, CodingKey {
        case catalogModelID = "catalog_model_id"
        case resolution
        case requestedIdentity = "requested_identity"
        case resolvedIdentity = "resolved_identity"
        case defensiveProfileID = "defensive_profile_id"
        case researchNeeded = "research_needed"
        case fieldOrigins = "field_origins"
    }

    public init(
        catalogModelID: String,
        resolution: CapabilityProfileResolutionV1,
        requestedIdentity: ModelCapabilityIdentityV1?,
        resolvedIdentity: ModelCapabilityIdentityV1?,
        defensiveProfileID: String?,
        researchNeeded: Bool,
        fieldOrigins: [String: ResolvedCapabilityOriginV1]
    ) {
        self.catalogModelID = catalogModelID
        self.resolution = resolution
        self.requestedIdentity = requestedIdentity
        self.resolvedIdentity = resolvedIdentity
        self.defensiveProfileID = defensiveProfileID
        self.researchNeeded = researchNeeded
        self.fieldOrigins = fieldOrigins
    }
}

public struct CatalogCapabilityAuditV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "catalog-capability-audit/v1"

    public let schema: String
    public let records: [CatalogCapabilityAuditRecordV1]

    public init(schema: String = schemaVersion, records: [CatalogCapabilityAuditRecordV1]) {
        self.schema = schema
        self.records = records
    }
}

public enum CatalogCapabilityAuditError: Error, Sendable, Equatable {
    case emptyCatalogModelID
    case duplicateCatalogModelID(String)
}

public extension ModelCapabilityResolver {
    func audit(_ inputs: [CatalogCapabilityAuditInputV1]) throws -> CatalogCapabilityAuditV1 {
        var seen = Set<String>()
        var records: [CatalogCapabilityAuditRecordV1] = []
        records.reserveCapacity(inputs.count)

        for input in inputs {
            let catalogModelID = input.catalogModelID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !catalogModelID.isEmpty else {
                throw CatalogCapabilityAuditError.emptyCatalogModelID
            }
            guard seen.insert(catalogModelID).inserted else {
                throw CatalogCapabilityAuditError.duplicateCatalogModelID(catalogModelID)
            }
            let profile = try resolve(
                CapabilityLookupV1(
                    familyID: input.familyID,
                    variantID: input.variantID,
                    versionID: input.versionID,
                    modality: input.modality,
                    catalogModelID: catalogModelID
                )
            )
            records.append(
                CatalogCapabilityAuditRecordV1(
                    catalogModelID: catalogModelID,
                    resolution: resolutionClass(profile),
                    requestedIdentity: profile.requestedIdentity,
                    resolvedIdentity: profile.resolvedIdentity,
                    defensiveProfileID: profile.defensiveProfileID,
                    researchNeeded: profile.researchNeeded,
                    fieldOrigins: fieldOrigins(profile.fields)
                )
            )
        }

        return CatalogCapabilityAuditV1(records: records)
    }

    private func resolutionClass(
        _ profile: ResolvedCapabilityProfileV1
    ) -> CapabilityProfileResolutionV1 {
        guard let resolved = profile.resolvedIdentity else { return .defensive }
        return profile.requestedIdentity == resolved ? .exact : .inherited
    }

    private func fieldOrigins(
        _ fields: ResolvedCapabilityFieldsV1
    ) -> [String: ResolvedCapabilityOriginV1] {
        var result: [String: ResolvedCapabilityOriginV1] = [:]
        for (key, value) in fields.integers { result[key] = value.origin }
        for (key, value) in fields.decimals { result[key] = value.origin }
        for (key, value) in fields.booleans { result[key] = value.origin }
        for (key, value) in fields.strings { result[key] = value.origin }
        for (key, value) in fields.integerLists { result[key] = value.origin }
        return result
    }
}
