import Foundation

public enum TreatmentCausalityStoreV2 {
    public static func requireCurrent(dataRoot: URL, approval: Bool = true) throws -> TreatmentCausalityV2 {
        let currentBytes = try read(TreatmentCausalityV2.currentPath, dataRoot: dataRoot)
        let value = try JSONDecoder().decode(TreatmentCausalityV2.self, from: currentBytes)
        let revision = value.header.revision
        try PlanningValidation.require(currentBytes == read(TreatmentCausalityV2.versionPath(revision), dataRoot: dataRoot),
                                       "treatmentCausality.currentMirror")
        let treatmentBytes = try read(PipelineLayout.treatmentCurrentFile, dataRoot: dataRoot)
        let originalBytes = try read(PipelineLayout.treatmentVersionFile(revision), dataRoot: dataRoot)
        try PlanningValidation.require(treatmentBytes == originalBytes
            && value.treatmentReference.sha256 == FileDigest.sha256(of: originalBytes), "treatmentCausality.treatmentMirror")
        let latest = TreatmentStore.nextVersion(dataRoot: dataRoot) - 1
        try PlanningValidation.require(latest == revision, "treatmentCausality.latestTreatment")
        let names = try FileManager.default.contentsOfDirectory(atPath: dataRoot.appendingPathComponent("treatment/causality").path)
        let causalVersions = names.compactMap { name -> Int? in
            guard name.hasPrefix("v"), name.hasSuffix(".v2.json") else { return nil }
            return Int(name.dropFirst().dropLast(".v2.json".count))
        }
        try PlanningValidation.require(causalVersions.max() == revision, "treatmentCausality.latestRevision")
        guard let treatmentText = String(data: treatmentBytes, encoding: .utf8) else {
            throw ProductionPlanningError.invalid("treatmentCausality.treatmentUTF8")
        }
        let treatment = try Treatment.parsing(treatmentText)
        try PlanningValidation.require(treatment.meta.version == revision && treatment.meta.project == value.header.projectID,
                                       "treatmentCausality.treatmentIdentity")
        let briefBytes = try read(PipelineLayout.briefFile, dataRoot: dataRoot)
        guard let briefText = String(data: briefBytes, encoding: .utf8) else {
            throw ProductionPlanningError.invalid("treatmentCausality.briefUTF8")
        }
        let brief = try YAMLCoding.decode(Brief.self, from: briefText)
        try PlanningValidation.require(value.mode.rawValue == brief.conceptType.rawValue, "treatmentCausality.mode")
        try value.header.requireCurrentInputs(dataRoot: dataRoot)
        for reference in [value.treatmentReference, value.briefReference, value.storySourceReference] {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
        let source = try JSONDecoder().decode(StorySourceV1.self, from: read(StorySourceV1.currentPath, dataRoot: dataRoot))
        try PlanningValidation.require(source.header.projectID == value.header.projectID, "treatmentCausality.sourceProject")
        try source.requireCurrentBytes(dataRoot: dataRoot)
        let prior = try history(dataRoot: dataRoot, through: revision - 1)
        if let prior {
            let path = TreatmentCausalityV2.versionPath(prior.header.revision)
            let hash = FileDigest.sha256(of: try read(path, dataRoot: dataRoot))
            try PlanningValidation.require(value.header.inputs.contains { $0.path == path && $0.sha256 == hash },
                                           "treatmentCausality.priorBytes")
        }
        try value.validate(treatmentBody: treatment.bodyMarkdown, previous: prior, approval: approval)
        try value.header.requireCurrentInputs(dataRoot: dataRoot)
        try PlanningValidation.require(currentBytes == read(TreatmentCausalityV2.currentPath, dataRoot: dataRoot),
                                       "treatmentCausality.changedDuringRead")
        return value
    }

    public static func history(dataRoot: URL, through revision: Int) throws -> TreatmentCausalityV2? {
        guard revision > 0 else { return nil }
        var prior: TreatmentCausalityV2?
        for number in 1...revision {
            let bytes = try read(TreatmentCausalityV2.versionPath(number), dataRoot: dataRoot)
            let value = try JSONDecoder().decode(TreatmentCausalityV2.self, from: bytes)
            let treatmentBytes = try read(PipelineLayout.treatmentVersionFile(number), dataRoot: dataRoot)
            guard let text = String(data: treatmentBytes, encoding: .utf8) else {
                throw ProductionPlanningError.invalid("treatmentCausality.historyUTF8")
            }
            let treatment = try Treatment.parsing(text)
            try PlanningValidation.require(value.header.revision == number && treatment.meta.version == number
                && value.header.projectID == treatment.meta.project
                && value.treatmentReference.sha256 == FileDigest.sha256(of: treatmentBytes), "treatmentCausality.historyBytes")
            if let prior {
                let path = TreatmentCausalityV2.versionPath(prior.header.revision)
                let hash = FileDigest.sha256(of: try read(path, dataRoot: dataRoot))
                try PlanningValidation.require(value.header.inputs.contains { $0.path == path && $0.sha256 == hash },
                                               "treatmentCausality.historyPriorBytes")
            }
            try value.validate(treatmentBody: treatment.bodyMarkdown, previous: prior)
            prior = value
        }
        return prior
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
    }
}
