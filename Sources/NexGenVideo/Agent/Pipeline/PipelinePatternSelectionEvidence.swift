import Foundation
import NexGenEngine

enum PipelinePatternSelectionEvidence {
    static func read(dataRoot: URL) throws -> (decision: PatternRecommendationsStore.Decision, references: [CanonicalArtifactReferenceV1])? {
        let path = PatternRecommendationsStore.decisionPath
        let candidate = dataRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: candidate.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil else { return nil }
        let bytes = try exactBytes(path, dataRoot: dataRoot)
        let value = try JSONDecoder().decode(PatternRecommendationsStore.Decision.self, from: bytes)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard value.schema == "native-pattern-selection/v1", value.projectID == project.project,
              UUID(uuidString: value.id)?.uuidString.lowercased() == value.id else { throw invalid() }
        let archive = "brief/pattern-selections/\(value.id)"
        guard bytes == (try exactBytes(archive + ".v1.json", dataRoot: dataRoot)) else { throw invalid() }
        let resultPath = archive + ".recommendations.json"
        let resultBytes = try exactBytes(resultPath, sha256: value.resultSHA256, dataRoot: dataRoot)
        let recorded = try PatternRecommendationsModel.decode(resultBytes)
        var refs = [PlanningWriterIO.reference(path, id: "pattern-choice", role: "host.pattern-choice", bytes: bytes),
            PlanningWriterIO.reference(archive + ".v1.json", id: value.id, role: "host.pattern-choice", bytes: bytes),
            PlanningWriterIO.reference(resultPath, id: value.id + ".recommendations", role: "host.pattern-comparison", bytes: resultBytes)]
        let briefPath = archive + ".brief.yaml"
        let briefBytes = try exactBytes(briefPath, sha256: value.briefSHA256, dataRoot: dataRoot)
        let brief = try YAMLCoding.decode(Brief.self, from: String(decoding: briefBytes, as: UTF8.self))
        try brief.validate()
        guard brief.project == value.projectID, brief.directorPattern == value.patternID,
              brief.generator == "brief-native@pattern-selection/" + value.id,
              value.briefSHA256 == FileDigest.sha256(of: try exactBytes(PipelineLayout.briefFile, dataRoot: dataRoot)) else { throw invalid() }
        refs.append(PlanningWriterIO.reference(briefPath, id: value.id + ".brief", role: "host.pattern-choice-brief", bytes: briefBytes))
        if let selected = value.patternID {
            guard let sha = value.selectedPatternSHA256 else { throw invalid() }
            let patternPath = archive + ".pattern.json"
            let patternBytes = try exactBytes(patternPath, sha256: sha, dataRoot: dataRoot)
            _ = try PatternRecommendationsModel.detail(patternBytes, expectedID: selected)
            refs.append(PlanningWriterIO.reference(patternPath, id: selected, role: "host.pattern-signature", bytes: patternBytes))
            if !value.restored {
                guard let result = recorded.recommendations?.results.first(where: { $0.id == selected }),
                      !result.excluded, value.warnings == result.warnings,
                      !result.requiresDeliberateChoice || !value.reason.isEmpty else { throw invalid() }
            }
        } else if value.selectedPatternSHA256 != nil { throw invalid() }
        return (value, refs)
    }

    static func references(dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] { try read(dataRoot: dataRoot)?.references ?? [] }

    private static func exactBytes(_ path: String, sha256: String? = nil, dataRoot: URL) throws -> Data {
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        guard url.standardizedFileURL == dataRoot.appendingPathComponent(path).standardizedFileURL else { throw invalid() }
        let bytes = try Data(contentsOf: url)
        if let sha256, FileDigest.sha256(of: bytes) != sha256 { throw invalid() }
        return bytes
    }

    private static func invalid() -> GateBlocked {
        GateBlocked("The saved native pattern choice or its comparison changed. Restore its exact decision files before continuing.")
    }
}
