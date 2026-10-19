import CoreMedia
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Recovered export timing")
@MainActor
struct ExportRecoveredTimingTests {
    @Test("Fractional history uses its persisted rate without a timeline snapshot")
    func fractionalHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID().uuidString
        let id = UUID().uuidString
        let timelineSHA = String(repeating: "a", count: 64)
        func attempt(requirements: [DeliveryRequirementV1]) -> DeliveryAttemptV1 {
            DeliveryAttemptV1(id: id, spec: DeliverySpecV1(id: "fractional-history", targetKind: .master,
                container: "mp4", videoCodec: "h264", width: 1280, height: 720,
                fpsNumerator: 30_000, fpsDenominator: 1_001, colorSpace: "sRGB", hdr: false,
                audioLayout: "stereo", captionMode: "none", disclosureMode: "none", requirements: requirements),
                finishedTimelineSHA256: timelineSHA, status: .failed, failures: ["Interrupted fixture export"],
                createdAt: "2026-10-19T00:00:00Z", completedAt: "2026-10-19T00:00:01Z")
        }
        let expectation = try ProductionDeliveryRangeExpectation(snapshot: .init(home: root,
            range: CMTimeRange(start: .zero, duration: CMTime(value: 1_001, timescale: 1_000)),
            fingerprint: String(repeating: "b", count: 64)), attempt: attempt(requirements: []))
        let bytes = try JSONEncoder().encode(expectation)
        let record = attempt(requirements: [.init(id: "core.production-output-range", state: .enforced,
            required: true, value: FileDigest.sha256(of: bytes))])
        try DeliveryValidatorV1.validate(attempt: record)
        let rangeURL = root.appendingPathComponent(ProductionDeliveryRangeExpectation.path(attemptID: id))
        let recordURL = root.appendingPathComponent("delivery/attempts/\(id).v1.json")
        for url in [rangeURL, recordURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try bytes.write(to: rangeURL)
        try JSONEncoder().encode(record).write(to: recordURL)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("delivery/timelines/\(timelineSHA).json").path))

        let queue = ExportQueue()
        _ = queue.loadPersistedDeliveryJobs(ownerKey: owner, dataRoot: root)
        let job = try #require(queue.jobs(ownerKey: owner).first)
        #expect(job.id == id)
        #expect(job.durationFrames == 30)
        #expect(job.fpsDenominator == 1_001)
        #expect(abs(try #require(job.frameRate) - 30_000.0 / 1_001.0) < 0.000_001)
        #expect(abs(try #require(job.durationSeconds) - 1.001) < 0.000_001)
    }

    @Test("Covering frames retain the fractional boundary without floating point rounding")
    func coveringFrameBoundary() {
        #expect(ExportJob.coveringFrames(duration: CMTime(value: 1_001, timescale: 1_000),
            fpsNumerator: 30_000, fpsDenominator: 1_001) == 30)
        #expect(ExportJob.coveringFrames(duration: CMTime(value: 10_011, timescale: 10_000),
            fpsNumerator: 30_000, fpsDenominator: 1_001) == 31)
        #expect(ExportJob.coveringFrames(duration: CMTime(value: 1, timescale: 1),
            fpsNumerator: 30, fpsDenominator: 1) == 30)
        #expect(ExportJob.coveringFrames(duration: .invalid, fpsNumerator: 30, fpsDenominator: 1) == nil)
        #expect(ExportJob.coveringFrames(duration: CMTime(value: 1, timescale: 1),
            fpsNumerator: 30, fpsDenominator: 0) == nil)
    }

    @Test("Legacy integer rates keep their default denominator")
    func integerDefault() {
        let job = ExportJob(id: "integer", ownerKey: "owner", projectID: "project", kind: .video,
            destinationURL: nil, title: "Export", durationFrames: 75, fps: 25, width: 1280, height: 720)
        #expect(job.fpsDenominator == 1)
        #expect(job.frameRate == 25)
        #expect(job.durationSeconds == 3)
    }
}
