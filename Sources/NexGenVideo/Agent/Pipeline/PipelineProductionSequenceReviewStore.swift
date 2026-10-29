import AVFoundation
import Darwin
import Foundation
import NexGenEngine

@MainActor
enum PipelineProductionSequenceReviewStore {
    private struct SourceFileFence: Sendable {
        struct Entry: Sendable, Equatable {
            let url: URL
            let resolved: URL
            let stamp: [Int64]
        }
        let entries: [Entry]

        static func capture(_ urls: [URL]) throws -> SourceFileFence {
            let entries = try urls.map { original -> Entry in
                let resolved = original.standardizedFileURL.resolvingSymlinksInPath()
                var info = stat()
                guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw changed() }
                return Entry(url: original, resolved: resolved, stamp: [Int64(info.st_dev), Int64(bitPattern: info.st_ino),
                    info.st_size, Int64(info.st_mode), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                    Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)])
            }
            return SourceFileFence(entries: entries)
        }
        func requireUnchanged() throws {
            guard try Self.capture(entries.map(\.url)).entries == entries else { throw changed() }
        }
    }

    struct Snapshot: Sendable {
        let home: URL
        let key: String
        let input: Inputs
        let timeline: CanonicalArtifactReferenceV1
        let edl: CanonicalArtifactReferenceV1
        let reel: CanonicalArtifactReferenceV1
        let reelByteCount: Int64
        var durationFrames: Int { input.durationFrames }
        var cutFrames: [Int] { input.edl.cutFrames }
        var shotIDs: [String] { input.shotIDs }
    }

    struct SourceSnapshot: Codable, Sendable, Equatable {
        let schema: String
        let projectID: String
        let mediaID: String
        let originalFilename: String
        let originIdentity: String
        let frozen: CanonicalArtifactReferenceV1
        var receipt: CanonicalArtifactReferenceV1 {
            get throws {
                let bytes = try PlanningWriterIO.json(self)
                return PlanningWriterIO.reference("reviews/sequence/sources/receipts/" + FileDigest.sha256(of: bytes) + ".v2.json",
                    id: "film-source-receipt-" + FileDigest.sha256(of: Data(mediaID.utf8)), role: "host.sequence-source-snapshot", bytes: bytes)
            }
        }
    }

    struct Inputs: Sendable, Equatable {
        let projectID: String
        let fingerprint: String
        let assembly: CanonicalArtifactReferenceV1
        let projection: CanonicalArtifactReferenceV1
        let references: [CanonicalArtifactReferenceV1]
        let sources: [SourceSnapshot]
        let edl: ProductionSequenceEDLV2
        let shotIDs: [String]
        let durationFrames: Int
        let soundtrackEndTicks: Int64?
        let musicRequirements: [ProductionMusicCoverageRequirementV2]
    }

    private struct InputReviewHead: Codable, Sendable {
        let projectID: String
        let inputFingerprint: String
        let review: CanonicalArtifactReferenceV1
    }

    struct ReelAuthorization: Sendable {
        fileprivate let home: URL
        fileprivate let expected: Inputs
        fileprivate let output: URL
        fileprivate let originalResolver: MediaResolver
        fileprivate init(home: URL, expected: Inputs, output: URL, originalResolver: MediaResolver) {
            self.home = home; self.expected = expected; self.output = output; self.originalResolver = originalResolver
        }

        @MainActor
        func requireCurrent(timeline: Timeline, resolver: MediaResolver, outputURL: URL) async throws {
            guard outputURL.standardizedFileURL == output.standardizedFileURL,
                  resolver.projectHome == home, let root = DataRootResolver.dataRoot(of: home) else { throw changed() }
            let frozen = resolver.snapshot()
            let current = try await background {
                let original = try readInputs(dataRoot: root, timeline: timeline, resolver: originalResolver)
                guard original == expected else { throw changed() }
                try requireSourceSnapshots(expected.sources, dataRoot: root)
                return try readInputs(dataRoot: root, timeline: timeline, resolver: frozen, sourceOrigins: expected.sources)
            }
            guard current == expected else { throw changed() }
        }
    }

    static func capture(editor: EditorViewModel) async throws -> Snapshot {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Build film review")
        defer { access.end(editor: editor) }
        let actualTimeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let input = try await background { try readInputs(dataRoot: access.root, timeline: actualTimeline, resolver: resolver) }
        let preparedSources = try await background {
            let sourceFence = try SourceFileFence.capture(Array(resolver.expectedURLMap(for: Set(actualTimeline.tracks.flatMap(\.clips).filter { $0.mediaType != .text }.map(\.mediaRef))).values))
            let binding = try ExportQueue.SourceBinding.video(timeline: actualTimeline, resolver: resolver,
                additionalFiles: [], isCancelled: { Task.isCancelled })
            let frozen = try binding.freeze(jobID: "film-review-" + UUID().uuidString, isCancelled: { Task.isCancelled })
            do {
                try frozen.verify(isCancelled: { Task.isCancelled })
                let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                    additionalCanonicalPaths: input.references.filter { !($0.path.hasPrefix("reviews/sequence/sources/")) }.map(\.path))
                let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                    for source in input.sources {
                        guard let actual = frozen.files.first(where: { $0.ref == source.mediaID }),
                              actual.state.digest == source.frozen.sha256 else { throw changed() }
                        _ = try ProjectLocalFile.ensureDirectory((source.frozen.path as NSString).deletingLastPathComponent, dataRoot: staging)
                        let destination = staging.appendingPathComponent(source.frozen.path)
                        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: actual.url, to: destination) }
                        _ = try ProjectLocalFile.requireHash(source.frozen.sha256, at: source.frozen.path, dataRoot: staging)
                        try writeImmutable(PlanningWriterIO.json(source), reference: source.receipt, dataRoot: staging)
                    }
                    try requireSourceSnapshots(input.sources, dataRoot: staging)
                    return true
                }
                do {
                    try binding.verify(isCancelled: { Task.isCancelled })
                    guard try readInputs(dataRoot: access.root, timeline: actualTimeline, resolver: resolver) == input else { throw changed() }
                    try fence.requireUnchanged()
                    try sourceFence.requireUnchanged()
                    frozen.remove()
                    return (transaction, fence, sourceFence)
                } catch { transaction.discard(); throw error }
            } catch { frozen.remove(); throw error }
        }
        defer { Task.detached { preparedSources.0.discard() } }
        try Task.checkCancellation()
        _ = try preparedSources.0.commit { _ in
            try access.requireCurrent(editor: editor)
            guard try timelineHash(editor.timeline) == input.edl.timelineSHA256 else { throw changed() }
            try preparedSources.1.requireCanonicalRootsUnchanged()
            try preparedSources.2.requireUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        let frozenURLs = Dictionary(uniqueKeysWithValues: input.sources.map { ($0.mediaID, access.root.appendingPathComponent($0.frozen.path)) })
        let exportResolver = resolver.snapshot(overriding: frozenURLs)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("production-review-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let authorization = ReelAuthorization(home: access.home, expected: input, output: output, originalResolver: resolver)
        let exporter = ExportService()
        await withTaskCancellationHandler {
            await exporter.export(timeline: actualTimeline, resolver: exportResolver, format: .h264, resolution: .r720p,
                outputURL: output, nativeReviewAuthorization: authorization)
        } onCancel: { Task { @MainActor in exporter.cancel() } }
        try Task.checkCancellation()
        if let error = exporter.error { throw GateBlocked("The film review could not be rendered: " + error) }
        guard exporter.lastReport?.offlineMediaRefs.isEmpty == true,
              exporter.lastReport?.unprocessableMediaRefs.isEmpty == true else { throw changed() }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard try readInputs(dataRoot: access.root, timeline: actualTimeline, resolver: resolver) == input else { throw changed() }
            let originalSources = try SourceFileFence.capture(Array(resolver.expectedURLMap(for: Set(input.sources.map(\.mediaID))).values))
            let film = AVURLAsset(url: output)
            let duration = try await film.load(.duration)
            let video = try await film.loadTracks(withMediaType: .video)
            let expectedDuration = CMTime(value: input.edl.outputDurationTicks, timescale: Int32(input.edl.timebase.ticksPerSecond))
            guard !video.isEmpty, duration.isNumeric, CMTimeCompare(duration, expectedDuration) == 0 else {
                throw GateBlocked("The actual film duration does not match its exact selected output range.")
            }
            let generator = AVAssetImageGenerator(asset: film)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let first = try await generator.image(at: .zero)
            let lastTime = CMTime(value: Int64(input.durationFrames - 1), timescale: Int32(actualTimeline.fps))
            let last = try await generator.image(at: lastTime)
            guard CMTimeCompare(first.actualTime, .zero) == 0, CMTimeCompare(last.actualTime, lastTime) == 0 else {
                throw GateBlocked("The actual review film's first or last decoded frame does not match its output interval.")
            }
            let audio = try await film.loadTracks(withMediaType: .audio)
            if expectsAudibleAudio(timeline: actualTimeline, outputStartTicks: input.edl.outputStartTicks,
                outputDurationTicks: input.edl.outputDurationTicks, timebase: input.edl.timebase) {
                guard !audio.isEmpty else { throw GateBlocked("The review film is missing the timeline's sound.") }
            }
            if let audioEnd = input.soundtrackEndTicks {
                let expectedEnd = CMTime(value: audioEnd, timescale: Int32(input.edl.timebase.ticksPerSecond))
                var ends: [CMTime] = []
                for track in audio { ends.append(try await track.load(.timeRange).end) }
                guard let actualEnd = ends.max(by: { CMTimeCompare($0, $1) < 0 }), CMTimeCompare(actualEnd, expectedEnd) == 0 else {
                    throw GateBlocked("The actual review soundtrack does not end at its exact planned audio tick.")
                }
            }
            let hash = try FileDigest.sha256(of: output)
            let values = try output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw changed() }
            let directory = "reviews/sequence/reels/" + input.fingerprint + "-" + hash
            let timelineBytes = try PlanningWriterIO.json(actualTimeline)
            let edlBytes = try PlanningWriterIO.json(input.edl)
            let timeline = PlanningWriterIO.reference(directory + "/timeline.v2.json", id: "sequence-timeline", role: "host.sequence-timeline", bytes: timelineBytes)
            let edl = PlanningWriterIO.reference(directory + "/edl.v2.json", id: "sequence-edl", role: "host.sequence-edl", bytes: edlBytes)
            let reel = CanonicalArtifactReferenceV1(id: "sequence-reel", role: "host.sequence-reel", path: directory + "/film.mp4", sha256: hash)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: input.references.map(\.path))
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                for (reference, bytes) in [(timeline, timelineBytes), (edl, edlBytes)] {
                    try writeImmutable(bytes, reference: reference, dataRoot: staging)
                }
                let destination = staging.appendingPathComponent(reel.path)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try ProjectLocalFile.requireHash(reel.sha256, at: reel.path, dataRoot: staging)
                } else { try FileManager.default.copyItem(at: output, to: destination) }
                _ = try ProjectLocalFile.requireHash(reel.sha256, at: reel.path, dataRoot: staging)
                return Snapshot(home: access.home, key: access.key, input: input,
                    timeline: timeline, edl: edl, reel: reel, reelByteCount: Int64(size))
            }
            do { try fence.requireUnchanged(); try originalSources.requireUnchanged(); return (transaction, fence, originalSources) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let written = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            guard try timelineHash(editor.timeline) == input.edl.timelineSHA256 else { throw changed() }
            try result.1.requireCanonicalRootsUnchanged()
            try result.2.requireUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        editor.onPipelineChanged?()
        return written
    }

    static func loadCurrent(editor: EditorViewModel, matchingInputFingerprint: String? = nil) async throws -> (Snapshot, ProductionSequenceReviewV2)? {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home), let key = editor.openWorkingCopyKey else { return nil }
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let result = try await background { () throws -> (Snapshot, ProductionSequenceReviewV2)? in
            let input = try readInputs(dataRoot: root, timeline: timeline, resolver: resolver)
            guard matchingInputFingerprint == nil || matchingInputFingerprint == input.fingerprint,
                  let head = try readInputHead(input.fingerprint, projectID: input.projectID, dataRoot: root) else { return nil }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(head.review.sha256, at: head.review.path, dataRoot: root))
            let review = try requireReview(bytes: bytes, inputs: input, dataRoot: root, rejectBlocking: false)
            return (Snapshot(home: home, key: key, input: input, timeline: review.timeline, edl: review.edl,
                reel: review.reel, reelByteCount: review.reelByteCount), review)
        }
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
              try timelineHash(editor.timeline) == timelineHash(timeline) else { throw changed() }
        return result
    }

    static func save(snapshot: Snapshot, adjacentPairCompleted: Bool, wholePlaybackCompleted: Bool,
                     findings: [SequenceReviewFindingV1], musicCoverage: [ProductionMusicCoverageObservationV2] = [],
                     findingResolutions: [ProductionSequenceReviewV2.FindingResolution] = [], editor: EditorViewModel) async throws {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Record film review")
        defer { access.end(editor: editor) }
        guard access.home == snapshot.home, access.key == snapshot.key else { throw changed() }
        let timeline = editor.timeline
        let resolver = editor.mediaResolver.snapshot()
        let reviewedAt = ISO8601DateFormatter().string(from: Date())
        let result = try await background {
            let originalSources = try SourceFileFence.capture(Array(resolver.expectedURLMap(for: Set(snapshot.input.sources.map(\.mediaID))).values))
            guard try readInputs(dataRoot: access.root, timeline: timeline, resolver: resolver) == snapshot.input else { throw changed() }
            try requireSnapshotFiles(snapshot, dataRoot: access.root)
            let head = try readInputHead(snapshot.input.fingerprint, projectID: snapshot.input.projectID, dataRoot: access.root)
            let priorBytes = try head.map { try Data(contentsOf: ProjectLocalFile.requireHash($0.review.sha256, at: $0.review.path, dataRoot: access.root)) }
            let prior = try priorBytes.map { try JSONDecoder().decode(ProductionSequenceReviewV2.self, from: $0) }
            let previous = head?.review
            if let priorBytes { _ = try requireReview(bytes: priorBytes, inputs: snapshot.input, dataRoot: access.root, rejectBlocking: false) }
            let review = ProductionSequenceReviewV2(projectID: snapshot.input.projectID, assembly: snapshot.input.assembly,
                projection: snapshot.input.projection, inputFingerprint: snapshot.input.fingerprint,
                timeline: snapshot.timeline, edl: snapshot.edl, reel: snapshot.reel, reelByteCount: snapshot.reelByteCount,
                durationFrames: snapshot.durationFrames, cutFrames: snapshot.cutFrames, inputs: snapshot.input.references,
                adjacentPairCompleted: adjacentPairCompleted, wholePlaybackCompleted: wholePlaybackCompleted,
                findings: findings.map(nativeFinding), reviewedAt: reviewedAt, musicCoverage: musicCoverage,
                findingResolutions: findingResolutions, supersedes: previous)
            try review.validate(edl: snapshot.input.edl, shotIDs: Set(snapshot.shotIDs), rejectBlocking: false,
                musicRequirements: snapshot.input.musicRequirements)
            if let prior { try requireRetainedObservations(previous: prior, current: review) }
            let bytes = try PlanningWriterIO.json(review)
            let archive = archiveReference(bytes)
            let headPath = try inputHeadPath(snapshot.input.fingerprint)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: review.artifactReferences.map(\.path) + [headPath, ProductionSequenceReviewV2.relativePath])
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                try writeImmutable(bytes, reference: archive, dataRoot: staging)
                _ = try ProjectLocalFile.ensureDirectory((headPath as NSString).deletingLastPathComponent, dataRoot: staging)
                try PlanningWriterIO.json(InputReviewHead(projectID: review.projectID, inputFingerprint: review.inputFingerprint,
                    review: archive)).write(to: staging.appendingPathComponent(headPath), options: .atomic)
                try bytes.write(to: staging.appendingPathComponent(ProductionSequenceReviewV2.relativePath), options: .atomic)
                let stagedResolver = try rebase(resolver: resolver, timeline: timeline, from: access.root, to: staging)
                _ = try requireCurrent(dataRoot: staging, timeline: timeline, resolver: stagedResolver, rejectBlocking: false, sourceOrigins: snapshot.input.sources)
                return true
            }
            do { try fence.requireUnchanged(); try originalSources.requireUnchanged(); return (transaction, fence, originalSources) }
            catch { transaction.discard(); throw error }
        }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        _ = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            guard try timelineHash(editor.timeline) == snapshot.input.edl.timelineSHA256 else { throw changed() }
            try result.1.requireCanonicalRootsUnchanged()
            try result.2.requireUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        editor.onPipelineChanged?()
    }

    nonisolated static func requireCurrent(dataRoot: URL, timeline: Timeline, resolver: MediaResolver? = nil) throws -> ProductionSequenceReviewV2 {
        try requireCurrent(dataRoot: dataRoot, timeline: timeline, resolver: resolver, rejectBlocking: true)
    }

    nonisolated static func artifactReference(dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        try PlanningWriterIO.reference(ProductionSequenceReviewV2.relativePath, id: "production-sequence-review",
            role: "host.production-sequence-review", dataRoot: dataRoot)
    }

    nonisolated static func repairInstructions(dataRoot: URL, phase: String, timeline: Timeline,
                                               resolver: MediaResolver) -> String? {
        guard phase == "render", FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(ProductionSequenceReviewV2.relativePath).path) else { return nil }
        do {
            guard let trusted = resolver.trustedProductionDeclaration else { return nil }
            _ = try ProjectPackGate.requireMutation(projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: trusted.packName, declaredBinding: trusted.binding, declaredProductionContract: trusted.productionContract)
            guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: trusted.binding,
                expectedProductionContract: trusted.productionContract), workflow.isProductionV2 else { return nil }
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(ProductionSequenceReviewV2.relativePath, dataRoot: dataRoot))
            let review = try JSONDecoder().decode(ProductionSequenceReviewV2.self, from: bytes)
            try requireInputHead(review: review, bytes: bytes, dataRoot: dataRoot)
            try requireReviewHistory(review, dataRoot: dataRoot)
            let archive = archiveReference(bytes)
            _ = try ProjectLocalFile.requireHash(archive.sha256, at: archive.path, dataRoot: dataRoot)
            for ref in review.artifactReferences { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
            guard review.projectID == projection.header.projectID,
                  review.projection.path == ProductionPlanProjectionV1.versionPath(projection.header.revision),
                  try timelineHash(timeline) == review.timeline.sha256 else { return nil }
            let edl = try PlanningWriterIO.read(ProductionSequenceEDLV2.self, at: review.edl.path, dataRoot: dataRoot)
            let musicRequirements: [ProductionMusicCoverageRequirementV2]
            if workflow.packID == "musicvideo" {
                musicRequirements = try ProductionMusicCoverageRequirementV2.requirements(for:
                    MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot))
            } else { musicRequirements = [] }
            try review.validate(edl: edl, shotIDs: Set(projection.shots.map(\.id)), rejectBlocking: false, musicRequirements: musicRequirements)
            let sources = try review.inputs.filter { $0.role == "host.sequence-source-snapshot" }.map {
                try PlanningWriterIO.read(SourceSnapshot.self, at: $0.path, dataRoot: dataRoot)
            }
            let mediaIDs = Set(timeline.tracks.flatMap(\.clips).filter { $0.mediaType != .text }.map(\.mediaRef))
            guard Set(sources.map(\.mediaID)) == mediaIDs else { return nil }
            for source in sources {
                guard source.schema == "native-film-source-snapshot/v2", source.projectID == review.projectID,
                      let url = resolver.resolveURL(for: source.mediaID),
                      try FileDigest.sha256(of: url) == source.frozen.sha256,
                      source.originIdentity == originIdentity(url: url, dataRoot: dataRoot) else { return nil }
            }
            let resolved = Set(review.findingResolutions.map(\.findingID))
            let findings = review.findings.filter { !resolved.contains($0.id) && ($0.severity != .info || $0.recommendedAction != .accept) }
            let failedRoles = review.musicCoverage.filter { !$0.visible }
            guard !findings.isEmpty || !failedRoles.isEmpty else { return nil }
            let observations = String(decoding: try PlanningWriterIO.json(findings), as: UTF8.self)
            let music = String(decoding: try PlanningWriterIO.json(failedRoles), as: UTF8.self)
            return """
            Historical native film-review observations, bound to the exact retained reel and unchanged cut: \(observations)
            Observed missing musical/spatial roles: \(music)
            These observations are repair context, not current phase approval or delivery authorization. Propose only attributed repairs for the recorded shots and ranges. Explicit rewind, canonical writer validation and host-owned paid-generation approval remain required. Never mutate a take, timeline, canon, approval or budget from a finding.
            """
        } catch { return nil }
    }

    nonisolated private static func requireCurrent(dataRoot: URL, timeline: Timeline, resolver: MediaResolver?,
                                                  rejectBlocking: Bool, sourceOrigins: [SourceSnapshot]? = nil) throws -> ProductionSequenceReviewV2 {
        guard let resolver else { throw GateBlocked("Restore the current film's media before validating its native review.") }
        let inputs = try readInputs(dataRoot: dataRoot, timeline: timeline, resolver: resolver, sourceOrigins: sourceOrigins)
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(ProductionSequenceReviewV2.relativePath, dataRoot: dataRoot))
        return try requireReview(bytes: bytes, inputs: inputs, dataRoot: dataRoot, rejectBlocking: rejectBlocking)
    }

    nonisolated private static func requireReview(bytes: Data, inputs: Inputs, dataRoot: URL,
                                                  rejectBlocking: Bool) throws -> ProductionSequenceReviewV2 {
        let review = try JSONDecoder().decode(ProductionSequenceReviewV2.self, from: bytes)
        guard review.projectID == inputs.projectID, review.assembly == inputs.assembly, review.projection == inputs.projection,
              review.inputFingerprint == inputs.fingerprint, review.inputs == inputs.references else { throw changed() }
        try review.validate(edl: inputs.edl, shotIDs: Set(inputs.shotIDs), rejectBlocking: rejectBlocking,
            musicRequirements: inputs.musicRequirements)
        try requireSourceSnapshots(inputs.sources, dataRoot: dataRoot)
        try requireInputHead(review: review, bytes: bytes, dataRoot: dataRoot)
        try requireReviewHistory(review, dataRoot: dataRoot)
        for reference in review.artifactReferences {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
        guard try Data(contentsOf: ProjectLocalFile.resolve(archiveReference(bytes).path, dataRoot: dataRoot)) == bytes,
              try PlanningWriterIO.read(ProductionSequenceEDLV2.self, at: review.edl.path, dataRoot: dataRoot) == inputs.edl else { throw changed() }
        let size = try ProjectLocalFile.resolve(review.reel.path, dataRoot: dataRoot).resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == review.reelByteCount else { throw changed() }
        return review
    }

    nonisolated private static func inputHeadPath(_ fingerprint: String) throws -> String {
        guard fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw changed() }
        return "reviews/sequence/by-input/" + fingerprint + ".v2.json"
    }

    nonisolated private static func readInputHead(_ fingerprint: String, projectID: String, dataRoot: URL) throws -> InputReviewHead? {
        let path = try inputHeadPath(fingerprint)
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else { return nil }
        let head = try PlanningWriterIO.read(InputReviewHead.self, at: path, dataRoot: dataRoot)
        let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(head.review.sha256, at: head.review.path, dataRoot: dataRoot))
        let review = try JSONDecoder().decode(ProductionSequenceReviewV2.self, from: bytes)
        guard head.projectID == projectID, head.inputFingerprint == fingerprint,
              review.projectID == projectID, review.inputFingerprint == fingerprint,
              head.review == archiveReference(bytes) else { throw changed() }
        return head
    }

    nonisolated private static func requireInputHead(review: ProductionSequenceReviewV2, bytes: Data, dataRoot: URL) throws {
        guard let head = try readInputHead(review.inputFingerprint, projectID: review.projectID, dataRoot: dataRoot),
              head.review == archiveReference(bytes) else { throw changed() }
    }

    nonisolated private static func requireRetainedObservations(previous: ProductionSequenceReviewV2, current: ProductionSequenceReviewV2) throws {
        guard previous.projectID == current.projectID, previous.inputFingerprint == current.inputFingerprint,
              previous.edl.sha256 == current.edl.sha256 else { throw changed() }
        for finding in previous.findings where finding.severity == .blocking {
            guard current.findings.contains(finding) else {
                throw GateBlocked("Keep the recorded blocking finding. Describe its resolution after inspecting the current film.")
            }
        }
        for failed in previous.musicCoverage where !failed.visible {
            guard let observed = current.musicCoverage.first(where: { $0.id == failed.id }),
                  !observed.visible || observed.evidence != failed.evidence else {
                throw GateBlocked("Describe the newly observed musical role before confirming its visibility.")
            }
        }
    }

    nonisolated private static func requireReviewHistory(_ review: ProductionSequenceReviewV2, dataRoot: URL) throws {
        var current = review
        var visited = Set<String>()
        while let reference = current.supersedes {
            try Task.checkCancellation()
            guard visited.insert(reference.sha256).inserted else { throw changed() }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot))
            guard archiveReference(bytes) == reference else { throw changed() }
            let previous = try JSONDecoder().decode(ProductionSequenceReviewV2.self, from: bytes)
            try requireRetainedObservations(previous: previous, current: current)
            current = previous
        }
    }

    nonisolated private static func readInputs(dataRoot: URL, timeline: Timeline, resolver: MediaResolver, sourceOrigins: [SourceSnapshot]? = nil) throws -> Inputs {
        let home = FrameInventory.projectHome(of: dataRoot)
        guard let trusted = resolver.trustedProductionDeclaration else { throw GateBlocked("Reopen the project to restore its trusted production workflow.") }
        _ = try ProjectPackGate.requireMutation(projectURL: home, declaredPack: trusted.packName,
            declaredBinding: trusted.binding, declaredProductionContract: trusted.productionContract)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: trusted.binding,
            expectedProductionContract: trusted.productionContract), workflow.isProductionV2 else { throw changed() }
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        guard gates.get("render").approved else { throw GateBlocked("Complete Render approval before reviewing the finished film.") }
        let registry = PackCatalog.registry(activePack: workflow.packID)
        guard let lineage = try PhaseContractRuntime.lineageProvider(workflow: workflow, phase: "render", registry: registry) else { throw changed() }
        try PipelineLineageStore.requireCurrent(phase: "render", snapshot: lineage(dataRoot), dataRoot: dataRoot)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let assembly = try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: dataRoot)
        let mediaIDs = Set(timeline.tracks.flatMap(\.clips).filter { $0.mediaType != .text }.map(\.mediaRef))
        let urls = resolver.expectedURLMap(for: mediaIDs)
        let sourceFence = try SourceFileFence.capture(Array(urls.values))
        try PipelineProductionAssemblyWriter.requireExportTimeline(dataRoot: dataRoot, timeline: timeline, mediaURLs: urls)
        let board = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let output = try ProductionPlanAssemblyV1.outputInterval(proof: assembly, timing: board.timing)
        let frameRate = Int64(timeline.fps).multipliedReportingOverflow(by: assembly.timebase.fpsDenominator)
        guard timeline.fps > 0, !frameRate.overflow, frameRate.partialValue == assembly.timebase.fpsNumerator,
              let frames = Int(exactly: try ProductionPlanAssemblyV1.coveringFrameCount(for: output.durationTicks, timebase: assembly.timebase)) else { throw changed() }
        let startFrame = try ProductionPlanAssemblyV1.frameIndex(for: output.startTicks, timebase: assembly.timebase)
        let outputEndFrame = startFrame.addingReportingOverflow(Int64(frames))
        guard !outputEndFrame.overflow, let firstFrame = Int(exactly: startFrame),
              let endFrame = Int(exactly: outputEndFrame.partialValue) else { throw changed() }
        var refs = try PipelineProductionAssemblyWriter.artifactReferences(dataRoot: dataRoot)
        let musicRequirements: [ProductionMusicCoverageRequirementV2]
        if workflow.packID == "musicvideo" {
            let music = try MusicvideoProductionExtensionStoreV2.requireCurrent(projection: projection, dataRoot: dataRoot)
            musicRequirements = try ProductionMusicCoverageRequirementV2.requirements(for: music)
            refs += music.artifactReferences
            refs.append(try PlanningWriterIO.reference(MusicvideoProductionExtensionV2.path(revision: projection.header.revision),
                id: MusicvideoProductionExtensionV2.artifactID, role: "musicvideo.production", dataRoot: dataRoot))
        } else { musicRequirements = [] }
        var sourceByMedia: [String: CanonicalArtifactReferenceV1] = [:]
        var sourceSnapshots: [SourceSnapshot] = []
        for id in mediaIDs.sorted() {
            guard let url = urls[id] else { throw GateBlocked("Restore all offline media before reviewing the film.") }
            let actual = url.standardizedFileURL.resolvingSymlinksInPath()
            guard try actual.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw changed() }
            let sha = try FileDigest.sha256(of: actual)
            let identity: String
            if let original = sourceOrigins?.first(where: { $0.mediaID == id }),
               actual == dataRoot.appendingPathComponent(original.frozen.path).standardizedFileURL.resolvingSymlinksInPath(),
               sha == original.frozen.sha256 {
                identity = original.originIdentity
            } else { identity = originIdentity(url: actual, dataRoot: dataRoot) }
            let ext = actual.pathExtension.lowercased()
            guard ext.count <= 16, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw changed() }
            let path = "reviews/sequence/sources/" + sha + "/source" + (ext.isEmpty ? "" : "." + ext)
            let reference = CanonicalArtifactReferenceV1(id: "film-media-" + FileDigest.sha256(of: Data(id.utf8)),
                role: "host.sequence-source", path: path, sha256: sha)
            let source = SourceSnapshot(schema: "native-film-source-snapshot/v2", projectID: projection.header.projectID,
                mediaID: id, originalFilename: resolver.interchangeFilename(for: id), originIdentity: identity, frozen: reference)
            sourceSnapshots.append(source)
            sourceByMedia[id] = reference
            refs += [reference, try source.receipt]
        }
        let assemblyRef = try PlanningWriterIO.reference(ProductionPlanAssemblyProofV1.relativePath,
            id: "film-assembly", role: "core.production-assembly", dataRoot: dataRoot)
        let projectionRef = try PlanningWriterIO.reference(ProductionPlanProjectionV1.versionPath(projection.header.revision),
            id: "film-projection", role: "core.production-plan", dataRoot: dataRoot)
        refs += [assemblyRef, projectionRef]
        let timelineSHA = try timelineHash(timeline)
        let placed = Dictionary(uniqueKeysWithValues: assembly.placements.map { ($0.clipID, $0) })
        var clips: [ProductionSequenceEDLV2.Clip] = []
        var cuts = Set<Int>()
        for track in timeline.tracks {
            for clip in track.clips {
                guard clip.startFrame >= 0, clip.durationFrames > 0, clip.trimStartFrame >= 0,
                      clip.speed.isFinite, clip.speed > 0 else { throw GateBlocked("Repair empty or invalid timeline clips before reviewing the film.") }
                let source = clip.mediaType == .text ? nil : sourceByMedia[clip.mediaRef]
                guard clip.mediaType == .text || source != nil else { throw changed() }
                let placement = placed[clip.id]
                let shotID: String?
                if let placement, let source, source.sha256 == placement.output.sha256 { shotID = placement.shotID }
                else { shotID = nil }
                clips.append(.init(trackID: track.id, clipID: clip.id, shotID: shotID, mediaID: source == nil ? nil : clip.mediaRef,
                    source: source, startFrame: clip.startFrame, durationFrames: clip.durationFrames, sourceStartFrame: clip.trimStartFrame, speed: clip.speed))
                if !track.hidden && clip.mediaType.isVisual && (clip.opacity > 0 || clip.opacityTrack != nil) {
                    for edge in [clip.startFrame, clip.endFrame] where edge > firstFrame && edge < endFrame { cuts.insert(edge - firstFrame) }
                }
            }
        }
        guard !clips.isEmpty else { throw GateBlocked("Add the intended film to the timeline before reviewing it.") }
        let edl = ProductionSequenceEDLV2(projectID: projection.header.projectID, timelineSHA256: timelineSHA,
            timebase: assembly.timebase, outputStartTicks: output.startTicks, outputDurationTicks: output.durationTicks,
            clips: clips, cutFrames: cuts.sorted())
        refs = try unique(refs)
        let fingerprintBytes = try PlanningWriterIO.json(refs) + PlanningWriterIO.json(edl)
        let fingerprint = FileDigest.sha256(of: fingerprintBytes)
        let soundtrackEnd: Int64?
        if workflow.packID == "musicvideo", let audio = assembly.audio {
            let end = audio.startTicks.addingReportingOverflow(audio.durationTicks)
            let outputEnd = output.startTicks.addingReportingOverflow(output.durationTicks)
            guard !end.overflow, !outputEnd.overflow else { throw changed() }
            let relative = min(end.partialValue, outputEnd.partialValue) - output.startTicks
            soundtrackEnd = relative > 0 ? relative : nil
        } else { soundtrackEnd = nil }
        try sourceFence.requireUnchanged()
        return Inputs(projectID: projection.header.projectID, fingerprint: fingerprint, assembly: assemblyRef,
            projection: projectionRef, references: refs, sources: sourceSnapshots, edl: edl, shotIDs: projection.shots.map(\.id), durationFrames: frames, soundtrackEndTicks: soundtrackEnd, musicRequirements: musicRequirements)
    }

    nonisolated static func expectsAudibleAudio(timeline: Timeline, outputStartTicks: Int64, outputDurationTicks: Int64,
                                               timebase: RationalTimebaseV1) -> Bool {
        let start = CMTime(value: outputStartTicks, timescale: Int32(timebase.ticksPerSecond))
        let end = CMTimeAdd(start, CMTime(value: outputDurationTicks, timescale: Int32(timebase.ticksPerSecond)))
        return timeline.tracks.contains { track in
            track.type == .audio && !track.muted && track.clips.contains { clip in
                clip.volume > 0 && CMTimeCompare(CMTime(value: Int64(clip.startFrame), timescale: Int32(timeline.fps)), end) < 0
                    && CMTimeCompare(CMTime(value: Int64(clip.endFrame), timescale: Int32(timeline.fps)), start) > 0
            }
        }
    }

    nonisolated private static func originIdentity(url: URL, dataRoot: URL) -> String {
        let actual = url.standardizedFileURL.resolvingSymlinksInPath()
        let home = FrameInventory.projectHome(of: dataRoot).standardizedFileURL
        let root = dataRoot.standardizedFileURL
        if actual.path.hasPrefix(root.path + "/") { return "pipeline:" + String(actual.path.dropFirst(root.path.count + 1)) }
        if actual.path.hasPrefix(home.path + "/") { return "project:" + String(actual.path.dropFirst(home.path.count + 1)) }
        return "external:" + actual.path
    }

    nonisolated private static func rebase(resolver: MediaResolver, timeline: Timeline, from root: URL, to staging: URL) throws -> MediaResolver {
        let input = try readInputs(dataRoot: root, timeline: timeline, resolver: resolver)
        let urls = try Dictionary(uniqueKeysWithValues: input.sources.map {
            ($0.mediaID, try ProjectLocalFile.requireHash($0.frozen.sha256, at: $0.frozen.path, dataRoot: staging))
        })
        return resolver.snapshot(overriding: urls)
    }

    nonisolated private static func requireSourceSnapshots(_ sources: [SourceSnapshot], dataRoot: URL) throws {
        for source in sources {
            _ = try ProjectLocalFile.requireHash(source.frozen.sha256, at: source.frozen.path, dataRoot: dataRoot)
            let receipt = try source.receipt
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(receipt.sha256, at: receipt.path, dataRoot: dataRoot))
            guard try JSONDecoder().decode(SourceSnapshot.self, from: bytes) == source else { throw changed() }
        }
    }

    nonisolated private static func requireSnapshotFiles(_ value: Snapshot, dataRoot: URL) throws {
        for reference in [value.timeline, value.edl, value.reel] {
            _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        }
        guard value.timeline.sha256 == value.input.edl.timelineSHA256,
              try PlanningWriterIO.read(ProductionSequenceEDLV2.self, at: value.edl.path, dataRoot: dataRoot) == value.input.edl else { throw changed() }
    }

    nonisolated private static func nativeFinding(_ finding: SequenceReviewFindingV1) -> SequenceReviewFindingV1 {
        .init(id: finding.id, scope: finding.scope, category: finding.category, severity: finding.severity,
            shotIDs: finding.shotIDs, startFrame: finding.startFrame, endFrame: finding.endFrame, evidence: finding.evidence,
            recommendedAction: finding.recommendedAction, provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
    }

    nonisolated private static func archiveReference(_ bytes: Data) -> CanonicalArtifactReferenceV1 {
        PlanningWriterIO.reference("reviews/sequence/archive/" + FileDigest.sha256(of: bytes) + ".v2.json",
            id: "production-film-review", role: "host.production-sequence-review", bytes: bytes)
    }

    nonisolated private static func writeImmutable(_ bytes: Data, reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws {
        _ = try ProjectLocalFile.ensureDirectory((reference.path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
        let destination = dataRoot.appendingPathComponent(reference.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == bytes else { throw changed() }
        } else { try bytes.write(to: destination, options: .atomic) }
    }

    nonisolated private static func unique(_ refs: [CanonicalArtifactReferenceV1]) throws -> [CanonicalArtifactReferenceV1] {
        var result: [String: CanonicalArtifactReferenceV1] = [:]
        for ref in refs {
            if let previous = result[ref.path] { guard previous.sha256 == ref.sha256 else { throw changed() } }
            else { result[ref.path] = ref }
        }
        return result.values.sorted { $0.path < $1.path }
    }

    nonisolated private static func timelineHash(_ timeline: Timeline) throws -> String { FileDigest.sha256(of: try PlanningWriterIO.json(timeline)) }
    nonisolated private static func changed() -> GateBlocked { GateBlocked("The film, its production sources or its output range changed. Build and review the current film again.") }
    nonisolated private static func background<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
