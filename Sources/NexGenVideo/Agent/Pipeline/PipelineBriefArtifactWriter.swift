import Foundation
import NexGenEngine

enum PipelineBriefArtifactWriter {
    static func write(_ brief: Brief, dataRoot: URL, replacingNativePatternChoice: Bool = false) throws {
        try brief.validate()
        guard let mode = Mode(rawValue: brief.projectMode) else {
            throw ToolError("brief rejected — project_mode '\(brief.projectMode)' is unsupported.")
        }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let project: ProjectMeta
        do { project = try store.load(ProjectMeta.self, at: PipelineLayout.projectFile) }
        catch { throw ToolError("Couldn't synchronize the brief with project.yaml: \(error)") }
        guard project.project == brief.project else {
            throw ToolError("brief rejected — project.yaml belongs to '\(project.project)', not '\(brief.project)'.")
        }
        let synchronized = ProjectMeta(project: project.project, mode: mode,
            budgetEur: brief.budgetEur, created: project.created)
        do { try synchronized.validate() }
        catch { throw ToolError("brief rejected — project metadata would be invalid: \(error)") }
        let briefURL = dataRoot.appendingPathComponent(PipelineLayout.briefFile)
        let projectURL = dataRoot.appendingPathComponent(PipelineLayout.projectFile)
        let previousChoice = try PipelinePatternSelectionEvidence.read(dataRoot: dataRoot)
        let choiceURL = dataRoot.appendingPathComponent(PatternRecommendationsStore.decisionPath)
        try ArtifactTransaction.perform(paths: [briefURL, projectURL, choiceURL], dataRoot: dataRoot) {
            if FileManager.default.fileExists(atPath: briefURL.path) {
                let source = try ProjectLocalFile.resolve(PipelineLayout.briefFile, dataRoot: dataRoot)
                let history = try ProjectLocalFile.ensureDirectory("history", dataRoot: dataRoot)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                do {
                    try FileManager.default.copyItem(at: source,
                        to: history.appendingPathComponent("brief-\(stamp)-\(UUID().uuidString).yaml"))
                } catch { throw ToolError("Couldn't preserve the previous \(PipelineLayout.briefFile): \(error)") }
            }
            try store.save(brief, to: PipelineLayout.briefFile)
            try store.save(synchronized, to: PipelineLayout.projectFile)
            if previousChoice != nil, !replacingNativePatternChoice { try FileManager.default.removeItem(at: choiceURL) }
        }
    }
}
