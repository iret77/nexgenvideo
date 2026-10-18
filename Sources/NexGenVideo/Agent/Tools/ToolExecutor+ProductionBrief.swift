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
        let range = workflow.packID == "musicvideo" ? try await measuredPlaybackRange(editor: editor, dataRoot: root) : nil
        let paths = [PipelineLayout.briefFile, PipelineLayout.projectFile, StorySourceV1.currentPath,
                     PlaybackRangeV1.currentPath, PipelineLayout.gatesFile, PipelineLayout.lineageFile]
            .map { root.appendingPathComponent($0) }
        var result: ToolResult?
        try ArtifactTransaction.perform(paths: paths, dataRoot: root) {
            try access.revalidate()
            if let range { try range.requireCurrentInputs(dataRoot: root) }
            let written = try writeBriefTool(editor, args, allowsGenericMode: workflow.packID == nil)
            let source = try PipelineStorySourceWriter.bindCurrentSelection(access: access)
            try PipelineStorySourceWriter.requireConfirmed(source, workflowID: workflow.contractID, dataRoot: root)
            var files = [(StorySourceV1.currentPath, try PlanningWriterIO.json(source))]
            if let range {
                let brief = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: root)
                let header = PlanningArtifactHeaderV1(projectID: source.header.projectID, revision: 1, origin: .userRevision,
                    inputs: [brief, range.analysis, range.audio])
                let playback = PlaybackRangeV1(header: header, kind: .fullSong, analysis: range.analysis,
                    timebase: range.timebase, audioDurationTicks: range.durationTicks, startTicks: 0, durationTicks: range.durationTicks)
                try playback.validate()
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

    private struct MeasuredPlaybackRange {
        let analysis: CanonicalArtifactReferenceV1
        let audio: CanonicalArtifactReferenceV1
        let timebase: RationalTimebaseV1
        let durationTicks: Int64

        func requireCurrentInputs(dataRoot: URL) throws {
            for reference in [analysis, audio] {
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
            }
        }
    }

    private func measuredPlaybackRange(editor: EditorViewModel, dataRoot: URL) async throws -> MeasuredPlaybackRange {
        let measured = try currentMeasuredAnalysis(dataRoot: dataRoot)
        let analysis = try PlanningWriterIO.reference(FrameInventory.relativePath(of: measured.url, to: dataRoot),
            id: "analysis", role: "musicvideo.analysis", dataRoot: dataRoot)
        let audio = try PlanningWriterIO.reference(FrameInventory.relativePath(of: measured.song, to: dataRoot),
            id: "audio", role: "musicvideo.track", dataRoot: dataRoot)
        let duration = try await AVURLAsset(url: measured.song).load(.duration)
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0, editor.timeline.fps > 0 else {
            throw ToolError("The selected track has no exact readable duration.")
        }
        let scale = Int64(duration.timescale)
        let fps = Int64(editor.timeline.fps)
        var first = scale
        var second = fps
        while second != 0 { (first, second) = (second, first % second) }
        let product = (scale / first).multipliedReportingOverflow(by: fps)
        guard !product.overflow, product.partialValue <= Int64(Int32.max) else {
            throw ToolError("The track and frame rate have no supported exact common timebase.")
        }
        let ticks = duration.value.multipliedReportingOverflow(by: product.partialValue / scale)
        guard !ticks.overflow, ticks.partialValue > 0 else { throw ToolError("The track duration exceeds the supported timebase.") }
        let timebase = RationalTimebaseV1(ticksPerSecond: product.partialValue, fpsNumerator: fps)
        try timebase.validate()
        let range = MeasuredPlaybackRange(analysis: analysis, audio: audio, timebase: timebase, durationTicks: ticks.partialValue)
        try range.requireCurrentInputs(dataRoot: dataRoot)
        return range
    }
}
