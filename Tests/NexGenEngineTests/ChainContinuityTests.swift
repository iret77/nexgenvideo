import Foundation
import Testing
@testable import NexGenEngine

/// chain_with_previous_end continuity bookkeeping (#196). Ports of the dispatcher's `needs_last_frame`
/// lookahead + the chain branch of `_resolve_anchor_frames`, plus the `last_frame_path` manifest field.
@Suite("chain continuity")
struct ChainContinuityTests {
    static func shot(_ id: String, start: Double, chain: Bool = false, source: SourceMode = .generated) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: start, timeEnd: start + 4, durationS: 4,
                 type: .performance, sourceMode: source, description: "d", visualPrompt: "p", mood: "m",
                 keyframeStrategy: .start, chainWithPreviousEnd: chain)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: shots)
    }

    @Test("a shot needs its last frame iff its successor chains; predecessor resolves for a chained shot")
    func lookaheadAndPredecessor() throws {
        let sl = try Self.shotlist([
            try Self.shot("s001", start: 0),
            try Self.shot("s002", start: 4, chain: true),
            try Self.shot("s003", start: 8),
        ])
        #expect(ChainContinuity.needsLastFrame(sl, shotId: "s001"))
        #expect(!ChainContinuity.needsLastFrame(sl, shotId: "s002"))
        #expect(!ChainContinuity.needsLastFrame(sl, shotId: "s003"))

        #expect(ChainContinuity.chainPredecessor(sl, shotId: "s002") == "s001")
        #expect(ChainContinuity.chainPredecessor(sl, shotId: "s001") == nil)
        #expect(ChainContinuity.chainPredecessor(sl, shotId: "s003") == nil)
    }

    @Test("imported shots are skipped in the chain order")
    func importedSkipped() throws {
        let sl = try Self.shotlist([
            try Self.shot("s001", start: 0),
            try Self.shot("s002", start: 4, source: .imported),
            try Self.shot("s003", start: 8, chain: true),
        ])
        // s002 is user-shot, never rendered → s003 chains off s001, and s001 needs its last frame.
        #expect(ChainContinuity.chainPredecessor(sl, shotId: "s003") == "s001")
        #expect(ChainContinuity.needsLastFrame(sl, shotId: "s001"))
    }

    @Test("execution plan predecessor skips imported shots")
    func executionPredecessorSkipsImported() {
        let plan = ExecutionPlanV1(
            id: "plan",
            projectID: "p",
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: String(repeating: "a", count: 64)
            ),
            shots: [
                Self.executionShot("s001", source: .generated),
                Self.executionShot("s002", source: .imported),
                Self.executionShot("s003", source: .generated),
            ]
        )

        #expect(ChainContinuity.executionPredecessor(plan, shotID: "s003") == "s001")
    }

    @Test("render manifest round-trips last_frame_path")
    func manifestRoundTrip() throws {
        var manifest = RenderManifest(project: "p", phase: "preview")
        record(&manifest, shotId: "s001", output: "media/s001.mp4", costEur: 1.0,
               phase: "preview", lastFramePath: "media/s001.last_frame.png")
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(RenderManifest.self, from: data)
        #expect(decoded.entries["s001"]?.lastFramePath == "media/s001.last_frame.png")
    }

    private static func executionShot(
        _ id: String,
        source: ExecutionSourceModeV1
    ) -> ExecutionShotV1 {
        ExecutionShotV1(
            id: id,
            sourceMode: source,
            startState: ExecutionStateV1(summary: "Start."),
            endState: ExecutionStateV1(summary: "End."),
            primaryAction: "Hold.",
            camera: ExecutionCameraPlanV1(movementID: "core.static"),
            renderability: .green,
            acceptance: [
                ExecutionAcceptanceCriterionV1(
                    id: "accept-\(id)",
                    requirement: "The shot is legible.",
                    severity: "required"
                ),
            ]
        )
    }
}
