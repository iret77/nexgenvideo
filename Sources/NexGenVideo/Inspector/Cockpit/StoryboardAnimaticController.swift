import AVFoundation
import CoreMedia
import NexGenEngine
import Observation

@MainActor @Observable
final class StoryboardAnimaticController {
    private(set) var timing: StoryboardTimingV1?
    private(set) var tick: Int64 = 0
    private(set) var isPlaying = false
    private var configuring = false
    private var preparingPlayback = false
    var isPreparing: Bool { configuring || preparingPlayback }
    private(set) var failure: String?
    var cameraID: String?
    @ObservationIgnored private var timebase: CMTimebase?
    @ObservationIgnored private var audioPlayer: AVPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var configuration = UUID()
    @ObservationIgnored private var startTick: Int64 = 0
    @ObservationIgnored private var audioStartHost: CMTime?

    var endTick: Int64 { (timing?.rangeStartTicks ?? 0) + (timing?.rangeDurationTicks ?? 0) }
    var activeShot: StoryboardTimingV1.PlannedShot? { timing?.activeShot(at: tick, cameraID: cameraID) }
    var activeMoment: StoryboardTimingV1.Moment? {
        activeShot.flatMap { timing?.activeMoment(shotID: $0.id, at: tick) }
    }

    func configure(_ value: StoryboardTimingV1, dataRoot: URL) async {
        stop()
        let token = UUID()
        configuration = token
        timing = nil; audioPlayer = nil; timebase = nil; failure = nil; configuring = true
        defer { if configuration == token { configuring = false } }
        do {
            try value.timebase.validate()
            let end = value.rangeStartTicks.addingReportingOverflow(value.rangeDurationTicks)
            guard value.rangeStartTicks >= 0, value.rangeDurationTicks > 0, !end.overflow else {
                throw ToolError("The Animatic timing is invalid. Review the Storyboard timing.")
            }
            var created: CMTimebase?
            guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created) == noErr, let created else {
                throw ToolError("The Animatic playback clock could not start.")
            }
            var preparedAudio: AVPlayer?
            if let audio = value.audio {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ProjectLocalFile.requireHash(audio.source.sha256, at: audio.source.path, dataRoot: dataRoot)
                }.value
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let expected = CMTime(value: audio.durationTicks, timescale: Int32(value.timebase.ticksPerSecond))
                let tolerance = CMTime(value: 1, timescale: Int32(value.timebase.ticksPerSecond))
                guard !tracks.isEmpty, duration.isNumeric,
                      abs(CMTimeGetSeconds(CMTimeSubtract(duration, expected))) <= CMTimeGetSeconds(tolerance) else {
                    throw ToolError("The Storyboard audio duration no longer matches the source. Refresh its timing before playback.")
                }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.automaticallyWaitsToMinimizeStalling = false
                player.sourceClock = CMClockGetHostTimeClock()
                let audioEnd = end.partialValue.subtractingReportingOverflow(audio.offsetTicks)
                if !audioEnd.overflow, audioEnd.partialValue > 0 {
                    player.currentItem?.forwardPlaybackEndTime = CMTime(value: min(audio.durationTicks, audioEnd.partialValue),
                        timescale: Int32(value.timebase.ticksPerSecond))
                }
                preparedAudio = player
            }
            guard configuration == token, !Task.isCancelled else { return }
            timebase = created; audioPlayer = preparedAudio; timing = value
            tick = value.rangeStartTicks
            cameraID = value.mode == .multicam
                ? (value.shots.contains(where: { $0.cameraID == cameraID }) ? cameraID : value.shots.first?.cameraID) : nil
            CMTimebaseSetTime(created, time: time(tick))
        } catch {
            guard configuration == token, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    func play() async {
        guard !isPlaying, !isPreparing, let timing, let timebase else { return }
        if tick >= endTick { tick = timing.rangeStartTicks }
        let token = UUID()
        operation = token; preparingPlayback = true; failure = nil
        defer { if operation == token { preparingPlayback = false } }
        do {
            var sourceTick: Int64?
            if let audio = timing.audio, let player = audioPlayer {
                let elapsed = tick.subtractingReportingOverflow(audio.offsetTicks)
                guard !elapsed.overflow else { throw ToolError("The audio offset is outside the playback range.") }
                if elapsed.partialValue < audio.durationTicks, audio.offsetTicks < endTick {
                    sourceTick = max(0, elapsed.partialValue)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while player.status == .unknown, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                        guard operation == token else { return }
                    }
                    guard player.status == .readyToPlay else {
                        throw player.error ?? ToolError("The Storyboard audio could not be opened.")
                    }
                    let positioned = await player.seek(to: time(max(0, elapsed.partialValue)), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard operation == token, !Task.isCancelled else { return }
                    guard positioned else { throw ToolError("The Storyboard audio could not seek to this position.") }
                    let timeout = Task {
                        try? await Task.sleep(for: .seconds(10))
                        if !Task.isCancelled { player.cancelPendingPrerolls() }
                    }
                    let ready = await withCheckedContinuation { continuation in
                        player.preroll(atRate: 1) { @Sendable ready in continuation.resume(returning: ready) }
                    }
                    timeout.cancel()
                    guard operation == token, !Task.isCancelled else { return }
                    guard ready else { throw ToolError("The Storyboard audio could not be prepared. Try playback again.") }
                }
            }
            guard operation == token, !Task.isCancelled else { return }
            let hostStart = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 1, timescale: 10))
            startTick = tick
            guard CMTimebaseSetRateAndAnchorTime(timebase, rate: 1, anchorTime: time(tick), immediateSourceTime: hostStart) == noErr else {
                throw ToolError("The Animatic playback clock could not start.")
            }
            if let sourceTick, let audio = timing.audio {
                let delay = max(0, audio.offsetTicks - tick)
                let audioStart = CMTimeAdd(hostStart, time(delay))
                audioStartHost = audioStart
                audioPlayer?.setRate(1, time: time(sourceTick), atHostTime: audioStart)
            } else { audioStartHost = nil }
            isPlaying = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.sampleClock()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        } catch {
            guard operation == token else { return }
            stop(); failure = error.localizedDescription
        }
    }

    func pause() {
        sampleClock(checkAudio: false)
        stop()
    }

    func seek(to newTick: Int64) {
        stop()
        guard let timing, let timebase else { return }
        tick = min(max(newTick, timing.rangeStartTicks), endTick)
        CMTimebaseSetTime(timebase, time: time(tick))
    }

    func stop() {
        operation = UUID()
        ticker?.cancel(); ticker = nil
        if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
        audioPlayer?.cancelPendingPrerolls()
        audioPlayer?.pause()
        audioPlayer?.currentItem?.cancelPendingSeeks()
        audioStartHost = nil; isPlaying = false; preparingPlayback = false
    }

    private func time(_ value: Int64) -> CMTime {
        CMTime(value: value, timescale: Int32(timing?.timebase.ticksPerSecond ?? 1))
    }

    private func sampleClock(checkAudio: Bool = true) {
        guard isPlaying, let timing, let timebase else { return }
        let current = CMTimeConvertScale(CMTimebaseGetTime(timebase), timescale: Int32(timing.timebase.ticksPerSecond), method: .roundTowardZero)
        guard current.isNumeric else { stop(); failure = "The playback clock became unavailable."; return }
        tick = min(endTick, max(startTick, current.value))
        if tick >= endTick { stop(); return }
        let frameTicks = timing.timebase.ticksPerSecond * timing.timebase.fpsDenominator / timing.timebase.fpsNumerator
        if checkAudio, let start = audioStartHost, let player = audioPlayer,
           CMTimeCompare(CMClockGetTime(CMClockGetHostTimeClock()), CMTimeAdd(start, CMTimeMultiply(time(frameTicks), multiplier: 2))) >= 0,
           let audio = timing.audio, let sourceTick = audio.sourceTick(atTimelineTick: tick) {
            let drift = abs(CMTimeGetSeconds(CMTimeSubtract(player.currentTime(), time(sourceTick))))
            if player.status == .failed || player.currentItem?.status == .failed || player.timeControlStatus != .playing
                || !drift.isFinite || drift > timing.timebase.seconds(for: frameTicks) {
                stop(); failure = player.currentItem?.error?.localizedDescription ?? player.error?.localizedDescription
                    ?? "Audio playback lost synchronization. Play again from this position."
            }
        }
    }
}
