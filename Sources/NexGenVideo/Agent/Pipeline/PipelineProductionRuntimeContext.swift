import Darwin
import Foundation
import NexGenEngine

enum PipelineProductionRuntimeContext {
    struct Prepared: Sendable {
        let dataRoot: URL
        let workflow: HostWorkflowKey
        let phase: String?
        let instructions: String?
        let packRevision: UInt64
        let source: ReadFence
        let mediaURLs: [URL: URL]
        let media: PipelineNativeTakeSourceFence.Snapshot

        func requireCurrent(dataRoot: URL, workflow: HostWorkflowKey, phase: String?) throws {
            guard self.dataRoot == dataRoot, self.workflow == workflow, self.phase == phase,
                  packRevision == PackCatalog.revision(named: workflow.packID ?? "") else { throw changed() }
            try source.requireCurrent()
            for (original, resolved) in mediaURLs {
                guard original.resolvingSymlinksInPath().standardizedFileURL == resolved else { throw changed() }
            }
            try media.requireUnchanged()
        }
    }

    static func prepare(dataRoot: URL, declaration: ProjectPackGate.MutationDeclaration,
                        timeline: Timeline, resolver: MediaResolver) throws -> Prepared {
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot,
            expectedPack: declaration.binding, expectedProductionContract: declaration.productionContract),
              workflow.isProductionV2,
              resolver.trustedProductionDeclaration == declaration else { throw changed() }
        let source = try ReadFence.capture(dataRoot: dataRoot)
        let contract = try PhaseContractRuntime.contract(workflow: workflow)
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot, order: contract.order)
        let urls = state.nextPhase == "render" ? Set(timeline.tracks.flatMap(\.clips).filter { $0.mediaType != .text }.compactMap {
            resolver.resolveURL(for: $0.mediaRef)
        }) : Set<URL>()
        let mediaURLs = Dictionary(uniqueKeysWithValues: urls.map { ($0, $0.resolvingSymlinksInPath().standardizedFileURL) })
        let media = try PipelineNativeTakeSourceFence.capture(Array(mediaURLs.values))
        let revision = PackCatalog.revision(named: workflow.packID ?? "")
        let prompt = try state.nextPhase.map {
            try instructions(dataRoot: dataRoot, workflow: workflow, phase: $0, timeline: timeline, resolver: resolver)
        }
        try source.requireCurrent()
        try media.requireUnchanged()
        guard revision == PackCatalog.revision(named: workflow.packID ?? "") else { throw changed() }
        return Prepared(dataRoot: dataRoot, workflow: workflow, phase: state.nextPhase,
            instructions: prompt, packRevision: revision, source: source, mediaURLs: mediaURLs, media: media)
    }

    static func instructions(dataRoot: URL, workflow: HostWorkflowKey, phase: String,
                             timeline: Timeline? = nil, resolver: MediaResolver? = nil) throws -> String {
        guard workflow.isProductionV2 else { throw changed() }
        let contract = try PhaseContractRuntime.contract(workflow: workflow)
        var prompt = try contract.instructions(for: phase)
        if let iteration = TakeRepairPlan.runtimeInstructions(phase: phase) { prompt += "\n\n" + iteration }
        if let timeline, let resolver,
           let repair = PipelineProductionSequenceReviewStore.repairInstructions(dataRoot: dataRoot,
                phase: phase, timeline: timeline, resolver: resolver) {
            prompt += "\n\n" + repair
        }
        if let style = try ProductionStyleContext.prompt(dataRoot: dataRoot, phase: phase) { prompt += "\n\n" + style }
        if let packName = workflow.packID {
            prompt = try PipelineProductionKnowledgeContext.append(to: prompt,
                dataRoot: dataRoot, phase: phase, packName: packName)
        }
        return prompt
    }

    struct ReadFence: Sendable {
        let states: [URL: [Int64]]

        static func capture(dataRoot: URL) throws -> ReadFence {
            let root = dataRoot.standardizedFileURL
            let home = FrameInventory.projectHome(of: root)
            var paths = [home, root, home.appendingPathComponent("ngv.json"), home.appendingPathComponent(".ngv-open-generation")]
                + [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.gatesFile,
                   PipelineLayout.lineageFile, PipelineLayout.productionDesignFile, ResolvedProductionStyleV1.relativePath,
                   StorySourceV1.currentPath, ScriptV1.currentPath, StoryboardTimingV1.currentPath,
                   ShotPlanningDraftV1.currentPath, RenderReviewV1.currentPath, ProductionSequenceReviewV2.relativePath,
                   PlaybackRangeV1.currentPath, "shotlist"].map { root.appendingPathComponent($0) }
            if let bytes = try? Data(contentsOf: root.appendingPathComponent(ProductionSequenceReviewV2.relativePath)),
               let review = try? JSONDecoder().decode(ProductionSequenceReviewV2.self, from: bytes) {
                paths += review.artifactReferences.compactMap { try? ProjectLocalFile.resolve($0.path, dataRoot: root) }
            }
            return ReadFence(states: try Dictionary(uniqueKeysWithValues: Set(paths).map { ($0, try stamp($0)) }))
        }

        func requireCurrent() throws {
            for (path, expected) in states {
                try Task.checkCancellation()
                guard try Self.stamp(path) == expected else { throw changed() }
            }
        }

        private static func stamp(_ url: URL) throws -> [Int64] {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return [] }
                throw changed()
            }
            guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { throw changed() }
            let identity = [Int64(info.st_dev), Int64(bitPattern: info.st_ino), Int64(info.st_mode)]
            if info.st_mode & S_IFMT == S_IFDIR { return identity }
            return identity + [info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
        }
    }

    private static func changed() -> GateBlocked {
        GateBlocked("The project or current production phase changed while its agent context was being prepared. Continue from the current phase.")
    }
}
