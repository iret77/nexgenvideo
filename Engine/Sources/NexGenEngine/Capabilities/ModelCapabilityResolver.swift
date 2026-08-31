import Foundation

public enum ModelCapabilityKnowledgeError: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case emptyIdentifier(String)
    case duplicateProfile(ModelCapabilityIdentityV1)
    case duplicateField(String)
    case incompatibleFieldType(String)
    case missingDefensiveProfile(CapabilityModalityV1)
    case duplicateDefensiveProfile(CapabilityModalityV1)
    case invalidPredecessor(ModelCapabilityIdentityV1)
    case cyclicLineage(ModelCapabilityIdentityV1)
    case ambiguousLatestProfile(family: ModelFamilyID, variant: ModelVariantID)
    case invalidEvidenceConfidence(Double)
    case invalidEvidence(String)
    case invalidFieldSemantics(String)
    case invalidEndpointConstraint(String)
    case unknownField(String)
    case invalidFieldModality(field: String, modality: CapabilityModalityV1)
    case missingDefensiveField(profileID: String, field: String)
    case invalidEndpointMergePolicy(String)
    case invalidOffering(String)
    case invalidAlias(ModelCapabilityIdentityV1)
}

public struct ModelCapabilityResolver: Sendable {
    private let knowledgeBase: ModelCapabilityKnowledgeBaseV1
    private let profilesByIdentity: [ModelCapabilityIdentityV1: ModelCapabilityProfileV1]
    private let defensiveByModality: [CapabilityModalityV1: DefensiveCapabilityProfileV1]

    public init(knowledgeBase: ModelCapabilityKnowledgeBaseV1) throws {
        try Self.validate(knowledgeBase)
        self.knowledgeBase = knowledgeBase
        profilesByIdentity = Dictionary(
            uniqueKeysWithValues: knowledgeBase.profiles.map { ($0.identity, $0) }
        )
        defensiveByModality = Dictionary(
            uniqueKeysWithValues: knowledgeBase.defensiveProfiles.map { ($0.modality, $0) }
        )
    }

    public func resolve(_ lookup: CapabilityLookupV1) throws -> ResolvedCapabilityProfileV1 {
        let requested = resolvedLookupIdentity(lookup)
        let defensive = defensiveByModality[lookup.modality]!

        guard let requested else {
            return ResolvedCapabilityProfileV1(
                requestedIdentity: nil,
                resolvedIdentity: nil,
                defensiveProfileID: defensive.id,
                researchNeeded: true,
                fields: resolvedDefensive(defensive)
            )
        }

        let exact = profilesByIdentity[requested]
        let start: ModelCapabilityProfileV1?
        if let exact {
            start = exact
        } else {
            start = try latestProfile(
                familyID: requested.familyID,
                variantID: requested.variantID,
                modality: requested.modality
            )
        }

        guard let start else {
            return ResolvedCapabilityProfileV1(
                requestedIdentity: requested,
                resolvedIdentity: nil,
                defensiveProfileID: defensive.id,
                researchNeeded: true,
                fields: resolvedDefensive(defensive)
            )
        }

        let chain = lineage(from: start)
        let startIsExact = exact != nil
        let fields = resolveFields(
            chain: chain,
            startIsExact: startIsExact,
            defensive: defensive
        )
        return ResolvedCapabilityProfileV1(
            requestedIdentity: requested,
            resolvedIdentity: start.identity,
            defensiveProfileID: usesDefensive(fields) ? defensive.id : nil,
            researchNeeded: !startIsExact || needsResearch(fields),
            fields: fields
        )
    }

    public func resolveOffering(
        _ offering: CapabilityOfferingIdentityV1,
        lookup: CapabilityLookupV1,
        overlay: EndpointCapabilityOverlayV1? = nil
    ) throws -> ResolvedOfferingCapabilityProfileV1 {
        try Self.validate(offering)
        guard offering.modality == lookup.modality else {
            throw ModelCapabilityKnowledgeError.invalidOffering("modality")
        }
        if let catalogModelID = lookup.catalogModelID,
           catalogModelID != offering.catalogModelID {
            throw ModelCapabilityKnowledgeError.invalidOffering("catalog_model_id")
        }
        let intrinsic = try resolve(lookup)
        guard let overlay else {
            return ResolvedOfferingCapabilityProfileV1(
                offering: offering,
                intrinsic: intrinsic,
                effective: intrinsic
            )
        }
        guard overlay.offering == offering else {
            throw ModelCapabilityKnowledgeError.invalidOffering("overlay_binding")
        }
        let effective = try applying(overlay, to: intrinsic)
        return ResolvedOfferingCapabilityProfileV1(
            offering: offering,
            intrinsic: intrinsic,
            effective: effective
        )
    }

    private func applying(
        _ overlay: EndpointCapabilityOverlayV1,
        to profile: ResolvedCapabilityProfileV1
    ) throws -> ResolvedCapabilityProfileV1 {
        let endpointID = overlay.offering.endpointID
        try Self.validate(overlay.offering)
        guard profile.requestedIdentity?.modality == nil
                || profile.requestedIdentity?.modality == overlay.offering.modality,
              profile.resolvedIdentity?.modality == nil
                || profile.resolvedIdentity?.modality == overlay.offering.modality else {
            throw ModelCapabilityKnowledgeError.invalidOffering("resolved_profile_modality")
        }
        guard !overlay.schemaEvidence.isEmpty else {
            throw ModelCapabilityKnowledgeError.invalidEndpointConstraint("schema_evidence")
        }
        try Self.validateEvidence(overlay.schemaEvidence)
        try Self.validateEvidence(overlay.restrictions)
        try Self.validateEndpointFields(
            overlay.restrictions,
            modality: overlay.offering.modality
        )
        for (field, constraint) in overlay.arrayConstraints {
            try Self.require(field, field: "array_constraint.field")
            guard constraint.maxItems.map({ $0 >= 0 }) ?? true else {
                throw ModelCapabilityKnowledgeError.invalidEndpointConstraint(field)
            }
            let definition = try Self.registeredField(
                field,
                type: .integer,
                modality: overlay.offering.modality
            )
            guard definition.endpointMergePolicy == .maximum else {
                throw ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(field)
            }
        }

        var fields = profile.fields
        fields.integers = restrictIntegers(
            fields.integers,
            with: overlay.restrictions.integers,
            endpointID: endpointID
        )
        fields.decimals = restrictDecimals(
            fields.decimals,
            with: overlay.restrictions.decimals,
            endpointID: endpointID
        )
        fields.booleans = restrictBooleans(
            fields.booleans,
            with: overlay.restrictions.booleans,
            endpointID: endpointID
        )
        fields.strings = restrictStrings(
            fields.strings,
            with: overlay.restrictions.strings,
            endpointID: endpointID
        )
        fields.integerLists = restrictIntegerLists(
            fields.integerLists,
            with: overlay.restrictions.integerLists,
            endpointID: endpointID
        )

        for (fieldID, constraint) in overlay.arrayConstraints {
            let intrinsic = fields.integers[fieldID]
            let effective: Int
            let semantics: CapabilityValueSemanticsV1
            if !constraint.isPresent {
                effective = 0
                semantics = .hardAPILimit
            } else if let maximum = constraint.maxItems {
                guard let intrinsic else { continue }
                effective = Swift.min(intrinsic.value, maximum)
                semantics = maximum < intrinsic.value ? .hardAPILimit : intrinsic.semantics
            } else {
                continue
            }
            fields.integers[fieldID] = ResolvedCapabilityValueV1(
                value: effective,
                semantics: semantics,
                origin: endpointOrigin(
                    endpointID,
                    prior: intrinsic?.origin ?? fallbackOrigin(profile)
                ),
                evidence: (intrinsic?.evidence ?? []) + overlay.schemaEvidence
            )
        }

        return ResolvedCapabilityProfileV1(
            requestedIdentity: profile.requestedIdentity,
            resolvedIdentity: profile.resolvedIdentity,
            defensiveProfileID: profile.defensiveProfileID,
            researchNeeded: profile.researchNeeded,
            fields: fields
        )
    }

    public static func validate(_ knowledgeBase: ModelCapabilityKnowledgeBaseV1) throws {
        guard knowledgeBase.schema == modelCapabilityKnowledgeBaseV1Schema else {
            throw ModelCapabilityKnowledgeError.unsupportedSchema(knowledgeBase.schema)
        }
        var identities = Set<ModelCapabilityIdentityV1>()
        for profile in knowledgeBase.profiles {
            try validate(profile.identity)
            guard identities.insert(profile.identity).inserted else {
                throw ModelCapabilityKnowledgeError.duplicateProfile(profile.identity)
            }
            try validateEvidence(profile.fields)
            try validateRegisteredFields(
                profile.fields,
                modality: profile.identity.modality,
                defensiveProfileID: nil
            )
            guard !semantics(profile.fields).contains(.defensiveDefault) else {
                throw ModelCapabilityKnowledgeError.invalidFieldSemantics("intrinsic_profile")
            }
        }

        var defensiveModalities = Set<CapabilityModalityV1>()
        for profile in knowledgeBase.defensiveProfiles {
            try require(profile.id, field: "defensive_profile.id")
            guard defensiveModalities.insert(profile.modality).inserted else {
                throw ModelCapabilityKnowledgeError.duplicateDefensiveProfile(profile.modality)
            }
            try validateEvidence(profile.fields)
            try validateRegisteredFields(
                profile.fields,
                modality: profile.modality,
                defensiveProfileID: profile.id
            )
            guard semantics(profile.fields).allSatisfy({ $0 == .defensiveDefault }) else {
                throw ModelCapabilityKnowledgeError.invalidFieldSemantics("defensive_profile")
            }
        }

        for alias in knowledgeBase.aliases {
            try require(alias.catalogModelID, field: "alias.catalog_model_id")
            try validate(alias.identity)
            guard identities.contains(alias.identity) else {
                throw ModelCapabilityKnowledgeError.invalidAlias(alias.identity)
            }
        }
        for modality in CapabilityModalityV1.allCases where !defensiveModalities.contains(modality) {
            throw ModelCapabilityKnowledgeError.missingDefensiveProfile(modality)
        }

        let byIdentity = Dictionary(
            uniqueKeysWithValues: knowledgeBase.profiles.map { ($0.identity, $0) }
        )
        for profile in knowledgeBase.profiles {
            guard let predecessorID = profile.predecessorVersionID else { continue }
            let predecessorIdentity = ModelCapabilityIdentityV1(
                familyID: profile.identity.familyID,
                variantID: profile.identity.variantID,
                versionID: predecessorID,
                modality: profile.identity.modality
            )
            guard byIdentity[predecessorIdentity] != nil else {
                throw ModelCapabilityKnowledgeError.invalidPredecessor(profile.identity)
            }
        }
        for profile in knowledgeBase.profiles {
            var seen = Set<ModelCapabilityIdentityV1>()
            var cursor: ModelCapabilityProfileV1? = profile
            while let current = cursor {
                guard seen.insert(current.identity).inserted else {
                    throw ModelCapabilityKnowledgeError.cyclicLineage(profile.identity)
                }
                guard let predecessorID = current.predecessorVersionID else { break }
                cursor = byIdentity[ModelCapabilityIdentityV1(
                    familyID: current.identity.familyID,
                    variantID: current.identity.variantID,
                    versionID: predecessorID,
                    modality: current.identity.modality
                )]
            }
        }
    }

    private func resolvedLookupIdentity(_ lookup: CapabilityLookupV1) -> ModelCapabilityIdentityV1? {
        if let catalogModelID = lookup.catalogModelID {
            let matches = Set(
                knowledgeBase.aliases
                    .filter { $0.catalogModelID == catalogModelID }
                    .map(\.identity)
            )
            if matches.count == 1, let identity = matches.first,
               identity.modality == lookup.modality {
                return identity
            }
            if matches.count > 1 { return nil }
        }
        guard let familyID = lookup.familyID,
              let variantID = lookup.variantID,
              let versionID = lookup.versionID else {
            return nil
        }
        return ModelCapabilityIdentityV1(
            familyID: familyID,
            variantID: variantID,
            versionID: versionID,
            modality: lookup.modality
        )
    }

    private func latestProfile(
        familyID: ModelFamilyID,
        variantID: ModelVariantID,
        modality: CapabilityModalityV1
    ) throws -> ModelCapabilityProfileV1? {
        let candidates = knowledgeBase.profiles.filter {
            $0.identity.familyID == familyID
                && $0.identity.variantID == variantID
                && $0.identity.modality == modality
        }
        guard !candidates.isEmpty else { return nil }
        let predecessorIDs = Set(candidates.compactMap(\.predecessorVersionID))
        let tips = candidates.filter { !predecessorIDs.contains($0.identity.versionID) }
        guard tips.count == 1 else {
            throw ModelCapabilityKnowledgeError.ambiguousLatestProfile(
                family: familyID,
                variant: variantID
            )
        }
        return tips[0]
    }

    private func lineage(from profile: ModelCapabilityProfileV1) -> [ModelCapabilityProfileV1] {
        var result: [ModelCapabilityProfileV1] = []
        var cursor: ModelCapabilityProfileV1? = profile
        while let current = cursor {
            result.append(current)
            guard let predecessorID = current.predecessorVersionID else { break }
            cursor = profilesByIdentity[ModelCapabilityIdentityV1(
                familyID: current.identity.familyID,
                variantID: current.identity.variantID,
                versionID: predecessorID,
                modality: current.identity.modality
            )]
        }
        return result
    }

    private func resolveFields(
        chain: [ModelCapabilityProfileV1],
        startIsExact: Bool,
        defensive: DefensiveCapabilityProfileV1
    ) -> ResolvedCapabilityFieldsV1 {
        ResolvedCapabilityFieldsV1(
            integers: resolveDictionary(
                chain: chain,
                defensive: defensive,
                startIsExact: startIsExact,
                keyPath: \.integers
            ),
            decimals: resolveDictionary(
                chain: chain,
                defensive: defensive,
                startIsExact: startIsExact,
                keyPath: \.decimals
            ),
            booleans: resolveDictionary(
                chain: chain,
                defensive: defensive,
                startIsExact: startIsExact,
                keyPath: \.booleans
            ),
            strings: resolveDictionary(
                chain: chain,
                defensive: defensive,
                startIsExact: startIsExact,
                keyPath: \.strings
            ),
            integerLists: resolveDictionary(
                chain: chain,
                defensive: defensive,
                startIsExact: startIsExact,
                keyPath: \.integerLists
            )
        )
    }

    private func resolveDictionary<Value>(
        chain: [ModelCapabilityProfileV1],
        defensive: DefensiveCapabilityProfileV1,
        startIsExact: Bool,
        keyPath: KeyPath<CapabilityFieldsV1, [String: EvidencedCapabilityFieldV1<Value>]>
    ) -> [String: ResolvedCapabilityValueV1<Value>]
    where Value: Codable & Sendable & Equatable {
        var keys = Set(defensive.fields[keyPath: keyPath].keys)
        for profile in chain {
            keys.formUnion(profile.fields[keyPath: keyPath].keys)
        }
        var resolved: [String: ResolvedCapabilityValueV1<Value>] = [:]
        for key in keys.sorted() {
            for (index, profile) in chain.enumerated() {
                guard let field = profile.fields[keyPath: keyPath][key],
                      let value = field.value else { continue }
                resolved[key] = ResolvedCapabilityValueV1(
                    value: value,
                    semantics: field.semantics,
                    origin: ResolvedCapabilityOriginV1(
                        kind: index == 0 && startIsExact ? .exact : .inherited,
                        profileID: identityString(profile.identity),
                        versionID: profile.identity.versionID
                    ),
                    evidence: field.evidence
                )
                break
            }
            if resolved[key] == nil,
               let field = defensive.fields[keyPath: keyPath][key],
               let value = field.value {
                resolved[key] = ResolvedCapabilityValueV1(
                    value: value,
                    semantics: field.semantics,
                    origin: ResolvedCapabilityOriginV1(
                        kind: .defensive,
                        profileID: defensive.id
                    ),
                    evidence: field.evidence
                )
            }
        }
        return resolved
    }

    private func resolvedDefensive(
        _ defensive: DefensiveCapabilityProfileV1
    ) -> ResolvedCapabilityFieldsV1 {
        resolveFields(
            chain: [],
            startIsExact: false,
            defensive: defensive
        )
    }

    private func usesDefensive(_ fields: ResolvedCapabilityFieldsV1) -> Bool {
        allOrigins(fields).contains { $0.kind == .defensive }
    }

    private func needsResearch(_ fields: ResolvedCapabilityFieldsV1) -> Bool {
        allOrigins(fields).contains { $0.kind != .exact }
            || allEvidence(fields).contains { evidence in
                evidence.conflict?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
    }

    private func allOrigins(_ fields: ResolvedCapabilityFieldsV1) -> [ResolvedCapabilityOriginV1] {
        fields.integers.values.map(\.origin)
            + fields.decimals.values.map(\.origin)
            + fields.booleans.values.map(\.origin)
            + fields.strings.values.map(\.origin)
            + fields.integerLists.values.map(\.origin)
    }

    private func allEvidence(_ fields: ResolvedCapabilityFieldsV1) -> [CapabilityEvidenceV1] {
        fields.integers.values.flatMap(\.evidence)
            + fields.decimals.values.flatMap(\.evidence)
            + fields.booleans.values.flatMap(\.evidence)
            + fields.strings.values.flatMap(\.evidence)
            + fields.integerLists.values.flatMap(\.evidence)
    }

    private func restrictIntegers(
        _ current: [String: ResolvedCapabilityValueV1<Int>],
        with restrictions: [String: EndpointIntegerRestrictionV1],
        endpointID: String
    ) -> [String: ResolvedCapabilityValueV1<Int>] {
        var result = current
        for (key, restriction) in restrictions {
            guard let intrinsic = result[key] else { continue }
            let effective = restriction.operation == .maximum
                ? Swift.min(intrinsic.value, restriction.value)
                : Swift.max(intrinsic.value, restriction.value)
            result[key] = ResolvedCapabilityValueV1(
                value: effective,
                semantics: effective == intrinsic.value ? intrinsic.semantics : .hardAPILimit,
                origin: endpointOrigin(endpointID, prior: intrinsic.origin),
                evidence: intrinsic.evidence + restriction.evidence
            )
        }
        return result
    }

    private func restrictDecimals(
        _ current: [String: ResolvedCapabilityValueV1<Double>],
        with restrictions: [String: EndpointDecimalRestrictionV1],
        endpointID: String
    ) -> [String: ResolvedCapabilityValueV1<Double>] {
        var result = current
        for (key, restriction) in restrictions {
            guard let intrinsic = result[key] else { continue }
            let effective = restriction.operation == .maximum
                ? Swift.min(intrinsic.value, restriction.value)
                : Swift.max(intrinsic.value, restriction.value)
            result[key] = ResolvedCapabilityValueV1(
                value: effective,
                semantics: effective == intrinsic.value ? intrinsic.semantics : .hardAPILimit,
                origin: endpointOrigin(endpointID, prior: intrinsic.origin),
                evidence: intrinsic.evidence + restriction.evidence
            )
        }
        return result
    }

    private func restrictBooleans(
        _ current: [String: ResolvedCapabilityValueV1<Bool>],
        with restrictions: [String: EndpointBooleanRestrictionV1],
        endpointID: String
    ) -> [String: ResolvedCapabilityValueV1<Bool>] {
        var result = current
        for (key, restriction) in restrictions {
            guard let intrinsic = result[key] else { continue }
            result[key] = ResolvedCapabilityValueV1(
                value: intrinsic.value && restriction.value,
                semantics: .hardAPILimit,
                origin: endpointOrigin(endpointID, prior: intrinsic.origin),
                evidence: intrinsic.evidence + restriction.evidence
            )
        }
        return result
    }

    private func restrictStrings(
        _ current: [String: ResolvedCapabilityValueV1<[String]>],
        with restrictions: [String: EndpointStringListRestrictionV1],
        endpointID: String
    ) -> [String: ResolvedCapabilityValueV1<[String]>] {
        var result = current
        for (key, restriction) in restrictions {
            guard let intrinsic = result[key] else { continue }
            result[key] = ResolvedCapabilityValueV1(
                value: intrinsic.value.filter(Set(restriction.values).contains),
                semantics: .supportedSet,
                origin: endpointOrigin(endpointID, prior: intrinsic.origin),
                evidence: intrinsic.evidence + restriction.evidence
            )
        }
        return result
    }

    private func restrictIntegerLists(
        _ current: [String: ResolvedCapabilityValueV1<[Int]>],
        with restrictions: [String: EndpointIntegerListRestrictionV1],
        endpointID: String
    ) -> [String: ResolvedCapabilityValueV1<[Int]>] {
        var result = current
        for (key, restriction) in restrictions {
            guard let intrinsic = result[key] else { continue }
            result[key] = ResolvedCapabilityValueV1(
                value: intrinsic.value.filter(Set(restriction.values).contains),
                semantics: .supportedSet,
                origin: endpointOrigin(endpointID, prior: intrinsic.origin),
                evidence: intrinsic.evidence + restriction.evidence
            )
        }
        return result
    }

    private func endpointOrigin(
        _ endpointID: String,
        prior: ResolvedCapabilityOriginV1
    ) -> ResolvedCapabilityOriginV1 {
        ResolvedCapabilityOriginV1(
            kind: .endpointOverlay,
            profileID: prior.profileID,
            versionID: prior.versionID,
            endpointID: endpointID
        )
    }

    private func fallbackOrigin(
        _ profile: ResolvedCapabilityProfileV1
    ) -> ResolvedCapabilityOriginV1 {
        if let identity = profile.resolvedIdentity {
            return ResolvedCapabilityOriginV1(
                kind: .inherited,
                profileID: identityString(identity),
                versionID: identity.versionID
            )
        }
        return ResolvedCapabilityOriginV1(
            kind: .defensive,
            profileID: profile.defensiveProfileID ?? "unknown"
        )
    }

    private static func validate(_ identity: ModelCapabilityIdentityV1) throws {
        try require(identity.familyID.rawValue, field: "family_id")
        try require(identity.variantID.rawValue, field: "variant_id")
        try require(identity.versionID.rawValue, field: "version_id")
    }

    private static func validate(_ offering: CapabilityOfferingIdentityV1) throws {
        try require(offering.providerID, field: "offering.provider_id")
        try require(offering.offeringID, field: "offering.offering_id")
        try require(offering.endpointID, field: "offering.endpoint_id")
        try require(offering.catalogModelID, field: "offering.catalog_model_id")
    }

    private static func validateEvidence(_ fields: CapabilityFieldsV1) throws {
        let evidence = fields.integers.values.flatMap(\.evidence)
            + fields.decimals.values.flatMap(\.evidence)
            + fields.booleans.values.flatMap(\.evidence)
            + fields.strings.values.flatMap(\.evidence)
            + fields.integerLists.values.flatMap(\.evidence)
        try validateEvidence(evidence)
        let populatedFields = fields.integers.values.map { ($0.value != nil, $0.evidence) }
            + fields.decimals.values.map { ($0.value != nil, $0.evidence) }
            + fields.booleans.values.map { ($0.value != nil, $0.evidence) }
            + fields.strings.values.map { ($0.value != nil, $0.evidence) }
            + fields.integerLists.values.map { ($0.value != nil, $0.evidence) }
        guard populatedFields.allSatisfy({ !$0.0 || !$0.1.isEmpty }) else {
            throw ModelCapabilityKnowledgeError.invalidEvidence("missing field evidence")
        }
    }

    private static func validateEvidence(
        _ restrictions: EndpointCapabilityRestrictionsV1
    ) throws {
        let entries = restrictions.integers.map { ($0.key, $0.value.evidence) }
            + restrictions.decimals.map { ($0.key, $0.value.evidence) }
            + restrictions.booleans.map { ($0.key, $0.value.evidence) }
            + restrictions.strings.map { ($0.key, $0.value.evidence) }
            + restrictions.integerLists.map { ($0.key, $0.value.evidence) }
        var fieldIDs = Set<String>()
        for (fieldID, evidence) in entries {
            try require(fieldID, field: "endpoint_restriction.field")
            guard fieldIDs.insert(fieldID).inserted,
                  !evidence.isEmpty else {
                throw ModelCapabilityKnowledgeError.invalidEndpointConstraint(fieldID)
            }
            try validateEvidence(evidence)
        }
        for (fieldID, restriction) in restrictions.integers where restriction.value < 0 {
            throw ModelCapabilityKnowledgeError.invalidEndpointConstraint(fieldID)
        }
        for (fieldID, restriction) in restrictions.decimals
        where !restriction.value.isFinite || restriction.value < 0 {
            throw ModelCapabilityKnowledgeError.invalidEndpointConstraint(fieldID)
        }
        for (fieldID, restriction) in restrictions.strings
        where Set(restriction.values).count != restriction.values.count {
            throw ModelCapabilityKnowledgeError.invalidEndpointConstraint(fieldID)
        }
        for (fieldID, restriction) in restrictions.integerLists
        where Set(restriction.values).count != restriction.values.count {
            throw ModelCapabilityKnowledgeError.invalidEndpointConstraint(fieldID)
        }
    }

    private static func validateRegisteredFields(
        _ fields: CapabilityFieldsV1,
        modality: CapabilityModalityV1,
        defensiveProfileID: String?
    ) throws {
        let typed = fields.integers.map { ($0.key, CapabilityFieldValueTypeV1.integer, $0.value.value != nil) }
            + fields.decimals.map { ($0.key, CapabilityFieldValueTypeV1.decimal, $0.value.value != nil) }
            + fields.booleans.map { ($0.key, CapabilityFieldValueTypeV1.boolean, $0.value.value != nil) }
            + fields.strings.map { ($0.key, CapabilityFieldValueTypeV1.stringList, $0.value.value != nil) }
            + fields.integerLists.map { ($0.key, CapabilityFieldValueTypeV1.integerList, $0.value.value != nil) }
        var local = Set<String>()
        for (field, type, _) in typed {
            guard local.insert(field).inserted else {
                throw ModelCapabilityKnowledgeError.duplicateField(field)
            }
            _ = try registeredField(field, type: type, modality: modality)
        }

        for (field, value) in fields.integers where value.value.map({ $0 < 0 }) == true {
            throw ModelCapabilityKnowledgeError.invalidFieldSemantics(field)
        }
        for (field, value) in fields.decimals
        where value.value.map({ !$0.isFinite || $0 < 0 }) == true {
            throw ModelCapabilityKnowledgeError.invalidFieldSemantics(field)
        }
        for (field, value) in fields.strings {
            guard value.value.map({ Set($0).count == $0.count }) ?? true else {
                throw ModelCapabilityKnowledgeError.invalidFieldSemantics(field)
            }
        }
        for (field, value) in fields.integerLists {
            guard value.value.map({ Set($0).count == $0.count && $0.allSatisfy { $0 >= 0 } }) ?? true else {
                throw ModelCapabilityKnowledgeError.invalidFieldSemantics(field)
            }
        }

        if let defensiveProfileID {
            let populated = Set(typed.compactMap { $0.2 ? $0.0 : nil })
            for definition in CapabilityFieldRegistryV1.requiredDefensiveFields(for: modality)
            where !populated.contains(definition.id) {
                throw ModelCapabilityKnowledgeError.missingDefensiveField(
                    profileID: defensiveProfileID,
                    field: definition.id
                )
            }
        }
    }

    private static func registeredField(
        _ field: String,
        type: CapabilityFieldValueTypeV1,
        modality: CapabilityModalityV1
    ) throws -> CapabilityFieldDefinitionV1 {
        guard let definition = CapabilityFieldRegistryV1.byID[field] else {
            throw ModelCapabilityKnowledgeError.unknownField(field)
        }
        guard definition.valueType == type else {
            throw ModelCapabilityKnowledgeError.incompatibleFieldType(field)
        }
        guard definition.modalities.contains(modality) else {
            throw ModelCapabilityKnowledgeError.invalidFieldModality(
                field: field,
                modality: modality
            )
        }
        return definition
    }

    private static func validateEndpointFields(
        _ restrictions: EndpointCapabilityRestrictionsV1,
        modality: CapabilityModalityV1
    ) throws {
        for (field, restriction) in restrictions.integers {
            let definition = try registeredField(field, type: .integer, modality: modality)
            try validateNumericMerge(
                definition,
                operation: restriction.operation,
                field: field
            )
        }
        for (field, restriction) in restrictions.decimals {
            let definition = try registeredField(field, type: .decimal, modality: modality)
            try validateNumericMerge(
                definition,
                operation: restriction.operation,
                field: field
            )
        }
        for field in restrictions.booleans.keys {
            let definition = try registeredField(field, type: .boolean, modality: modality)
            guard definition.endpointMergePolicy == .booleanAnd else {
                throw ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(field)
            }
        }
        for field in restrictions.strings.keys {
            let definition = try registeredField(field, type: .stringList, modality: modality)
            guard definition.endpointMergePolicy == .setIntersection else {
                throw ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(field)
            }
        }
        for field in restrictions.integerLists.keys {
            let definition = try registeredField(field, type: .integerList, modality: modality)
            guard definition.endpointMergePolicy == .setIntersection else {
                throw ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(field)
            }
        }
    }

    private static func validateNumericMerge(
        _ definition: CapabilityFieldDefinitionV1,
        operation: EndpointNumericRestrictionOperationV1,
        field: String
    ) throws {
        let expected: EndpointNumericRestrictionOperationV1
        switch definition.endpointMergePolicy {
        case .maximum:
            expected = .maximum
        case .minimum:
            expected = .minimum
        default:
            throw ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(field)
        }
        guard operation == expected else {
            throw ModelCapabilityKnowledgeError.invalidEndpointMergePolicy(field)
        }
    }

    private static func semantics(
        _ fields: CapabilityFieldsV1
    ) -> [CapabilityValueSemanticsV1] {
        fields.integers.values.map(\.semantics)
            + fields.decimals.values.map(\.semantics)
            + fields.booleans.values.map(\.semantics)
            + fields.strings.values.map(\.semantics)
            + fields.integerLists.values.map(\.semantics)
    }

    private static func validateEvidence(_ evidence: [CapabilityEvidenceV1]) throws {
        for item in evidence where !(0...1).contains(item.confidence) {
            throw ModelCapabilityKnowledgeError.invalidEvidenceConfidence(item.confidence)
        }
        for item in evidence {
            guard !item.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.observedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelCapabilityKnowledgeError.invalidEvidence(item.sourceTitle)
            }
        }
    }

    private static func require(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelCapabilityKnowledgeError.emptyIdentifier(field)
        }
    }

    private func identityString(_ identity: ModelCapabilityIdentityV1) -> String {
        "\(identity.familyID.rawValue)/\(identity.variantID.rawValue)/\(identity.versionID.rawValue)"
    }
}
