import Foundation

public struct FrameReferenceBindingV1: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let role: String
    public let entityID: String
    public let viewID: String
    public let purpose: String
    public let requirementIDs: [String]
    public let isRequired: Bool
    public let priority: Int

    public init(
        path: String,
        sha256: String,
        role: String,
        entityID: String,
        viewID: String,
        purpose: String,
        requirementIDs: [String],
        isRequired: Bool,
        priority: Int
    ) {
        self.path = path
        self.sha256 = sha256
        self.role = role
        self.entityID = entityID
        self.viewID = viewID
        self.purpose = purpose
        self.requirementIDs = requirementIDs
        self.isRequired = isRequired
        self.priority = priority
    }
}

public struct FrameReferenceDeficitV1: Codable, Sendable, Equatable {
    public let requirementID: String
    public let detail: String

    public init(requirementID: String, detail: String) {
        self.requirementID = requirementID
        self.detail = detail
    }
}

public struct FrameReferencePlanV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "frame-reference-plan/v1"

    public let schema: String
    public let shotID: String
    public let maxReferenceImages: Int
    public let bindings: [FrameReferenceBindingV1]
    public let optionalDrops: [FrameReferenceBindingV1]
    public let deficits: [FrameReferenceDeficitV1]

    public init(
        schema: String = schemaVersion,
        shotID: String,
        maxReferenceImages: Int,
        bindings: [FrameReferenceBindingV1],
        optionalDrops: [FrameReferenceBindingV1] = [],
        deficits: [FrameReferenceDeficitV1] = []
    ) {
        self.schema = schema
        self.shotID = shotID
        self.maxReferenceImages = maxReferenceImages
        self.bindings = bindings
        self.optionalDrops = optionalDrops
        self.deficits = deficits
    }

    public var isExecutable: Bool {
        schema == Self.schemaVersion
            && maxReferenceImages >= 0
            && deficits.isEmpty
            && bindings.count <= maxReferenceImages
            && bindings.filter { $0.isRequired }.count <= maxReferenceImages
            && bindings.allSatisfy {
                !$0.path.isEmpty
                    && $0.sha256.count == 64
                    && $0.sha256.allSatisfy(\.isHexDigit)
                    && !$0.requirementIDs.isEmpty
            }
    }

    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "invalid" }
        return FileDigest.sha256(of: data)
    }
}

public protocol FrameReferencePlanProviding: Sendable {
    func planFrameReferences(
        dataRoot: URL,
        shotID: String,
        maxReferenceImages: Int
    ) -> FrameReferencePlanV1?
}
