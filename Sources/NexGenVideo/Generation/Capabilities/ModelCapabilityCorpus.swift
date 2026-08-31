import Foundation
import NexGenEngine

enum ModelCapabilityCorpusError: Error, Equatable {
    case resourceNotFound
    case invalid(String)
    case ownerConfirmationPending
}

struct ModelCapabilityCorpusSource: Decodable, Sendable {
    let id: String
    let title: String
    let url: String?
    let observedAt: String
    let kind: CapabilityEvidenceKindV1
    let confidence: Double
    let primary: Bool
    let scope: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case observedAt = "observed_at"
        case kind
        case confidence
        case primary
        case scope
    }
}

struct ModelCapabilityCorpusInventoryEntry: Decodable, Sendable {
    let catalogModelID: String
    let provider: String
    let providerModelID: String
    let providerQualifiedAlias: String
    let modality: CapabilityModalityV1
    let origins: [String]
    let sourceIDs: [String]
    let expectedResolution: CapabilityProfileResolutionV1
    let availability: String
    let fixture: Bool
    let familyID: ModelFamilyID?
    let variantID: ModelVariantID?
    let versionID: ModelVersionID?
    let notes: String?

    private enum CodingKeys: String, CodingKey {
        case catalogModelID = "catalog_model_id"
        case provider
        case providerModelID = "provider_model_id"
        case providerQualifiedAlias = "provider_qualified_alias"
        case modality
        case origins
        case sourceIDs = "source_ids"
        case expectedResolution = "expected_resolution"
        case availability
        case fixture
        case familyID = "family_id"
        case variantID = "variant_id"
        case versionID = "version_id"
        case notes
    }
}

struct ModelCapabilityCorpusProfileGaps: Decodable, Sendable {
    let identity: ModelCapabilityIdentityV1
    let fields: [String: String]
}

struct ModelCapabilityDefensiveDefaults: Decodable, Sendable {
    struct Table: Decodable, Sendable, Equatable {
        let characterAndPrimaryReferenceCounts: Int
        let imageOutputsPerRequest: Int
        let otherIntegerCounts: Int
        let durationMinimumSeconds: Double
        let durationMaximumSeconds: Double
        let booleans: Bool
        let sets: [String]

        private enum CodingKeys: String, CodingKey {
            case characterAndPrimaryReferenceCounts = "character_and_primary_reference_counts"
            case imageOutputsPerRequest = "image_outputs_per_request"
            case otherIntegerCounts = "other_integer_counts"
            case durationMinimumSeconds = "duration_minimum_seconds"
            case durationMaximumSeconds = "duration_maximum_seconds"
            case booleans
            case sets
        }
    }

    let ownerConfirmation: String
    let table: Table

    private enum CodingKeys: String, CodingKey {
        case ownerConfirmation = "owner_confirmation"
        case table
    }
}

struct ModelCapabilityUnavailableInventory: Decodable, Sendable {
    let provider: String
    let reason: String
}

struct ModelCapabilityCorpusDocument: Decodable, Sendable {
    static let schemaVersion = "model-capability-corpus/v1"

    let schema: String
    let observedAt: String
    let staleAfterDays: Int
    let defensiveDefaults: ModelCapabilityDefensiveDefaults
    let sources: [ModelCapabilityCorpusSource]
    let inventory: [ModelCapabilityCorpusInventoryEntry]
    let profileGaps: [ModelCapabilityCorpusProfileGaps]
    let knowledgeBase: ModelCapabilityKnowledgeBaseV1
    let unavailableInventories: [ModelCapabilityUnavailableInventory]

    private enum CodingKeys: String, CodingKey {
        case schema
        case observedAt = "observed_at"
        case staleAfterDays = "stale_after_days"
        case defensiveDefaults = "defensive_defaults"
        case sources
        case inventory
        case profileGaps = "profile_gaps"
        case knowledgeBase = "knowledge_base"
        case unavailableInventories = "unavailable_inventories"
    }

    static func decode(_ data: Data) throws -> Self {
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    func productionKnowledgeBase() throws -> ModelCapabilityKnowledgeBaseV1 {
        guard defensiveDefaults.ownerConfirmation == "confirmed" else {
            throw ModelCapabilityCorpusError.ownerConfirmationPending
        }
        return knowledgeBase
    }

    private func validate() throws {
        guard schema == Self.schemaVersion else {
            throw ModelCapabilityCorpusError.invalid("schema")
        }
        guard Self.isISODate(observedAt), staleAfterDays > 0 else {
            throw ModelCapabilityCorpusError.invalid("inventory_date")
        }
        guard defensiveDefaults.ownerConfirmation == "pending"
                || defensiveDefaults.ownerConfirmation == "confirmed" else {
            throw ModelCapabilityCorpusError.invalid("owner_confirmation")
        }
        _ = try ModelCapabilityResolver(knowledgeBase: knowledgeBase)

        var sourceIDs = Set<String>()
        var sourceTitles = Set<String>()
        var sourcesByTitle: [String: ModelCapabilityCorpusSource] = [:]
        var primarySourceTitles = Set<String>()
        for source in sources {
            guard !source.id.isEmpty,
                  sourceIDs.insert(source.id).inserted,
                  !source.title.isEmpty,
                  sourceTitles.insert(source.title).inserted,
                  !source.scope.isEmpty,
                  Self.isISODate(source.observedAt),
                  (0...1).contains(source.confidence),
                  source.url.map({ URL(string: $0)?.scheme == "https" }) ?? true else {
                throw ModelCapabilityCorpusError.invalid("source")
            }
            if source.primary {
                primarySourceTitles.insert(source.title)
            }
            sourcesByTitle[source.title] = source
        }

        var offers = Set<String>()
        var providerAliases = Set<String>()
        let resolver = try ModelCapabilityResolver(knowledgeBase: knowledgeBase)
        for entry in inventory {
            guard !entry.catalogModelID.isEmpty,
                  !entry.provider.isEmpty,
                  !entry.providerModelID.isEmpty,
                  entry.providerQualifiedAlias == "\(entry.provider)::\(entry.providerModelID)",
                  !entry.origins.isEmpty,
                  !entry.sourceIDs.isEmpty,
                  Set(entry.sourceIDs).isSubset(of: sourceIDs),
                  ["active", "stale", "research-needed"].contains(entry.availability),
                  providerAliases.insert(entry.providerQualifiedAlias).inserted else {
                throw ModelCapabilityCorpusError.invalid("inventory")
            }
            let offerKey = "\(entry.provider)\u{1f}\(entry.providerModelID)\u{1f}\(entry.modality.rawValue)"
            guard offers.insert(offerKey).inserted else {
                throw ModelCapabilityCorpusError.invalid("duplicate_offer")
            }
            let resolution = try resolver.resolve(
                CapabilityLookupV1(
                    familyID: entry.familyID,
                    variantID: entry.variantID,
                    versionID: entry.versionID,
                    modality: entry.modality,
                    catalogModelID: entry.catalogModelID
                )
            )
            let actual: CapabilityProfileResolutionV1
            if resolution.resolvedIdentity == nil {
                actual = .defensive
            } else if resolution.requestedIdentity == resolution.resolvedIdentity {
                actual = .exact
            } else {
                actual = .inherited
            }
            guard actual == entry.expectedResolution else {
                throw ModelCapabilityCorpusError.invalid("expected_resolution")
            }
            if actual == .exact {
                guard resolution.resolvedIdentity?.familyID == entry.familyID,
                      resolution.resolvedIdentity?.variantID == entry.variantID,
                      resolution.resolvedIdentity?.versionID == entry.versionID else {
                    throw ModelCapabilityCorpusError.invalid("exact_identity")
                }
                for alias in [
                    entry.catalogModelID,
                    entry.providerModelID,
                    entry.providerQualifiedAlias,
                ] {
                    let aliased = try resolver.resolve(
                        CapabilityLookupV1(modality: entry.modality, catalogModelID: alias)
                    )
                    guard aliased.resolvedIdentity == resolution.resolvedIdentity else {
                        throw ModelCapabilityCorpusError.invalid("canonical_alias")
                    }
                }
            }
        }

        let profiles = Dictionary(
            uniqueKeysWithValues: knowledgeBase.profiles.map { ($0.identity, $0) }
        )
        var gapsByIdentity: [ModelCapabilityIdentityV1: [String: String]] = [:]
        for gapRecord in profileGaps {
            guard profiles[gapRecord.identity] != nil,
                  gapsByIdentity.updateValue(gapRecord.fields, forKey: gapRecord.identity) == nil,
                  gapRecord.fields.values.allSatisfy({ !$0.isEmpty }) else {
                throw ModelCapabilityCorpusError.invalid("profile_gaps")
            }
            for fieldID in gapRecord.fields.keys {
                guard let definition = CapabilityFieldRegistryV1.byID[fieldID],
                      definition.modalities.contains(gapRecord.identity.modality) else {
                    throw ModelCapabilityCorpusError.invalid("profile_gap_field")
                }
            }
        }

        for profile in knowledgeBase.profiles {
            let fieldIDs = Self.fieldIDs(profile.fields)
            let gapIDs = Set(gapsByIdentity[profile.identity, default: [:]].keys)
            let requiredIDs = Set(
                CapabilityFieldRegistryV1.requiredDefensiveFields(for: profile.identity.modality)
                    .map(\.id)
            )
            guard fieldIDs.isDisjoint(with: gapIDs),
                  fieldIDs.union(gapIDs) == requiredIDs else {
                throw ModelCapabilityCorpusError.invalid("profile_field_coverage")
            }
            let evidenceGroups = Self.evidenceGroups(profile.fields)
            guard !evidenceGroups.isEmpty,
                  evidenceGroups.allSatisfy({ evidence in
                      !evidence.isEmpty
                          && evidence.allSatisfy({ item in
                              guard let source = sourcesByTitle[item.sourceTitle] else {
                                  return false
                              }
                              return item.observedAt == source.observedAt
                                  && item.sourceURL == source.url
                                  && item.kind == source.kind
                                  && item.confidence == source.confidence
                                  && Self.isISODate(item.observedAt)
                                  && !item.evidenceSourceIsInvalid
                          })
                          && evidence.contains(where: {
                              primarySourceTitles.contains($0.sourceTitle)
                          })
                  }) else {
                throw ModelCapabilityCorpusError.invalid("profile_evidence")
            }
        }
        for profile in knowledgeBase.defensiveProfiles {
            let evidenceGroups = Self.evidenceGroups(profile.fields)
            guard !evidenceGroups.isEmpty,
                  evidenceGroups.allSatisfy({ evidence in
                      !evidence.isEmpty
                          && evidence.allSatisfy({ item in
                              guard let source = sourcesByTitle[item.sourceTitle] else {
                                  return false
                              }
                              return item.observedAt == source.observedAt
                                  && item.sourceURL == source.url
                                  && item.kind == source.kind
                                  && item.confidence == source.confidence
                          })
                  }) else {
                throw ModelCapabilityCorpusError.invalid("defensive_evidence")
            }
        }

        var unavailableProviders = Set<String>()
        for unavailable in unavailableInventories {
            guard !unavailable.provider.isEmpty,
                  !unavailable.reason.isEmpty,
                  unavailableProviders.insert(unavailable.provider).inserted else {
                throw ModelCapabilityCorpusError.invalid("unavailable_inventory")
            }
        }
    }

    private static func fieldIDs(_ fields: CapabilityFieldsV1) -> Set<String> {
        Set(fields.integers.keys)
            .union(fields.decimals.keys)
            .union(fields.booleans.keys)
            .union(fields.strings.keys)
            .union(fields.integerLists.keys)
    }

    private static func evidenceGroups(
        _ fields: CapabilityFieldsV1
    ) -> [[CapabilityEvidenceV1]] {
        fields.integers.values.map { $0.evidence }
            + fields.decimals.values.map { $0.evidence }
            + fields.booleans.values.map { $0.evidence }
            + fields.strings.values.map { $0.evidence }
            + fields.integerLists.values.map { $0.evidence }
    }

    private static func isISODate(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else {
            return false
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }
}

private extension CapabilityEvidenceV1 {
    var evidenceSourceIsInvalid: Bool {
        !(0...1).contains(confidence)
            || sourceTitle.isEmpty
            || sourceURL.map({ URL(string: $0)?.scheme == "https" }) == false
    }
}

enum BundledModelCapabilityCorpus {
    static func load() throws -> ModelCapabilityCorpusDocument {
        for bundle in [Bundle.main, Bundle.module] {
            if let url = bundle.url(
                forResource: "model-capability-corpus-v1",
                withExtension: "json",
                subdirectory: "ModelCapabilities"
            ) {
                return try ModelCapabilityCorpusDocument.decode(Data(contentsOf: url))
            }
        }
        throw ModelCapabilityCorpusError.resourceNotFound
    }
}
