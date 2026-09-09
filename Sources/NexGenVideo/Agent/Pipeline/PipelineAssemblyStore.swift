import Foundation
import NexGenEngine

enum PipelineAssemblyStore {
    enum DriftAction: String {
        case adopt
        case rebuild
    }

    struct ExistingState {
        let policy: AssemblyPolicyV1
        let plan: AssemblyPlanV1
        let manifest: AssemblyManifestV1
    }

    static let policyPath = "assembly/policy.v1.json"

    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func fingerprint(timeline: Timeline) throws -> String {
        FileDigest.sha256(of: try canonical(timeline))
    }

    static func regionFingerprint(
        timeline: Timeline,
        videoTrackID: String?,
        audioTrackID: String?
    ) throws -> String? {
        let ids = Set([videoTrackID, audioTrackID].compactMap { $0 })
        guard !ids.isEmpty else { return nil }
        let tracks = timeline.tracks.filter { ids.contains($0.id) }
            .sorted { $0.id < $1.id }
        guard !tracks.isEmpty else { return nil }
        return FileDigest.sha256(of: try canonical(tracks))
    }

    static func load(dataRoot: URL) throws -> ExistingState? {
        let planURL = dataRoot.appendingPathComponent(AssemblyPlanV1.relativePath)
        let manifestURL = dataRoot.appendingPathComponent(AssemblyManifestV1.relativePath)
        let policyURL = dataRoot.appendingPathComponent(policyPath)
        let planExists = FileManager.default.fileExists(atPath: planURL.path)
        let manifestExists = FileManager.default.fileExists(atPath: manifestURL.path)
        let policyExists = FileManager.default.fileExists(atPath: policyURL.path)
        guard planExists == manifestExists, manifestExists == policyExists else {
            throw ToolError("The assembly plan and manifest are incomplete. Restore both records before rebuilding the cut.")
        }
        guard planExists else { return nil }
        let policyData = try Data(contentsOf: ProjectLocalFile.resolve(policyPath, dataRoot: dataRoot))
        let planData = try Data(contentsOf: ProjectLocalFile.resolve(AssemblyPlanV1.relativePath, dataRoot: dataRoot))
        let manifestData = try Data(contentsOf: ProjectLocalFile.resolve(AssemblyManifestV1.relativePath, dataRoot: dataRoot))
        let policy = try JSONDecoder().decode(AssemblyPolicyV1.self, from: policyData)
        let plan = try JSONDecoder().decode(AssemblyPlanV1.self, from: planData)
        let manifest = try JSONDecoder().decode(AssemblyManifestV1.self, from: manifestData)
        guard plan.policySHA256 == FileDigest.sha256(of: policyData),
              manifest.planSHA256 == FileDigest.sha256(of: planData) else {
            throw ToolError("The assembly transaction is incomplete. Restore its matching plan and manifest before editing the cut.")
        }
        try AssemblyValidatorV1.validate(
            manifest: manifest,
            plan: plan,
            planSHA256: manifest.planSHA256,
            policy: policy
        )
        return ExistingState(
            policy: policy,
            plan: plan,
            manifest: manifest
        )
    }

    static func persist(
        policy: AssemblyPolicyV1,
        plan: AssemblyPlanV1,
        planData: Data,
        manifest: AssemblyManifestV1,
        dataRoot: URL
    ) throws {
        try AssemblyValidatorV1.validate(plan: plan, policy: policy)
        let policyData = try canonical(policy)
        guard FileDigest.sha256(of: policyData) == plan.policySHA256,
              plan.policyPath == policyPath,
              try canonical(plan) == planData else {
            throw ToolError("The assembly plan does not bind the exact resolved policy bytes.")
        }
        try AssemblyValidatorV1.validate(
            manifest: manifest,
            plan: plan,
            planSHA256: FileDigest.sha256(of: planData),
            policy: policy
        )
        let manifestData = try canonical(manifest)
        let policyURL = dataRoot.appendingPathComponent(policyPath)
        let planURL = dataRoot.appendingPathComponent(AssemblyPlanV1.relativePath)
        let manifestURL = dataRoot.appendingPathComponent(AssemblyManifestV1.relativePath)
        try ArtifactTransaction.perform(paths: [policyURL, planURL, manifestURL], dataRoot: dataRoot) {
            try FileManager.default.createDirectory(at: policyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try policyData.write(to: policyURL, options: .atomic)
            try planData.write(to: planURL, options: .atomic)
            try manifestData.write(to: manifestURL, options: .atomic)
        }
    }

    static func requireCurrentSources(_ selected: [SelectedShotMediaV1], dataRoot: URL) throws {
        for item in selected {
            let source = try ProjectLocalFile.resolve(item.sourcePath, dataRoot: dataRoot)
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == item.sourceByteCount,
                  try FileDigest.sha256(of: source) == item.sourceSHA256 else {
                throw ToolError("Assembly source '\(item.shotID)' changed or is offline. Restore the exact selected bytes before editing the timeline.")
            }
            if let reviewPath = item.reviewPath, let reviewSHA256 = item.reviewSHA256 {
                _ = try ProjectLocalFile.requireHash(reviewSHA256, at: reviewPath, dataRoot: dataRoot)
            }
        }
    }

    static func idempotencyKey(planData: Data) -> String {
        FileDigest.sha256(of: Data((FileDigest.sha256(of: planData) + "\napply/v1").utf8))
    }
}
