import AVFoundation
import BpyRuntimeProtocol
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
    private let retention: BpySequenceRetention
    private let release: @Sendable () -> Void
    private let lock = NSLock()
    private var available = true

    fileprivate init(proof: SpatialClaySequenceProof, files: [String: URL], root: URL,
                     retention: BpySequenceRetention, release: @escaping @Sendable () -> Void) throws {
        self.proof = proof
        proofData = try SpatialSceneStore.encode(proof)
        self.files = files
        self.root = root
        self.retention = retention
        self.release = release
    }

    var isAvailable: Bool { lock.withLock { available } }
    var workOwner: UUID { retention.workOwner }

    func borrowFiles() throws -> [BpyRuntimeFile] {
        try lock.withLock {
            guard available else { throw SpatialSceneError.changed }
            return try retention.borrow()
        }
    }

    func discard() {
        let shouldRemove = lock.withLock {
            guard available else { return false }
            available = false
            return true
        }
        guard shouldRemove else { return }
        release()
        retention.release()
    }

    deinit { discard() }
}

final class SpatialClaySequenceReceipts: @unchecked Sendable {
    private final class CandidateRef { weak var value: SpatialClaySequenceCandidate? }
    private struct Record {
        let binding: Data
        var chunkHashes: [String] = []
        var seal: String?
        let candidate = CandidateRef()
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
            record.candidate.value = candidate
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
    func close() {
        let candidates = lock.withLock {
            closed = true
            let candidates = records.values.compactMap { $0.candidate.value }
            records.removeAll()
            return candidates
        }
        for candidate in candidates { candidate.discard() }
    }
}

extension SpatialClayRenderer {
    static func prepareSequence(
        request: SpatialClayRequest, revision: SpatialSceneRevision, state: SpatialClayState,
        timing: SpatialClaySequenceTiming, runtime: BpyRuntimeSession, runtimeRoot: URL,
        cancellation: BpyOperationCancellation,
        jobID: UUID = UUID(), isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SpatialClaySequenceCandidate {
        let task = Task.detached(priority: .userInitiated) {
            try await prepareSequenceOffMain(request: request, revision: revision, state: state, timing: timing,
                runtime: runtime, runtimeRoot: runtimeRoot, jobID: jobID, cancellation: cancellation,
                isCancelled: { Task.isCancelled || isCancelled() })
        }
        let registration = cancellation.observe { task.cancel() }
        defer { withExtendedLifetime(registration) {} }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel(); task.cancel() }
    }

    private static func prepareSequenceOffMain(
        request: SpatialClayRequest, revision: SpatialSceneRevision, state: SpatialClayState,
        timing: SpatialClaySequenceTiming, runtime: BpyRuntimeSession, runtimeRoot: URL,
        jobID: UUID, cancellation: BpyOperationCancellation, isCancelled: @escaping @Sendable () -> Bool
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
        var transferred = false
        defer {
            if !transferred {
                runtime.releaseSpatialSequence(id)
            }
        }
        let root = try BpyHostStaging.shared.directory("sequence-" + id.uuidString)
        let retention = runtime.sequenceRetention(root: root)
        defer { if !transferred { retention.release() } }
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
                runtime: runtime, runtimeRoot: runtimeRoot, cancellation: cancellation,
                jobID: chunks.isEmpty ? jobID : UUID(), isCancelled: isCancelled)
            defer { chunk.release() }
            try runtime.appendSpatialSequence(id, candidate: chunk, source: revision, cancellation: cancellation)
            let stem = String(format: "chunk-%08d", frames[0].frame)
            for output in chunk.proof.outputs {
                guard let file = chunk.files[output.filename] else { throw SpatialSceneError.changed }
                let name = output.filename == "clay.mov" ? stem + ".mov" : output.filename
                let url = root.appendingPathComponent(name)
                try retention.copy(file, to: url)
                files[name] = url
                outputs.append(.init(filename: name, sha256: output.sha256, byteCount: output.byteCount,
                    width: output.width, height: output.height, frameCount: output.frameCount, mediaKind: output.mediaKind))
            }
            let proofName = stem + ".json"
            let proofURL = root.appendingPathComponent(proofName)
            try retention.copy(chunk.proofData, to: proofURL)
            files[proofName] = proofURL
            outputs.append(.init(filename: proofName, sha256: SpatialSceneStore.digest(chunk.proofData),
                byteCount: chunk.proofData.count, width: 0, height: 0, frameCount: 0, mediaKind: "application/json"))
            chunks.append(.init(proofFilename: proofName, proofSHA256: SpatialSceneStore.digest(chunk.proofData),
                movieFilename: frames.count > 1 ? stem + ".mov" : nil,
                startFrame: chunkRequest.startFrame, endFrame: chunkRequest.endFrame,
                jobID: chunk.proof.jobID, jobFingerprint: chunk.proof.jobFingerprint))
        }
        let media = try retention.encoding(width: request.width, height: request.height)
        defer { media.abandon() }
        try await encodeSequenceMovie(request: request, clock: clock, files: files, media: media,
            retention: retention, cancellation: cancellation, isCancelled: isCancelled)
        let movie = try media.finish()
        defer { movie.release() }
        try retention.adopt(movie)
        files["clay.mov"] = movie.url
        outputs.append(.init(filename: "clay.mov", sha256: movie.sha256, byteCount: Int(movie.byteCount),
            width: request.width, height: request.height, frameCount: state.frames.count, mediaKind: "video/quicktime"))
        let proof = SpatialClaySequenceProof(id: id, request: request, state: state, scene: scene, timing: timing,
            timebaseNumerator: revision.snapshot.timebaseNumerator,
            timebaseDenominator: revision.snapshot.timebaseDenominator, chunks: chunks, outputs: outputs)
        let candidate = try SpatialClaySequenceCandidate(proof: proof, files: files, root: root, retention: retention,
                                                         release: { [weak runtime] in runtime?.releaseSpatialSequence(id) })
        try await runtime.retainSpatialSequence(candidate, source: revision, cancellation: cancellation)
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

    static func validateSequence(proofData: Data, files: [String: URL], against revision: SpatialSceneRevision,
                                 scope: BpyMediaReadScope) throws {
        try scope.withConsumer { work in
            try scope.check()
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
                try scope.check()
                guard next <= proof.request.endFrame, chunk.startFrame == next,
                      chunk.endFrame == min(next + chunkSize - 1, proof.request.endFrame),
                      let dataURL = files[chunk.proofFilename] else { throw SpatialSceneError.changed }
                let data = try SpatialSceneStore.read(dataURL.lastPathComponent, in: dataURL.deletingLastPathComponent(),
                    checking: { try scope.check(); try work.check() })
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
                      let state = item.state, state.frames == Array(proof.state.frames[(next - proof.request.startFrame)...(chunk.endFrame - proof.request.startFrame)]),
                      metadata[chunk.proofFilename] == SpatialClayOutput(filename: chunk.proofFilename,
                        sha256: chunk.proofSHA256, byteCount: data.count, width: 0, height: 0, frameCount: 0, mediaKind: "application/json") else {
                    throw SpatialSceneError.changed
                }
                let identity = [item.runtimeLockSHA256, item.workerSHA256, item.rendererScriptSHA256,
                                item.rendererBinarySHA256, item.renderer, item.blenderBuildHash]
                if let rendererIdentity, rendererIdentity != identity { throw SpatialSceneError.changed }
                rendererIdentity = identity
                var chunkFiles: [String: URL] = [:]
                for output in item.outputs {
                    let name = output.filename == "clay.mov" ? chunk.movieFilename : output.filename
                    guard let name, let url = files[name], expectedNames.insert(name).inserted,
                          metadata[name] == SpatialClayOutput(filename: name, sha256: output.sha256, byteCount: output.byteCount,
                            width: output.width, height: output.height, frameCount: output.frameCount, mediaKind: output.mediaKind) else {
                        throw SpatialSceneError.changed
                    }
                    chunkFiles[output.filename] = url
                }
                try validate(proof: item, proofData: data, files: chunkFiles, against: revision, scope: scope)
                guard expectedNames.insert(chunk.proofFilename).inserted else { throw SpatialSceneError.changed }
                next = chunk.endFrame + 1
            }
            guard next == proof.request.endFrame + 1, expectedNames == Set(files.keys),
                  let movie = files["clay.mov"], let output = metadata["clay.mov"] else { throw SpatialSceneError.changed }
            let digest = try sequenceFileDigest(movie, scope: scope)
            guard output == SpatialClayOutput(filename: "clay.mov", sha256: digest.sha256, byteCount: digest.byteCount,
                width: proof.request.width, height: proof.request.height,
                frameCount: proof.state.frames.count, mediaKind: "video/quicktime") else { throw SpatialSceneError.changed }
        }
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

    static func sequenceSampleHasExpectedPresentation(_ sample: CMSampleBuffer, index: Int, clock: SequenceClock) -> Bool {
        guard (0..<clock.count).contains(index) else { return false }
        let presentation = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetOutputDuration(sample)
        return presentation.isNumeric && duration.isNumeric
            && CMTimeCompare(presentation, clock.presentation(index)) == 0
            && CMTimeCompare(duration, clock.sampleDuration(index)) == 0
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

    private static func sequenceFileDigest(_ url: URL, scope: BpyMediaReadScope) throws -> (sha256: String, byteCount: Int) {
        try scope.withConsumer { work in
        let activity = BpyObservedActivity(options: .userInitiated, reason: "Verify a 3D movie", parent: work.id)
        defer { activity.end() }
        func check() throws { try scope.check(); try work.check() }
        try check()
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw SpatialSceneError.changed }
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SpatialSceneError.changed }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size > 0 else { throw SpatialSceneError.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var digest = SHA256(), count = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try check()
            digest.update(data: data)
            count += data.count
        }
        guard fstat(fd, &after) == 0, before.st_size == count, before.st_size == after.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SpatialSceneError.changed }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
        }
    }

    private static func sequenceImage(_ index: Int, request: SpatialClayRequest, files: [String: URL],
                                      readFile: (URL) throws -> BpyRuntimeFile, checking: () throws -> Void) throws -> CGImage {
        guard let url = files[String(format: "clay-%08d.png", request.startFrame + index)] else { throw SpatialSceneError.changed }
        let file = try readFile(url)
        defer { file.release() }
        return try decodePNG(file.verifiedData(maximum: BpyRuntimeLimits.maximumOutputBytes, checking: checking), width: request.width, height: request.height)
    }

    private static func encodeSequenceMovie(request: SpatialClayRequest, clock: SequenceClock, files: [String: URL],
                                            media: BpySequenceRetention.Encoding, retention: BpySequenceRetention,
                                            cancellation: BpyOperationCancellation,
                                            isCancelled: @escaping @Sendable () -> Bool) async throws {
        let work = try BpyMemoryCoordinator.shared.beginConsumer(owner: media.workOwner, cancellation: cancellation)
        defer { work.release() }
        let writer = try AVAssetWriter(outputURL: media.url, fileType: .mov)
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
        let lifetime = try BpyMediaWriter(writer: writer, pin: media.retainForIO(), cancellation: cancellation, work: work)
        defer { lifetime.requestCancel() }
        do {
        guard try lifetime.perform({ writer.startWriting() }) else { throw writer.error ?? SpatialSceneError.changed }
        try lifetime.perform { writer.startSession(atSourceTime: .zero) }
        for index in 0..<clock.count {
            try media.checkSize()
            let deadline = try BpyRuntimeClock.awakeSeconds() + 30
            while !input.isReadyForMoreMediaData {
                try work.check()
                guard !isCancelled() else { throw CancellationError() }
                guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw SpatialSceneError.invalid("The Clay sequence encoder stopped responding.") }
                guard writer.status == .writing else { throw writer.error ?? SpatialSceneError.changed }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard !isCancelled() else { throw CancellationError() }
            try BpyMediaDecode.withPixels(width: request.width, height: request.height,
                encodedBytes: BpyRuntimeLimits.maximumOutputBytes, owner: media.workOwner, cancellation: cancellation,
                checking: { if isCancelled() { throw CancellationError() } }) {
                let image = try sequenceImage(index, request: request, files: files, readFile: { try retention.file(at: $0) }, checking: {
                    try cancellation.check(); try work.check()
                    if isCancelled() { throw CancellationError() }
                })
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
                    sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample,
                    try lifetime.perform({ input.append(sample) }) else {
                    throw writer.error ?? SpatialSceneError.invalid("The Clay sequence frame could not be written.")
                }
            }
        }
        try lifetime.perform { writer.endSession(atSourceTime: clock.duration); input.markAsFinished() }
        try await lifetime.finish(deadline: BpyRuntimeClock.awakeSeconds() + 30,
            checking: { if isCancelled() { throw CancellationError() } })
        try work.check()
        guard writer.status == .completed, !isCancelled() else { throw writer.error ?? CancellationError() }
        try media.checkSize(planningFrame: false)
        } catch {
            try await lifetime.cancelAndWait()
            try work.rethrowAfterCleanup(error)
        }
    }

    static func verifySequenceMovie(_ candidate: SpatialClaySequenceCandidate,
                                    cancellation: BpyOperationCancellation,
                                    isCancelled: @escaping @Sendable () -> Bool) async throws {
        let task = Task.detached {
            try await verifySequenceMovieOffMain(candidate, cancellation: cancellation, isCancelled: isCancelled)
        }
        let registration = cancellation.observe { task.cancel() }
        defer { withExtendedLifetime(registration) {} }
        try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel(); task.cancel() }
    }

    private static func recordSequenceTimingFailure(_ sample: CMSampleBuffer?, index: Int, clock: SequenceClock,
                                                    candidate: SpatialClaySequenceCandidate, reader: AVAssetReader) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let directory = environment["NGV_BPY_COMMAND_EVIDENCE"], !directory.isEmpty else { return }
        func time(_ value: CMTime) -> [String: Any] {
            ["value": value.value, "timescale": value.timescale, "flags": value.flags.rawValue, "epoch": value.epoch]
        }
        var actual: [String: Any] = ["present": false]
        if let sample {
            actual = ["present": true, "sampleCount": CMSampleBufferGetNumSamples(sample),
                "rawPresentation": time(CMSampleBufferGetPresentationTimeStamp(sample)),
                "rawDuration": time(CMSampleBufferGetDuration(sample)),
                "outputPresentation": time(CMSampleBufferGetOutputPresentationTimeStamp(sample)),
                "outputDuration": time(CMSampleBufferGetOutputDuration(sample))]
            let image = CMSampleBufferGetImageBuffer(sample)
            actual["imagePresent"] = image != nil
            if let image { actual["width"] = CVPixelBufferGetWidth(image); actual["height"] = CVPixelBufferGetHeight(image) }
        }
        let error = reader.error as NSError?
        let record: [String: Any] = ["schema": "nexgenvideo/clay-movie-timing-failure/1", "partialDiagnosticOnly": true,
            "candidateID": candidate.proof.id.uuidString, "frameIndex": index, "frameCount": clock.count,
            "expectedPresentation": time(clock.presentation(index)), "expectedDuration": time(clock.sampleDuration(index)),
            "actual": actual, "readerStatus": reader.status.rawValue,
            "readerErrorDomain": error?.domain ?? "", "readerErrorCode": error?.code ?? 0]
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("clay-movie-timing-failure-\(candidate.proof.id.uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func verifySequenceMovieOffMain(_ candidate: SpatialClaySequenceCandidate,
        cancellation: BpyOperationCancellation, isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let work = try BpyMemoryCoordinator.shared.beginConsumer(owner: candidate.workOwner, cancellation: cancellation)
        defer { work.release() }
        let borrowed = try candidate.borrowFiles()
        var transferred = false
        defer { if !transferred { for file in borrowed { file.release() } } }
        let proof = candidate.proof
        let clock = try sequenceClock(proof.timing, numerator: proof.timebaseNumerator,
                                      denominator: proof.timebaseDenominator, count: proof.state.frames.count)
        guard candidate.isAvailable, let movie = candidate.files["clay.mov"] else { throw SpatialSceneError.changed }
        let asset = AVURLAsset(url: movie)
        transferred = true
        let reading = try BpyMediaReader.begin(asset: asset, files: borrowed, cancellation: cancellation, work: work)
        var complete = false
        defer { reading.endBody(success: complete) }
        do {
        let byURL = Dictionary(uniqueKeysWithValues: borrowed.map { ($0.url, $0) })
        try reading.check()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try reading.progress()
        guard tracks.count == 1, let track = tracks.first else { throw SpatialSceneError.changed }
        let size = try await track.load(.naturalSize)
        try reading.progress()
        let duration = try await asset.load(.duration)
        try reading.progress()
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
        try reading.start(reader)
        for index in 0..<clock.count {
            guard !Task.isCancelled, !isCancelled(), candidate.isAvailable else { throw CancellationError() }
            try BpyMediaDecode.withPixels(width: proof.request.width, height: proof.request.height,
                encodedBytes: BpyRuntimeLimits.maximumOutputBytes, owner: candidate.workOwner, cancellation: cancellation,
                checking: { try reading.check(); if isCancelled() { throw CancellationError() } }) {
                let sample = output.copyNextSampleBuffer()
                let image = sample.flatMap { CMSampleBufferGetImageBuffer($0) }
                guard let sample, let image, sequenceSampleHasExpectedPresentation(sample, index: index, clock: clock) else {
                    recordSequenceTimingFailure(sample, index: index, clock: clock, candidate: candidate, reader: reader)
                    throw SpatialSceneError.invalid("The complete Clay movie lost a frame or changed its exact timing.")
                }
                try verifyMovieFrame(image, expected: sequenceImage(index, request: proof.request, files: candidate.files, readFile: {
                    guard let file = byURL[$0] else { throw SpatialSceneError.changed }
                    return try file.retained()
                }, checking: { try cancellation.check(); try reading.check() }))
            }
            try reading.progress()
        }
        guard output.copyNextSampleBuffer() == nil, reader.status == .completed else {
            throw SpatialSceneError.invalid("The complete Clay movie has unexpected frames.")
        }
        try reading.check()
        complete = true
        } catch {
            try reading.check()
            throw error
        }
    }
}
