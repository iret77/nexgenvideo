import Foundation
import NexGenEngine

enum ModelCapabilityResearchFieldValueV1: Sendable, Equatable {
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case stringList([String])
    case integerList([Int])
}

enum ModelCapabilityResearchDiffDecisionV1: String, Sendable, Equatable {
    case applicable
    case unchanged
    case conflictKeepsFallback = "conflict_keeps_fallback"
    case insufficientEvidence = "insufficient_evidence"
    case curatedPreferred = "curated_preferred"
    case endpointBounded = "endpoint_bounded"
    case endpointUnavailable = "endpoint_unavailable"
    case inactive
}

struct ModelCapabilityResearchFieldDiffV1: Sendable, Equatable {
    let fieldID: String
    let current: ModelCapabilityResearchFieldValueV1?
    let candidate: ModelCapabilityResearchFieldValueV1
    let semantics: CapabilityValueSemanticsV1
    let evidence: [CapabilityEvidenceV1]
    let decision: ModelCapabilityResearchDiffDecisionV1
}

struct ModelCapabilityResearchReviewV1: Sendable, Equatable {
    let id: UUID
    let request: ModelCapabilityResearchRequestV1
    let candidate: ModelCapabilityResearchCandidateV1
    let fields: [ModelCapabilityResearchFieldDiffV1]

    var applicableFieldCount: Int {
        fields.filter { Self.acceptableDecisions.contains($0.decision) }.count
    }

    var acceptableFieldIDs: Set<String> {
        Set(
            fields
                .filter { Self.acceptableDecisions.contains($0.decision) }
                .map(\.fieldID)
        )
    }

    private static let acceptableDecisions: Set<ModelCapabilityResearchDiffDecisionV1> = [
        .applicable,
        .unchanged,
    ]
}

enum ModelCapabilityResearchReviewBuilder {
    static func build(
        request: ModelCapabilityResearchRequestV1,
        candidate: ModelCapabilityResearchCandidateV1,
        fallback: ResolvedCapabilityProfileV1,
        id: UUID = UUID()
    ) throws -> ModelCapabilityResearchReviewV1 {
        try ModelCapabilityResearchValidator.validate(candidate, for: request, allowEmpirical: false)
        guard fallback.requestedIdentity == request.binding.identity else {
            throw ModelCapabilityResearchValidationError.wrongBinding
        }
        let current = flatten(fallback.fields)
        let proposed = flatten(candidate.fields)
        let diffs = proposed.keys.sorted().compactMap { fieldID -> ModelCapabilityResearchFieldDiffV1? in
            guard let proposedField = proposed[fieldID] else { return nil }
            let currentField = current[fieldID]
            let decision: ModelCapabilityResearchDiffDecisionV1
            if ModelCapabilityResearchEvidencePolicy.hasConflict(proposedField.evidence) {
                decision = .conflictKeepsFallback
            } else if !ModelCapabilityResearchEvidencePolicy.isProven(proposedField.evidence) {
                decision = .insufficientEvidence
            } else if currentField?.value == proposedField.value {
                decision = .unchanged
            } else if request.scope == .intrinsic,
                      Self.curatedWins(current: currentField, proposed: proposedField) {
                decision = .curatedPreferred
            } else {
                decision = .applicable
            }
            return ModelCapabilityResearchFieldDiffV1(
                fieldID: fieldID,
                current: currentField?.value,
                candidate: proposedField.value,
                semantics: proposedField.semantics,
                evidence: proposedField.evidence,
                decision: decision
            )
        }
        return ModelCapabilityResearchReviewV1(
            id: id,
            request: request,
            candidate: candidate,
            fields: diffs
        )
    }

    private struct FlatField {
        let value: ModelCapabilityResearchFieldValueV1
        let semantics: CapabilityValueSemanticsV1
        let evidence: [CapabilityEvidenceV1]
        let origin: ResolvedCapabilityOriginV1?
    }

    private static func flatten(_ fields: CapabilityFieldsV1) -> [String: FlatField] {
        var result: [String: FlatField] = [:]
        for (key, field) in fields.integers {
            guard let value = field.value else { continue }
            result[key] = FlatField(
                value: .integer(value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: nil
            )
        }
        for (key, field) in fields.decimals {
            guard let value = field.value else { continue }
            result[key] = FlatField(
                value: .decimal(value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: nil
            )
        }
        for (key, field) in fields.booleans {
            guard let value = field.value else { continue }
            result[key] = FlatField(
                value: .boolean(value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: nil
            )
        }
        for (key, field) in fields.strings {
            guard let value = field.value else { continue }
            result[key] = FlatField(
                value: .stringList(value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: nil
            )
        }
        for (key, field) in fields.integerLists {
            guard let value = field.value else { continue }
            result[key] = FlatField(
                value: .integerList(value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: nil
            )
        }
        return result
    }

    private static func flatten(_ fields: ResolvedCapabilityFieldsV1) -> [String: FlatField] {
        var result: [String: FlatField] = [:]
        for (key, field) in fields.integers {
            result[key] = FlatField(
                value: .integer(field.value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: field.origin
            )
        }
        for (key, field) in fields.decimals {
            result[key] = FlatField(
                value: .decimal(field.value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: field.origin
            )
        }
        for (key, field) in fields.booleans {
            result[key] = FlatField(
                value: .boolean(field.value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: field.origin
            )
        }
        for (key, field) in fields.strings {
            result[key] = FlatField(
                value: .stringList(field.value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: field.origin
            )
        }
        for (key, field) in fields.integerLists {
            result[key] = FlatField(
                value: .integerList(field.value),
                semantics: field.semantics,
                evidence: field.evidence,
                origin: field.origin
            )
        }
        return result
    }

    private static func curatedWins(current: FlatField?, proposed: FlatField) -> Bool {
        guard let current, current.origin?.kind == .exact,
              let currentQuality = ModelCapabilityResearchEvidencePolicy.bestQuality(current.evidence),
              let proposedQuality = ModelCapabilityResearchEvidencePolicy.bestQuality(proposed.evidence) else {
            return false
        }
        return currentQuality >= proposedQuality
    }
}

struct ModelCapabilityResearchEffectiveResolutionV1: Sendable, Equatable {
    let profile: ResolvedCapabilityProfileV1
    let fieldDecisions: [String: ModelCapabilityResearchDiffDecisionV1]
    let localEvidenceIsStale: Bool
}

enum ModelCapabilityResearchOverlayResolver {
    static func resolve(
        curatedIntrinsic: ResolvedCapabilityProfileV1,
        record: ModelCapabilityResearchOverlayRecordV1?,
        endpointOverlay: EndpointCapabilityOverlayV1? = nil,
        offering: CapabilityOfferingIdentityV1? = nil,
        currentMode: String? = nil,
        staleAfterDays: Int,
        now: Date
    ) throws -> ModelCapabilityResearchEffectiveResolutionV1 {
        if let record, curatedIntrinsic.requestedIdentity != record.binding.identity {
            throw ModelCapabilityResearchValidationError.wrongBinding
        }
        return try resolve(
            curatedIntrinsic: curatedIntrinsic,
            records: record.map { [$0] } ?? [],
            endpointOverlay: endpointOverlay,
            offering: offering,
            currentMode: currentMode,
            staleAfterDays: staleAfterDays,
            now: now
        )
    }

    static func resolve(
        curatedIntrinsic: ResolvedCapabilityProfileV1,
        records: [ModelCapabilityResearchOverlayRecordV1],
        endpointOverlay: EndpointCapabilityOverlayV1? = nil,
        offering: CapabilityOfferingIdentityV1? = nil,
        currentMode: String? = nil,
        staleAfterDays: Int,
        now: Date
    ) throws -> ModelCapabilityResearchEffectiveResolutionV1 {
        guard let requestedIdentity = curatedIntrinsic.requestedIdentity else {
            throw ModelCapabilityResearchValidationError.wrongBinding
        }
        let matching = records.filter {
            $0.binding.identity == requestedIdentity
        }
        let activeIntrinsic = matching.filter {
            $0.status == .active && $0.scope == .intrinsic
        }
        guard activeIntrinsic.count <= 1 else {
            throw ModelCapabilityResearchStoreError.duplicateActiveKey(
                activeIntrinsic[0].canonicalKey
            )
        }
        let activeEndpoints = matching.filter {
            $0.status == .active && $0.scope == .endpoint
        }
        let endpointRecord = activeEndpoints.filter { record in
            guard let offering else { return false }
            return endpointMatches(
                offering,
                binding: record.binding,
                currentMode: currentMode
            )
        }
        guard endpointRecord.count <= 1 else {
            throw ModelCapabilityResearchStoreError.duplicateActiveKey(
                endpointRecord[0].canonicalKey
            )
        }

        var fields = curatedIntrinsic.fields
        var decisions = matching
            .filter { $0.status != .active }
            .flatMap(\.fieldIDs)
            .reduce(into: [String: ModelCapabilityResearchDiffDecisionV1]()) {
                $0[$1] = .inactive
            }
        if let record = activeIntrinsic.first {
            merge(
                current: &fields.integers,
                proposed: record.fields.integers,
                record: record,
                decisions: &decisions
            )
            merge(
                current: &fields.decimals,
                proposed: record.fields.decimals,
                record: record,
                decisions: &decisions
            )
            merge(
                current: &fields.booleans,
                proposed: record.fields.booleans,
                record: record,
                decisions: &decisions
            )
            merge(
                current: &fields.strings,
                proposed: record.fields.strings,
                record: record,
                decisions: &decisions
            )
            merge(
                current: &fields.integerLists,
                proposed: record.fields.integerLists,
                record: record,
                decisions: &decisions
            )
        }
        var merged = ResolvedCapabilityProfileV1(
            requestedIdentity: curatedIntrinsic.requestedIdentity,
            resolvedIdentity: curatedIntrinsic.resolvedIdentity,
            defensiveProfileID: curatedIntrinsic.defensiveProfileID,
            researchNeeded: curatedIntrinsic.researchNeeded || decisions.values.contains(where: {
                [.conflictKeepsFallback, .insufficientEvidence, .curatedPreferred].contains($0)
            }),
            fields: fields
        )
        if let record = endpointRecord.first {
            var endpointFields = merged.fields
            merge(
                current: &endpointFields.integers,
                proposed: record.fields.integers,
                record: record,
                protectExactCurrent: false,
                decisions: &decisions
            )
            merge(
                current: &endpointFields.decimals,
                proposed: record.fields.decimals,
                record: record,
                protectExactCurrent: false,
                decisions: &decisions
            )
            merge(
                current: &endpointFields.booleans,
                proposed: record.fields.booleans,
                record: record,
                protectExactCurrent: false,
                decisions: &decisions
            )
            merge(
                current: &endpointFields.strings,
                proposed: record.fields.strings,
                record: record,
                protectExactCurrent: false,
                decisions: &decisions
            )
            merge(
                current: &endpointFields.integerLists,
                proposed: record.fields.integerLists,
                record: record,
                protectExactCurrent: false,
                decisions: &decisions
            )
            merged = ResolvedCapabilityProfileV1(
                requestedIdentity: merged.requestedIdentity,
                resolvedIdentity: merged.resolvedIdentity,
                defensiveProfileID: merged.defensiveProfileID,
                researchNeeded: merged.researchNeeded || decisions.values.contains(where: {
                    [.conflictKeepsFallback, .insufficientEvidence, .curatedPreferred].contains($0)
                }),
                fields: endpointFields
            )
        } else {
            for record in activeEndpoints {
                for fieldID in record.fieldIDs where decisions[fieldID] == nil {
                    decisions[fieldID] = .endpointUnavailable
                }
            }
        }
        let effective = try applyEndpoint(
            endpointOverlay,
            expectedOffering: offering,
            to: merged,
            decisions: decisions
        )
        let appliedRecords = activeIntrinsic + endpointRecord
        return ModelCapabilityResearchEffectiveResolutionV1(
            profile: effective.profile,
            fieldDecisions: effective.decisions,
            localEvidenceIsStale: appliedRecords.contains {
                isStale($0, staleAfterDays: staleAfterDays, now: now)
            }
        )
    }

    static func applyingResolvedEndpointBoundary(
        _ boundary: ResolvedCapabilityProfileV1,
        to resolution: ModelCapabilityResearchEffectiveResolutionV1
    ) -> ModelCapabilityResearchEffectiveResolutionV1 {
        var fields = resolution.profile.fields
        var decisions = resolution.fieldDecisions

        for (fieldID, endpoint) in boundary.fields.integers
        where endpoint.origin.kind == .endpointOverlay {
            guard let policy = CapabilityFieldRegistryV1.byID[fieldID]?.endpointMergePolicy,
                  policy != .intrinsicOnly else { continue }
            guard let current = fields.integers[fieldID] else {
                fields.integers[fieldID] = endpoint
                markBounded(fieldID, changed: true, decisions: &decisions)
                continue
            }
            let value: Int
            switch policy {
            case .maximum: value = min(current.value, endpoint.value)
            case .minimum: value = max(current.value, endpoint.value)
            default: value = endpoint.value
            }
            fields.integers[fieldID] = boundedValue(value, current: current, endpoint: endpoint)
            markBounded(fieldID, changed: value != current.value, decisions: &decisions)
        }
        for (fieldID, endpoint) in boundary.fields.decimals
        where endpoint.origin.kind == .endpointOverlay {
            guard let policy = CapabilityFieldRegistryV1.byID[fieldID]?.endpointMergePolicy,
                  policy != .intrinsicOnly else { continue }
            guard let current = fields.decimals[fieldID] else {
                fields.decimals[fieldID] = endpoint
                markBounded(fieldID, changed: true, decisions: &decisions)
                continue
            }
            let value: Double
            switch policy {
            case .maximum: value = min(current.value, endpoint.value)
            case .minimum: value = max(current.value, endpoint.value)
            default: value = endpoint.value
            }
            fields.decimals[fieldID] = boundedValue(value, current: current, endpoint: endpoint)
            markBounded(fieldID, changed: value != current.value, decisions: &decisions)
        }
        for (fieldID, endpoint) in boundary.fields.booleans
        where endpoint.origin.kind == .endpointOverlay {
            guard let policy = CapabilityFieldRegistryV1.byID[fieldID]?.endpointMergePolicy,
                  policy != .intrinsicOnly else { continue }
            guard let current = fields.booleans[fieldID] else {
                fields.booleans[fieldID] = endpoint
                markBounded(fieldID, changed: true, decisions: &decisions)
                continue
            }
            let value = policy == .booleanAnd
                ? current.value && endpoint.value
                : endpoint.value
            fields.booleans[fieldID] = boundedValue(value, current: current, endpoint: endpoint)
            markBounded(fieldID, changed: value != current.value, decisions: &decisions)
        }
        for (fieldID, endpoint) in boundary.fields.strings
        where endpoint.origin.kind == .endpointOverlay {
            guard let policy = CapabilityFieldRegistryV1.byID[fieldID]?.endpointMergePolicy,
                  policy != .intrinsicOnly else { continue }
            guard let current = fields.strings[fieldID] else {
                fields.strings[fieldID] = endpoint
                markBounded(fieldID, changed: true, decisions: &decisions)
                continue
            }
            let value = policy == .setIntersection
                ? current.value.filter(Set(endpoint.value).contains)
                : endpoint.value
            fields.strings[fieldID] = boundedValue(value, current: current, endpoint: endpoint)
            markBounded(fieldID, changed: value != current.value, decisions: &decisions)
        }
        for (fieldID, endpoint) in boundary.fields.integerLists
        where endpoint.origin.kind == .endpointOverlay {
            guard let policy = CapabilityFieldRegistryV1.byID[fieldID]?.endpointMergePolicy,
                  policy != .intrinsicOnly else { continue }
            guard let current = fields.integerLists[fieldID] else {
                fields.integerLists[fieldID] = endpoint
                markBounded(fieldID, changed: true, decisions: &decisions)
                continue
            }
            let value = policy == .setIntersection
                ? current.value.filter(Set(endpoint.value).contains)
                : endpoint.value
            fields.integerLists[fieldID] = boundedValue(
                value,
                current: current,
                endpoint: endpoint
            )
            markBounded(fieldID, changed: value != current.value, decisions: &decisions)
        }

        return ModelCapabilityResearchEffectiveResolutionV1(
            profile: ResolvedCapabilityProfileV1(
                requestedIdentity: resolution.profile.requestedIdentity,
                resolvedIdentity: resolution.profile.resolvedIdentity,
                defensiveProfileID: resolution.profile.defensiveProfileID,
                researchNeeded: resolution.profile.researchNeeded,
                fields: fields
            ),
            fieldDecisions: decisions,
            localEvidenceIsStale: resolution.localEvidenceIsStale
        )
    }

    private static func merge<Value>(
        current: inout [String: ResolvedCapabilityValueV1<Value>],
        proposed: [String: EvidencedCapabilityFieldV1<Value>],
        record: ModelCapabilityResearchOverlayRecordV1,
        protectExactCurrent: Bool = true,
        decisions: inout [String: ModelCapabilityResearchDiffDecisionV1]
    ) where Value: Codable & Sendable & Equatable {
        for (fieldID, field) in proposed {
            guard let value = field.value else {
                decisions[fieldID] = .insufficientEvidence
                continue
            }
            if ModelCapabilityResearchEvidencePolicy.hasConflict(field.evidence) {
                decisions[fieldID] = .conflictKeepsFallback
                continue
            }
            guard ModelCapabilityResearchEvidencePolicy.isProven(field.evidence) else {
                decisions[fieldID] = .insufficientEvidence
                continue
            }
            if let existing = current[fieldID] {
                if existing.value == value {
                    let endpointScoped = record.scope == .endpoint
                    current[fieldID] = ResolvedCapabilityValueV1(
                        value: value,
                        semantics: endpointScoped ? field.semantics : existing.semantics,
                        origin: endpointScoped ? localOrigin(record) : existing.origin,
                        evidence: combinedEvidence(existing.evidence, field.evidence)
                    )
                    decisions[fieldID] = .unchanged
                    continue
                }
                if protectExactCurrent,
                   existing.origin.kind == .exact,
                   let curatedQuality = ModelCapabilityResearchEvidencePolicy.bestQuality(existing.evidence),
                   let localQuality = ModelCapabilityResearchEvidencePolicy.bestQuality(field.evidence),
                   curatedQuality >= localQuality {
                    decisions[fieldID] = .curatedPreferred
                    continue
                }
            }
            current[fieldID] = ResolvedCapabilityValueV1(
                value: value,
                semantics: field.semantics,
                origin: localOrigin(record),
                evidence: field.evidence
            )
            decisions[fieldID] = .applicable
        }
    }

    private static func localOrigin(
        _ record: ModelCapabilityResearchOverlayRecordV1
    ) -> ResolvedCapabilityOriginV1 {
        ResolvedCapabilityOriginV1(
            kind: record.scope == .endpoint ? .endpointOverlay : .exact,
            profileID: "local-research:\(record.id)",
            versionID: record.binding.identity.versionID,
            endpointID: record.scope == .endpoint ? record.binding.endpointID : nil
        )
    }

    private static func combinedEvidence(
        _ existing: [CapabilityEvidenceV1],
        _ proposed: [CapabilityEvidenceV1]
    ) -> [CapabilityEvidenceV1] {
        proposed.reduce(into: existing) { result, evidence in
            if !result.contains(evidence) { result.append(evidence) }
        }
    }

    private static func boundedValue<Value>(
        _ value: Value,
        current: ResolvedCapabilityValueV1<Value>,
        endpoint: ResolvedCapabilityValueV1<Value>
    ) -> ResolvedCapabilityValueV1<Value>
    where Value: Codable & Sendable & Equatable {
        ResolvedCapabilityValueV1(
            value: value,
            semantics: value == current.value ? current.semantics : endpoint.semantics,
            origin: endpoint.origin,
            evidence: combinedEvidence(current.evidence, endpoint.evidence)
        )
    }

    private struct EndpointResult {
        var profile: ResolvedCapabilityProfileV1
        var decisions: [String: ModelCapabilityResearchDiffDecisionV1]
    }

    private static func applyEndpoint(
        _ overlay: EndpointCapabilityOverlayV1?,
        expectedOffering: CapabilityOfferingIdentityV1?,
        to profile: ResolvedCapabilityProfileV1,
        decisions: [String: ModelCapabilityResearchDiffDecisionV1]
    ) throws -> EndpointResult {
        guard let overlay else { return EndpointResult(profile: profile, decisions: decisions) }
        try ModelCapabilityResolver.validate(overlay)
        guard let expectedOffering,
              expectedOffering == overlay.offering,
              profile.requestedIdentity?.modality == overlay.offering.modality else {
            throw ModelCapabilityResearchValidationError.wrongBinding
        }
        var fields = profile.fields
        var updatedDecisions = decisions
        for (fieldID, restriction) in overlay.restrictions.integers {
            guard let current = fields.integers[fieldID] else { continue }
            let value = restriction.operation == .maximum
                ? min(current.value, restriction.value)
                : max(current.value, restriction.value)
            fields.integers[fieldID] = endpointValue(
                value,
                prior: current,
                endpointID: overlay.offering.endpointID,
                evidence: restriction.evidence
            )
            markBounded(fieldID, changed: value != current.value, decisions: &updatedDecisions)
        }
        for (fieldID, restriction) in overlay.restrictions.decimals {
            guard let current = fields.decimals[fieldID] else { continue }
            let value = restriction.operation == .maximum
                ? min(current.value, restriction.value)
                : max(current.value, restriction.value)
            fields.decimals[fieldID] = endpointValue(
                value,
                prior: current,
                endpointID: overlay.offering.endpointID,
                evidence: restriction.evidence
            )
            markBounded(fieldID, changed: value != current.value, decisions: &updatedDecisions)
        }
        for (fieldID, restriction) in overlay.restrictions.booleans {
            guard let current = fields.booleans[fieldID] else { continue }
            let value = current.value && restriction.value
            fields.booleans[fieldID] = endpointValue(
                value,
                prior: current,
                endpointID: overlay.offering.endpointID,
                evidence: restriction.evidence
            )
            markBounded(fieldID, changed: value != current.value, decisions: &updatedDecisions)
        }
        for (fieldID, restriction) in overlay.restrictions.strings {
            guard let current = fields.strings[fieldID] else { continue }
            let supported = Set(restriction.values)
            let value = current.value.filter(supported.contains)
            fields.strings[fieldID] = endpointValue(
                value,
                prior: current,
                endpointID: overlay.offering.endpointID,
                evidence: restriction.evidence,
                semantics: .supportedSet
            )
            markBounded(fieldID, changed: value != current.value, decisions: &updatedDecisions)
        }
        for (fieldID, restriction) in overlay.restrictions.integerLists {
            guard let current = fields.integerLists[fieldID] else { continue }
            let supported = Set(restriction.values)
            let value = current.value.filter(supported.contains)
            fields.integerLists[fieldID] = endpointValue(
                value,
                prior: current,
                endpointID: overlay.offering.endpointID,
                evidence: restriction.evidence,
                semantics: .supportedSet
            )
            markBounded(fieldID, changed: value != current.value, decisions: &updatedDecisions)
        }
        for (fieldID, constraint) in overlay.arrayConstraints {
            let current = fields.integers[fieldID]
            let value: Int
            let semantics: CapabilityValueSemanticsV1
            if !constraint.isPresent {
                value = 0
                semantics = .hardAPILimit
            } else if let maximum = constraint.maxItems {
                guard let current else { continue }
                value = min(current.value, maximum)
                semantics = value == current.value ? current.semantics : .hardAPILimit
            } else {
                continue
            }
            fields.integers[fieldID] = ResolvedCapabilityValueV1(
                value: value,
                semantics: semantics,
                origin: endpointOrigin(
                    overlay.offering.endpointID,
                    prior: current?.origin ?? fallbackOrigin(profile)
                ),
                evidence: (current?.evidence ?? []) + overlay.schemaEvidence
            )
            markBounded(
                fieldID,
                changed: current.map { value != $0.value } ?? true,
                decisions: &updatedDecisions
            )
        }
        return EndpointResult(
            profile: ResolvedCapabilityProfileV1(
                requestedIdentity: profile.requestedIdentity,
                resolvedIdentity: profile.resolvedIdentity,
                defensiveProfileID: profile.defensiveProfileID,
                researchNeeded: profile.researchNeeded,
                fields: fields
            ),
            decisions: updatedDecisions
        )
    }

    private static func endpointValue<Value>(
        _ value: Value,
        prior: ResolvedCapabilityValueV1<Value>,
        endpointID: String,
        evidence: [CapabilityEvidenceV1],
        semantics: CapabilityValueSemanticsV1? = nil
    ) -> ResolvedCapabilityValueV1<Value> where Value: Codable & Sendable & Equatable {
        ResolvedCapabilityValueV1(
            value: value,
            semantics: semantics ?? (value == prior.value ? prior.semantics : .hardAPILimit),
            origin: endpointOrigin(endpointID, prior: prior.origin),
            evidence: prior.evidence + evidence
        )
    }

    private static func endpointOrigin(
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

    private static func fallbackOrigin(
        _ profile: ResolvedCapabilityProfileV1
    ) -> ResolvedCapabilityOriginV1 {
        if let identity = profile.resolvedIdentity {
            return ResolvedCapabilityOriginV1(
                kind: .inherited,
                profileID: [
                    identity.familyID.rawValue,
                    identity.variantID.rawValue,
                    identity.versionID.rawValue,
                ].joined(separator: "/"),
                versionID: identity.versionID
            )
        }
        return ResolvedCapabilityOriginV1(
            kind: .defensive,
            profileID: profile.defensiveProfileID ?? "unknown"
        )
    }

    private static func markBounded(
        _ fieldID: String,
        changed: Bool,
        decisions: inout [String: ModelCapabilityResearchDiffDecisionV1]
    ) {
        guard changed else { return }
        if decisions[fieldID] == nil
            || decisions[fieldID] == .applicable
            || decisions[fieldID] == .unchanged {
            decisions[fieldID] = .endpointBounded
        }
    }

    private static func endpointMatches(
        _ offering: CapabilityOfferingIdentityV1,
        binding: ModelCapabilityResearchBindingV1,
        currentMode: String?
    ) -> Bool {
        offering.providerID == binding.providerID
            && offering.offeringID == binding.offeringID
            && offering.endpointID == binding.endpointID
            && offering.catalogModelID == binding.catalogModelID
            && offering.modality == binding.identity.modality
            && binding.mode == currentMode
    }

    private static func isStale(
        _ record: ModelCapabilityResearchOverlayRecordV1,
        staleAfterDays: Int,
        now: Date
    ) -> Bool {
        guard staleAfterDays > 0 else { return true }
        let dates = record.allEvidence.compactMap {
            ModelCapabilityResearchDatePolicy.date($0.observedAt)
        }
        guard let newest = dates.max(),
              let deadline = ModelCapabilityResearchDatePolicy.adding(
                days: staleAfterDays,
                to: newest
              ) else {
            return true
        }
        return now >= deadline
    }
}
