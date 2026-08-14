import AVFoundation
import Foundation
import MusicUnderstanding
import NexGenEngine

struct AppleMusicUnderstandingAnalyzer: MusicUnderstandingAnalyzing {
    private static let timeoutS = 300.0

    enum AnalysisError: LocalizedError {
        case timedOut
        case unavailable

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Music Understanding did not finish within "
                    + "\(Int(AppleMusicUnderstandingAnalyzer.timeoutS)) seconds."
            case .unavailable:
                return "Music Understanding requires macOS 27 or newer."
            }
        }
    }

    func analyze(_ audio: URL) throws -> MusicUnderstandingMeasurement {
        guard #available(macOS 27.0, *) else { throw AnalysisError.unavailable }
        return try analyzeOnMacOS27(audio)
    }

    @available(macOS 27.0, *)
    private func analyzeOnMacOS27(_ audio: URL) throws -> MusicUnderstandingMeasurement {
        let completion = AnalysisCompletion()
        let task = Task.detached(priority: .userInitiated) {
            do {
                let asset = AVURLAsset(
                    url: audio,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                )
                let session = try await MusicUnderstandingSession(asset: asset)
                let result = try await session.analyze(for: [.rhythm, .structure])
                let rhythm = result.rhythm
                let structure = result.structure
                completion.finish(
                    .success(
                        MusicUnderstandingMeasurement(
                            beats: rhythm?.beats.compactMap(Self.seconds) ?? [],
                            bars: rhythm?.bars.compactMap(Self.seconds) ?? [],
                            bpm: rhythm?.beatsPerMinute.map { Double($0) },
                            sections: structure?.sections.compactMap(Self.range) ?? [],
                            segments: structure?.segments.compactMap(Self.range) ?? [],
                            phrases: structure?.phrases.compactMap(Self.range) ?? []
                        )
                    )
                )
            } catch {
                completion.finish(.failure(error))
            }
        }
        guard completion.wait(timeoutS: Self.timeoutS) else {
            task.cancel()
            throw AnalysisError.timedOut
        }
        return try completion.result().get()
    }

    private static func seconds(_ time: CMTime) -> Double? {
        let value = time.seconds
        return value.isFinite && value >= 0 ? rounded(value) : nil
    }

    private static func range(_ value: CMTimeRange) -> MeasuredMusicRange? {
        let start = value.start.seconds
        let end = value.end.seconds
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return MeasuredMusicRange(start: rounded(start), end: rounded(end))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}

private final class AnalysisCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var stored: Result<MusicUnderstandingMeasurement, any Error>?

    func finish(_ result: Result<MusicUnderstandingMeasurement, any Error>) {
        lock.lock()
        guard stored == nil else {
            lock.unlock()
            return
        }
        stored = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeoutS: Double) -> Bool {
        semaphore.wait(timeout: .now() + timeoutS) == .success
    }

    func result() -> Result<MusicUnderstandingMeasurement, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? .failure(AppleMusicUnderstandingAnalyzer.AnalysisError.timedOut)
    }
}
