import AVFoundation
import NexGenEngine
import Observation

@MainActor @Observable
final class PlaybackRangeAudioController {
    private(set) var preparing = false
    private(set) var playing = false
    private(set) var positionTicks: Int64 = 0
    private(set) var failure: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()

    func play(audio: CanonicalArtifactReferenceV1, timebase: RationalTimebaseV1,
              startTicks: Int64, endTicks: Int64, dataRoot: URL) async {
        stop()
        let token = UUID()
        operation = token; preparing = true; failure = nil; positionTicks = startTicks
        defer { if operation == token { preparing = false } }
        do {
            try timebase.validate()
            guard startTicks >= 0, endTicks > startTicks else { throw ToolError("Choose a non-empty range to preview.") }
            let url = try await Task.detached(priority: .userInitiated) {
                try ProjectLocalFile.requireHash(audio.sha256, at: audio.path, dataRoot: dataRoot)
            }.value
            guard operation == token, !Task.isCancelled else { return }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let scale = Int32(timebase.ticksPerSecond)
            let end = CMTime(value: endTicks, timescale: scale)
            guard duration.isNumeric, !tracks.isEmpty, CMTimeCompare(duration, end) >= 0 else {
                throw ToolError("The selected audio cannot play this range. Reload the source.")
            }
            guard operation == token, !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: asset)
            item.forwardPlaybackEndTime = end
            let prepared = AVPlayer(playerItem: item)
            player = prepared
            let deadline = ContinuousClock.now + .seconds(10)
            while prepared.status == .unknown, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                guard operation == token else { return }
            }
            guard prepared.status == .readyToPlay else {
                throw prepared.error ?? ToolError("The track could not be opened for preview.")
            }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { item.cancelPendingSeeks() }
            }
            let positioned = await prepared.seek(to: CMTime(value: startTicks, timescale: scale),
                toleranceBefore: .zero, toleranceAfter: .zero)
            timeout.cancel()
            guard operation == token, !Task.isCancelled else { return }
            guard positioned else { throw ToolError("The track could not seek to the selected start.") }
            preparing = false; playing = true
            prepared.play()
            monitor = Task { [weak self] in
                var lastProgress = ContinuousClock.now
                var previous = startTicks
                while !Task.isCancelled {
                    guard let self, self.operation == token else { return }
                    let time = CMTimeConvertScale(prepared.currentTime(), timescale: scale, method: .roundTowardZero)
                    if prepared.status == .failed || item.status == .failed {
                        self.stop(); self.failure = item.error?.localizedDescription ?? prepared.error?.localizedDescription
                            ?? "Track preview stopped. Try again."; return
                    }
                    if time.isNumeric {
                        self.positionTicks = min(endTicks, max(startTicks, time.value))
                        if time.value >= endTicks { self.stop(); return }
                        if time.value > previous { previous = time.value; lastProgress = .now }
                    }
                    if ContinuousClock.now - lastProgress > .seconds(10) {
                        self.stop(); self.failure = "Track preview stopped making progress. Try again."; return
                    }
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        } catch {
            guard operation == token else { return }
            stop()
            if !(error is CancellationError) { failure = error.localizedDescription }
        }
    }

    func stop() {
        operation = UUID()
        monitor?.cancel(); monitor = nil
        player?.pause(); player?.currentItem?.cancelPendingSeeks(); player = nil
        preparing = false; playing = false
    }
}
