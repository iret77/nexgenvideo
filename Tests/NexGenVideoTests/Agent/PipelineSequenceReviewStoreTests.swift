import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Pipeline sequence review")
@MainActor
struct PipelineSequenceReviewStoreTests {
    @Test("review reel preserves exact source trims, cut order and gaps")
    func reviewReelPreservesPlanEDL() async throws {
        let fixture = try await makeFixture(withGap: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let reel = try await ReviewReelBuilder.build(
            plan: fixture.plan,
            dataRoot: fixture.dataRoot
        )

        #expect(reel.entries.map(\.shotID) == ["shot-001", "shot-002"])
        #expect(reel.entries.map(\.sourceStartFrame) == [0, 30])
        #expect(reel.entries.map(\.reelStartFrame) == [0, 60])
        #expect(reel.durationFrames == 90)
        #expect(try FileDigest.sha256(of: ProjectLocalFile.resolve(reel.path, dataRoot: fixture.dataRoot)) == reel.sha256)
        #expect(try FileDigest.sha256(of: ProjectLocalFile.resolve(reel.edlPath, dataRoot: fixture.dataRoot)) == reel.edlSHA256)
    }

    @Test("current review fails closed after selected source bytes drift")
    func currentReviewRejectsSourceDrift() async throws {
        let fixture = try await makeFixture(withGap: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let reel = try await ReviewReelBuilder.build(
            plan: fixture.plan,
            dataRoot: fixture.dataRoot
        )
        let fingerprints = try PipelineSequenceReviewStore.productionFingerprints(
            selectedMedia: fixture.plan.selectedMedia,
            dataRoot: fixture.dataRoot
        )
        let review = SequenceReviewV1(
            projectID: fixture.plan.projectID,
            selectedMedia: fixture.plan.selectedMedia,
            reviewReel: reel,
            executionPlanSHA256: fingerprints.execution,
            canonSHA256: fingerprints.canon,
            referencePlanSHA256: fingerprints.references,
            adjacentPairCompleted: true,
            wholePlaybackCompleted: true,
            findings: [],
            reviewedAt: "2026-09-09T00:00:00Z"
        )
        let bytes = try PipelineAssemblyStore.canonical(review)
        let current = fixture.dataRoot.appendingPathComponent(SequenceReviewV1.relativePath)
        let archive = fixture.dataRoot.appendingPathComponent(
            "reviews/sequence/archive/\(FileDigest.sha256(of: bytes)).v1.json"
        )
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: current, options: .atomic)
        try bytes.write(to: archive, options: .atomic)

        let loaded = try PipelineSequenceReviewStore.requireCurrent(
            dataRoot: fixture.dataRoot,
            timeline: fixture.timeline
        )
        #expect(loaded == review)

        let source = try ProjectLocalFile.resolve("assets/source.mov", dataRoot: fixture.dataRoot)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("drift".utf8))
        try handle.close()
        #expect(throws: (any Error).self) {
            _ = try PipelineSequenceReviewStore.requireCurrent(
                dataRoot: fixture.dataRoot,
                timeline: fixture.timeline
            )
        }
    }

    private struct Fixture {
        let home: URL
        let dataRoot: URL
        let plan: AssemblyPlanV1
        let timeline: Timeline
    }

    private func makeFixture(withGap: Bool) async throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sequence-review-\(UUID().uuidString).ngv")
        let dataRoot = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            ProjectMeta(project: "sequence-fixture", mode: .generic),
            to: PipelineLayout.projectFile
        )
        let generated = try await ImageVideoGenerator.blackVideo(
            size: CGSize(width: 320, height: 180)
        )
        let source = dataRoot.appendingPathComponent("assets/source.mov")
        try FileManager.default.copyItem(at: generated, to: source)
        let sourceHash = try FileDigest.sha256(of: source)
        let sourceBytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        let context = ProjectCreativeContextV1(
            projectID: "sequence-fixture",
            artifacts: [],
            media: [.init(
                id: "source-001",
                role: "core.project-media",
                path: "assets/source.mov",
                sha256: sourceHash
            )]
        )
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let execution = ExecutionPlanV1(
            id: "execution-fixture",
            projectID: "sequence-fixture",
            creativeContext: .init(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: FileDigest.sha256(of: contextData)
            ),
            shots: [executionShot(id: "shot-001"), executionShot(id: "shot-002")]
        )
        _ = try PipelineExecutionPlanWriter.write(
            plan: execution,
            context: context,
            dataRoot: dataRoot
        )

        let selected: [SelectedShotMediaV1] = [
            .init(
                shotID: "shot-001",
                sourceKind: .importedSource,
                sourcePath: "assets/source.mov",
                sourceSHA256: sourceHash,
                sourceByteCount: sourceBytes,
                sourceFPS: 30,
                sourceStartFrame: 0,
                sourceEndFrame: 30
            ),
            .init(
                shotID: "shot-002",
                sourceKind: .importedSource,
                sourcePath: "assets/source.mov",
                sourceSHA256: sourceHash,
                sourceByteCount: sourceBytes,
                sourceFPS: 30,
                sourceStartFrame: 30,
                sourceEndFrame: 60
            ),
        ]
        let policy = AssemblyPolicyV1(
            id: "fixture.freeform",
            version: "1.0.0",
            timing: .freeform,
            timelineFPS: 30
        )
        let policyData = try PipelineAssemblyStore.canonical(policy)
        let secondStart = withGap ? 60 : 30
        let placements: [AssemblyPlacementV1] = [
            .init(
                shotID: "shot-001",
                trackID: "assembly-video",
                timelineStartFrame: 0,
                sourceStartFrame: 0,
                sourceEndFrame: 30
            ),
            .init(
                shotID: "shot-002",
                trackID: "assembly-video",
                timelineStartFrame: secondStart,
                sourceStartFrame: 30,
                sourceEndFrame: 60
            ),
        ]
        let plan = AssemblyPlanV1(
            projectID: "sequence-fixture",
            phase: "final",
            selectedMedia: selected,
            placements: placements,
            existingRegionFingerprint: nil,
            policyPath: PipelineAssemblyStore.policyPath,
            policySHA256: FileDigest.sha256(of: policyData)
        )
        let planData = try PipelineAssemblyStore.canonical(plan)
        var firstClip = Clip(
            mediaRef: "source-001",
            mediaType: .video,
            sourceClipType: .video,
            startFrame: 0,
            durationFrames: 30
        )
        firstClip.id = "clip-001"
        var secondClip = Clip(
            mediaRef: "source-001",
            mediaType: .video,
            sourceClipType: .video,
            startFrame: secondStart,
            durationFrames: 30
        )
        secondClip.id = "clip-002"
        secondClip.trimStartFrame = 30
        var track = Track(type: .video, clips: [firstClip, secondClip])
        track.id = "assembly-video"
        var timeline = Timeline()
        timeline.fps = 30
        timeline.width = 1280
        timeline.height = 720
        timeline.settingsConfigured = true
        timeline.tracks = [track]
        let manifest = AssemblyManifestV1(
            projectID: "sequence-fixture",
            phase: "final",
            planSHA256: FileDigest.sha256(of: planData),
            policyID: policy.id,
            policyVersion: policy.version,
            policySHA256: plan.policySHA256,
            priorRegionFingerprint: nil,
            appliedRegionFingerprint: try PipelineAssemblyStore.regionFingerprint(
                timeline: timeline,
                videoTrackID: track.id,
                audioTrackID: nil
            ) ?? "",
            timelineFingerprint: try PipelineAssemblyStore.fingerprint(timeline: timeline),
            idempotencyKey: PipelineAssemblyStore.idempotencyKey(planData: planData),
            placements: zip(selected, placements).enumerated().map { index, pair in
                .init(
                    selected: pair.0,
                    placement: pair.1,
                    clipIDs: [index == 0 ? "clip-001" : "clip-002"]
                )
            }
        )
        try PipelineAssemblyStore.persist(
            policy: policy,
            plan: plan,
            planData: planData,
            manifest: manifest,
            dataRoot: dataRoot
        )
        return Fixture(home: home, dataRoot: dataRoot, plan: plan, timeline: timeline)
    }

    private func executionShot(id: String) -> ExecutionShotV1 {
        ExecutionShotV1(
            id: id,
            sourceMode: .imported,
            sourceAssetID: "source-001",
            startState: .init(summary: "The source begins."),
            endState: .init(summary: "The source ends."),
            primaryAction: "Use the selected source.",
            camera: .init(movementID: "core.source"),
            renderability: .green,
            acceptance: [.init(
                id: "accept-\(id)",
                requirement: "The selected source remains intact.",
                severity: "required"
            )]
        )
    }
}
