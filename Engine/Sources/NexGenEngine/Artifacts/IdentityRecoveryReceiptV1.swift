import Foundation

public struct IdentityRecoveryPhaseBindingV1: Codable, Sendable, Equatable {
    public let original: PhaseLineageEntry
    public let recovered: PhaseLineageEntry

    public init(original: PhaseLineageEntry, recovered: PhaseLineageEntry) {
        self.original = original
        self.recovered = recovered
    }
}

public struct IdentityRecoveryReceiptV1: Codable, Sendable, Equatable {
    public let schema: String
    public let projectID: String
    public let sourceSchema: String
    public let targetSchema: String
    public let originalManifestSHA256: String
    public let recoveredManifestSHA256: String
    public let originalLineageSHA256: String?
    public let gatesSHA256: String
    public let aliases: [DerivedIdentityAssetV1]
    public let phases: [String: IdentityRecoveryPhaseBindingV1]
    public let stalePhases: [String]

    public init(projectID: String, originalManifestSHA256: String, recoveredManifestSHA256: String, originalLineageSHA256: String?, gatesSHA256: String, aliases: [DerivedIdentityAssetV1], phases: [String: IdentityRecoveryPhaseBindingV1], stalePhases: [String]) {
        schema = "identity-recovery/v1"
        self.projectID = projectID
        sourceSchema = "musicvideo/2.0.0"
        targetSchema = "musicvideo/2.1.0"
        self.originalManifestSHA256 = originalManifestSHA256
        self.recoveredManifestSHA256 = recoveredManifestSHA256
        self.originalLineageSHA256 = originalLineageSHA256
        self.gatesSHA256 = gatesSHA256
        self.aliases = aliases
        self.phases = phases
        self.stalePhases = stalePhases
    }
}

public enum IdentityRecoveryReceiptStoreV1 {
    public static let relativePath = "recovery/identity-provenance.v1.json"
    public static let rebindPath = "recovery/identity-provenance-rebind.v1.json"

    public static func load(dataRoot: URL) throws -> IdentityRecoveryReceiptV1 {
        let url = try ProjectLocalFile.resolve(relativePath, dataRoot: dataRoot)
        let receipt = try JSONDecoder().decode(IdentityRecoveryReceiptV1.self, from: Data(contentsOf: url))
        guard receipt.schema == "identity-recovery/v1",
              receipt.sourceSchema == "musicvideo/2.0.0",
              receipt.targetSchema == "musicvideo/2.1.0",
              receipt.projectID == (try DerivedIdentityAssetStoreV1.projectID(dataRoot: dataRoot)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return receipt
    }

    public static func save(_ receipt: IdentityRecoveryReceiptV1, dataRoot: URL) throws {
        _ = try ProjectLocalFile.ensureDirectory("recovery", dataRoot: dataRoot)
        let destination = dataRoot.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        try JSONArtifactStore(dataRoot: dataRoot).save(receipt, to: relativePath)
    }
}
