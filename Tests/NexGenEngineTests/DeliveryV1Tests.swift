import Foundation
import Testing
@testable import NexGenEngine

@Suite("Delivery V1")
struct DeliveryV1Tests {
    @Test("success requires exact output and QC")
    func successfulAttempt() throws {
        let spec = DeliverySpecV1(id: "master-prores", targetKind: .master,
            container: "mov", videoCodec: "apcn", width: 1920, height: 1080,
            fpsNumerator: 24, colorSpace: "rec709", hdr: false,
            audioLayout: "stereo", captionMode: "none", disclosureMode: "sidecar")
        let qc = DeliveryProbeQCV1(durationValue: 240, durationTimescale: 24,
            width: 1920, height: 1080, fpsNumerator: 24, fpsDenominator: 1,
            videoCodec: "apcn", audioCodec: "lpcm", audioChannels: 2, passed: true)
        let attempt = DeliveryAttemptV1(id: hash("attempt"), spec: spec,
            finishedTimelineSHA256: hash("finish"), status: .succeeded,
            outputPath: "delivery/master.mov", outputSHA256: hash("output"),
            outputByteCount: 1_024, probeQC: qc,
            createdAt: "2026-09-09T00:00:00Z", completedAt: "2026-09-09T00:01:00Z")
        try DeliveryValidatorV1.validateSuccessfulAttempt(attempt,
            finishedTimelineSHA256: hash("finish"), requiredSequenceReviewSHA256: nil)

        let failed = DeliveryAttemptV1(id: hash("failed"), spec: spec,
            finishedTimelineSHA256: hash("finish"), status: .failed,
            failures: ["export failed"], createdAt: "2026-09-09T00:00:00Z",
            completedAt: "2026-09-09T00:00:01Z")
        #expect(throws: DeliveryValidationErrorV1.self) {
            try DeliveryValidatorV1.validateSuccessfulAttempt(failed,
                finishedTimelineSHA256: hash("finish"), requiredSequenceReviewSHA256: nil)
        }
    }

    @Test("unsupported required delivery capability blocks before export")
    func unsupportedRequirement() {
        let spec = DeliverySpecV1(id: "unsupported-master", targetKind: .master,
            container: "mov", videoCodec: "apcn", width: 1920, height: 1080,
            fpsNumerator: 24, colorSpace: "rec709", hdr: false,
            audioLayout: "5.1", captionMode: "embedded", disclosureMode: "sidecar",
            requirements: [.init(id: "audio.stems.dialogue", state: .unsupported,
                required: true, value: "separate")])
        #expect(throws: DeliveryValidationErrorV1.self) {
            try DeliveryValidatorV1.validate(spec: spec)
        }
    }

    private func hash(_ value: String) -> String { FileDigest.sha256(of: Data(value.utf8)) }
}
