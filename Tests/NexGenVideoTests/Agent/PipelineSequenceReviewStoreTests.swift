import AVFoundation
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Pipeline sequence review")
@MainActor
struct PipelineSequenceReviewStoreTests {
    @Test func findingNavigationRejectsChangedCutAndSourceWithoutRebuildingReel() async throws {
        let fixture = try await makeFixture(withGap: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let reel = try await ReviewReelBuilder.build(plan: fixture.plan, dataRoot: fixture.dataRoot)
        let fingerprints = try PipelineSequenceReviewStore.productionFingerprints(selectedMedia: fixture.plan.selectedMedia,
            dataRoot: fixture.dataRoot)
        let snapshot = PipelineSequenceReviewStore.Snapshot(home: fixture.home, projectID: fixture.plan.projectID,
            plan: fixture.plan, reel: reel, executionPlanSHA256: fingerprints.execution,
            canonSHA256: fingerprints.canon, referencePlanSHA256: fingerprints.references)
        let finding = SequenceReviewFindingV1(id: "opening", scope: .wholePlayback, category: .visualArtifact,
            severity: .warning, shotIDs: ["shot-001"], startFrame: 1, endFrame: 10, evidence: "Inspect the opening.",
            recommendedAction: .localRepair, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { fixture.home })
        let target = try PipelineSequenceReviewStore.findingTarget(finding, snapshot: snapshot, dataRoot: fixture.dataRoot,
            timeline: fixture.timeline, resolver: resolver)
        #expect(target.startFrame == 1 && target.endFrame == 10)
        #expect(target.clipIDs == Set(fixture.timeline.tracks.flatMap(\.clips).filter { $0.startFrame < 10 && $0.endFrame > 1 }.map(\.id)))
        var changed = fixture.timeline
        changed.tracks[0].clips[0].startFrame += 1
        #expect(throws: (any Error).self) {
            _ = try PipelineSequenceReviewStore.findingTarget(finding, snapshot: snapshot, dataRoot: fixture.dataRoot,
                timeline: changed, resolver: resolver)
        }
        let source = try #require(fixture.plan.selectedMedia.first)
        let url = try ProjectLocalFile.resolve(source.sourcePath, dataRoot: fixture.dataRoot)
        try Data("changed media".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try PipelineSequenceReviewStore.findingTarget(finding, snapshot: snapshot, dataRoot: fixture.dataRoot,
                timeline: fixture.timeline, resolver: resolver)
        }
    }

    @Test("review reel preserves exact source trims, cut order and gaps")
    func reviewReelPreservesPlanEDL() async throws {
        let fixture = try await makeFixture(withGap: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let reel = try await ReviewReelBuilder.build(
            plan: fixture.plan,
            dataRoot: fixture.dataRoot
        )

        #expect(reel.entries.map(\.shotID) == ["shot-001", "shot-002"])
        #expect(reel.entries.map(\.sourceStartFrame) == [0, 30])
        #expect(reel.entries.map(\.reelStartFrame) == [0, 60])
        #expect(reel.durationFrames == 90)
        #expect(try FileDigest.sha256(of: ProjectLocalFile.resolve(reel.path, dataRoot: fixture.dataRoot)) == reel.sha256)
        #expect(try FileDigest.sha256(of: ProjectLocalFile.resolve(reel.edlPath, dataRoot: fixture.dataRoot)) == reel.edlSHA256)
    }

    @Test("current review fails closed after selected source bytes drift")
    func currentReviewRejectsSourceDrift() async throws {
        let fixture = try await makeFixture(withGap: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let reel = try await ReviewReelBuilder.build(
            plan: fixture.plan,
            dataRoot: fixture.dataRoot
        )
        let fingerprints = try PipelineSequenceReviewStore.productionFingerprints(
            selectedMedia: fixture.plan.selectedMedia,
            dataRoot: fixture.dataRoot
        )
        let review = SequenceReviewV1(
            projectID: fixture.plan.projectID,
            selectedMedia: fixture.plan.selectedMedia,
            reviewReel: reel,
            executionPlanSHA256: fingerprints.execution,
            canonSHA256: fingerprints.canon,
            referencePlanSHA256: fingerprints.references,
            adjacentPairCompleted: true,
            wholePlaybackCompleted: true,
            findings: [],
            reviewedAt: "2026-09-09T00:00:00Z"
        )
        let bytes = try PipelineAssemblyStore.canonical(review)
        let current = fixture.dataRoot.appendingPathComponent(SequenceReviewV1.relativePath)
        let archive = fixture.dataRoot.appendingPathComponent(
            "reviews/sequence/archive/\(FileDigest.sha256(of: bytes)).v1.json"
        )
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: current, options: .atomic)
        try bytes.write(to: archive, options: .atomic)

        let loaded = try PipelineSequenceReviewStore.requireCurrent(
            dataRoot: fixture.dataRoot,
            timeline: fixture.timeline
        )
        #expect(loaded == review)

        let soundtrackURL = fixture.dataRoot.appendingPathComponent(ReviewReelSoundtrack.path(reelPath: reel.path))
        let soundtrackBytes = try Data(contentsOf: soundtrackURL)
        try FileManager.default.removeItem(at: soundtrackURL)
        do {
            _ = try PipelineSequenceReviewStore.requireCurrent(dataRoot: fixture.dataRoot, timeline: fixture.timeline)
            Issue.record("A legacy review without its soundtrack record remained current.")
        } catch {
            #expect(error.localizedDescription.contains("Build a new review reel and record the review again"))
            #expect(!error.localizedDescription.contains(fixture.home.path))
        }
        try soundtrackBytes.write(to: soundtrackURL, options: .atomic)

        let source = try ProjectLocalFile.resolve("assets/source.mov", dataRoot: fixture.dataRoot)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("drift".utf8))
        try handle.close()
        #expect(throws: (any Error).self) {
            _ = try PipelineSequenceReviewStore.requireCurrent(
                dataRoot: fixture.dataRoot,
                timeline: fixture.timeline
            )
        }
    }

    @Test("current sequence findings reach render repair planning without mutating state")
    func sequenceFindingsReachRepairPlanner() async throws {
        let fixture = try await makeFixture(withGap: false)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let reel = try await ReviewReelBuilder.build(
            plan: fixture.plan,
            dataRoot: fixture.dataRoot
        )
        let fingerprints = try PipelineSequenceReviewStore.productionFingerprints(
            selectedMedia: fixture.plan.selectedMedia,
            dataRoot: fixture.dataRoot
        )
        let finding = SequenceReviewFindingV1(
            id: "finding-prop-state",
            scope: .adjacentPair,
            category: .stateAndProps,
            severity: .blocking,
            shotIDs: ["shot-001", "shot-002"],
            startFrame: 25,
            endFrame: 35,
            evidence: "The carried prop disappears across the cut.",
            recommendedAction: .localRepair,
            provenance: .init(kind: .nativeUser, reviewerID: "native-user")
        )
        let review = SequenceReviewV1(
            projectID: fixture.plan.projectID,
            selectedMedia: fixture.plan.selectedMedia,
            reviewReel: reel,
            executionPlanSHA256: fingerprints.execution,
            canonSHA256: fingerprints.canon,
            referencePlanSHA256: fingerprints.references,
            adjacentPairCompleted: true,
            wholePlaybackCompleted: true,
            findings: [finding],
            reviewedAt: "2026-09-09T00:00:00Z"
        )
        let bytes = try PipelineAssemblyStore.canonical(review)
        let current = fixture.dataRoot.appendingPathComponent(SequenceReviewV1.relativePath)
        let archive = fixture.dataRoot.appendingPathComponent(
            "reviews/sequence/archive/\(FileDigest.sha256(of: bytes)).v1.json"
        )
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: current, options: .atomic)
        try bytes.write(to: archive, options: .atomic)

        let instructions = try #require(PipelineSequenceReviewStore.repairInstructions(
            dataRoot: fixture.dataRoot,
            phase: "render"
        ))
        #expect(instructions.contains(finding.id))
        #expect(instructions.contains(finding.evidence))
        #expect(PipelineSequenceReviewStore.repairInstructions(
            dataRoot: fixture.dataRoot,
            phase: "frames"
        ) == nil)
    }

    @Test("source video audio stays suppressed while the real soundtrack preserves gain and fades")
    func reviewReelBindsAudibleTimelineSoundtrack() async throws {
        let fixture = try await makeFixture(withGap: false, sourceHasAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let song = fixture.dataRoot.appendingPathComponent("assets/song.wav")
        try writeSong(at: song)
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "song", name: "Song", type: .audio,
            source: .project(relativePath: "pipeline/assets/song.wav"), duration: 3, hasAudio: true)]
        let sourceManifest = manifest
        let resolver = MediaResolver(manifest: { sourceManifest }, projectURL: { fixture.home })
        var timeline = fixture.timeline
        var songClip = Clip(mediaRef: "song", mediaType: .audio, sourceClipType: .audio,
            startFrame: 0, durationFrames: 60)
        songClip.trimStartFrame = 6
        songClip.volume = 0.5
        songClip.fadeInFrames = 15
        songClip.fadeOutFrames = 15
        timeline.tracks.append(Track(type: .audio, clips: [songClip]))
        let reel = try await ReviewReelBuilder.build(plan: fixture.plan, dataRoot: fixture.dataRoot,
            timeline: timeline, resolver: resolver)
        let movie = try ProjectLocalFile.resolve(reel.path, dataRoot: fixture.dataRoot)
        let samples = try await decodedAudio(movie)
        #expect(samples.count > 90_000)
        let middle = rms(samples, from: 0.9, to: 1.1)
        #expect(middle > 0.05 && middle < 0.13)
        #expect(rms(samples, from: 0.02, to: 0.1) < middle * 0.4)
        #expect(rms(samples, from: 1.9, to: 1.98) < middle * 0.4)
        try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
            timeline: timeline, resolver: resolver)
        for mutation in 0..<4 {
            var changed = timeline
            switch mutation {
            case 0: changed.tracks[1].clips[0].trimStartFrame += 1
            case 1: changed.tracks[1].muted = true
            case 2: changed.tracks[1].clips[0].volume = 0.9
            default: changed.tracks[1].clips[0].fadeInFrames = 0
            }
            #expect(throws: (any Error).self) {
                try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
                    timeline: changed, resolver: resolver)
            }
        }
        let rebound = fixture.dataRoot.appendingPathComponent("assets/rebound.wav")
        try FileManager.default.copyItem(at: song, to: rebound)
        manifest.entries[0].source = .project(relativePath: "pipeline/assets/rebound.wav")
        let reboundManifest = manifest
        let reboundResolver = MediaResolver(manifest: { reboundManifest }, projectURL: { fixture.home })
        #expect(throws: (any Error).self) {
            try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
                timeline: timeline, resolver: reboundResolver)
        }
        let handle = try FileHandle(forWritingTo: song)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed soundtrack".utf8))
        try handle.close()
        #expect(throws: (any Error).self) {
            try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
                timeline: timeline, resolver: resolver)
        }
    }

    @Test("externally linked timeline audio remains audible and exact source changes invalidate review")
    func reviewReelSupportsExternalAudio() async throws {
        let fixture = try await makeFixture(withGap: false)
        let song = fixture.home.deletingLastPathComponent().appendingPathComponent("external-review-\(UUID().uuidString).wav")
        let alternate = song.appendingPathExtension("alternate.wav")
        defer {
            try? FileManager.default.removeItem(at: fixture.home)
            try? FileManager.default.removeItem(at: song)
            try? FileManager.default.removeItem(at: alternate)
        }
        try writeSong(at: song)
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "external-song", name: "External song", type: .audio,
            source: .external(absolutePath: song.path), duration: 3, hasAudio: true)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { fixture.home })
        var timeline = fixture.timeline
        timeline.tracks.append(Track(type: .audio, clips: [Clip(mediaRef: "external-song", mediaType: .audio,
            sourceClipType: .audio, startFrame: 0, durationFrames: 60)]))
        let reel = try await ReviewReelBuilder.build(plan: fixture.plan, dataRoot: fixture.dataRoot,
            timeline: timeline, resolver: resolver)
        let samples = try await decodedAudio(ProjectLocalFile.resolve(reel.path, dataRoot: fixture.dataRoot))
        #expect(rms(samples, from: 0.5, to: 1.5) > 0.1)
        let binding = try ReviewReelSoundtrack.capture(timeline: timeline, resolver: resolver, fps: 30, dataRoot: fixture.dataRoot)
        #expect(binding.sources.first?.isExternal == true)
        #expect(binding.sources.first?.path == song.standardizedFileURL.resolvingSymlinksInPath().path)
        timeline.tracks[1].displayHeight += 50
        try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
            timeline: timeline, resolver: resolver)

        var overlong = timeline
        overlong.tracks[1].clips[0].durationFrames = 90
        do {
            _ = try await ReviewReelBuilder.build(plan: fixture.plan, dataRoot: fixture.dataRoot,
                timeline: overlong, resolver: resolver)
            Issue.record("A picture-only EDL incorrectly claimed to cover an audio tail.")
        } catch {
            #expect(error.localizedDescription.contains("Extend the picture cut to cover it or trim the audio"))
        }
        try FileManager.default.copyItem(at: song, to: alternate)
        manifest.entries[0].source = .external(absolutePath: alternate.path)
        #expect(throws: (any Error).self) {
            try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
                timeline: timeline, resolver: resolver)
        }
        manifest.entries[0].source = .external(absolutePath: song.path)
        let handle = try FileHandle(forWritingTo: song)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed external source".utf8))
        try handle.close()
        #expect(throws: (any Error).self) {
            try ReviewReelSoundtrack.requireCurrent(reel: reel, plan: fixture.plan, dataRoot: fixture.dataRoot,
                timeline: timeline, resolver: resolver)
        }
    }

    @Test("project audio accepts canonical parent aliases while rejecting symlink escapes")
    func soundtrackNormalizesParentAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let home = real.appendingPathComponent("project.ngv")
        let dataRoot = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let song = dataRoot.appendingPathComponent("song.wav")
        try Data("exact source bytes".utf8).write(to: song)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasedHome = alias.appendingPathComponent("project.ngv")
        let aliasedRoot = aliasedHome.appendingPathComponent("pipeline")
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "song", name: "Song", type: .audio,
            source: .project(relativePath: "pipeline/song.wav"), duration: 1, hasAudio: true)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { aliasedHome })
        var timeline = Timeline()
        timeline.tracks = [Track(type: .audio, clips: [Clip(mediaRef: "song", mediaType: .audio,
            sourceClipType: .audio, startFrame: 0, durationFrames: 30)])]
        let binding = try ReviewReelSoundtrack.capture(timeline: timeline, resolver: resolver, fps: 30, dataRoot: aliasedRoot)
        #expect(binding.sources.first?.path == "pipeline/song.wav")
        #expect(binding.sources.first?.sha256 == FileDigest.sha256(of: Data("exact source bytes".utf8)))
        let source = try #require(binding.sources.first)
        #expect(try source.resolve(dataRoot: aliasedRoot).resolvingSymlinksInPath() == song.resolvingSymlinksInPath())
        let outside = root.appendingPathComponent("outside.wav")
        try Data("outside project".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dataRoot.appendingPathComponent("escape.wav"), withDestinationURL: outside)
        manifest.entries[0].source = .project(relativePath: "pipeline/escape.wav")
        #expect(throws: (any Error).self) {
            _ = try ReviewReelSoundtrack.capture(timeline: timeline, resolver: resolver, fps: 30, dataRoot: aliasedRoot)
        }
    }

    private func writeSong(at url: URL, frequency: Double = 440) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        let samples = try #require(buffer.floatChannelData?[0])
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * frequency * 2 * .pi / 48_000) * 0.25)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { storage in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: storage.count, destination: storage.baseAddress!)
            }
            #expect(status == noErr)
            bytes.withUnsafeBytes { storage in
                for offset in stride(from: 0, to: storage.count, by: MemoryLayout<Float>.size) {
                    result.append(storage.loadUnaligned(fromByteOffset: offset, as: Float.self))
                }
            }
        }
        #expect(reader.status == .completed)
        return result
    }

    private func rms(_ samples: [Float], from: Double, to: Double) -> Double {
        let start = min(samples.count, Int(from * 48_000))
        let end = min(samples.count, Int(to * 48_000))
        guard end > start else { return 0 }
        return sqrt(samples[start..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - start))
    }

    private struct Fixture {
        let home: URL
        let dataRoot: URL
        let plan: AssemblyPlanV1
        let timeline: Timeline
    }

    private func makeFixture(withGap: Bool, sourceHasAudio: Bool = false) async throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sequence-review-\(UUID().uuidString).ngv")
        let dataRoot = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(
            at: dataRoot.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try YAMLArtifactStore(dataRoot: dataRoot).save(
            ProjectMeta(project: "sequence-fixture", mode: .generic),
            to: PipelineLayout.projectFile
        )
        let generated = try await ImageVideoGenerator.blackVideo(
            size: CGSize(width: 320, height: 180)
        )
        let source = dataRoot.appendingPathComponent("assets/source.mov")
        if sourceHasAudio {
            let tone = dataRoot.appendingPathComponent("assets/provider-tone.wav")
            try writeSong(at: tone, frequency: 880)
            let video = AVURLAsset(url: generated)
            let audio = AVURLAsset(url: tone)
            let videoTrack = try #require(try await video.loadTracks(withMediaType: .video).first)
            let audioTrack = try #require(try await audio.loadTracks(withMediaType: .audio).first)
            let composition = AVMutableComposition()
            let picture = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            let sound = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 30))
            try picture.insertTimeRange(range, of: videoTrack, at: .zero)
            try sound.insertTimeRange(range, of: audioTrack, at: .zero)
            let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
            try await export.export(to: source, as: .mov)
            #expect(try await !AVURLAsset(url: source).loadTracks(withMediaType: .audio).isEmpty)
        } else {
            try FileManager.default.copyItem(at: generated, to: source)
        }
        let sourceHash = try FileDigest.sha256(of: source)
        let sourceBytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        let context = ProjectCreativeContextV1(
            projectID: "sequence-fixture",
            artifacts: [],
            media: [.init(
                id: "source-001",
                role: "core.project-media",
                path: "assets/source.mov",
                sha256: sourceHash
            )]
        )
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let execution = ExecutionPlanV1(
            id: "execution-fixture",
            projectID: "sequence-fixture",
            creativeContext: .init(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: FileDigest.sha256(of: contextData)
            ),
            shots: [executionShot(id: "shot-001"), executionShot(id: "shot-002")]
        )
        _ = try PipelineExecutionPlanWriter.write(
            plan: execution,
            context: context,
            dataRoot: dataRoot
        )

        let selected: [SelectedShotMediaV1] = [
            .init(
                shotID: "shot-001",
                sourceKind: .importedSource,
                sourcePath: "assets/source.mov",
                sourceSHA256: sourceHash,
                sourceByteCount: sourceBytes,
                sourceFPS: 30,
                sourceStartFrame: 0,
                sourceEndFrame: 30
            ),
            .init(
                shotID: "shot-002",
                sourceKind: .importedSource,
                sourcePath: "assets/source.mov",
                sourceSHA256: sourceHash,
                sourceByteCount: sourceBytes,
                sourceFPS: 30,
                sourceStartFrame: 30,
                sourceEndFrame: 60
            ),
        ]
        let policy = AssemblyPolicyV1(
            id: "fixture.freeform",
            version: "1.0.0",
            timing: .freeform,
            timelineFPS: 30
        )
        let policyData = try PipelineAssemblyStore.canonical(policy)
        let secondStart = withGap ? 60 : 30
        let placements: [AssemblyPlacementV1] = [
            .init(
                shotID: "shot-001",
                trackID: "assembly-video",
                timelineStartFrame: 0,
                sourceStartFrame: 0,
                sourceEndFrame: 30
            ),
            .init(
                shotID: "shot-002",
                trackID: "assembly-video",
                timelineStartFrame: secondStart,
                sourceStartFrame: 30,
                sourceEndFrame: 60
            ),
        ]
        let plan = AssemblyPlanV1(
            projectID: "sequence-fixture",
            phase: "final",
            selectedMedia: selected,
            placements: placements,
            existingRegionFingerprint: nil,
            policyPath: PipelineAssemblyStore.policyPath,
            policySHA256: FileDigest.sha256(of: policyData)
        )
        let planData = try PipelineAssemblyStore.canonical(plan)
        var firstClip = Clip(
            mediaRef: "source-001",
            mediaType: .video,
            sourceClipType: .video,
            startFrame: 0,
            durationFrames: 30
        )
        firstClip.id = "clip-001"
        var secondClip = Clip(
            mediaRef: "source-001",
            mediaType: .video,
            sourceClipType: .video,
            startFrame: secondStart,
            durationFrames: 30
        )
        secondClip.id = "clip-002"
        secondClip.trimStartFrame = 30
        var track = Track(type: .video, clips: [firstClip, secondClip])
        track.id = "assembly-video"
        var timeline = Timeline()
        timeline.fps = 30
        timeline.width = 1280
        timeline.height = 720
        timeline.settingsConfigured = true
        timeline.tracks = [track]
        let manifest = AssemblyManifestV1(
            projectID: "sequence-fixture",
            phase: "final",
            planSHA256: FileDigest.sha256(of: planData),
            policyID: policy.id,
            policyVersion: policy.version,
            policySHA256: plan.policySHA256,
            priorRegionFingerprint: nil,
            appliedRegionFingerprint: try PipelineAssemblyStore.regionFingerprint(
                timeline: timeline,
                videoTrackID: track.id,
                audioTrackID: nil
            ) ?? "",
            timelineFingerprint: try PipelineAssemblyStore.fingerprint(timeline: timeline),
            idempotencyKey: PipelineAssemblyStore.idempotencyKey(planData: planData),
            placements: zip(selected, placements).enumerated().map { index, pair in
                .init(
                    selected: pair.0,
                    placement: pair.1,
                    clipIDs: [index == 0 ? "clip-001" : "clip-002"]
                )
            }
        )
        try PipelineAssemblyStore.persist(
            policy: policy,
            plan: plan,
            planData: planData,
            manifest: manifest,
            dataRoot: dataRoot
        )
        return Fixture(home: home, dataRoot: dataRoot, plan: plan, timeline: timeline)
    }

    private func executionShot(id: String) -> ExecutionShotV1 {
        ExecutionShotV1(
            id: id,
            sourceMode: .imported,
            sourceAssetID: "source-001",
            startState: .init(summary: "The source begins."),
            endState: .init(summary: "The source ends."),
            primaryAction: "Use the selected source.",
            camera: .init(movementID: "core.source"),
            renderability: .green,
            acceptance: [.init(
                id: "accept-\(id)",
                requirement: "The selected source remains intact.",
                severity: "required"
            )]
        )
    }
}
