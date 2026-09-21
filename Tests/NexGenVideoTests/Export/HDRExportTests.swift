import AVFoundation
import Foundation
import NexGenEngine
import Testing
import VideoToolbox
@testable import NexGenVideo

private let hdrRuntimeQCEnabled =
    ProcessInfo.processInfo.environment["NGV_HDR_RUNTIME_QC"] == "1"

@Suite("HEVC Main10 HDR export", .serialized)
@MainActor
struct HDRExportTests {
    @Test("preflight rejects every unavailable HDR dependency")
    func unsupportedCapabilities() {
        let supported = HDRExportCapabilitySnapshot(
            hlgColorSpacesAvailable: true,
            videoRangePixelBuffersAvailable: true,
            main10EncoderAvailable: true,
            movieWriterAcceptsSettings: true
        )
        #expect(HDRExportCapability.evaluate(supported).isSupported)

        let unsupported = [
            HDRExportCapabilitySnapshot(
                hlgColorSpacesAvailable: false,
                videoRangePixelBuffersAvailable: true,
                main10EncoderAvailable: true,
                movieWriterAcceptsSettings: true
            ),
            HDRExportCapabilitySnapshot(
                hlgColorSpacesAvailable: true,
                videoRangePixelBuffersAvailable: false,
                main10EncoderAvailable: true,
                movieWriterAcceptsSettings: true
            ),
            HDRExportCapabilitySnapshot(
                hlgColorSpacesAvailable: true,
                videoRangePixelBuffersAvailable: true,
                main10EncoderAvailable: false,
                movieWriterAcceptsSettings: true
            ),
            HDRExportCapabilitySnapshot(
                hlgColorSpacesAvailable: true,
                videoRangePixelBuffersAvailable: true,
                main10EncoderAvailable: true,
                movieWriterAcceptsSettings: false
            ),
        ]
        for snapshot in unsupported {
            let result = HDRExportCapability.evaluate(snapshot)
            #expect(!result.isSupported)
            #expect(result.reason?.isEmpty == false)
        }
    }

    @Test("writer settings pin Main10 BT.2020 HLG")
    func writerSettings() throws {
        let settings = HDRVideoExporter.videoWriterSettings(size: CGSize(width: 1920, height: 1080))
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        let color = try #require(settings[AVVideoColorPropertiesKey] as? [String: Any])
        #expect(color[AVVideoColorPrimariesKey] as? String == AVVideoColorPrimaries_ITU_R_2020)
        #expect(color[AVVideoTransferFunctionKey] as? String == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(color[AVVideoYCbCrMatrixKey] as? String == AVVideoYCbCrMatrix_ITU_R_2020)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(
            compression[kVTCompressionPropertyKey_ProfileLevel as String] as? String
                == (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        )
        #expect(HDRVideoExporter.hlgReferenceWhiteSignal == 0.75)
    }

    @Test(
        "round trip proves metadata, title burn-in, reference frames, and SDR white mapping",
        .enabled(if: hdrRuntimeQCEnabled)
    )
    func roundTripQC() async throws {
        let source = try await FixtureVideo.write(
            scenes: [
                .init(rgb: (0, 0, 0), seconds: 1),
                .init(rgb: (104, 104, 104), seconds: 1),
                .init(rgb: (255, 0, 0), seconds: 1),
                .init(rgb: (255, 255, 255), seconds: 1),
            ],
            fps: 10,
            size: 320
        )
        defer { try? FileManager.default.removeItem(at: source) }
        var timeline = fixtureTimeline(source: source, durationFrames: 120)
        var title = Fixtures.clip(
            id: "title",
            mediaRef: "",
            mediaType: .text,
            start: 0,
            duration: 30
        )
        title.textContent = "HDR"
        var style = TextStyle()
        style.fontSize = 120
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        title.textStyle = style
        timeline.timeline.tracks.insert(Fixtures.videoTrack(clips: [title]), at: 0)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr-round-trip-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }

        let capability = await HDRVideoExporter.capability(
            renderSize: CGSize(width: 320, height: 320)
        )
        #expect(capability.isSupported, "\(capability.reason ?? "HDR preflight failed")")
        let service = ExportService()
        await service.export(
            timeline: timeline.timeline,
            resolver: timeline.resolver,
            format: .hevcMain10HLG,
            resolution: .matchTimeline,
            outputURL: output
        )
        try #require(service.error == nil, "\(service.error ?? "HDR export failed")")

        let spec = hdrSpec(width: 320, height: 320, fps: 30)
        let baseQC = try await PipelineDeliveryStore.probeOutput(
            outputURL: output,
            spec: spec,
            expectedDurationFrames: 120
        )
        #expect(baseQC.passed)
        let hdrQC = try await HDRDeliveryQC.probe(outputURL: output, spec: spec)
        try DeliveryValidatorV1.validate(
            hdrQC: hdrQC,
            outputSHA256: try FileDigest.sha256(of: output)
        )
        #expect(hdrQC.referenceFrames[0].lumaMinimumCode <= 70)
        #expect(hdrQC.referenceFrames[0].lumaMaximumCode > 100)
        #expect((350...450).contains(hdrQC.referenceFrames[1].lumaMaximumCode))
        #expect((380...420).contains(Int(hdrQC.referenceFrames[2].chromaCbMeanCode.rounded())))
        #expect((710...750).contains(Int(hdrQC.referenceFrames[2].chromaCrMeanCode.rounded())))
        #expect((700...740).contains(hdrQC.referenceFrames[3].lumaMaximumCode))
        try publishEvidence(hdrQC, movie: output)
    }

    private func fixtureTimeline(
        source: URL,
        durationFrames: Int
    ) -> (timeline: Timeline, resolver: MediaResolver) {
        let mediaRef = "hdr-fixture"
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: mediaRef,
            name: "HDR QC fixture",
            type: .video,
            source: .external(absolutePath: source.path),
            duration: Double(durationFrames) / 30
        )]
        var timeline = Fixtures.timeline(
            fps: 30,
            tracks: [Fixtures.videoTrack(clips: [
                Fixtures.clip(
                    id: "fixture",
                    mediaRef: mediaRef,
                    start: 0,
                    duration: durationFrames
                ),
            ])]
        )
        timeline.width = 320
        timeline.height = 320
        return (
            timeline,
            MediaResolver(manifest: { manifest }, projectURL: { nil })
        )
    }

    private func hdrSpec(width: Int, height: Int, fps: Int) -> DeliverySpecV1 {
        DeliverySpecV1(
            id: "hdr-qc-fixture",
            targetKind: .master,
            container: "mov",
            videoCodec: "hvc1",
            width: width,
            height: height,
            fpsNumerator: fps,
            colorSpace: "bt2020-hlg",
            hdr: true,
            audioLayout: "none",
            captionMode: "none",
            disclosureMode: "project-record",
            requirements: [
                .init(
                    id: "core.hdr-conversion",
                    state: .enforced,
                    required: true,
                    value: HDRVideoExporter.conversionID
                ),
                .init(
                    id: "core.hdr-qc",
                    state: .enforced,
                    required: true,
                    value: DeliveryHDRQCV1.schemaVersion
                ),
            ]
        )
    }

    private func publishEvidence(_ qc: DeliveryHDRQCV1, movie: URL) throws {
        guard let path = ProcessInfo.processInfo.environment["NGV_HDR_QC_OUTPUT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PipelineAssemblyStore.canonical(qc).write(
            to: directory.appendingPathComponent("hdr-qc.v1.json"),
            options: .atomic
        )
        let destination = directory.appendingPathComponent("hdr-reference.mov")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: movie, to: destination)
    }
}
