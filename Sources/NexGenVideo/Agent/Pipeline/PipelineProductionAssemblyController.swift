import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionAssemblyController {
    enum State: String, Sendable { case ready, assembled, drifted, blocked }

    struct Snapshot: Sendable, Equatable {
        let projectKey: String
        let fingerprint: String
        let state: State
        let message: String
    }

    static func capture(editor: EditorViewModel) async throws -> Snapshot {
        let context = try PipelineProductionAssemblyWriter.Context(editor: editor)
        let result = try await Task.detached(priority: .userInitiated) { try read(context) }.value
        try context.requireCurrent(editor: editor)
        return result
    }

    @discardableResult
    static func build(expected: Snapshot, rebuild: Bool = false, editor: EditorViewModel) async throws -> ProductionPlanAssemblyProofV1 {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Build production cut")
        defer { access.end(editor: editor) }
        let context = try PipelineProductionAssemblyWriter.Context(editor: editor)
        let current = try await Task.detached(priority: .userInitiated) { try read(context) }.value
        try access.requireCurrent(editor: editor)
        try context.requireCurrent(editor: editor)
        guard current == expected, current.projectKey == context.projectKey,
              current.state == .ready || (rebuild && current.state == .drifted) else {
            throw GateBlocked("The production sources or cut changed. Reload its assembly status before building the cut.")
        }
        let writer = try await Task.detached(priority: .userInitiated) {
            try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "render")
        }.value
        let result = try await PipelineProductionAssemblyWriter.assemble(editor: editor, access: writer,
            driftAction: rebuild ? "rebuild" : nil, validateCommit: { try access.requireCurrent(editor: editor) }, didCommit: { access.end(editor: editor) })
        access.end(editor: editor)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return result
    }

    nonisolated private static func read(_ context: PipelineProductionAssemblyWriter.Context) throws -> Snapshot {
        guard let root = DataRootResolver.dataRoot(of: context.home) else { throw changed() }
        _ = try ProjectPackGate.requireMutation(projectURL: context.home, declaredPack: context.declaration.packName,
            declaredBinding: context.declaration.binding, declaredProductionContract: context.declaration.productionContract)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: context.declaration.binding,
            expectedProductionContract: context.declaration.productionContract), workflow.isProductionV2 else { throw changed() }
        let base = try PlanningWriterIO.json(context.timeline) + PlanningWriterIO.json(context.manifest)
            + PlanningWriterIO.json(context.media.map { [$0.id, $0.path, $0.type.rawValue] })
        var refs: [CanonicalArtifactReferenceV1] = []
        var state: State = .blocked
        var message = ""
        do {
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            let board = try PlanningWriterIO.storyboard(dataRoot: root)
            guard let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: root) else { throw changed() }
            try PipelineRenderReviewWriter.requireCurrent(review, root)
            let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
            try GateGuard.requirePriorApproved(gates, order: PhaseContractRuntime.order(workflow: workflow), phase: "render")
            guard projection.timebase.fpsDenominator > 0,
                  projection.timebase.fpsNumerator % projection.timebase.fpsDenominator == 0,
                  projection.timebase.fpsNumerator / projection.timebase.fpsDenominator == Int64(context.timeline.fps) else { throw changed() }
            refs = board.references + projection.header.inputs + [try PlanningWriterIO.reference(
                ProductionPlanProjectionV1.versionPath(projection.header.revision), id: "production-plan", role: "core.production-plan", dataRoot: root),
                try PlanningWriterIO.reference(RenderReviewV1.versionPath(review.header.revision), id: "render-review", role: "core.render-review", dataRoot: root)]
            for shot in projection.shots {
                refs += try PipelineProductionPerformanceAlignment.requireCurrent(shotID: shot.id, projection: projection, dataRoot: root)
                if shot.sourceMode == .imported {
                    guard let source = projection.source(for: shot.id) else { throw changed() }
                    _ = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: root)
                    refs.append(source)
                } else if ShotDeliveryModeResolverV1.resolve(shot) == .timelineAnimatedStill {
                    refs.append(try PipelineProductionRenderWriter.requireStill(shotID: shot.id, dataRoot: root).reference)
                } else {
                    let selected = try PipelineProductionRenderWriter.requireSelected(shotID: shot.id, dataRoot: root)
                    refs += [selected.reference, selected.selection.record, selected.selection.review, selected.record.output]
                }
            }
            var startupOwned: Set<String> = []
            if workflow.packID == "musicvideo" {
                let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: root)
                refs += music.artifactReferences
                startupOwned = try PipelineProductionMusicMix.requireDeclaredPlacements(projection: projection, context: context, dataRoot: root)
                if let anchor = try PipelineProductionMusicMix.startupSongTrack(timeline: context.timeline,
                    manifest: context.manifest, media: context.media, source: music.track) { startupOwned.insert(anchor) }
            }
            let assemblyURL = root.appendingPathComponent(PipelineProductionAssemblyWriter.receiptPath)
            if FileManager.default.fileExists(atPath: assemblyURL.path) {
                let receipt = try PlanningWriterIO.read(PipelineProductionAssemblyWriter.Receipt.self,
                    at: PipelineProductionAssemblyWriter.receiptPath, dataRoot: root)
                guard receipt.projectKey == context.projectKey, receipt.workflow == workflow else { throw changed() }
                refs.append(try PlanningWriterIO.reference(PipelineProductionAssemblyWriter.receiptPath,
                    id: "host-assembly", role: "host.production-assembly", dataRoot: root))
                let urls = Dictionary(uniqueKeysWithValues: context.media.map { ($0.id, $0.url) })
                do {
                    refs += try PipelineProductionAssemblyWriter.artifactReferences(dataRoot: root)
                    try PipelineProductionAssemblyWriter.requireCurrentTimeline(dataRoot: root, timeline: context.timeline, mediaURLs: urls)
                    state = .assembled; message = String(localized: "The current cut matches the approved production sources.")
                } catch {
                    state = .drifted; message = String(localized: "The production sources or assembled tracks changed. Keep the current cut, or explicitly rebuild it from the production plan.")
                }
            } else {
                try PipelineProductionMusicMix.requireNoForeignTracks(context.timeline, owned: startupOwned)
                guard !gates.get("render").approved else { throw changed() }
                let current = try ProjectStateBuilder.buildSnapshot(dataRoot: root, order: PhaseContractRuntime.order(workflow: workflow))
                guard current.nextPhase == "render" else { throw changed() }
                state = .ready; message = String(localized: "The selected production sources are ready to build the cut.")
            }
        } catch {
            state = .blocked; message = error.localizedDescription
        }
        let fingerprint = FileDigest.sha256(of: base + (try PlanningWriterIO.json(refs)) + Data((state.rawValue + message).utf8))
        return .init(projectKey: context.projectKey, fingerprint: fingerprint, state: state, message: message)
    }

    nonisolated private static func changed() -> GateBlocked {
        GateBlocked("Complete the current Render Review and select the required takes or source ranges before building the cut.")
    }
}
