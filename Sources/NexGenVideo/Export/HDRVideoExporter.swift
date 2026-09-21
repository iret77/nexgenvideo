import AVFoundation
import CoreImage
import VideoToolbox

struct HDRExportCapabilitySnapshot: Sendable, Equatable {
    let hlgColorSpacesAvailable: Bool
    let videoRangePixelBuffersAvailable: Bool
    let main10EncoderAvailable: Bool
    let movieWriterAcceptsSettings: Bool
}

struct HDRExportCapability: Sendable, Equatable {
    let isSupported: Bool
    let reason: String?

    static func evaluate(_ snapshot: HDRExportCapabilitySnapshot) -> Self {
        if !snapshot.hlgColorSpacesAvailable {
            return .init(isSupported: false, reason: "BT.2020 HLG color conversion is unavailable.")
        }
        if !snapshot.videoRangePixelBuffersAvailable {
            return .init(isSupported: false, reason: "10-bit video-range pixel buffers are unavailable.")
        }
        if !snapshot.main10EncoderAvailable {
            return .init(isSupported: false, reason: "HEVC Main10 encoding is unavailable.")
        }
        if !snapshot.movieWriterAcceptsSettings {
            return .init(isSupported: false, reason: "QuickTime cannot write the requested Main10 HLG settings.")
        }
        return .init(isSupported: true, reason: nil)
    }
}

enum HDRVideoExporter {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    static let conversionID = "rec709-sdr-reference-white-75-to-bt2020-hlg"
    static let hlgReferenceWhiteSignal = 0.75

    struct TextOverlay: @unchecked Sendable {
        let image: CGImage
        let placement: CGPoint
        let clip: Clip
    }

    struct Inputs: @unchecked Sendable {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix?
        let textOverlays: [TextOverlay]
        let fps: Int
    }

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var cancelHandler: (@Sendable () -> Void)?

        func cancel() {
            lock.lock()
            cancelled = true
            let handler = cancelHandler
            lock.unlock()
            handler?()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.lock()
            cancelHandler = handler
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { handler() }
        }
    }

    struct HDRExportError: LocalizedError {
        let reason: String
        var errorDescription: String? { "HDR export failed: \(reason)" }
    }

    static func capability(renderSize: CGSize) async -> HDRExportCapability {
        let snapshot = await Task.detached(priority: .userInitiated) {
            capabilitySnapshot(renderSize: renderSize)
        }.value
        return HDRExportCapability.evaluate(snapshot)
    }

    static func requireCapability(renderSize: CGSize) async throws {
        let result = await capability(renderSize: renderSize)
        guard result.isSupported else {
            throw HDRExportError(reason: result.reason ?? "the selected HDR settings are unavailable")
        }
    }

    static func colorProperties() -> [String: Any] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
    }

    static func videoWriterSettings(size: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: colorProperties(),
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_ProfileLevel as String:
                    kVTProfileLevel_HEVC_Main10_AutoLevel,
            ],
        ]
    }

    static func export(
        _ inputs: Inputs,
        renderSize: CGSize,
        to outputURL: URL,
        cancellation: Cancellation,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await requireCapability(renderSize: renderSize)
        if cancellation.isCancelled { throw CancellationError() }

        let tracks = try await inputs.composition.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw HDRExportError(reason: "the timeline has no video") }
        let duration = try await inputs.composition.load(.duration)

        let reader = try AVAssetReader(asset: inputs.composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: NSNumber(value: false),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
        )
        videoOutput.videoComposition = inputs.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw HDRExportError(reason: "the SDR timeline compositor cannot feed the HDR converter")
        }
        reader.add(videoOutput)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings = videoWriterSettings(size: renderSize)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw HDRExportError(reason: "the movie writer rejected the Main10 HLG settings")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw HDRExportError(reason: "the movie writer rejected the HDR video track")
        }
        writer.add(videoInput)

        let audioTracks = try await inputs.composition.loadTracks(withMediaType: .audio)
        let audioPair = try makeAudioPair(
            tracks: audioTracks,
            mix: inputs.audioMix,
            reader: reader,
            writer: writer
        )

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.startWriting() else {
            throw HDRExportError(reason: writer.error?.localizedDescription ?? "the writer could not start")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw HDRExportError(reason: reader.error?.localizedDescription ?? "the timeline reader could not start")
        }

        let failure = FailureBox()
        let videoState = PumpState()
        let audioState = audioPair.map { _ in PumpState() }
        let coordinator = PumpCoordinator(
            reader: reader,
            writer: writer,
            videoState: videoState,
            audioState: audioState,
            failure: failure
        )
        cancellation.setCancelHandler { coordinator.cancel() }
        let videoPump = VideoPump(
            input: videoInput,
            output: videoOutput,
            adaptor: adaptor,
            renderSize: renderSize,
            overlays: inputs.textOverlays,
            fps: inputs.fps,
            duration: duration,
            cancellation: cancellation,
            state: videoState,
            coordinator: coordinator
        )
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pumpVideo(videoPump, onProgress: onProgress)
            }
            if let audioPair, let audioState {
                group.addTask {
                    await pumpAudio(
                        audioPair,
                        cancellation: cancellation,
                        state: audioState,
                        coordinator: coordinator
                    )
                }
            }
            group.addTask { await monitor(coordinator) }
            await group.waitForAll()
        }

        if cancellation.isCancelled || failure.cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if let reason = failure.reason {
            reader.cancelReading()
            writer.cancelWriting()
            throw HDRExportError(reason: reason)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw HDRExportError(reason: reader.error?.localizedDescription ?? "the timeline reader failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw HDRExportError(reason: writer.error?.localizedDescription ?? "the writer did not complete")
        }
    }

    private static func capabilitySnapshot(renderSize: CGSize) -> HDRExportCapabilitySnapshot {
        let inputSpace = CGColorSpace(name: CGColorSpace.itur_709)
        let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        let outputSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        let colorSpaces = inputSpace != nil && workingSpace != nil && outputSpace != nil

        var buffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            nil,
            max(2, Int(renderSize.width)),
            max(2, Int(renderSize.height)),
            pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )

        var compressionSession: VTCompressionSession?
        let encoderStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(max(2, Int(renderSize.width))),
            height: Int32(max(2, Int(renderSize.height))),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &compressionSession
        )
        var main10 = false
        if encoderStatus == noErr, let compressionSession {
            let profileStatus = VTSessionSetProperty(
                compressionSession,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_HEVC_Main10_AutoLevel
            )
            let preparationStatus = profileStatus == noErr
                ? VTCompressionSessionPrepareToEncodeFrames(compressionSession)
                : profileStatus
            main10 = profileStatus == noErr && preparationStatus == noErr
            VTCompressionSessionInvalidate(compressionSession)
        }

        var writerAcceptsSettings = false
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngv-hdr-capability-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: probeURL) }
        if let writer = try? AVAssetWriter(outputURL: probeURL, fileType: .mov) {
            let settings = videoWriterSettings(size: renderSize)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerAcceptsSettings = writer.canApply(outputSettings: settings, forMediaType: .video)
                && writer.canAdd(input)
        }

        return .init(
            hlgColorSpacesAvailable: colorSpaces,
            videoRangePixelBuffersAvailable: pixelStatus == kCVReturnSuccess && buffer != nil,
            main10EncoderAvailable: main10,
            movieWriterAcceptsSettings: writerAcceptsSettings
        )
    }

    private struct AudioPair: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
    }

    private static func makeAudioPair(
        tracks: [AVAssetTrack],
        mix: AVAudioMix?,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws -> AudioPair? {
        guard !tracks.isEmpty else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output),
              writer.canApply(outputSettings: audioSettings, forMediaType: .audio),
              writer.canAdd(input) else {
            throw HDRExportError(reason: "the timeline audio cannot be written with the HDR movie")
        }
        reader.add(output)
        writer.add(input)
        return .init(input: input, output: output)
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedReason: String?
        private var storedCancelled = false

        func fail(_ reason: String) {
            lock.lock()
            if storedReason == nil { storedReason = reason }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            storedCancelled = true
            lock.unlock()
        }

        var reason: String? {
            lock.lock()
            defer { lock.unlock() }
            return storedReason
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedCancelled
        }
    }

    private final class PumpState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        var lastProgress = -1.0

        func install(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    private final class PumpCoordinator: @unchecked Sendable {
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let videoState: PumpState
        private let audioState: PumpState?
        private let failure: FailureBox
        private let lock = NSLock()
        private var stopped = false
        private var lastActivity = Date()

        init(
            reader: AVAssetReader,
            writer: AVAssetWriter,
            videoState: PumpState,
            audioState: PumpState?,
            failure: FailureBox
        ) {
            self.reader = reader
            self.writer = writer
            self.videoState = videoState
            self.audioState = audioState
            self.failure = failure
        }

        func activity() {
            lock.lock()
            lastActivity = Date()
            lock.unlock()
        }

        func fail(_ reason: String) {
            failure.fail(reason)
            abort()
        }

        func cancel() {
            failure.cancel()
            abort()
        }

        private func abort() {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            stopped = true
            lock.unlock()
            reader.cancelReading()
            writer.cancelWriting()
            videoState.finish()
            audioState?.finish()
        }

        var isFinished: Bool {
            videoState.isFinished && (audioState?.isFinished ?? true)
        }

        var writerFailed: Bool { writer.status == .failed }

        var writerFailureReason: String {
            writer.error?.localizedDescription ?? "the HDR movie writer failed"
        }

        var readerFailureReason: String? {
            guard reader.status == .failed else { return nil }
            return reader.error?.localizedDescription ?? "the timeline reader failed"
        }

        var hasStalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !stopped && Date().timeIntervalSince(lastActivity) > 120
        }
    }

    private struct VideoPump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let renderSize: CGSize
        let overlays: [TextOverlay]
        let fps: Int
        let duration: CMTime
        let cancellation: Cancellation
        let state: PumpState
        let coordinator: PumpCoordinator
    }

    private static func pumpAudio(
        _ pair: AudioPair,
        cancellation: Cancellation,
        state: PumpState,
        coordinator: PumpCoordinator
    ) async {
        let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.hdr.audio")
        await withCheckedContinuation { continuation in
            guard state.install(continuation) else {
                continuation.resume()
                return
            }
            pair.input.requestMediaDataWhenReady(on: queue) {
                guard !state.isFinished else { return }
                while pair.input.isReadyForMoreMediaData {
                    if state.isFinished { return }
                    if cancellation.isCancelled {
                        coordinator.cancel()
                        return
                    }
                    guard let sample = pair.output.copyNextSampleBuffer() else {
                        if let reason = coordinator.readerFailureReason {
                            coordinator.fail(reason)
                        } else {
                            pair.input.markAsFinished()
                            state.finish()
                        }
                        return
                    }
                    guard pair.input.append(sample) else {
                        coordinator.fail("audio encoding failed")
                        return
                    }
                    coordinator.activity()
                }
            }
        }
    }

    private static func pumpVideo(
        _ pump: VideoPump,
        onProgress: (@Sendable (Double) -> Void)?
    ) async {
        let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.hdr.video")
        let inputSpace = CGColorSpace(name: CGColorSpace.itur_709)!
        let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let outputSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        let context = CIContext(options: [
            .workingColorSpace: workingSpace,
            .outputColorSpace: outputSpace,
        ])
        let bounds = CGRect(origin: .zero, size: pump.renderSize)

        await withCheckedContinuation { continuation in
            guard pump.state.install(continuation) else {
                continuation.resume()
                return
            }
            pump.input.requestMediaDataWhenReady(on: queue) {
                guard !pump.state.isFinished else { return }
                while pump.input.isReadyForMoreMediaData {
                    if pump.state.isFinished { return }
                    if pump.cancellation.isCancelled {
                        pump.coordinator.cancel()
                        return
                    }
                    guard let sample = pump.output.copyNextSampleBuffer() else {
                        if let reason = pump.coordinator.readerFailureReason {
                            pump.coordinator.fail(reason)
                        } else {
                            pump.input.markAsFinished()
                            pump.state.finish()
                        }
                        return
                    }
                    guard let source = CMSampleBufferGetImageBuffer(sample),
                          let pool = pump.adaptor.pixelBufferPool else {
                        pump.coordinator.fail(
                            "the HDR pixel-buffer pipeline became unavailable"
                        )
                        return
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let frame = Int((pts.seconds * Double(max(1, pump.fps))).rounded())
                    // Reader alpha isn't delivery truth; the rendered timeline canvas is opaque.
                    var image = CIImage(cvPixelBuffer: source, options: [.colorSpace: inputSpace])
                        .applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        ])
                    for overlay in pump.overlays
                        where frame >= overlay.clip.startFrame && frame < overlay.clip.endFrame {
                        var title = CIImage(cgImage: overlay.image, options: [.colorSpace: inputSpace])
                            .transformed(by: CGAffineTransform(
                                translationX: overlay.placement.x,
                                y: overlay.placement.y
                            ))
                        let opacity = min(1, max(0, overlay.clip.opacityAt(frame: frame)))
                        if opacity < 1 {
                            title = title.applyingFilter("CIColorMatrix", parameters: [
                                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                            ])
                        }
                        image = title.composited(over: image)
                    }
                    // Prevent SDR titles and effects from creating undeclared HDR highlight energy.
                    let constrained = image.applyingFilter("CIColorClamp", parameters: [
                        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                    ]).cropped(to: bounds)
                    var destination: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
                    guard status == kCVReturnSuccess, let destination else {
                        pump.coordinator.fail(
                            "a 10-bit HDR frame buffer could not be allocated"
                        )
                        return
                    }
                    tagHLG(destination, colorSpace: outputSpace)
                    context.render(constrained, to: destination, bounds: bounds, colorSpace: outputSpace)
                    guard pump.adaptor.append(destination, withPresentationTime: pts) else {
                        pump.coordinator.fail("a converted HDR frame could not be encoded")
                        return
                    }
                    pump.coordinator.activity()
                    if let onProgress, pump.duration.seconds > 0,
                       pts.seconds - pump.state.lastProgress >= 0.25 {
                        pump.state.lastProgress = pts.seconds
                        onProgress(min(1, max(0, pts.seconds / pump.duration.seconds)))
                    }
                }
            }
        }
    }

    private static func monitor(_ coordinator: PumpCoordinator) async {
        while !coordinator.isFinished {
            if coordinator.writerFailed {
                coordinator.fail(coordinator.writerFailureReason)
                return
            }
            if coordinator.hasStalled {
                coordinator.fail("the HDR movie writer made no progress for 120 seconds")
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func tagHLG(_ buffer: CVPixelBuffer, colorSpace: CGColorSpace) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
    }
}
