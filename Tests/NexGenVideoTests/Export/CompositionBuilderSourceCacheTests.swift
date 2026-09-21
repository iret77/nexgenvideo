import AVFoundation
import Foundation
import os
import Testing
@testable import NexGenVideo

@Suite("CompositionBuilder source cache", .serialized, .timeLimit(.minutes(1)))
struct CompositionBuilderSourceCacheTests {

    @Test func repeatedClipsFromLongSourceLoadOneAssetAndVideoTrack() async throws {
        let sourceURL = try await FixtureVideo.write(
            scenes: [FixtureVideo.Scene(rgb: (32, 96, 160), seconds: 60)],
            fps: 1,
            size: 64
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let clipCount = 240
        let trackCount = 12
        let timeline = makeRepeatedVideoTimeline(
            clipCount: clipCount,
            trackCount: trackCount,
            mediaRef: "long-source"
        )
        let assetCreations = OSAllocatedUnfairLock(initialState: 0)
        let videoTrackLoads = OSAllocatedUnfairLock(initialState: 0)
        let started = ContinuousClock.now

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { _ in sourceURL },
            renderSize: CGSize(width: 320, height: 180),
            makeAsset: { url in
                assetCreations.withLock { $0 += 1 }
                return AVURLAsset(url: url)
            },
            loadTracks: { asset, mediaType in
                if mediaType == .video { videoTrackLoads.withLock { $0 += 1 } }
                return try await asset.loadTracks(withMediaType: mediaType)
            }
        )

        let elapsed = started.duration(to: .now)
        print("SOURCE_CACHE_BENCHMARK clips=\(clipCount) sourceSeconds=60 elapsed=\(elapsed)")
        #expect(assetCreations.withLock { $0 } == 1)
        #expect(videoTrackLoads.withLock { $0 } == 1)
        #expect(result.offlineMediaRefs.isEmpty)
        #expect(result.unprocessableMediaRefs.isEmpty)

        let mappings = result.trackMappings.filter { mapping in
            guard mapping.isVideo, case .timeline = mapping.kind else { return false }
            return true
        }
        #expect(mappings.count == trackCount)
        var insertedClipCount = 0
        for mapping in mappings {
            guard case .timeline(let trackIndex, let clipIDs) = mapping.kind else { continue }
            let clips = timeline.tracks[trackIndex].clips
            let segments = mapping.compositionTrack.segments.filter { !$0.isEmpty }
            insertedClipCount += clipIDs?.count ?? 0
            #expect(segments.count == clips.count)
            for (segment, clip) in zip(segments, clips) {
                let expectedStart = Double(clip.trimStartFrame) / Double(timeline.fps)
                let expectedDuration = Double(clip.durationFrames) / Double(timeline.fps)
                #expect(abs(segment.timeMapping.source.start.seconds - expectedStart) < 0.001)
                #expect(abs(segment.timeMapping.source.duration.seconds - expectedDuration) < 0.001)
                #expect(segment.timeMapping.target.start == CMTime(
                    value: CMTimeValue(clip.startFrame),
                    timescale: CMTimeScale(timeline.fps)
                ))
            }
        }
        #expect(insertedClipCount == clipCount)
    }

    @Test func canonicalAliasesShareVideoAndAudioFailuresWithinEachBuild() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-cache-\(UUID().uuidString).mov")
        let aliasURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-cache-alias-\(UUID().uuidString).mov")
        try Data("unreadable".utf8).write(to: sourceURL)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: aliasURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        let urlsByRef = [
            "video-source": sourceURL,
            "video-alias": aliasURL,
            "audio-source": sourceURL,
            "audio-alias": aliasURL,
        ]
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "v1", mediaRef: "video-source", start: 0, duration: 6),
                Fixtures.clip(id: "v2", mediaRef: "video-alias", start: 6, duration: 6),
            ]),
            Fixtures.audioTrack(clips: [
                Fixtures.clip(id: "a1", mediaRef: "audio-source", mediaType: .audio, start: 0, duration: 6),
                Fixtures.clip(id: "a2", mediaRef: "audio-alias", mediaType: .audio, start: 6, duration: 6),
            ]),
        ])
        let assetCreations = OSAllocatedUnfairLock(initialState: 0)
        let trackLoads = OSAllocatedUnfairLock(initialState: [String: Int]())

        func build() async throws -> CompositionResult {
            try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { urlsByRef[$0] },
                renderSize: CGSize(width: 320, height: 180),
                makeAsset: { url in
                    assetCreations.withLock { $0 += 1 }
                    return AVURLAsset(url: url)
                },
                loadTracks: { _, mediaType in
                    trackLoads.withLock { $0[mediaType.rawValue, default: 0] += 1 }
                    throw ExpectedLoadFailure()
                }
            )
        }

        let first = try await build()
        #expect(first.offlineMediaRefs == Set(urlsByRef.keys))
        #expect(assetCreations.withLock { $0 } == 1)
        #expect(trackLoads.withLock { $0[AVMediaType.video.rawValue] } == 1)
        #expect(trackLoads.withLock { $0[AVMediaType.audio.rawValue] } == 1)

        let second = try await build()
        #expect(second.offlineMediaRefs == Set(urlsByRef.keys))
        #expect(assetCreations.withLock { $0 } == 2)
        #expect(trackLoads.withLock { $0[AVMediaType.video.rawValue] } == 2)
        #expect(trackLoads.withLock { $0[AVMediaType.audio.rawValue] } == 2)
    }

    private func makeRepeatedVideoTimeline(
        clipCount: Int,
        trackCount: Int,
        mediaRef: String
    ) -> Timeline {
        let clipsPerTrack = clipCount / trackCount
        var globalIndex = 0
        let tracks = (0..<trackCount).map { trackIndex in
            let clips = (0..<clipsPerTrack).map { localIndex in
                defer { globalIndex += 1 }
                return Fixtures.clip(
                    id: "clip-\(globalIndex)",
                    mediaRef: mediaRef,
                    start: localIndex * 6,
                    duration: 6,
                    trimStart: (globalIndex % 50) * 30
                )
            }
            return Fixtures.videoTrack(id: "track-\(trackIndex)", clips: clips)
        }
        return Fixtures.timeline(fps: 30, tracks: tracks)
    }

    private struct ExpectedLoadFailure: Error {}
}
