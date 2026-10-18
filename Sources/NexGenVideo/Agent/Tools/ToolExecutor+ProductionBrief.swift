import AVFoundation
import Foundation
import NexGenEngine

extension ToolExecutor {
    func writeProductionBriefTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let root = try resolveDataRoot(args, editor: editor)
        let declaration = try mutationPackDeclaration(editor, dataRoot: root)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root,
            expectedPack: declaration.binding, expectedProductionContract: declaration.productionContract), workflow.isProductionV2 else {
            return try writeBriefTool(editor, args)
        }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "brief")
        guard try PipelineStorySourceWriter.confirmedSelection(dataRoot: root, workflowID: workflow.contractID) != nil else {
            throw ToolError("Choose existing story material or Develop from scratch in the native story card first.")
        }
        let range = workflow.packID == "musicvideo" ? try await PipelinePlaybackRangeWriter.capture(editor: editor) : nil
        let paths = [PipelineLayout.briefFile, PipelineLayout.projectFile, StorySourceV1.currentPath,
                     PlaybackRangeV1.currentPath, PipelineLayout.gatesFile, PipelineLayout.lineageFile]
            .map { root.appendingPathComponent($0) }
        var result: ToolResult?
        try ArtifactTransaction.perform(paths: paths, dataRoot: root) {
            try access.revalidate()
            if let range { try PipelinePlaybackRangeWriter.requireCurrent(range, dataRoot: root) }
            let written = try writeBriefTool(editor, args, allowsGenericMode: workflow.packID == nil)
            let source = try PipelineStorySourceWriter.bindCurrentSelection(access: access)
            try PipelineStorySourceWriter.requireConfirmed(source, workflowID: workflow.contractID, dataRoot: root)
            var files = [(StorySourceV1.currentPath, try PlanningWriterIO.json(source))]
            if let range {
                let brief = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: root)
                let playback = try PipelinePlaybackRangeWriter.materialize(range, brief: brief)
                files.append((PlaybackRangeV1.currentPath, try PlanningWriterIO.json(playback)))
            }
            try access.publish(files) {
                let current = try PlanningWriterIO.read(StorySourceV1.self, at: StorySourceV1.currentPath, dataRoot: root)
                try PipelineStorySourceWriter.requireConfirmed(current, workflowID: workflow.contractID, dataRoot: root)
            }
            result = written
        }
        guard let result else { throw ToolError("The Brief could not be published.") }
        return result
    }

}
