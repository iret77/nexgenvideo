import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Pipeline delivery store")
struct PipelineDeliveryStoreTests {
    @Test("finished source rejects timeline and media drift")
    func finishedSourceDrift() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-finish-\(UUID().uuidString).ngv")
        let dataRoot = home.appendingPathComponent("pipeline")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("delivery/timelines"),
            withIntermediateDirectories: true
        )
        let source = dataRoot.appendingPathComponent("source.mov")
        try Data("source-bytes".utf8).write(to: source)

        var timeline = Timeline()
        timeline.fps = 30
        let timelineData = try PipelineAssemblyStore.canonical(timeline)
        let timelineHash = FileDigest.sha256(of: timelineData)
        let timelinePath = "delivery/timelines/\(timelineHash).json"
        try timelineData.write(to: dataRoot.appendingPathComponent(timelinePath))
        let plan = FinishPlanV1(
            projectID: "delivery-fixture",
            sourceTimelineSHA256: timelineHash
        )
        let planData = try PipelineAssemblyStore.canonical(plan)
        try planData.write(
            to: dataRoot.appendingPathComponent(FinishPlanV1.relativePath),
            options: .atomic
        )
        let manifest = FinishedTimelineManifestV1(
            projectID: "delivery-fixture",
            finishPlanSHA256: FileDigest.sha256(of: planData),
            timelinePath: timelinePath,
            timelineSHA256: timelineHash,
            media: [.init(
                path: source.path,
                sha256: try FileDigest.sha256(of: source)
            )],
            operationProofs: [],
            adoptedManualTimeline: true
        )
        try PipelineAssemblyStore.canonical(manifest).write(
            to: dataRoot.appendingPathComponent(FinishedTimelineManifestV1.relativePath),
            options: .atomic
        )

        _ = try PipelineDeliveryStore.requireCurrentFinished(
            dataRoot: dataRoot,
            timeline: timeline
        )
        timeline.fps = 24
        #expect(throws: (any Error).self) {
            _ = try PipelineDeliveryStore.requireCurrentFinished(
                dataRoot: dataRoot,
                timeline: timeline
            )
        }
        timeline.fps = 30
        try FileManager.default.removeItem(at: source)
        #expect(throws: (any Error).self) {
            _ = try PipelineDeliveryStore.requireCurrentFinished(
                dataRoot: dataRoot,
                timeline: timeline
            )
        }
    }

    @Test("startup recovery preserves interrupted export as terminal history")
    func interruptedExportRecovery() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-recovery-\(UUID().uuidString).ngv")
        let dataRoot = home.appendingPathComponent("pipeline")
        defer { try? FileManager.default.removeItem(at: home) }
        let job = dataRoot.appendingPathComponent("delivery/jobs/attempt-1")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)

        let spec = DeliverySpecV1(
            id: "master.h264.720p",
            targetKind: .master,
            container: "mp4",
            videoCodec: "avc1",
            width: 1280,
            height: 720,
            fpsNumerator: 30,
            colorSpace: "rec709-sdr",
            hdr: false,
            audioLayout: "none",
            captionMode: "none",
            disclosureMode: "project-record"
        )
        let running = DeliveryAttemptV1(
            id: "attempt-1",
            spec: spec,
            finishedTimelineSHA256: FileDigest.sha256(of: Data("timeline".utf8)),
            status: .running,
            outputPath: home.appendingPathComponent("master.mp4").path,
            createdAt: "2026-09-09T00:00:00Z"
        )
        try PipelineAssemblyStore.canonical(running).write(
            to: job.appendingPathComponent("current.v1.json"),
            options: .atomic
        )
        let active = DeliveryAttemptV1(
            id: "attempt-active",
            spec: spec,
            finishedTimelineSHA256: running.finishedTimelineSHA256,
            status: .queued,
            outputPath: home.appendingPathComponent("active.mp4").path,
            createdAt: running.createdAt
        )
        let activeJob = dataRoot.appendingPathComponent("delivery/jobs/attempt-active")
        try FileManager.default.createDirectory(at: activeJob, withIntermediateDirectories: true)
        try PipelineAssemblyStore.canonical(active).write(
            to: activeJob.appendingPathComponent("current.v1.json"),
            options: .atomic
        )

        try PipelineDeliveryStore.recoverInterruptedJobs(
            dataRoot: dataRoot,
            excludingIDs: [active.id]
        )
        let recovered = try PipelineDeliveryStore.loadAttempt(
            id: running.id,
            dataRoot: dataRoot
        )
        #expect(recovered.status == .interrupted)
        #expect(recovered.outputPath == running.outputPath)
        #expect(recovered.failures == ["Export interrupted before completion."])
        #expect(recovered.completedAt != nil)
        let stillQueued = try JSONDecoder().decode(
            DeliveryAttemptV1.self,
            from: Data(contentsOf: activeJob.appendingPathComponent("current.v1.json"))
        )
        #expect(stillQueued == active)

        try PipelineDeliveryStore.recoverInterruptedJobs(
            dataRoot: dataRoot,
            excludingIDs: [active.id]
        )
        #expect(try PipelineDeliveryStore.loadAttempt(
            id: running.id,
            dataRoot: dataRoot
        ) == recovered)
        #expect(throws: (any Error).self) {
            _ = try PipelineDeliveryStore.markRunning(running, dataRoot: dataRoot)
        }
        let currentAfterRejectedTransition = try JSONDecoder().decode(
            DeliveryAttemptV1.self,
            from: Data(contentsOf: job.appendingPathComponent("current.v1.json"))
        )
        #expect(currentAfterRejectedTransition == recovered)
    }

    @Test("a bound success receipt stays historical when the current finish changes")
    func exactReceiptDoesNotReplaceNewerSelection() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-receipt-\(UUID().uuidString).ngv")
        let dataRoot = home.appendingPathComponent("pipeline")
        let output = home.appendingPathComponent("master.mp4")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("delivery/timelines"),
            withIntermediateDirectories: true
        )

        let timeline = Timeline()
        let timelineData = try PipelineAssemblyStore.canonical(timeline)
        let timelineHash = FileDigest.sha256(of: timelineData)
        let timelinePath = "delivery/timelines/\(timelineHash).json"
        try timelineData.write(to: dataRoot.appendingPathComponent(timelinePath))
        let plan = FinishPlanV1(
            projectID: "receipt-project",
            sourceTimelineSHA256: timelineHash
        )
        let planData = try PipelineAssemblyStore.canonical(plan)
        let manifest = FinishedTimelineManifestV1(
            projectID: plan.projectID,
            finishPlanSHA256: FileDigest.sha256(of: planData),
            timelinePath: timelinePath,
            timelineSHA256: timelineHash,
            media: [],
            operationProofs: [],
            adoptedManualTimeline: true
        )
        let manifestData = try PipelineAssemblyStore.canonical(manifest)
        try planData.write(to: dataRoot.appendingPathComponent(FinishPlanV1.relativePath))
        try manifestData.write(to: dataRoot.appendingPathComponent(FinishedTimelineManifestV1.relativePath))
        let finished = PipelineDeliveryStore.FinishedState(
            plan: plan,
            planData: planData,
            manifest: manifest,
            manifestData: manifestData
        )
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { home })
        let spec = DeliverySpecV1(
            id: "master.h264.match",
            targetKind: .master,
            container: "mp4",
            videoCodec: "avc1",
            width: timeline.width,
            height: timeline.height,
            fpsNumerator: timeline.fps,
            colorSpace: "rec709-sdr",
            hdr: false,
            audioLayout: "none",
            captionMode: "none",
            disclosureMode: "project-record"
        )
        let queued = try PipelineDeliveryStore.enqueueAttempt(
            id: "receipt-attempt",
            dataRoot: dataRoot,
            finished: finished,
            spec: spec,
            format: .h264,
            resolution: .matchTimeline,
            outputURL: output,
            timeline: timeline,
            resolver: resolver
        )
        #expect(throws: (any Error).self) {
            _ = try PipelineDeliveryStore.enqueueAttempt(
                id: queued.id,
                dataRoot: dataRoot,
                finished: finished,
                spec: spec,
                format: .h264,
                resolution: .matchTimeline,
                outputURL: output,
                timeline: timeline,
                resolver: resolver
            )
        }
        let running = try PipelineDeliveryStore.markRunning(queued, dataRoot: dataRoot)

        let newerPlan = FinishPlanV1(
            projectID: "newer-project",
            sourceTimelineSHA256: timelineHash
        )
        let newerPlanData = try PipelineAssemblyStore.canonical(newerPlan)
        let newerManifest = FinishedTimelineManifestV1(
            projectID: newerPlan.projectID,
            finishPlanSHA256: FileDigest.sha256(of: newerPlanData),
            timelinePath: timelinePath,
            timelineSHA256: timelineHash,
            media: [],
            operationProofs: [],
            adoptedManualTimeline: true
        )
        try newerPlanData.write(to: dataRoot.appendingPathComponent(FinishPlanV1.relativePath))
        try PipelineAssemblyStore.canonical(newerManifest).write(
            to: dataRoot.appendingPathComponent(FinishedTimelineManifestV1.relativePath)
        )

        try Data("verified encoded bytes".utf8).write(to: output)
        let outputHash = try FileDigest.sha256(of: output)
        let qc = DeliveryProbeQCV1(
            durationValue: 30,
            durationTimescale: 30,
            width: timeline.width,
            height: timeline.height,
            fpsNumerator: timeline.fps,
            fpsDenominator: 1,
            videoCodec: "avc1",
            audioCodec: nil,
            audioChannels: 0,
            passed: true
        )
        let outputSize = try #require(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let result = try PipelineDeliveryStore.finishSuccessful(
            running,
            dataRoot: dataRoot,
            finished: finished,
            outputURL: output,
            evidence: .init(
                sha256: outputHash,
                byteCount: Int64(outputSize),
                probeQC: qc
            ),
            publishedState: try ExportQueue.PathState.capture(output),
            selectIfCurrent: true
        )
        let succeeded = result.attempt

        #expect(succeeded.finishedTimelineSHA256 == timelineHash)
        #expect(succeeded.outputSHA256 == outputHash)
        #expect(!FileManager.default.fileExists(
            atPath: dataRoot.appendingPathComponent(PipelineDeliveryStore.selectionPath).path
        ))
        #expect(try PipelineDeliveryStore.loadAttempt(id: succeeded.id, dataRoot: dataRoot) == succeeded)

        try Data("replacement".utf8).write(to: output)
        #expect(throws: (any Error).self) {
            _ = try PipelineDeliveryStore.loadAttempt(id: succeeded.id, dataRoot: dataRoot)
        }
    }
}
