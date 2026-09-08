import Foundation

public enum ProductionReviewScopeV1: String, Codable, Sendable {
    case frame, shot, sequence, project
}

public enum ProductionReviewEvidenceKindV1: String, Codable, Sendable {
    case image, video, audio, audiovisual
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
