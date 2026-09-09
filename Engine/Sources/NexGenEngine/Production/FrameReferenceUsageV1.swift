import Foundation

public struct FrameReferenceUsageV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "frame-reference-usage/v1"

    public let schema: String
    public let shotID: String
    public let role: String
    public let outputPath: String
    public let outputSHA256: String
    public let modelID: String
    public let generationPackageID: String
    public let plan: FrameReferencePlanV1

    public init(
        shotID: String,
        role: String,
        outputPath: String,
        outputSHA256: String,
        modelID: String,
        generationPackageID: String,
        plan: FrameReferencePlanV1
    ) {
        schema = Self.schemaVersion
        self.shotID = shotID
        self.role = role
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.modelID = modelID
        self.generationPackageID = generationPackageID
        self.plan = plan
    }
}

public enum FrameReferenceUsageStoreV1 {
    public static func path(shotID: String, role: String) -> String {
        "frames/reference-usage/\(shotID)-\(role).v1.json"
    }

    public static func encode(_ usage: FrameReferenceUsageV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(usage)
    }

    public static func load(
        shotID: String,
        role: String,
        dataRoot: URL
    ) throws -> FrameReferenceUsageV1 {
        let relativePath = path(shotID: shotID, role: role)
        let url = try ProjectLocalFile.resolve(relativePath, dataRoot: dataRoot)
        let data = try Data(contentsOf: url)
        let usage = try JSONDecoder().decode(FrameReferenceUsageV1.self, from: data)
        guard try encode(usage) == data else {
            throw GateBlocked("The frame reference proof is not canonical.")
        }
        return usage
    }

    public static func requireCurrent(
        shotID: String,
        role: String,
        framePath: String,
        modelID: String,
        provider: any FrameReferencePlanProviding,
        dataRoot: URL
    ) throws {
        let usage = try load(shotID: shotID, role: role, dataRoot: dataRoot)
        guard usage.schema == FrameReferenceUsageV1.schemaVersion,
              usage.shotID == shotID,
              usage.role == role,
              usage.outputPath == framePath,
              usage.modelID == modelID,
              usage.generationPackageID.count == 64,
              usage.generationPackageID.allSatisfy(\.isHexDigit),
              usage.plan.isExecutable,
              usage.plan.shotID == shotID else {
            throw GateBlocked("The frame reference proof has the wrong identity.")
        }
        _ = try ProjectLocalFile.requireHash(
            usage.outputSHA256,
            at: usage.outputPath,
            dataRoot: dataRoot
        )
        for binding in usage.plan.bindings {
            _ = try ProjectLocalFile.requireHash(
                binding.sha256,
                at: binding.path,
                dataRoot: dataRoot
            )
        }
        guard let current = provider.planFrameReferences(
            dataRoot: dataRoot,
            shotID: shotID,
            maxReferenceImages: usage.plan.maxReferenceImages
        ), current == usage.plan else {
            throw GateBlocked("The frame references no longer match the current semantic plan.")
        }
    }
}
