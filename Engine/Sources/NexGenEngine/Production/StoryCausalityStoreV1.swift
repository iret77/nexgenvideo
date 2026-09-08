import Foundation

public enum StoryCausalityStoreV1 {
    public static let lineageID = "story-causality.v1"
    public static func versionPath(_ version: Int) -> String { "treatment/causality/v\(version).json" }

    public static func history(dataRoot: URL, through version: Int) throws -> StoryCausalityPlanV1? {
        var previous: StoryCausalityPlanV1?
        guard version > 0 else { return nil }
        for number in 1...version {
            let path = versionPath(number)
            let url = dataRoot.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                guard previous == nil, (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                    throw GateBlocked("Story causality history is incomplete at Treatment v\(number).")
                }
                continue
            }
            let plan = try JSONDecoder().decode(StoryCausalityPlanV1.self, from: Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
            let treatmentURL = try ProjectLocalFile.resolve(PipelineLayout.treatmentVersionFile(number), dataRoot: dataRoot)
            let bytes = try Data(contentsOf: treatmentURL)
            guard let text = String(data: bytes, encoding: .utf8) else { throw GateBlocked("Treatment is not UTF-8.") }
            let treatment = try Treatment.parsing(text)
            guard plan.schema == "story-causality/v1", plan.treatmentVersion == number,
                  plan.project == treatment.meta.project, plan.treatmentSHA256 == FileDigest.sha256(of: bytes),
                  Set(plan.affectedBeatIDs) == plan.draft.affectedBeats(comparedWith: previous?.draft) else {
                throw GateBlocked("Story causality does not match Treatment v\(number).")
            }
            try plan.draft.validate(body: treatment.bodyMarkdown, previous: previous?.draft)
            previous = plan
        }
        return previous
    }

    public static func requireCurrent(dataRoot: URL, approval: Bool = true) throws -> StoryCausalityPlanV1? {
        let version = TreatmentStore.nextVersion(dataRoot: dataRoot) - 1
        let plan = try history(dataRoot: dataRoot, through: version)
        let current = dataRoot.appendingPathComponent(StoryCausalityPlanV1.relativePath)
        let trace = try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot)?.phases[lineageID] != nil
        guard let plan else {
            guard !trace, !FileManager.default.fileExists(atPath: current.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else {
                throw GateBlocked("Story causality history is missing. Restore it before continuing.")
            }
            return nil
        }
        let versionBytes = try Data(contentsOf: ProjectLocalFile.resolve(versionPath(version), dataRoot: dataRoot))
        let currentBytes = try Data(contentsOf: ProjectLocalFile.resolve(StoryCausalityPlanV1.relativePath, dataRoot: dataRoot))
        let treatmentBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.treatmentCurrentFile, dataRoot: dataRoot))
        let briefBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: dataRoot))
        let brief = try YAMLCoding.decode(Brief.self, from: String(decoding: briefBytes, as: UTF8.self))
        guard versionBytes == currentBytes, plan.treatmentSHA256 == FileDigest.sha256(of: treatmentBytes),
              plan.briefSHA256 == FileDigest.sha256(of: briefBytes), plan.draft.mode.rawValue == brief.conceptType.rawValue else {
            throw GateBlocked("Story causality is stale. Revise Treatment against the current Brief.")
        }
        try PipelineLineageStore.requireCurrent(phase: lineageID, snapshot: snapshot(dataRoot: dataRoot), dataRoot: dataRoot)
        if approval, !plan.draft.unresolvedDecisions.isEmpty {
            throw GateBlocked("Resolve Treatment's listed canon alternatives before approval.")
        }
        return plan
    }

    public static func snapshot(dataRoot: URL) throws -> PhaseLineageSnapshot {
        let paths = [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.treatmentCurrentFile]
        let inputs = try paths.map { $0 + ":" + (try FileDigest.sha256(of: ProjectLocalFile.resolve($0, dataRoot: dataRoot))) }.joined(separator: "\n")
        return PhaseLineageSnapshot(inputFingerprint: FileDigest.sha256(of: Data(inputs.utf8)),
            artifactFingerprint: try FileDigest.sha256(of: ProjectLocalFile.resolve(StoryCausalityPlanV1.relativePath, dataRoot: dataRoot)))
    }

    @discardableResult
    public static func write(treatment: Treatment, draft: StoryCausalityDraftV1, dataRoot: URL) throws -> URL {
        let version = treatment.meta.version
        guard version == TreatmentStore.nextVersion(dataRoot: dataRoot) else { throw GateBlocked("Treatment versions cannot be overwritten.") }
        let previous = try history(dataRoot: dataRoot, through: version - 1)
        if previous == nil, try PipelineLineageStore.loadIfPresent(dataRoot: dataRoot)?.phases[lineageID] != nil {
            throw GateBlocked("Restore missing story causality history before revising Treatment.")
        }
        let briefURL = try ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: dataRoot)
        let briefBytes = try Data(contentsOf: briefURL)
        let brief = try YAMLCoding.decode(Brief.self, from: String(decoding: briefBytes, as: UTF8.self))
        guard draft.mode.rawValue == brief.conceptType.rawValue else { throw GateBlocked("Causality mode must follow the approved Brief concept type.") }
        try draft.validate(body: treatment.bodyMarkdown, previous: previous?.draft)
        let treatmentBytes = Data(try treatment.serialized().utf8)
        let plan = StoryCausalityPlanV1(schema: "story-causality/v1", project: treatment.meta.project,
            treatmentVersion: version, treatmentSHA256: FileDigest.sha256(of: treatmentBytes),
            briefSHA256: FileDigest.sha256(of: briefBytes), draft: draft,
            affectedBeatIDs: draft.affectedBeats(comparedWith: previous?.draft).sorted())
        let paths = [PipelineLayout.treatmentVersionFile(version), PipelineLayout.treatmentCurrentFile,
                     versionPath(version), StoryCausalityPlanV1.relativePath, PipelineLayout.lineageFile]
        let urls = paths.map { dataRoot.appendingPathComponent($0) }
        guard !FileManager.default.fileExists(atPath: urls[2].path) else { throw GateBlocked("Causality versions cannot be overwritten.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(plan)
        try ArtifactTransaction.perform(paths: urls, dataRoot: dataRoot) {
            guard briefBytes == (try Data(contentsOf: briefURL)) else { throw GateBlocked("Brief changed while preparing Treatment.") }
            for url in urls { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            try treatmentBytes.write(to: urls[0], options: .atomic)
            try treatmentBytes.write(to: urls[1], options: .atomic)
            try bytes.write(to: urls[2], options: .atomic)
            try bytes.write(to: urls[3], options: .atomic)
            try PipelineLineageStore.record(phase: lineageID, snapshot: snapshot(dataRoot: dataRoot), dataRoot: dataRoot)
        }
        return urls[0]
    }
}
