import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Pipeline delivery store")
struct PipelineDeliveryStoreTests {
    @Test("HDR delivery is explicit while SDR specifications stay unchanged")
    @MainActor
    func hdrAndSDRSpecifications() throws {
        var timeline = Timeline()
        timeline.width = 1920
        timeline.height = 1080
        timeline.fps = 30

        let sdr = try PipelineDeliveryStore.defaultSpec(
            id: "sdr",
            targetKind: .master,
            timeline: timeline,
            format: .h265,
            resolution: .matchTimeline,
            requireSequenceReview: false
        )
        #expect(sdr.container == "mp4")
        #expect(sdr.videoCodec == "hvc1")
        #expect(sdr.colorSpace == "rec709-sdr")
        #expect(!sdr.hdr)
        #expect(!sdr.requirements.contains { $0.id.hasPrefix("core.hdr-") })

        let hdr = try PipelineDeliveryStore.defaultSpec(
            id: "hdr",
            targetKind: .master,
            timeline: timeline,
            format: .hevcMain10HLG,
            resolution: .matchTimeline,
            requireSequenceReview: false
        )
        #expect(hdr.container == "mov")
        #expect(hdr.videoCodec == "hvc1")
        #expect(hdr.colorSpace == "bt2020-hlg")
        #expect(hdr.hdr)
        #expect(hdr.requirements.contains {
            $0.id == "core.hdr-conversion"
                && $0.value == HDRVideoExporter.conversionID
                && $0.required
                && $0.state == .enforced
        })
        #expect(hdr.requirements.contains {
            $0.id == "core.hdr-qc"
                && $0.value == DeliveryHDRQCV1.schemaVersion
                && $0.required
                && $0.state == .enforced
        })
    }

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
            createdAt: "2026-09-09T00:00:00Z"
        )
        try PipelineAssemblyStore.canonical(running).write(
            to: job.appendingPathComponent("current.v1.json"),
            options: .atomic
        )

        try PipelineDeliveryStore.recoverInterruptedJobs(dataRoot: dataRoot)
        let recovered = try PipelineDeliveryStore.loadAttempt(
            id: running.id,
            dataRoot: dataRoot
        )
        #expect(recovered.status == .interrupted)
        #expect(recovered.failures == ["Export interrupted before completion."])
        #expect(recovered.completedAt != nil)

        try PipelineDeliveryStore.recoverInterruptedJobs(dataRoot: dataRoot)
        #expect(try PipelineDeliveryStore.loadAttempt(
            id: running.id,
            dataRoot: dataRoot
        ) == recovered)
    }
}
