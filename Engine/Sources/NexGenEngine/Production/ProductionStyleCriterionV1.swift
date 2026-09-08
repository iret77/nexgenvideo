import Foundation

public enum ProductionReviewScopeV1: String, Codable, Sendable {
    case frame, shot, sequence, project
}

public enum ProductionReviewEvidenceKindV1: String, Codable, Sendable {
    case image, video, audio, audiovisual
}

public struct ProductionStyleVerificationV1: Codable, Sendable, Equatable {
    public let scope: ProductionReviewScopeV1
    public let evidenceKind: ProductionReviewEvidenceKindV1
    public let criterion: String

    public init(scope: ProductionReviewScopeV1, evidenceKind: ProductionReviewEvidenceKindV1, criterion: String) {
        self.scope = scope; self.evidenceKind = evidenceKind; self.criterion = criterion
    }

    public func validate(dimension: ProductionStyleDimensionV1) throws {
        guard !criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (scope == .frame) == (evidenceKind == .image),
              dimension != .sound || (evidenceKind == .audio || evidenceKind == .audiovisual),
              ![.editing, .timing].contains(dimension) || ([.sequence, .project].contains(scope) && [.video, .audiovisual].contains(evidenceKind)),
              dimension == .sound || evidenceKind != .audio else {
            throw GateBlocked("Style verification must name a concrete criterion and evidence appropriate to its dimension. A still cannot verify timing, cuts or sound.")
        }
    }
}

public struct ProductionStyleCriterionV1: Codable, Sendable, Equatable {
    public let id: String
    public let recipeID: String
    public let sourceClause: String
    public let dimension: ProductionStyleDimensionV1
    public let scope: ProductionReviewScopeV1
    public let evidenceKind: ProductionReviewEvidenceKindV1
}

public struct ResolvedProductionStyleCriterionV1: Codable, Sendable, Equatable {
    public let source: ProductionStyleCriterionV1
    public let expected: String
    public let overrideReason: String?
    public let scope: ProductionReviewScopeV1
    public let evidenceKind: ProductionReviewEvidenceKindV1

    public var auditKey: String { "style." + source.id }
}
