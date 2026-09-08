import Foundation

public enum ProductionStyleDimensionV1: String, Codable, Sendable, CaseIterable {
    case character, composition, camera, editing, lighting, color, timing, sound
}

public struct ProductionStyleOverrideV1: Codable, Sendable, Equatable {
    public let dimension: ProductionStyleDimensionV1
    public let value: String
    public let reason: String
    public let sourceEntryID: String?
    public let verification: ProductionStyleVerificationV1?

    public init(dimension: ProductionStyleDimensionV1, value: String, reason: String, sourceEntryID: String? = nil, verification: ProductionStyleVerificationV1? = nil) {
        self.dimension = dimension
        self.value = value
        self.reason = reason
        self.sourceEntryID = sourceEntryID
        self.verification = verification
    }
}

public struct ProductionStyleSelectionV1: Codable, Sendable, Equatable {
    public let directorID: String
    public let signatureID: String?
    public let signatureDimensions: [ProductionStyleDimensionV1]
    public let overrides: [ProductionStyleOverrideV1]

    public init(directorID: String, signatureID: String? = nil,
                signatureDimensions: [ProductionStyleDimensionV1] = [], overrides: [ProductionStyleOverrideV1] = []) {
        self.directorID = directorID
        self.signatureID = signatureID
        self.signatureDimensions = signatureDimensions
        self.overrides = overrides
    }
}

public struct ResolvedProductionStyleDimensionV1: Codable, Sendable, Equatable {
    public let dimension: ProductionStyleDimensionV1
    public let value: String
    public let sourceEntryID: String
    public let reason: String?
}

public struct ResolvedProductionStyleV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "resolved-production-style/v1"
    public static let relativePath = "production_design/resolved-style.v1.json"

    public let schema: String
    public let libraryVersion: String
    public let sourceCommit: String
    public let selection: ProductionStyleSelectionV1
    public let dimensions: [ResolvedProductionStyleDimensionV1]
    public let sourceVerifyClauses: [String: String]
    public let criteria: [ResolvedProductionStyleCriterionV1]

    public func value(_ dimension: ProductionStyleDimensionV1) -> String? {
        dimensions.first { $0.dimension == dimension }?.value
    }

    public func validate(catalog: ProductionKnowledgeCatalogV1) throws {
        guard self == (try Self.resolve(selection, catalog: catalog)) else {
            throw Self.invalid("Resolved style differs from its versioned sources and declared decisions.")
        }
    }

    public static func resolve(_ selection: ProductionStyleSelectionV1,
                               catalog: ProductionKnowledgeCatalogV1) throws -> Self {
        guard let library = catalog.library(id: "film-production-blueprints") else {
            throw ProductionKnowledgeErrorV1.missingResource("film-production-blueprints")
        }
        func entry(_ id: String, prefix: String) throws -> CreativeKnowledgeEntryV1 {
            guard id.hasPrefix(prefix), let entry = library.entries.first(where: { $0.id.rawValue == id }) else {
                throw invalid("Unknown or incompatible blueprint: \(id)")
            }
            return entry
        }
        let base = try entry(selection.directorID, prefix: "director-")
        var criteria = try verification(of: base)
        var resolved = dimensions(of: base).mapValues { value in
            (value: value, source: base.id.rawValue, reason: Optional<String>.none)
        }
        var verify = [base.id.rawValue: sourceFields(base)["Verify"] ?? ""]
        guard Set(selection.signatureDimensions).count == selection.signatureDimensions.count else {
            throw invalid("Signature dimensions must be unique.")
        }
        if let signatureID = selection.signatureID {
            let signature = try entry(signatureID, prefix: "dop-")
            guard !selection.signatureDimensions.isEmpty,
                  Set(selection.signatureDimensions).isSubset(of: [.lighting, .color, .camera]) else {
                throw invalid("Choose the signature's camera, lighting, or color dimensions explicitly.")
            }
            let fields = sourceFields(signature)
            let known = dimensions(of: signature)
            for dimension in selection.signatureDimensions {
                let declared = selection.overrides.first {
                    $0.dimension == dimension && $0.sourceEntryID == signatureID
                }
                guard let value = known[dimension] ?? declared?.value, !value.isEmpty else {
                    throw invalid("The signature does not label \(dimension.rawValue) separately. Declare that dimension and its source as an explicit override.")
                }
                resolved[dimension] = (value, signature.id.rawValue, "Explicitly selected signature dimension")
            }
            verify[signature.id.rawValue] = fields["Verify"] ?? ""
            let signatureCriteria = try verification(of: signature).filter { selection.signatureDimensions.contains($0.dimension) }
            for dimension in selection.signatureDimensions {
                guard signatureCriteria.contains(where: { $0.dimension == dimension })
                        || selection.overrides.contains(where: { $0.dimension == dimension && $0.verification != nil }) else {
                    throw invalid("The signature needs an explicit verification criterion for " + dimension.rawValue)
                }
            }
            criteria.removeAll { selection.signatureDimensions.contains($0.dimension) }
            criteria += signatureCriteria
        } else if !selection.signatureDimensions.isEmpty {
            throw invalid("Signature dimensions require a signature.")
        }
        guard Set(selection.overrides.map(\.dimension)).count == selection.overrides.count else {
            throw invalid("A style dimension may have only one override.")
        }
        for override in selection.overrides {
            try override.verification?.validate(dimension: override.dimension)
            guard !override.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !override.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("Every style override requires a value and reason.")
            }
            if let source = override.sourceEntryID,
               !library.entries.contains(where: { $0.id.rawValue == source }) {
                throw invalid("Unknown override source: \(source)")
            }
            resolved[override.dimension] = (override.value, override.sourceEntryID ?? "project-decision", override.reason)
            if !criteria.contains(where: { $0.dimension == override.dimension }), let verification = override.verification {
                criteria.append(ProductionStyleCriterionV1(id: "project-override." + override.dimension.rawValue,
                    recipeID: override.sourceEntryID ?? "project-decision", sourceClause: verification.criterion,
                    dimension: override.dimension, scope: verification.scope, evidenceKind: verification.evidenceKind))
            }
        }
        return Self(schema: schemaVersion, libraryVersion: library.version.rawValue,
                    sourceCommit: library.provenance.sourceCommit, selection: selection,
                    dimensions: ProductionStyleDimensionV1.allCases.compactMap { dimension in
                        guard let value = resolved[dimension] else { return nil }
                        return ResolvedProductionStyleDimensionV1(dimension: dimension, value: value.value,
                                                                  sourceEntryID: value.source, reason: value.reason)
                    }, sourceVerifyClauses: verify,
                    criteria: criteria.map { criterion in
                        let override = selection.overrides.first { $0.dimension == criterion.dimension }
                        let replacement = override?.value ?? (
                            criterion.recipeID == base.id.rawValue && selection.signatureDimensions.contains(criterion.dimension)
                                ? resolved[criterion.dimension]?.value : nil
                        )
                        return ResolvedProductionStyleCriterionV1(source: criterion,
                            expected: override?.verification?.criterion ?? replacement ?? criterion.sourceClause,
                            overrideReason: override?.reason ?? (replacement == nil ? nil : "Explicit signature dimension"),
                            scope: override?.verification?.scope ?? (replacement == nil ? criterion.scope : .sequence),
                            evidenceKind: override?.verification?.evidenceKind ?? (replacement == nil ? criterion.evidenceKind
                                : (criterion.evidenceKind == .audiovisual || criterion.dimension == .sound ? .audiovisual : .video)))
                    })
    }

    private static func verification(of entry: CreativeKnowledgeEntryV1) throws -> [ProductionStyleCriterionV1] {
        let prefix = "Blueprint verification: "
        let criteria = try entry.guidance.filter { $0.hasPrefix(prefix) }.map {
            try JSONDecoder().decode(ProductionStyleCriterionV1.self, from: Data($0.dropFirst(prefix.count).utf8))
        }
        let clauses = (sourceFields(entry)["Verify"] ?? "").split(separator: "?")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "?" }
        guard !criteria.isEmpty, criteria.map(\.sourceClause) == clauses,
              criteria.allSatisfy({ $0.recipeID == entry.id.rawValue }) else {
            throw invalid("Blueprint review bindings do not cover the source: \(entry.id.rawValue)")
        }
        return criteria
    }

    private static func sourceFields(_ entry: CreativeKnowledgeEntryV1) -> [String: String] {
        var fields: [String: String] = [:]
        for guidance in entry.guidance where guidance.hasPrefix("Blueprint dimension ") {
            let pair = guidance.dropFirst("Blueprint dimension ".count).split(separator: ":", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return fields
    }

    private static func dimensions(of entry: CreativeKnowledgeEntryV1) -> [ProductionStyleDimensionV1: String] {
        let fields = sourceFields(entry)
        let keys: [ProductionStyleDimensionV1: [String]] = [
            .character: ["character"], .composition: ["Composition"], .camera: ["Camera"],
            .editing: ["Editing"], .lighting: ["Light", "Light/Color"],
            .color: ["Color", "Grade", "Light/Color"], .timing: ["Timing"], .sound: ["Sound"],
        ]
        return keys.reduce(into: [:]) { result, item in
            if let value = item.value.compactMap({ fields[$0] }).first { result[item.key] = value }
        }
    }

    private static func invalid(_ reason: String) -> ProductionKnowledgeErrorV1 {
        .invalidValue(path: "resolved-production-style", reason: reason)
    }
}
