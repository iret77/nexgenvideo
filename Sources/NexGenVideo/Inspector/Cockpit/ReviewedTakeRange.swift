import Foundation
import NexGenEngine

struct ReviewedTakeRange: Codable, Sendable, Equatable {
    struct Stored: Identifiable, Sendable {
        let id: String
        let review: ReviewedTakeRange
    }
    struct Placement: Codable, Sendable {
        let schema: String
        let reviewID: String
        let source: RenderPublishedArtifactV1
        let fps: Int
        let clips: [Clip]
        let recordedAt: String
    }
    struct Range: Codable, Sendable, Equatable {
        let startFrame: Int
        let endFrame: Int
        let fps: Int
        var durationSeconds: Double { Double(endFrame - startFrame) / Double(fps) }

        func validate(sourceDuration: Double) throws {
            guard fps > 0, fps <= Int(Int32.max), startFrame >= 0, endFrame > startFrame,
                  sourceDuration.isFinite, sourceDuration > 0,
                  sourceDuration <= Double(Int.max / 2) / Double(fps),
                  Double(endFrame) / Double(fps) <= sourceDuration else {
                throw ToolError("Choose a nonempty source range inside the take at the timeline frame rate.")
            }
        }
    }
    let schema: String
    let takeID: String
    let source: RenderPublishedArtifactV1
    let range: Range
    let sourceDurationValue: Int64
    let sourceDurationTimescale: Int32
    let reviewer: String
    let findings: [TakeReview.Finding]
    let reviewedAt: String

    static func path(id: String) -> String { "renders/coverage/\(id).v1.json" }

    static func saved(takeID: String, home: URL) async throws -> [Stored] {
        try await Task.detached(priority: .utility) {
            guard let root = DataRootResolver.dataRoot(of: home) else { throw ToolError("The range review project is unavailable.") }
            let directory = root.appendingPathComponent("renders/coverage")
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            guard directory.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent("renders/coverage") else {
                throw ToolError("Range reviews cannot traverse symbolic links.")
            }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".v1.json") }
                .compactMap { url -> Stored? in
                    let id = String(url.lastPathComponent.dropLast(".v1.json".count))
                    let record = try load(id: id, dataRoot: root)
                    return record.takeID == takeID ? Stored(id: id, review: record) : nil
                }.sorted { $0.review.reviewedAt > $1.review.reviewedAt }
        }.value
    }

    func validate() throws {
        guard schema == "reviewed-take-range/v1", reviewer == "native-user", sourceDurationTimescale > 0 else {
            throw ToolError("The source-range review has invalid provenance.")
        }
        try range.validate(sourceDuration: Double(sourceDurationValue) / Double(sourceDurationTimescale))
        try TakeReview.validate(findings, duration: range.durationSeconds)
        guard findings.count == TakeReview.Pass.allCases.count, findings.allSatisfy({ $0.verdict != .rejected }) else {
            throw ToolError("Review and accept all six passes for this range. The whole take's review does not approve a range.")
        }
    }

    static func load(id: String, dataRoot: URL) throws -> Self {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ToolError("Invalid source-range review identity.")
        }
        let url = try ProjectLocalFile.requireHash(id, at: path(id: id), dataRoot: dataRoot)
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try record.validate()
        let take = try PipelineRenderTakeStore.take(id: record.takeID, dataRoot: dataRoot)
        guard record.source == take.output else { throw ToolError("The reviewed range does not belong to its take.") }
        return record
    }

    @MainActor
    static func save(snapshot: TakeReview.Snapshot, range: Range, findings: [TakeReview.Finding], editor: EditorViewModel) async throws -> String {
        let refreshed = try await TakeReview.capture(takeID: snapshot.take.id, home: snapshot.home)
        guard refreshed.take == snapshot.take, refreshed.durationValue == snapshot.durationValue,
              refreshed.durationTimescale == snapshot.durationTimescale, editor.workingRoot == snapshot.home,
              range.fps == editor.timeline.fps,
              let root = DataRootResolver.dataRoot(of: snapshot.home), let key = editor.openWorkingCopyKey else {
            throw ToolError("The take or active project changed. Review the current source again.")
        }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Record source-range review") else {
            throw ToolError("Wait for the active pipeline operation before saving the range review.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: snapshot.home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        let record = Self(schema: "reviewed-take-range/v1", takeID: snapshot.take.id, source: snapshot.take.output,
            range: range, sourceDurationValue: snapshot.durationValue, sourceDurationTimescale: snapshot.durationTimescale,
            reviewer: "native-user", findings: findings, reviewedAt: currentTimestamp())
        try record.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        let id = FileDigest.sha256(of: bytes)
        let target = root.appendingPathComponent(path(id: id))
        try ProjectWorkingCopy.markDirty(key: key)
        try ArtifactTransaction.perform(paths: [target], dataRoot: root) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == bytes else { throw ToolError("An immutable range review has different bytes.") }
            } else { try bytes.write(to: target, options: .atomic) }
        }
        editor.onPipelineChanged?()
        return id
    }

    @MainActor
    static func addToTimeline(id: String, home: URL, includeAudio: Bool, editor: EditorViewModel) async throws {
        guard editor.workingRoot == home, let root = DataRootResolver.dataRoot(of: home) else { throw ToolError("Open the range's project before adding it.") }
        let review = try load(id: id, dataRoot: root)
        let timeline = editor.timeline
        let start = editor.activeFrame
        guard timeline.fps == review.range.fps, start >= 0,
              start <= Int.max - (review.range.endFrame - review.range.startFrame) else {
            throw ToolError("The timeline frame rate changed. Review the range at the current frame rate before placing it.")
        }
        let snapshot = try await TakeReview.capture(takeID: review.takeID, home: home)
        guard snapshot.take.output == review.source, snapshot.durationValue == review.sourceDurationValue,
              snapshot.durationTimescale == review.sourceDurationTimescale else { throw ToolError("The reviewed source changed. Inspect the current take again.") }
        let asset = try await TakeReview.retainedAsset(snapshot: snapshot, editor: editor)
        let confirmed = try await TakeReview.capture(takeID: review.takeID, home: home)
        guard confirmed.take == snapshot.take, confirmed.durationValue == snapshot.durationValue,
              confirmed.durationTimescale == snapshot.durationTimescale else { throw ToolError("The range source changed before placement.") }
        guard editor.workingRoot == home, editor.timeline == timeline, let key = editor.openWorkingCopyKey,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Add reviewed source range") else {
            throw ToolError("The timeline or pipeline operation changed. Add the reviewed range again when it is idle.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        guard try load(id: id, dataRoot: root) == review else { throw ToolError("The immutable range review changed.") }
        try ProjectWorkingCopy.markDirty(key: key)
        try editor.withTimelineSwap(actionName: "Add Reviewed Range") {
            let track = editor.insertTrack(at: 0, type: .video)
            let ids = editor.placeClip(asset: asset, trackIndex: track, startFrame: start,
                durationFrames: review.range.endFrame - review.range.startFrame, addLinkedAudio: includeAudio,
                trimStartFrame: review.range.startFrame,
                trimEndFrame: max(0, secondsToFrame(seconds: snapshot.durationSeconds, fps: review.range.fps) - review.range.endFrame))
            let clips = editor.timeline.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
            guard !clips.isEmpty else { throw ToolError("The reviewed range could not be placed.") }
            let placement = Placement(schema: "reviewed-range-placement/v1", reviewID: id, source: review.source,
                fps: review.range.fps, clips: clips, recordedAt: currentTimestamp())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(placement)
            let target = root.appendingPathComponent("renders/coverage/placements/\(FileDigest.sha256(of: bytes)).v1.json")
            try ArtifactTransaction.perform(paths: [target], dataRoot: root) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try Data(contentsOf: target) == bytes else { throw ToolError("An immutable range placement has different bytes.") }
                } else { try bytes.write(to: target, options: .atomic) }
            }
            editor.selectedClipIds = Set(ids)
        }
    }
}
