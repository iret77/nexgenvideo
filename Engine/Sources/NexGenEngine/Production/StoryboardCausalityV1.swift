import Foundation

public struct StoryboardCausalityV1: Codable, Sendable, Equatable {
    public struct Binding: Codable, Sendable, Equatable {
        public let stepID: String
        public let beatIDs: [String]
        public let reason: String
    }
    public static let relativePath = "storyboard/causality.json"
    public let schema: String
    public let treatmentPlanSHA256: String
    public let storyboardSHA256: String
    public let bindings: [Binding]

    private static func validate(_ bindings: [Binding], storyboard: Storyboard, plan: StoryCausalityPlanV1) throws {
        let steps = storyboard.allSteps()
        guard storyboard.meta.project == plan.project, Set(steps.map(\.id)).count == steps.count,
              Set(bindings.map(\.stepID)) == Set(steps.map(\.id)), bindings.count == steps.count else {
            throw GateBlocked("Storyboard causality must map each step exactly once.")
        }
        let known = Set(plan.draft.beats.map(\.id))
        for binding in bindings {
            guard !binding.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(binding.beatIDs).count == binding.beatIDs.count,
                  Set(binding.beatIDs).isSubset(of: known) else {
                throw GateBlocked("Storyboard step \(binding.stepID) needs known, unique beat IDs and a concrete adaptation reason.")
            }
            if steps.first(where: { $0.id == binding.stepID })?.function == .story, binding.beatIDs.isEmpty {
                throw GateBlocked("Story step \(binding.stepID) must derive from a Treatment beat; revise Treatment before inventing new canon.")
            }
        }
        guard Set(bindings.flatMap(\.beatIDs)) == known else {
            throw GateBlocked("Storyboard omits Treatment beats. Revise the Treatment explicitly before dropping their causes or payoffs.")
        }
    }

    @discardableResult
    public static func write(storyboard: Storyboard, bindings: [Binding]?, dataRoot: URL) throws -> URL {
        guard let plan = try StoryCausalityStoreV1.requireCurrent(dataRoot: dataRoot) else {
            guard bindings == nil else { throw GateBlocked("Write Treatment causality before mapping Storyboard beats.") }
            return try StoryboardStore.save(storyboard, to: dataRoot)
        }
        guard let bindings else { throw GateBlocked("write_storyboard requires causality_bindings for the current Treatment.") }
        try validate(bindings, storyboard: storyboard, plan: plan)
        let version = storyboard.meta.version
        guard version == StoryboardStore.nextVersion(dataRoot: dataRoot) else { throw GateBlocked("Storyboard versions cannot be overwritten.") }
        let paths = [PipelineLayout.storyboardVersionFile(version), PipelineLayout.storyboardCurrentFile,
                     "storyboard/causality/v\(version).json", relativePath]
        let urls = paths.map { dataRoot.appendingPathComponent($0) }
        guard !FileManager.default.fileExists(atPath: urls[2].path) else { throw GateBlocked("Storyboard causality versions cannot be overwritten.") }
        let source = try FileDigest.sha256(of: ProjectLocalFile.resolve(StoryCausalityPlanV1.relativePath, dataRoot: dataRoot))
        try ArtifactTransaction.perform(paths: urls, dataRoot: dataRoot) {
            _ = try StoryboardStore.save(storyboard, to: dataRoot)
            let value = Self(schema: "storyboard-causality/v1", treatmentPlanSHA256: source,
                storyboardSHA256: try FileDigest.sha256(of: urls[0]), bindings: bindings)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let bytes = try encoder.encode(value)
            try FileManager.default.createDirectory(at: urls[2].deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: urls[2], options: .atomic)
            try bytes.write(to: urls[3], options: .atomic)
            _ = try requireCurrent(dataRoot: dataRoot)
        }
        return urls[0]
    }

    public static func requireCurrent(dataRoot: URL) throws -> Self? {
        guard let plan = try StoryCausalityStoreV1.requireCurrent(dataRoot: dataRoot) else { return nil }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(relativePath, dataRoot: dataRoot))
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard let storyboard = try StoryboardStore.load(dataRoot: dataRoot) else { throw GateBlocked("Storyboard is missing.") }
        guard storyboard.meta.version == StoryboardStore.nextVersion(dataRoot: dataRoot) - 1 else {
            throw GateBlocked("Storyboard current mirror does not identify its latest version.")
        }
        let versionBytes = try Data(contentsOf: ProjectLocalFile.resolve("storyboard/causality/v\(storyboard.meta.version).json", dataRoot: dataRoot))
        let storyboardBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.storyboardCurrentFile, dataRoot: dataRoot))
        let originalBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.storyboardVersionFile(storyboard.meta.version), dataRoot: dataRoot))
        guard value.schema == "storyboard-causality/v1", bytes == versionBytes, storyboardBytes == originalBytes,
              value.storyboardSHA256 == FileDigest.sha256(of: storyboardBytes),
              value.treatmentPlanSHA256 == (try FileDigest.sha256(of: ProjectLocalFile.resolve(StoryCausalityPlanV1.relativePath, dataRoot: dataRoot))) else {
            throw GateBlocked("Storyboard causality is stale. Revise Storyboard against the approved Treatment.")
        }
        try validate(value.bindings, storyboard: storyboard, plan: plan)
        return value
    }
}
