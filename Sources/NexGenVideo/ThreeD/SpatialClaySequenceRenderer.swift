import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Darwin
import Foundation

struct SpatialClaySequenceTiming: Codable, Sendable, Equatable {
    let numerator: Int64
    let denominator: Int32
}

struct SpatialClaySequenceChunk: Codable, Sendable, Equatable {
    let proofFilename: String
    let proofSHA256: String
    let movieFilename: String?
    let startFrame: Int
    let endFrame: Int
    let jobID: UUID
    let jobFingerprint: String
}

struct SpatialClaySequenceProof: Codable, Sendable, Equatable {
    var schema = "spatial-derivation-sequence/v1"
    let id: UUID
    let request: SpatialClayRequest
    let state: SpatialClayState
    let scene: SpatialSceneHead
    let timing: SpatialClaySequenceTiming
    let timebaseNumerator: Int
    let timebaseDenominator: Int
    let chunks: [SpatialClaySequenceChunk]
    let outputs: [SpatialClayOutput]
}

final class SpatialClaySequenceCandidate: @unchecked Sendable {
    let proof: SpatialClaySequenceProof
    let proofData: Data
    let files: [String: URL]
    private let root: URL
    private let release: @Sendable () -> Void
    private let lock = NSLock()
    private var available = true

    fileprivate init(proof: SpatialClaySequenceProof, files: [String: URL], root: URL,
                     release: @escaping @Sendable () -> Void) throws {
        self.proof = proof
        proofData = try SpatialSceneStore.encode(proof)
        self.files = files
        self.root = root
        self.release = release
    }

    var isAvailable: Bool { lock.withLock { available } }

    func discard() {
        let shouldRemove = lock.withLock {
            guard available else { return false }
            available = false
            return true
        }
        guard shouldRemove else { return }
        release()
        let directory = root
        Task.detached(priority: .utility) {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { NSLog("Clay sequence cleanup failed: %@", error.localizedDescription) }
        }
    }

    deinit { discard() }
}

final class SpatialClaySequenceReceipts: @unchecked Sendable {
    private struct Record {
        let binding: Data
        var chunkHashes: [String] = []
        var seal: String?
    }
    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    private var closed = false

    func begin(binding: Data) throws -> UUID {
        try lock.withLock {
            guard !closed, !records.values.contains(where: { $0.seal == nil }) else {
                throw SpatialSceneError.invalid("Finish the current Clay sequence before starting another.")
            }
            let id = UUID()
            records[id] = Record(binding: binding)
            return id
        }
    }

    func append(_ id: UUID, proof: Data) throws {
        try lock.withLock {
            guard !closed, var record = records[id], record.seal == nil else { throw SpatialSceneError.changed }
            record.chunkHashes.append(SpatialSceneStore.digest(proof))
            records[id] = record
        }
    }

    func seal(_ candidate: SpatialClaySequenceCandidate) throws {
        let binding = try SpatialClayRenderer.sequenceBinding(candidate.proof)
        try lock.withLock {
            guard !closed, candidate.isAvailable, var record = records[candidate.proof.id], record.seal == nil,
                  record.binding == binding,
                  record.chunkHashes == candidate.proof.chunks.map(\.proofSHA256) else {
                throw SpatialSceneError.invalid("The complete Clay sequence has no authenticated render history.")
            }
            record.seal = SpatialSceneStore.digest(candidate.proofData)
            records[candidate.proof.id] = record
        }
    }

    func authenticate(_ candidate: SpatialClaySequenceCandidate) throws {
        try lock.withLock {
            guard !closed, candidate.isAvailable,
                  records[candidate.proof.id]?.seal == SpatialSceneStore.digest(candidate.proofData) else {
                throw SpatialSceneError.invalid("The Clay sequence has no host-issued aggregate receipt.")
            }
        }
    }

    func release(_ id: UUID) { lock.withLock { _ = records.removeValue(forKey: id) } }
    func close() { lock.withLock { closed = true; records.removeAll() } }
}

extension SpatialClayRenderer {
    static func prepareSequence(
        request: SpatialClayRequest, revision: SpatialSceneRevision, state: SpatialClayState,
        timing: SpatialClaySequenceTiming, runtime: BpyRuntimeSession, runtimeRoot: URL,
        jobID: UUID = UUID(), isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SpatialClaySequenceCandidate {
        let task = Task.detached(priority: .userInitiated) {
            try await prepareSequenceOffMain(request: request, revision: revision, state: state, timing: timing,
                runtime: runtime, runtimeRoot: runtimeRoot, jobID: jobID,
                isCancelled: { Task.isCancelled || isCancelled() })
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func prepareSequenceOffMain(
        request: SpatialClayRequest, revision: SpatialSceneRevision, state: SpatialClayState,
        timing: SpatialClaySequenceTiming, runtime: BpyRuntimeSession, runtimeRoot: URL,
        jobID: UUID, isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> SpatialClaySequenceCandidate {
        try validateSequenceState(state, request: request, revision: revision)
        try validateSequenceRequest(request, revision: revision)
        let clock = try sequenceClock(timing, numerator: revision.snapshot.timebaseNumerator,
                                      denominator: revision.snapshot.timebaseDenominator, count: state.frames.count)
        let scene = SpatialSceneHead(id: revision.manifest.sceneID, name: revision.manifest.name,
            revision: revision.manifest.revision, manifestSHA256: SpatialSceneStore.digest(revision.manifestData))
        let initial = SpatialClaySequenceProof(id: jobID, request: request, state: state, scene: scene, timing: timing,
            timebaseNumerator: revision.snapshot.timebaseNumerator,
            timebaseDenominator: revision.snapshot.timebaseDenominator, chunks: [], outputs: [])
        let id = try runtime.beginSpatialSequence(binding: sequenceBinding(initial))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-clay-sequence-" + id.uuidString)
        var transferred = false
        defer {
            if !transferred {
                runtime.releaseSpatialSequence(id)
                try? FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var chunks: [SpatialClaySequenceChunk] = []
        var outputs: [SpatialClayOutput] = []
        var files: [String: URL] = [:]
        let chunkSize = min(32, 33_554_432 / (request.width * request.height))
        for offset in stride(from: 0, to: state.frames.count, by: chunkSize) {
            guard !isCancelled() else { throw CancellationError() }
            let frames = Array(state.frames[offset..<min(offset + chunkSize, state.frames.count)])
            let chunkState = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256,
                                             cameraID: state.cameraID, frames: frames)
            let chunkRequest = SpatialClayRequest(owner: request.owner, ownerArtifactSHA256: request.ownerArtifactSHA256,
                ownerBindingSHA256: request.ownerBindingSHA256, cameraID: request.cameraID,
                startFrame: frames[0].frame, endFrame: frames[frames.count - 1].frame,
                width: request.width, height: request.height, samples: request.samples,
                stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(chunkState)))
            let chunk = try await prepare(request: chunkRequest, revision: revision, state: chunkState,
                runtime: runtime, runtimeRoot: runtimeRoot, jobID: chunks.isEmpty ? jobID : UUID(), isCancelled: isCancelled)
            try runtime.appendSpatialSequence(id, candidate: chunk, source: revision)
            let stem = String(format: "chunk-%08d", offset)
            for output in chunk.proof.outputs {
                guard let data = chunk.files[output.filename] else { throw SpatialSceneError.changed }
                let name = output.filename == "clay.mov" ? stem + ".mov" : output.filename
                let url = root.appendingPathComponent(name)
                try data.write(to: url, options: .withoutOverwriting)
                files[name] = url
                outputs.append(.init(filename: name, sha256: output.sha256, byteCount: output.byteCount,
                    width: output.width, height: output.height, frameCount: output.frameCount, mediaKind: output.mediaKind))
            }
            let proofName = stem + ".json"
            let proofURL = root.appendingPathComponent(proofName)
            try chunk.proofData.write(to: proofURL, options: .withoutOverwriting)
            files[proofName] = proofURL
            outputs.append(.init(filename: proofName, sha256: SpatialSceneStore.digest(chunk.proofData),
                byteCount: chunk.proofData.count, width: 0, height: 0, frameCount: 0, mediaKind: "application/json"))
            chunks.append(.init(proofFilename: proofName, proofSHA256: SpatialSceneStore.digest(chunk.proofData),
                movieFilename: frames.count > 1 ? stem + ".mov" : nil,
                startFrame: chunkRequest.startFrame, endFrame: chunkRequest.endFrame,
                jobID: chunk.proof.jobID, jobFingerprint: chunk.proof.jobFingerprint))
        }
        let movie = root.appendingPathComponent("clay.mov")
        try await encodeSequenceMovie(request: request, clock: clock, files: files, output: movie, isCancelled: isCancelled)
        files["clay.mov"] = movie
        let movieDigest = try sequenceFileDigest(movie)
        outputs.append(.init(filename: "clay.mov", sha256: movieDigest.sha256, byteCount: movieDigest.byteCount,
            width: request.width, height: request.height, frameCount: state.frames.count, mediaKind: "video/quicktime"))
        let proof = SpatialClaySequenceProof(id: id, request: request, state: state, scene: scene, timing: timing,
            timebaseNumerator: revision.snapshot.timebaseNumerator,
            timebaseDenominator: revision.snapshot.timebaseDenominator, chunks: chunks, outputs: outputs)
        for url in files.values { try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path) }
        let candidate = try SpatialClaySequenceCandidate(proof: proof, files: files, root: root,
                                                         release: { [weak runtime] in runtime?.releaseSpatialSequence(id) })
        try await runtime.retainSpatialSequence(candidate, source: revision)
        guard !isCancelled() else { throw CancellationError() }
        transferred = true
        return candidate
    }

    static func sequenceBinding(_ proof: SpatialClaySequenceProof) throws -> Data {
        struct Binding: Encodable {
            let request: SpatialClayRequest
            let state: SpatialClayState
            let scene: SpatialSceneHead
            let timing: SpatialClaySequenceTiming
            let timebaseNumerator: Int
            let timebaseDenominator: Int
        }
        return try SpatialSceneStore.encode(Binding(request: proof.request, state: proof.state, scene: proof.scene,
            timing: proof.timing, timebaseNumerator: proof.timebaseNumerator, timebaseDenominator: proof.timebaseDenominator))
    }

    private static func validateSequenceRequest(_ request: SpatialClayRequest, revision: SpatialSceneRevision) throws {
        guard (64...4096).contains(request.width), (64...4096).contains(request.height),
              request.width.isMultiple(of: 2), request.height.isMultiple(of: 2), (1...128).contains(request.samples),
              [request.ownerArtifactSHA256, request.ownerBindingSHA256].allSatisfy({
                  $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }), let camera = revision.snapshot.cameras.first(where: { $0.id == request.cameraID }),
              camera.width * request.height == camera.height * request.width else {
            throw SpatialSceneError.invalid("The Clay sequence camera or render settings are invalid.")
        }
    }

    static func validateSequence(proofData: Data, files: [String: URL], against revision: SpatialSceneRevision) throws {
        let proof = try JSONDecoder().decode(SpatialClaySequenceProof.self, from: proofData)
        try validateSequenceState(proof.state, request: proof.request, revision: revision)
        try validateSequenceRequest(proof.request, revision: revision)
        guard try SpatialSceneStore.encode(proof) == proofData, proof.schema == "spatial-derivation-sequence/v1",
              proof.scene.id == revision.manifest.sceneID, proof.scene.revision == revision.manifest.revision,
              proof.scene.name == revision.manifest.name,
              proof.scene.manifestSHA256 == SpatialSceneStore.digest(revision.manifestData),
              proof.timebaseNumerator == revision.snapshot.timebaseNumerator,
              proof.timebaseDenominator == revision.snapshot.timebaseDenominator,
              proof.outputs.count == files.count, Set(proof.outputs.map(\.filename)) == Set(files.keys),
              !proof.chunks.isEmpty, Set(proof.chunks.map(\.jobID)).count == proof.chunks.count else {
            throw SpatialSceneError.changed
        }
        _ = try sequenceClock(proof.timing, numerator: proof.timebaseNumerator,
                              denominator: proof.timebaseDenominator, count: proof.state.frames.count)
        var expectedNames = Set(["clay.mov"])
        let metadata = Dictionary(uniqueKeysWithValues: proof.outputs.map { ($0.filename, $0) })
        var next = proof.request.startFrame
        let chunkSize = min(32, 33_554_432 / (proof.request.width * proof.request.height))
        var rendererIdentity: [String]?
        for chunk in proof.chunks {
            guard next <= proof.request.endFrame, chunk.startFrame == next,
                  chunk.endFrame == min(next + chunkSize - 1, proof.request.endFrame),
                  let dataURL = files[chunk.proofFilename] else { throw SpatialSceneError.changed }
            let data = try SpatialSceneStore.read(dataURL.lastPathComponent, in: dataURL.deletingLastPathComponent())
            let item = try JSONDecoder().decode(SpatialDerivationProof.self, from: data)
            guard SpatialSceneStore.digest(data) == chunk.proofSHA256,
                  chunk.proofFilename == String(format: "chunk-%08d.json", next),
                  chunk.movieFilename == (chunk.endFrame > next ? String(format: "chunk-%08d.mov", next) : nil),
                  item.jobID == chunk.jobID, item.jobFingerprint == chunk.jobFingerprint,
                  item.request.owner == proof.request.owner, item.request.ownerArtifactSHA256 == proof.request.ownerArtifactSHA256,
                  item.request.ownerBindingSHA256 == proof.request.ownerBindingSHA256,
                  item.request.cameraID == proof.request.cameraID, item.request.startFrame == next,
                  item.request.endFrame == chunk.endFrame, item.request.width == proof.request.width,
                  item.request.height == proof.request.height, item.request.samples == proof.request.samples,
                  let state = item.state, state.frames == Array(proof.state.frames[next...chunk.endFrame]),
                  metadata[chunk.proofFilename] == SpatialClayOutput(filename: chunk.proofFilename,
                    sha256: chunk.proofSHA256, byteCount: data.count, width: 0, height: 0, frameCount: 0, mediaKind: "application/json") else {
                throw SpatialSceneError.changed
            }
            let identity = [item.runtimeLockSHA256, item.workerSHA256, item.rendererScriptSHA256,
                            item.rendererBinarySHA256, item.renderer, item.blenderBuildHash]
            if let rendererIdentity, rendererIdentity != identity { throw SpatialSceneError.changed }
            rendererIdentity = identity
            var chunkFiles: [String: Data] = [:]
            for output in item.outputs {
                let name = output.filename == "clay.mov" ? chunk.movieFilename : output.filename
                guard let name, let url = files[name], expectedNames.insert(name).inserted,
                      metadata[name] == SpatialClayOutput(filename: name, sha256: output.sha256, byteCount: output.byteCount,
                        width: output.width, height: output.height, frameCount: output.frameCount, mediaKind: output.mediaKind) else {
                    throw SpatialSceneError.changed
                }
                chunkFiles[output.filename] = try SpatialSceneStore.read(url.lastPathComponent, in: url.deletingLastPathComponent())
            }
            try validate(.init(proof: item, proofData: data, files: chunkFiles), against: revision)
            guard expectedNames.insert(chunk.proofFilename).inserted else { throw SpatialSceneError.changed }
            next = chunk.endFrame + 1
        }
        guard next == proof.request.endFrame + 1, expectedNames == Set(files.keys),
              let movie = files["clay.mov"], let output = metadata["clay.mov"] else { throw SpatialSceneError.changed }
        let digest = try sequenceFileDigest(movie)
        guard output == SpatialClayOutput(filename: "clay.mov", sha256: digest.sha256, byteCount: digest.byteCount,
            width: proof.request.width, height: proof.request.height,
            frameCount: proof.state.frames.count, mediaKind: "video/quicktime") else { throw SpatialSceneError.changed }
    }

    struct SequenceClock {
        let timescale: Int32
        let frameTicks: Int64
        let durationTicks: Int64
        let count: Int
        var duration: CMTime { CMTime(value: durationTicks, timescale: timescale) }
        func presentation(_ index: Int) -> CMTime { CMTime(value: Int64(index) * frameTicks, timescale: timescale) }
        func sampleDuration(_ index: Int) -> CMTime {
            CMTime(value: index == count - 1 ? durationTicks - Int64(index) * frameTicks : frameTicks, timescale: timescale)
        }
    }

    static func sequenceClock(_ timing: SpatialClaySequenceTiming, numerator: Int, denominator: Int,
                              count: Int) throws -> SequenceClock {
        guard timing.numerator > 0, timing.denominator > 0, numerator > 0, numerator <= Int32.max,
              denominator > 0, denominator <= Int32.max, (1...1_000_001).contains(count) else { throw SpatialSceneError.changed }
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }
        let common = gcd(Int64(numerator), Int64(timing.denominator))
        let scale = Int64(numerator) / common * Int64(timing.denominator)
        guard scale <= Int32.max else {
            throw SpatialSceneError.invalid("The exact shot and scene timebases cannot be represented by this video container.")
        }
        let (duration, durationOverflow) = timing.numerator.multipliedReportingOverflow(by: scale / Int64(timing.denominator))
        let step = Int64(denominator) * (scale / Int64(numerator))
        let (full, fullOverflow) = Int64(count).multipliedReportingOverflow(by: step)
        guard !durationOverflow, !fullOverflow, duration > full - step, duration <= full else {
            throw SpatialSceneError.invalid("The Clay state does not cover the exact planned shot duration.")
        }
        return .init(timescale: Int32(scale), frameTicks: step, durationTicks: duration, count: count)
    }

    static func sequenceFileDigest(_ url: URL) throws -> (sha256: String, byteCount: Int) {
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw SpatialSceneError.changed }
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpatialSceneError.changed }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0 else { throw SpatialSceneError.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var digest = SHA256(), count = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            guard !Task.isCancelled else { throw CancellationError() }
            digest.update(data: data)
            count += data.count
        }
        guard fstat(fd, &after) == 0, before.st_size == count, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw SpatialSceneError.changed }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    private static func sequenceImage(_ index: Int, request: SpatialClayRequest, files: [String: URL]) throws -> CGImage {
        guard let url = files[String(format: "clay-%08d.png", request.startFrame + index)] else { throw SpatialSceneError.changed }
        return try decodePNG(SpatialSceneStore.read(url.lastPathComponent, in: url.deletingLastPathComponent()),
                             width: request.width, height: request.height)
    }

    private static func encodeSequenceMovie(request: SpatialClayRequest, clock: SequenceClock, files: [String: URL],
                                            output: URL, isCancelled: @escaping @Sendable () -> Bool) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.movieTimeScale = clock.timescale
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: request.width, AVVideoHeightKey: request.height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: max(2_000_000, request.width * request.height * 8)],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        input.mediaTimeScale = clock.timescale
        guard writer.canAdd(input) else { throw SpatialSceneError.invalid("The Clay sequence encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SpatialSceneError.changed }
        writer.startSession(atSourceTime: .zero)
        var complete = false
        defer { if !complete && writer.status == .writing { writer.cancelWriting() } }
        for index in 0..<clock.count {
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                guard !isCancelled(), Date() < deadline else { throw CancellationError() }
                guard writer.status == .writing else { throw writer.error ?? SpatialSceneError.changed }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard !isCancelled() else { throw CancellationError() }
            try autoreleasepool {
                let image = try sequenceImage(index, request: request, files: files)
                var optional: CVPixelBuffer?
                let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
                guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                                          attributes, &optional) == kCVReturnSuccess, let pixel = optional else {
                    throw SpatialSceneError.invalid("The Clay sequence frame could not be allocated.")
                }
                CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                CVPixelBufferLockBaseAddress(pixel, [])
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                    space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                    CVPixelBufferUnlockBaseAddress(pixel, [])
                    throw SpatialSceneError.invalid("The Clay sequence drawing surface is unavailable.")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                CVPixelBufferUnlockBaseAddress(pixel, [])
                var format: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel,
                    formatDescriptionOut: &format) == noErr, let format else { throw SpatialSceneError.changed }
                var timing = CMSampleTimingInfo(duration: clock.sampleDuration(index),
                    presentationTimeStamp: clock.presentation(index), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
                    sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample, input.append(sample) else {
                    throw writer.error ?? SpatialSceneError.invalid("The Clay sequence frame could not be written.")
                }
            }
        }
        writer.endSession(atSourceTime: clock.duration)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, !isCancelled() else { throw writer.error ?? CancellationError() }
        complete = true
    }

    static func verifySequenceMovie(_ candidate: SpatialClaySequenceCandidate,
                                    isCancelled: @escaping @Sendable () -> Bool) async throws {
        let proof = candidate.proof
        let clock = try sequenceClock(proof.timing, numerator: proof.timebaseNumerator,
                                      denominator: proof.timebaseDenominator, count: proof.state.frames.count)
        guard candidate.isAvailable, let movie = candidate.files["clay.mov"] else { throw SpatialSceneError.changed }
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw SpatialSceneError.changed }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        guard size.width == CGFloat(proof.request.width), size.height == CGFloat(proof.request.height),
              CMTimeCompare(duration, clock.duration) == 0 else {
            throw SpatialSceneError.invalid("The complete Clay movie dimensions or exact duration changed.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpatialSceneError.changed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpatialSceneError.changed }
        defer { if reader.status == .reading { reader.cancelReading() } }
        for index in 0..<clock.count {
            guard !Task.isCancelled, !isCancelled(), candidate.isAvailable else { throw CancellationError() }
            try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample),
                      CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), clock.presentation(index)) == 0,
                      CMTimeCompare(CMSampleBufferGetDuration(sample), clock.sampleDuration(index)) == 0 else {
                    throw SpatialSceneError.invalid("The complete Clay movie lost a frame or changed its exact timing.")
                }
                try verifyMovieFrame(image, expected: sequenceImage(index, request: proof.request, files: candidate.files))
            }
        }
        guard output.copyNextSampleBuffer() == nil, reader.status == .completed else {
            throw SpatialSceneError.invalid("The complete Clay movie has unexpected frames.")
        }
    }
}
