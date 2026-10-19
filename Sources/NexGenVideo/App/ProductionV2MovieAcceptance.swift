import AVFoundation
import NexGenEngine

enum ProductionV2MovieAcceptance {
    static func verify(output: URL, proof: ProductionPlanAssemblyProofV1, review: ProductionSequenceReviewV2,
                       dataRoot: URL, timeline: Timeline, resolver: MediaResolver, mirroredClipID: String? = nil) async throws -> [String: Any] {
        let result = try await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration)
            let edl = try PlanningWriterIO.read(ProductionSequenceEDLV2.self, at: review.edl.path, dataRoot: dataRoot)
            let fps = edl.timebase.framesPerSecond
            let outputStart = edl.timebase.seconds(for: edl.outputStartTicks)
            let seconds = edl.timebase.seconds(for: edl.outputDurationTicks)
            guard try await asset.load(.isPlayable), abs(duration.seconds - seconds) <= 1 / fps,
                  timeline.width * 9 == timeline.height * 16 else { throw failed("The final movie is unplayable, truncated or has a different canvas.") }
            let images = generator(asset)
            var verifiedFrames = 0
            var mirroredFrames = 0, asymmetricFrames = 0
            var minimumOriginalDifference = 1.0
            if let mirroredClipID {
                guard proof.placements.filter({ $0.clipID == mirroredClipID }).count == 1,
                      timeline.tracks.flatMap(\.clips).first(where: { $0.id == mirroredClipID })?.transform.flipHorizontal == true else {
                    throw failed("The independently compared mirror is not the retained native clip transform.")
                }
            }
            for placement in proof.placements {
                guard placement.sourceKind == .video, placement.motion == nil else {
                    throw failed("This source-comparison fixture requires moving video shots without a still-image motion transform.")
                }
                let source = try ProjectLocalFile.requireHash(placement.output.sha256, at: placement.output.path, dataRoot: dataRoot)
                let sourceImages = generator(AVURLAsset(url: source))
                let start = proof.timebase.seconds(for: placement.startTicks) - outputStart
                let length = proof.timebase.seconds(for: placement.durationTicks)
                let sourceStart = Double(placement.sourceInTicks) / Double(placement.sourceTimebase?.ticksPerSecond ?? proof.timebase.ticksPerSecond)
                var actual: [[Double]] = [], expected: [[Double]] = []
                for part in [0.2, 0.5, 0.8] {
                    let offset = floor(length * fps * part) / fps
                    guard start + offset >= 0, start + offset < seconds else { throw failed("A planned picture sample lies outside the delivered film.") }
                    let a = try rgb(try await images.image(at: CMTime(seconds: start + offset, preferredTimescale: 60_000)).image)
                    let original = try rgb(try await sourceImages.image(at: CMTime(seconds: sourceStart + offset, preferredTimescale: 60_000)).image)
                    let mirrored = placement.clipID == mirroredClipID
                    let e = mirrored ? horizontalMirror(original) : original
                    guard difference(a, e) < 0.01, zip(a, e).allSatisfy({ abs($0.0 - $0.1) < 0.25 }), (e.max() ?? 0) > 0.05 else {
                        throw failed("The exported picture differs from selected source \(placement.shotID) at \(sourceStart + offset) s.")
                    }
                    if mirrored {
                        mirroredFrames += 1
                        if difference(original, e) > 0.03 {
                            let originalDifference = difference(a, original)
                            guard originalDifference > 0.02 else {
                                throw failed("The exported picture retained the original orientation instead of the native finishing transform.")
                            }
                            asymmetricFrames += 1
                            minimumOriginalDifference = min(minimumOriginalDifference, originalDifference)
                        }
                    }
                    actual.append(a); expected.append(e); verifiedFrames += 1
                }
                var strongest = 0.0, actualMotion = 0.0
                for a in 0..<expected.count {
                    for b in (a + 1)..<expected.count {
                        let motion = difference(expected[a], expected[b])
                        if motion > strongest { strongest = motion; actualMotion = difference(actual[a], actual[b]) }
                    }
                }
                guard strongest > 0.005, actualMotion > strongest * 0.5 else {
                    throw failed("The exported shot lost the actual movement of selected source \(placement.shotID).")
                }
            }
            guard mirroredClipID == nil || (mirroredFrames == 3 && asymmetricFrames > 0) else {
                throw failed("The selected source does not visibly distinguish its mirrored and original orientations.")
            }
            let actual = try await pcm(asset)
            let count = Int((seconds * 48_000).rounded())
            var expected = [Float](repeating: 0, count: count)
            var audioClips = 0
            for track in timeline.tracks where track.type == .audio && !track.muted {
                for clip in track.clips {
                    guard clip.speed == 1, clip.volumeTrack == nil, clip.fadeInFrames == 0, clip.fadeOutFrames == 0,
                          let url = resolver.resolveURL(for: clip.mediaRef) else { throw failed("The comparison soundtrack has unsupported timing or missing source bytes.") }
                    let source = try await pcm(AVURLAsset(url: url))
                    let start = Double(clip.startFrame) / Double(timeline.fps) - outputStart
                    let first = Int((start * 48_000).rounded())
                    let sourceFirst = Int((Double(clip.trimStartFrame) / Double(timeline.fps) * 48_000).rounded())
                    let length = Int((Double(clip.durationFrames) / Double(timeline.fps) * 48_000).rounded())
                    let lower = max(0, -first), upper = min(length, count - first)
                    guard lower < upper, sourceFirst >= 0, sourceFirst + upper <= source.count else {
                        throw failed("The chosen soundtrack does not cover its exact edited range.")
                    }
                    for index in lower..<upper { expected[first + index] += source[sourceFirst + index] * Float(clip.volume) }
                    audioClips += 1
                }
            }
            let actualRMS = rms(actual), expectedRMS = rms(expected), correlation = correlation(actual, expected)
            guard audioClips > 0, abs(actual.count - count) <= 4_800, actualRMS > 0.001, expectedRMS > 0.001,
                  abs(actualRMS / expectedRMS - 1) < 0.05, correlation >= 0.98 else {
                throw failed("The exported sound is silent, truncated, shifted or differs from the edited source audio.")
            }
            return (verifiedFrames, audioClips, actual.count, actualRMS, correlation, duration.seconds,
                mirroredFrames, asymmetricFrames, minimumOriginalDifference)
        }.value
        var evidence: [String: Any] = ["verifiedShots": proof.placements.count, "verifiedFrames": result.0,
            "verifiedAudioClips": result.1, "decodedAudioSamples": result.2, "audioRMS": result.3,
            "audioCorrelation": result.4, "decodedDurationSeconds": result.5]
        if let mirroredClipID {
            evidence["mirroredClipID"] = mirroredClipID
            evidence["mirroredFrames"] = result.6
            evidence["asymmetricFrames"] = result.7
            evidence["minimumOriginalDifference"] = result.8
        }
        return evidence
    }

    private static func generator(_ asset: AVAsset) -> AVAssetImageGenerator {
        let result = AVAssetImageGenerator(asset: asset)
        result.appliesPreferredTrackTransform = true
        result.requestedTimeToleranceBefore = .zero; result.requestedTimeToleranceAfter = .zero
        return result
    }

    private static func pcm(_ asset: AVURLAsset) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw failed("An expected soundtrack has no audio track.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw failed("The soundtrack cannot be decoded to PCM.") }
        reader.add(output)
        guard reader.startReading() else { throw failed("The soundtrack decoder did not start.") }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { reader.cancelReading(); throw failed("PCM data is missing.") }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            guard bytes.count.isMultiple(of: 2), CMBlockBufferCopyDataBytes(block, atOffset: 0,
                dataLength: bytes.count, destination: &bytes) == noErr else { reader.cancelReading(); throw failed("PCM bytes are unreadable.") }
            for index in stride(from: 0, to: bytes.count, by: 2) {
                samples.append(Float(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768)
            }
        }
        guard reader.status == .completed, !samples.isEmpty else { throw failed("PCM decoding ended before the soundtrack completed.") }
        return samples
    }

    private static func rms(_ values: [Float]) -> Double {
        sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count)))
    }

    private static func correlation(_ actual: [Float], _ expected: [Float]) -> Double {
        let margin = 1_536, end = min(actual.count, expected.count) - margin
        guard end > margin else { return 0 }
        let step = max(1, (end - margin) / 4_096)
        var best = 0.0
        for lag in -margin...margin {
            var product = 0.0, actualEnergy = 0.0, expectedEnergy = 0.0
            for index in stride(from: margin, to: end, by: step) {
                let a = Double(actual[index]), e = Double(expected[index + lag])
                product += a * e; actualEnergy += a * a; expectedEnergy += e * e
            }
            let denominator = sqrt(actualEnergy * expectedEnergy)
            if denominator > 0 { best = max(best, product / denominator) }
        }
        return best
    }

    private static func rgb(_ image: CGImage) throws -> [Double] {
        let width = 32, height = 18
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { throw failed("A decoded picture could not be compared.") }
        return bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : Double($0.element) / 255 }
    }

    private static func difference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(max(1, a.count))
    }

    private static func horizontalMirror(_ pixels: [Double]) -> [Double] {
        let width = 32, height = 18, channels = 3
        return (0..<height).flatMap { y in
            (0..<width).flatMap { x in
                let index = (y * width + width - 1 - x) * channels
                return Array(pixels[index..<(index + channels)])
            }
        }
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Decoded V2 delivery: " + message) }
}
