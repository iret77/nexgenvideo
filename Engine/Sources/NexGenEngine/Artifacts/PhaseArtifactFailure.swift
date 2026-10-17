import Foundation

public struct PhaseArtifactFailure: Error, Sendable, Equatable, LocalizedError {
    public enum Requirement: String, Sendable, Equatable {
        case document, entities, priorArtifacts, projectIdentity, style, lighting
        case referenceImages, imageProvenance, identityVariants, locations, locationViews
        case characterViews, props
    }

    public let requirement: Requirement
    public let diagnostic: String

    public init(_ requirement: Requirement, diagnostic: String) {
        self.requirement = requirement
        self.diagnostic = diagnostic
    }

    public var errorDescription: String? { diagnostic }
}
