import AppKit
import AVFoundation
import NexGenEngine

@MainActor
enum MusicvideoDeliveryAcceptance {
    static func run(editor: EditorViewModel, outputDirectory: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested,
              let home = editor.workingRoot,
              let root = DataRootResolver.dataRoot(of: home),
              let owner = editor.openWorkingCopyKey,
              let songID = editor.mediaManifest.songAnchorAssetId,
              let songURL = editor.mediaResolver.resolveURL(for: songID),
              let assembly = try PipelineAssemblyStore.load(dataRoot: root),
              assembly.policy.timing == .musicSync else {
            throw ToolError("Musicvideo delivery requires a real assembled musicvideo project and song.")
        }
        let songDuration = try await AVURLAsset(url: songURL).load(.duration)
        guard songDuration.isNumeric, songDuration.seconds > 0, editor.timeline.fps > 0 else {
            throw ToolError("The source song duration and timeline frame rate must be finite and positive.")
        }
        let expectedFrames = Int((songDuration.seconds * Double(editor.timeline.fps)).rounded())
        guard expectedFrames > 0,
              abs(editor.timeline.totalFrames - expectedFrames) <= 1,
              assembly.policy.requiredDurationFrames == editor.timeline.totalFrames,
              assembly.plan.selectedMedia.count >= 2,
              assembly.manifest.timelineFingerprint == (try PipelineAssemblyStore.fingerprint(timeline: editor.timeline)),
              let style = try await TimelineStyleReview.capture(timeline: editor.timeline, resolver: editor.mediaResolver.snapshot()) else {
            throw ToolError("The complete song, assembled shots and production style must be present before delivery acceptance.")
        }
        try TimelineStyleReview.requireCurrent(style)
        _ = try PipelineSequenceReviewStore.requireCurrent(dataRoot: root, timeline: editor.timeline, resolver: editor.mediaResolver)
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && WorkspaceUIAcceptance.probeState(identifier: "export.start", in: $0) == true
        }), WorkspaceUIAcceptance.probeState(identifier: "export.require-sequence", in: window) == true else {
            throw ToolError("The native Export sheet must be open with sequence review required.")
        }
        let scale = Int(((Double(ProcessInfo.processInfo.environment["NGV_WORKSPACE_UI_SCALE"] ?? "1") ?? 1) * 100).rounded())
        let filename = "scale-\(scale)-musicvideo.mp4"
        let destination = outputDirectory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError("The acceptance export destination must be new.")
        }
        let oldJobs = Set(ExportQueue.shared.jobs(ownerKey: owner).map(\.id))
        window.makeKeyAndOrderFront(nil)
        if let failure = WorkspaceUIAcceptance.click(identifier: "export.start", in: window) {
            throw ToolError("Native Export action failed: \(failure)")
        }
        guard await waitUntil(seconds: 5, {
            NSApp.windows.contains { ($0 as? NSSavePanel)?.isVisible == true }
        }), let panel = NSApp.windows.compactMap({ $0 as? NSSavePanel }).first(where: \.isVisible) else {
            throw ToolError("The Export action did not open a native save panel.")
        }
        panel.directoryURL = outputDirectory
        panel.nameFieldStringValue = filename
        panel.makeKeyAndOrderFront(nil)
        guard await waitUntil(seconds: 5, {
            panel.url?.standardizedFileURL == destination.standardizedFileURL
        }) else { throw ToolError("The native save panel did not accept the export destination.") }
        panel.ok(nil)
        guard await waitUntil(seconds: 10, {
            ExportQueue.shared.jobs(ownerKey: owner).contains { !oldJobs.contains($0.id) }
        }), let job = ExportQueue.shared.jobs(ownerKey: owner).first(where: { !oldJobs.contains($0.id) }) else {
            throw ToolError("The native save action did not enqueue a delivery.")
        }
        guard await waitUntil(seconds: min(300, max(60, songDuration.seconds * 2)), { job.status.isTerminal }) else {
            ExportQueue.shared.cancel(jobID: job.id)
            _ = await ExportQueue.shared.waitForCompletion(jobID: job.id)
            throw ToolError("The native musicvideo export did not finish within its acceptance deadline.")
        }
        guard job.status == .completed, job.canReveal,
              job.destinationURL?.standardizedFileURL == destination.standardizedFileURL else {
            throw ToolError(job.failure ?? "The native delivery did not complete at its chosen destination.")
        }
        let attempt = try PipelineDeliveryStore.loadAttempt(id: job.id, dataRoot: root)
        guard attempt.status == .succeeded, attempt.probeQC?.passed == true,
              (attempt.probeQC?.audioChannels ?? 0) > 0,
              attempt.sequenceReviewSHA256 != nil,
              attempt.spec.requirements.contains(where: { $0.id == "core.sequence-review" && $0.required }),
              attempt.outputSHA256 == (try FileDigest.sha256(of: destination)) else {
            throw ToolError("The completed movie lacks its bound review, output hash or audiovisual delivery QC.")
        }
        let media = try await verifyMovie(
            at: destination, songURL: songURL, songDuration: songDuration.seconds,
            fps: editor.timeline.fps, assembly: assembly.plan, dataRoot: root
        )
        let receiptName = "scale-\(scale)-musicvideo-delivery.json"
        try PipelineAssemblyStore.canonical(attempt).write(
            to: outputDirectory.appendingPathComponent(receiptName), options: .atomic
        )
        return [
            "nativeExportSubmitted": true,
            "exportCompleted": true,
            "sequenceReviewBound": true,
            "styleReviewBound": true,
            "fullSongDuration": true,
            "outputSHA256": attempt.outputSHA256 ?? "",
            "movie": filename,
            "deliveryReceipt": receiptName,
            "expectedDurationFrames": expectedFrames,
            "shotIDs": assembly.plan.placements.map(\.shotID),
            "verifiedShotImages": media.shots,
            "verifiedMovingShots": media.shots,
            "verifiedFrames": media.frames,
            "decodedAudioSamples": media.audioSamples,
            "decodedAudioRMS": media.audioRMS,
            "decodedAudioCorrelation": media.audioCorrelation,
        ]
    }

    private static func verifyMovie(
        at url: URL, songURL: URL, songDuration: Double, fps: Int,
        assembly: AssemblyPlanV1, dataRoot: URL
    ) async throws -> (shots: Int, frames: Int, audioSamples: Int, audioRMS: Double, audioCorrelation: Double) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard abs(duration.seconds - songDuration) <= 1 / Double(fps),
              try await asset.load(.isPlayable) else {
            throw ToolError("The exported film is not playable for the full song with audio.")
        }
        let outputFrames = AVAssetImageGenerator(asset: asset)
        outputFrames.appliesPreferredTrackTransform = true
        outputFrames.requestedTimeToleranceBefore = .zero
        outputFrames.requestedTimeToleranceAfter = .zero
        let sources = Dictionary(uniqueKeysWithValues: assembly.selectedMedia.map { ($0.shotID, $0) })
        var verifiedFrames = 0
        for placement in assembly.placements {
            guard let source = sources[placement.shotID] else { throw ToolError("An assembled shot has no selected source.") }
            let sourceURL = try ProjectLocalFile.requireHash(source.sourceSHA256, at: source.sourcePath, dataRoot: dataRoot)
            let sourceFrames = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
            sourceFrames.appliesPreferredTrackTransform = true
            sourceFrames.requestedTimeToleranceBefore = .zero
            sourceFrames.requestedTimeToleranceAfter = .zero
            let length = placement.sourceEndFrame - placement.sourceStartFrame
            let offsets = Array(Set([length / 5, length / 2, length * 4 / 5])).sorted()
            guard offsets.count >= 2 else { throw ToolError("The acceptance shot must contain multiple video frames.") }
            var actualImages: [[Double]] = []
            var expectedImages: [[Double]] = []
            for offset in offsets {
                let outputTime = CMTime(value: Int64(placement.timelineStartFrame + offset), timescale: Int32(fps))
                let sourceTime = CMTime(value: Int64(placement.sourceStartFrame + offset), timescale: Int32(source.sourceFPS))
                let actual = try spatialRGB(try await outputFrames.image(at: outputTime).image)
                let expected = try spatialRGB(try await sourceFrames.image(at: sourceTime).image)
                guard imageDifference(actual, expected) < 0.01,
                      zip(actual, expected).allSatisfy({ abs($0.0 - $0.1) < 0.25 }),
                      (expected.max() ?? 0) > 0.05 else {
                    throw ToolError("The exported image does not match selected shot \(placement.shotID).")
                }
                actualImages.append(actual)
                expectedImages.append(expected)
                verifiedFrames += 1
            }
            var expectedMotion = 0.0
            var actualMotion = 0.0
            for first in 0..<(offsets.count - 1) {
                for second in (first + 1)..<offsets.count {
                    let motion = imageDifference(expectedImages[first], expectedImages[second])
                    if motion > expectedMotion {
                        expectedMotion = motion
                        actualMotion = imageDifference(actualImages[first], actualImages[second])
                    }
                }
            }
            guard expectedMotion > 0.0005, actualMotion >= expectedMotion * 0.7 else {
                throw ToolError("The exported shot \(placement.shotID) does not preserve its source movement.")
            }
        }
        let soundtrack = try await decodedSignal(asset: asset)
        let original = try await decodedSignal(asset: AVURLAsset(url: songURL))
        let correlation = audioCorrelation(soundtrack.values, original.values)
        guard soundtrack.rms > 0.001, original.rms > 0.001,
              abs(Double(soundtrack.samples) / 48_000 - songDuration) <= 0.1,
              abs(soundtrack.rms / original.rms - 1) < 0.05, correlation >= 0.98 else {
            throw ToolError("The exported soundtrack is silent, truncated or differs from the original song.")
        }
        return (assembly.placements.count, verifiedFrames, soundtrack.samples, soundtrack.rms, correlation)
    }

    private static func decodedSignal(asset: AVURLAsset) async throws -> (samples: Int, rms: Double, values: [Float]) {
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ToolError("The soundtrack has no audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw ToolError("The exported soundtrack cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw ToolError("The exported soundtrack decoder did not start.") }
        var samples = 0
        var sumSquares = 0.0
        var values: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            guard bytes.count.isMultiple(of: 2),
                  CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr else {
                reader.cancelReading()
                throw ToolError("The exported soundtrack has unreadable PCM samples.")
            }
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let sample = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                let value = Double(sample) / 32768
                sumSquares += value * value
                values.append(Float(value))
                samples += 1
            }
        }
        let rms = sqrt(sumSquares / Double(max(1, samples)))
        guard reader.status == .completed, samples > 0 else {
            throw ToolError("The soundtrack is truncated or undecodable.")
        }
        return (samples, rms, values)
    }

    private static func audioCorrelation(_ actual: [Float], _ expected: [Float]) -> Double {
        let margin = 1_536
        let end = min(actual.count, expected.count) - margin
        guard end > margin else { return 0 }
        let step = max(1, (end - margin) / 4_096)
        var best = 0.0
        for lag in -margin...margin {
            var product = 0.0
            var actualEnergy = 0.0
            var expectedEnergy = 0.0
            for index in stride(from: margin, to: end, by: step) {
                let a = Double(actual[index])
                let e = Double(expected[index + lag])
                product += a * e
                actualEnergy += a * a
                expectedEnergy += e * e
            }
            let denominator = sqrt(actualEnergy * expectedEnergy)
            if denominator > 0 { best = max(best, product / denominator) }
        }
        return best
    }

    private static func imageDifference(_ first: [Double], _ second: [Double]) -> Double {
        zip(first, second).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(max(1, first.count))
    }

    private static func spatialRGB(_ image: CGImage) throws -> [Double] {
        let width = 32
        let height = 18
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { throw ToolError("The movie frame could not be decoded for comparison.") }
        return bytes.enumerated().compactMap { index, value in index % 4 != 3 ? Double(value) / 255 : nil }
    }

    private static func waitUntil(seconds: Double, _ predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if predicate() { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return predicate()
    }
}
