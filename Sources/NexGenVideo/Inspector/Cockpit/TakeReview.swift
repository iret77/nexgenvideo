import AVFoundation
import Foundation
import NexGenEngine

struct TakeReview: Codable, Sendable, Equatable {
    enum Pass: String, Codable, Sendable, CaseIterable {
        case identity, continuity, timing, camera, audio, style
        var label: String {
            switch self {
            case .identity: String(localized: "Identity")
            case .continuity: String(localized: "Continuity")
            case .timing: String(localized: "Timing")
            case .camera: String(localized: "Camera")
            case .audio: String(localized: "Audio")
            case .style: String(localized: "Style")
            }
        }
    }
    enum Verdict: String, Codable, Sendable { case conforms, acceptedDeviation, rejected, notApplicable }
    struct Finding: Codable, Sendable, Equatable {
        let pass: Pass
        let verdict: Verdict
        let observation: String
        let startSeconds: Double
        let endSeconds: Double
    }
    struct Snapshot: Sendable {
        let home: URL
        let take: PipelineRenderTakeV1
        let mediaURL: URL
        let durationValue: Int64
        let durationTimescale: Int32
        let referenceImages: [RenderInputProof]
        var durationSeconds: Double { Double(durationValue) / Double(durationTimescale) }
    }
    let schema: String
    let takeID: String
    let outputSHA256: String
    let durationValue: Int64
    let durationTimescale: Int32
    let reviewer: String
    let findings: [Finding]
    let reviewedAt: String

    var accepted: Bool { findings.count == Pass.allCases.count && findings.allSatisfy { $0.verdict != .rejected } }
    static func path(takeID: String) -> String { "renders/takes/reviews/\(takeID)/current.v1.json" }

    static func capture(takeID: String, home: URL) async throws -> Snapshot {
        try await Task.detached(priority: .userInitiated) {
            guard let root = DataRootResolver.dataRoot(of: home) else { throw ToolError("Open the take's project before reviewing it.") }
            let take = try PipelineRenderTakeStore.take(id: takeID, dataRoot: root)
            let proof = try JSONDecoder().decode(RenderShotProvenanceProofV1.self,
                from: Data(contentsOf: ProjectLocalFile.requireHash(take.provenance.sha256, at: take.provenance.path, dataRoot: root)))
            let references = [proof.renderProofEntry?.startFrame, proof.renderProofEntry?.endFrame].compactMap { $0 }
                + (proof.renderProofEntry?.referenceImages ?? [])
            for reference in references {
                _ = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: home)
            }
            let url = try ProjectLocalFile.resolve(take.output.path, dataRoot: home)
            guard try FileDigest.sha256(of: url) == take.output.sha256 else { throw ToolError("The take's media bytes changed. Restore its original output before review.") }
            let duration = try await AVURLAsset(url: url).load(.duration)
            guard duration.isNumeric, duration.value > 0, duration.timescale > 0 else { throw ToolError("The take has no finite playable duration.") }
            return Snapshot(home: home, take: take, mediaURL: url, durationValue: duration.value, durationTimescale: duration.timescale,
                referenceImages: references)
        }.value
    }

    static func validate(_ findings: [Finding], duration: Double) throws {
        guard !findings.isEmpty, findings.map(\.pass) == Array(Pass.allCases.prefix(findings.count)),
              findings.count == Pass.allCases.count || findings.last?.verdict == .rejected,
              duration.isFinite, duration > 0 else {
            throw ToolError("Review the six passes in order: identity, continuity, timing, camera, audio and style.")
        }
        for finding in findings {
            guard !finding.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(finding.pass == .identity && [.acceptedDeviation, .notApplicable].contains(finding.verdict)),
                  finding.startSeconds.isFinite, finding.endSeconds.isFinite,
                  finding.startSeconds >= 0, finding.endSeconds > finding.startSeconds,
                  finding.endSeconds <= duration else { throw ToolError("Every review pass needs an observation and a valid range within the take.") }
        }
    }

    static func load(take: PipelineRenderTakeV1, dataRoot: URL) throws -> Self? {
        let target = path(takeID: take.id)
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(target).path) else { return nil }
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(target, dataRoot: dataRoot))
        let review = try JSONDecoder().decode(Self.self, from: bytes)
        guard review.schema == "take-review/v1", review.takeID == take.id, review.outputSHA256 == take.output.sha256,
              review.durationTimescale > 0, review.reviewer == "native-user" else { throw ToolError("The take review does not match its source.") }
        try validate(review.findings, duration: Double(review.durationValue) / Double(review.durationTimescale))
        let archived = "renders/takes/reviews/\(take.id)/\(FileDigest.sha256(of: bytes)).v1.json"
        guard try Data(contentsOf: ProjectLocalFile.resolve(archived, dataRoot: dataRoot)) == bytes else {
            throw ToolError("The current take review has no matching immutable record.")
        }
        return review
    }

    static func requireSelected(dataRoot: URL, phase: String) throws {
        let manifest = try loadRenderManifest(dataRoot: dataRoot, phase: phase)
        let index = try PipelineRenderTakeStore.load(dataRoot: dataRoot, project: manifest.project, phase: phase)
        let recordedShots = try Set(index.takeIDs.map { try PipelineRenderTakeStore.take(id: $0, dataRoot: dataRoot).shotID })
        let home = FrameInventory.projectHome(of: dataRoot)
        for (shotID, entry) in manifest.entries where recordedShots.contains(shotID) && entry.status == .rendered {
            guard let id = index.selected[shotID] else { throw GateBlocked("Select a recorded take for \(shotID) before approving Render.") }
            let take = try PipelineRenderTakeStore.take(id: id, dataRoot: dataRoot)
            guard take.output.path == entry.output,
                  try FileDigest.sha256(of: ProjectLocalFile.resolve(take.output.path, dataRoot: home)) == take.output.sha256,
                  let review = try load(take: take, dataRoot: dataRoot), review.accepted else {
                throw GateBlocked("Review the selected take for \(shotID). Unreviewed, changed or rejected media cannot pass Render approval.")
            }
        }
    }

    @MainActor
    static func select(take: PipelineRenderTakeV1, home: URL, editor: EditorViewModel) async throws {
        guard editor.workingRoot == home, let root = DataRootResolver.dataRoot(of: home),
              let review = try load(take: take, dataRoot: root), review.accepted else {
            throw ToolError("Review the take before selecting it in the active project.")
        }
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        if !editor.mediaAssets.contains(where: { $0.id == take.generationEventID }) {
            let source = try await capture(takeID: take.id, home: home)
            let asset = MediaAsset(id: take.generationEventID, url: source.mediaURL, type: .video,
                name: "\(take.shotID) · \(take.phase) take", duration: source.durationSeconds, generationInput: take.generationInput)
            await asset.loadMetadata()
            guard editor.workingRoot == home, let key = editor.openWorkingCopyKey,
                  editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil else {
                throw ToolError("The project or pipeline operation changed. Select the take again when Render is idle.")
            }
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
            try PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
                declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
            if !editor.mediaAssets.contains(where: { $0.id == take.generationEventID }) {
                try ProjectWorkingCopy.markDirty(key: key)
                editor.importMediaAsset(asset)
            }
        }
        let proof = try JSONDecoder().decode(RenderShotProvenanceProofV1.self,
            from: Data(contentsOf: ProjectLocalFile.requireHash(take.provenance.sha256, at: take.provenance.path, dataRoot: root)))
        let result = await ToolExecutor(editor: editor).execute(name: ToolName.recordRender.rawValue, args: [
            "project_dir": root.path, "phase": take.phase, "shot_id": take.shotID,
            "output": take.generationEventID, "expected_take_id": take.id, "cost_eur": proof.renderEntry.costEur,
        ])
        if result.isError {
            throw ToolError(result.content.compactMap { block in
                if case .text(let text) = block { return text }; return nil
            }.joined(separator: "\n"))
        }
    }

    @MainActor
    static func save(snapshot: Snapshot, findings: [Finding], editor: EditorViewModel) async throws {
        guard editor.workingRoot == snapshot.home, let root = DataRootResolver.dataRoot(of: snapshot.home),
              let key = editor.openWorkingCopyKey else { throw ToolError("The active project changed. Reopen the take review.") }
        try validate(findings, duration: snapshot.durationSeconds)
        let refreshed = try await capture(takeID: snapshot.take.id, home: snapshot.home)
        guard refreshed.take == snapshot.take, refreshed.durationValue == snapshot.durationValue,
              refreshed.durationTimescale == snapshot.durationTimescale, editor.workingRoot == snapshot.home else {
            throw ToolError("The take changed during review. Inspect the current source again.")
        }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Record take review") else {
            throw ToolError("Wait for the active pipeline operation before recording the review.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        _ = try ProjectPackGate.requireLiveMutation(projectURL: snapshot.home, declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        try PipelinePhaseAccess.requireCurrentPhaseAndIntake("render", dataRoot: root,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding)
        let review = Self(schema: "take-review/v1", takeID: snapshot.take.id, outputSHA256: snapshot.take.output.sha256,
            durationValue: snapshot.durationValue, durationTimescale: snapshot.durationTimescale,
            reviewer: "native-user", findings: findings, reviewedAt: currentTimestamp())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(review)
        let current = root.appendingPathComponent(path(takeID: snapshot.take.id))
        let archive = current.deletingLastPathComponent().appendingPathComponent(FileDigest.sha256(of: bytes) + ".v1.json")
        try ProjectWorkingCopy.markDirty(key: key)
        try ArtifactTransaction.perform(paths: [current, archive], dataRoot: root) {
            try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: archive.path) {
                guard try Data(contentsOf: archive) == bytes else { throw ToolError("An immutable review record has different bytes.") }
            } else { try bytes.write(to: archive, options: .atomic) }
            try bytes.write(to: current, options: .atomic)
        }
        editor.onPipelineChanged?()
    }
}
