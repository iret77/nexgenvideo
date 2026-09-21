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

    @Test("nonterminal and terminal delivery jobs have distinct durable shapes")
    func jobStateShapes() throws {
        let spec = DeliverySpecV1(id: "master-h264", targetKind: .master,
            container: "mp4", videoCodec: "avc1", width: 1280, height: 720,
            fpsNumerator: 30, colorSpace: "rec709-sdr", hdr: false,
            audioLayout: "none", captionMode: "none", disclosureMode: "project-record")
        let running = DeliveryAttemptV1(id: "attempt-1", spec: spec,
            finishedTimelineSHA256: hash("finish"), status: .running,
            createdAt: "2026-09-09T00:00:00Z")
        try DeliveryValidatorV1.validate(attempt: running)

        let interrupted = DeliveryAttemptV1(id: "attempt-1", spec: spec,
            finishedTimelineSHA256: hash("finish"), status: .interrupted,
            failures: ["Export interrupted before completion."],
            createdAt: "2026-09-09T00:00:00Z", completedAt: "2026-09-09T00:01:00Z")
        try DeliveryValidatorV1.validate(attempt: interrupted)

        let malformed = DeliveryAttemptV1(id: "attempt-2", spec: spec,
            finishedTimelineSHA256: hash("finish"), status: .failed,
            createdAt: "2026-09-09T00:00:00Z", completedAt: "2026-09-09T00:01:00Z")
        #expect(throws: DeliveryValidationErrorV1.self) {
            try DeliveryValidatorV1.validate(attempt: malformed)
        }
    }

    @Test("HDR evidence requires independent Main10, HLG, range, and frame proofs")
    func hdrEvidence() throws {
        let output = hash("hdr-output")
        let track = DeliveryHDRTrackQCV1(
            codec: "hvc1", bitsPerComponent: 10,
            colorPrimaries: "bt2020", transferFunction: "hlg",
            yCbCrMatrix: "bt2020-ncl", fullRange: false
        )
        let container = DeliveryHDRContainerQCV1(
            fileType: "mov", sampleEntry: "hvc1", hasHEVCConfiguration: true,
            profileIDC: 2, lumaBitDepth: 10, chromaBitDepth: 10,
            colorPrimariesIndex: 9, transferFunctionIndex: 18, matrixIndex: 9,
            fullRangeFlag: false
        )
        let frames = (0..<4).map {
            DeliveryHDRReferenceFrameQCV1(
                index: $0, presentationTimeValue: Int64($0 * 15),
                presentationTimeTimescale: 30, pixelFormat: "x420",
                lumaMinimumCode: 64, lumaMaximumCode: 721,
                outOfRangePixelCount: 0, pixelCount: 320 * 180,
                chromaCbMeanCode: 512, chromaCrMeanCode: 512,
                pixelSHA256: hash("frame-\($0)")
            )
        }
        let qc = DeliveryHDRQCV1(
            outputSHA256: output,
            conversion: "rec709-sdr-reference-white-75-to-bt2020-hlg",
            track: track,
            container: container,
            referenceFrames: frames,
            passed: true
        )
        try DeliveryValidatorV1.validate(hdrQC: qc, outputSHA256: output)

        let relabelled = DeliveryHDRQCV1(
            outputSHA256: output,
            conversion: qc.conversion,
            track: .init(
                codec: "hvc1", bitsPerComponent: 10,
                colorPrimaries: "bt2020", transferFunction: "rec709",
                yCbCrMatrix: "bt2020-ncl", fullRange: false
            ),
            container: container,
            referenceFrames: frames,
            passed: true
        )
        #expect(throws: DeliveryValidationErrorV1.self) {
            try DeliveryValidatorV1.validate(hdrQC: relabelled, outputSHA256: output)
        }

        let illegalRange = DeliveryHDRQCV1(
            outputSHA256: output,
            conversion: qc.conversion,
            track: track,
            container: container,
            referenceFrames: [
                .init(
                    index: 0, presentationTimeValue: 0,
                    presentationTimeTimescale: 30, pixelFormat: "x420",
                    lumaMinimumCode: 0, lumaMaximumCode: 1_023,
                    outOfRangePixelCount: 100, pixelCount: 320 * 180,
                    chromaCbMeanCode: 512, chromaCrMeanCode: 512,
                    pixelSHA256: hash("bad-frame")
                ),
            ] + Array(frames.dropFirst()),
            passed: true
        )
        #expect(throws: DeliveryValidationErrorV1.self) {
            try DeliveryValidatorV1.validate(hdrQC: illegalRange, outputSHA256: output)
        }
        let failures = DeliveryValidatorV1.hdrValidationFailures(
            hdrQC: illegalRange,
            outputSHA256: output
        )
        #expect(failures.contains(
            "reference_frames[0].luma_minimum_code expected >= 60 measured 0"
        ))
        #expect(failures.contains(
            "reference_frames[0].luma_maximum_code expected <= 944 measured 1023"
        ))

        var peakFrames = frames
        peakFrames[2] = .init(
            index: 2, presentationTimeValue: 30,
            presentationTimeTimescale: 30, pixelFormat: "x420",
            lumaMinimumCode: 64, lumaMaximumCode: 900,
            outOfRangePixelCount: 0, pixelCount: 320 * 180,
            chromaCbMeanCode: 512, chromaCrMeanCode: 512,
            pixelSHA256: hash("peak-frame")
        )
        let inventedHighlights = DeliveryHDRQCV1(
            outputSHA256: output,
            conversion: qc.conversion,
            track: track,
            container: container,
            referenceFrames: peakFrames,
            passed: true
        )
        #expect(throws: DeliveryValidationErrorV1.self) {
            try DeliveryValidatorV1.validate(
                hdrQC: inventedHighlights,
                outputSHA256: output
            )
        }
    }

    private func hash(_ value: String) -> String { FileDigest.sha256(of: Data(value.utf8)) }
}
