import Foundation

public struct ProductionTechnique34: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable { case A, B, C }
    public enum Status: String, Codable, Sendable { case decision, assumed }
    public let sourceVersion: String
    public let choice: Choice
    public let recommended: Choice
    public let reason: String
    public let recommendationReason: String
    public let status: Status
    public let assumptionScope: String
    public let mediumID: String?
    public let masterStyleLayers: [String]

    public func validate() throws {
        func filled(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard sourceVersion == "3.4", filled(reason), filled(recommendationReason),
              status != .assumed || filled(assumptionScope) else {
            throw GateBlocked("A technique decision needs source 3.4, a choice reason, recommendation reason and an exact ASSUMED scope when applicable.")
        }
        if choice == .C {
            guard let mediumID, masterStyleLayers.count == 7, masterStyleLayers.allSatisfy(filled) else {
                throw GateBlocked("Technique C needs one medium and all seven physical-medium layers.")
            }
            _ = try EngineProductionKnowledgeResourcesV1.loadArchive34().readTechnique("C", mediumID: mediumID)
        } else if mediumID != nil || !masterStyleLayers.isEmpty {
            throw GateBlocked("Only technique C carries a Master Style Block; do not mix technique shapes.")
        }
    }
}

public enum ProductionTechniqueStore34 {
    public static let path = "production_design/prompt-technique.3.4.json"
    public static let lineageID = "production-technique.3.4"

    public static func load(dataRoot: URL) throws -> ProductionTechnique34? {
        let url = dataRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
                || (try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot))?.phases[lineageID] != nil {
                throw GateBlocked("The recorded prompt technique is missing. Restore it or explicitly rewind Production Design.")
            }
            return nil
        }
        let before = try snapshot(dataRoot: dataRoot)
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        guard FileDigest.sha256(of: bytes) == before.artifactFingerprint else {
            throw GateBlocked("The prompt technique changed while reading it.")
        }
        let decision = try JSONDecoder().decode(ProductionTechnique34.self, from: bytes)
        try decision.validate()
        try PipelineLineageStore.requireCurrent(phase: lineageID, snapshot: before, dataRoot: dataRoot)
        guard before == (try snapshot(dataRoot: dataRoot)) else {
            throw GateBlocked("The prompt technique inputs changed while reading them.")
        }
        return decision
    }

    public static func snapshot(dataRoot: URL) throws -> PhaseLineageSnapshot {
        let inputs = try [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.productionDesignFile].map {
            $0 + ":" + (try FileDigest.sha256(of: ProjectLocalFile.resolve($0, dataRoot: dataRoot)))
        }.joined(separator: "\n")
        return PhaseLineageSnapshot(inputFingerprint: FileDigest.sha256(of: Data(inputs.utf8)),
            artifactFingerprint: try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }

    public static func write(_ decision: ProductionTechnique34, dataRoot: URL) throws {
        try decision.validate()
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        guard !gates.get("production_design").approved else {
            throw GateBlocked("Explicitly rewind Production Design before changing its prompt technique.")
        }
        let target = dataRoot.appendingPathComponent(path)
        let previous: Data? = FileManager.default.fileExists(atPath: target.path)
            ? try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)) : nil
        let history = previous.map { dataRoot.appendingPathComponent("production_design/technique-history/\(FileDigest.sha256(of: $0)).json") }
        let paths = [target, dataRoot.appendingPathComponent(PipelineLayout.lineageFile)] + [history].compactMap { $0 }
        try ArtifactTransaction.perform(paths: paths, dataRoot: dataRoot) {
            if let previous, let history {
                try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: history.path) {
                    guard try Data(contentsOf: history) == previous else { throw GateBlocked("Prompt-technique history changed.") }
                } else { try previous.write(to: history, options: .atomic) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(decision).write(to: target, options: .atomic)
            try PipelineLineageStore.record(phase: lineageID, snapshot: snapshot(dataRoot: dataRoot), dataRoot: dataRoot)
        }
    }
}
