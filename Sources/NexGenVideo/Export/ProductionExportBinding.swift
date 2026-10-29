import AVFoundation
import NexGenEngine

enum ProductionExportBinding {
    struct Snapshot: Sendable, Equatable {
        let home: URL
        let range: CMTimeRange
        let fingerprint: String
    }

    @MainActor
    static func capture(timeline: Timeline, resolver: MediaResolver) async throws -> Snapshot? {
        guard let home = resolver.projectHome else { return nil }
        let trusted = resolver.trustedProductionDeclaration
        let urls = resolver.expectedURLMap(for: Set(timeline.tracks.flatMap(\.clips).map(\.mediaRef)))
        return try await Task.detached(priority: .utility) { () throws -> Snapshot? in
            if let trusted {
                _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: trusted.packName,
                    declaredBinding: trusted.binding, declaredProductionContract: trusted.productionContract)
            }
            guard let root = DataRootResolver.dataRoot(of: home) else {
                guard trusted?.productionContract == nil,
                      trusted?.binding?.projectSchema != HostWorkflowKey.musicvideoV2Schema else {
                    throw ToolError("The production project cannot be read. Restore its project data before exporting.")
                }
                return nil
            }
            let declaration: ProjectPackGate.MutationDeclaration
            if let trusted {
                declaration = trusted
            } else {
                declaration = try ProjectPackGate.captureMutationDeclaration(projectURL: home)
                guard declaration.productionContract == nil,
                      ![ScriptV1.currentPath, StoryboardV2.currentPath, ShotPlanningDraftV1.currentPath,
                        ProductionPlanAssemblyProofV1.relativePath].contains(where: {
                            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                        }) else {
                    throw ToolError("Reopen the production project to restore its trusted workflow before exporting.")
                }
            }
            guard try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
                expectedProductionContract: declaration.productionContract)?.isProductionV2 == true else { return nil }
            guard trusted != nil else {
                throw ToolError("Reopen the production project to restore its trusted workflow before exporting.")
            }
            let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
            guard gates.get("render").approved else {
                throw ToolError("Approve Render and review the finished cut before exporting the production.")
            }
            try PipelineProductionAssemblyWriter.requireExportTimeline(dataRoot: root, timeline: timeline, mediaURLs: urls)
            let range = try PipelineProductionAssemblyWriter.exportRange(dataRoot: root, timeline: timeline)
            let references = try PipelineProductionAssemblyWriter.artifactReferences(dataRoot: root)
            let fingerprint = FileDigest.sha256(of: try PlanningWriterIO.json(references))
            return Snapshot(home: home, range: range, fingerprint: fingerprint)
        }.value
    }

    @MainActor
    static func revalidate(_ expected: Snapshot?, timeline: Timeline, resolver: MediaResolver) async throws {
        guard try await capture(timeline: timeline, resolver: resolver) == expected else {
            throw ToolError("The production's sources, selected takes or output range changed. Review the current cut before exporting again.")
        }
    }
}
