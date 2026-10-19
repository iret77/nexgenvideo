import AppKit
import NexGenEngine

@MainActor
enum AgentReviewChildOwnerFixture {
    static let shotCount = 34

    static func make(service: AgentService) async throws -> ProductionPlanningAcceptanceFixture.Context {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Explicit native acceptance is required.") }
        let context = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: service)
        var ready = false
        defer { if !ready { context.document.close() } }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        let root = context.dataRoot
        let script = try PlanningWriterIO.script(dataRoot: root)
        let steps = script.scenes.flatMap { scene in scene.events.map {
            StoryboardV2.StoryStep(id: "step-" + $0.id, sceneID: scene.id,
                eventIDs: [$0.id], function: .story, action: $0.action)
        } }
        guard steps.count == 2 else { throw GateBlocked("The review fixture needs its two actual abstract compositions.") }
        let bindings = script.events.map { StoryboardCausalityV2.Binding(stepID: "step-" + $0.id,
            beatIDs: $0.treatmentBeatIDs, reason: "An independent view of the approved abstract composition.") }
        let duration: Int64 = 200
        let proposals = (0..<shotCount).map { index in
            PipelineStoryboardBundleWriter.ShotProposal(id: nil, primaryStepID: steps[index % steps.count].id,
                additionalStepIDs: [], startTicks: Int64(index) * duration, durationTicks: duration,
                cameraID: nil, framing: .init(scale: "wide", composition: "One distinct coloured shape on a pale wall.", cameraView: "frontal"),
                moments: [.init(id: "review-moment-\(index)", offsetTicks: 0, intent: "Inspect this distinct abstract shape and its framing.")])
        }
        let proposal = PipelineStoryboardBundleWriter.Proposal(summary: script.summary, steps: steps, bindings: bindings,
            timebase: ProductionPlanningAcceptanceFixture.timebase, mode: .generic, rangeStartTicks: 0,
            rangeDurationTicks: Int64(shotCount) * duration, audio: nil, shots: proposals)
        try await ProductionPlanningAcceptanceFixture.run("write_storyboard_bundle",
            args: ["origin": "agentProposal", "proposal": try ProductionPlanningAcceptanceFixture.object(proposal)], in: context)
        var board = try PlanningWriterIO.storyboard(dataRoot: root, requireVisuals: false)
        let targets = board.timing.shots.map { ($0.id, $0.moments[0].id) }
        for (index, target) in targets.enumerated() {
            let image = FileManager.default.temporaryDirectory.appendingPathComponent("Review sketch-" + UUID().uuidString + ".png")
            try imageBytes(index: index).write(to: image)
            defer { try? FileManager.default.trashItem(at: image, resultingItemURL: nil) }
            board = try await PipelineStoryboardEditor.attachImage(from: image, shotID: target.0,
                momentID: target.1, expectedFingerprint: board.fingerprint, editor: context.editor)
        }
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
        var draft = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: context)
        let video = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.trashItem(at: video, resultingItemURL: nil) }
        for shotID in targets.map({ $0.0 }) {
            guard let original = draft.shots.first(where: { $0.shotID == shotID }) else { throw GateBlocked("The review fixture lost a planned shot.") }
            draft = try await PipelineShotPlanningEditor.attachSource(from: video,
                to: .init(shotID: shotID, sourceMode: .imported, camera: original.camera, obligations: []),
                in: draft, editor: context.editor)
            guard let imported = draft.shots.first(where: { $0.shotID == shotID }), let source = imported.source else {
                throw GateBlocked("The review fixture has no confirmed imported source.")
            }
            draft = try await PipelineShotPlanningEditor.replace(.init(shotID: shotID, sourceMode: .imported,
                source: source, camera: imported.camera, obligations: [], sourceInputRange: .init(source: source,
                    timebase: ProductionPlanningAcceptanceFixture.timebase, startTicks: 0, durationTicks: duration)),
                in: draft, editor: context.editor)
        }
        try await ProductionPlanningAcceptanceFixture.approve("shot_planning", in: context)
        try await ProductionPlanningAcceptanceFixture.writeBible(in: context)
        _ = try await ProductionPlanningAcceptanceFixture.prepareImportedAssets(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("bible", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.promoteImported(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("shotlist", in: context)
        try await ProductionPlanningAcceptanceFixture.prepareImportedSanity(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("sanity", in: context)
        try await ProductionPlanningAcceptanceFixture.prepareEmptyFrames(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("frames", in: context)
        ready = true
        return context
    }

    private static func imageBytes(index: Int) throws -> Data {
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: image) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSColor(calibratedHue: CGFloat(index) / CGFloat(shotCount), saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: CGFloat(40 + index * 3), y: 45, width: 70, height: 70)).fill()
        guard let bytes = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return bytes
    }
}
