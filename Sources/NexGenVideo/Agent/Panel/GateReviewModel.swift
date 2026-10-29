import Foundation
import NexGenEngine
import Observation

struct StoryboardReviewSnapshot: Sendable, Equatable {
    let storyboard: Storyboard
    let bytes: Data
    let sha256: String

    static func read(root: URL) throws -> Self {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(PipelineLayout.storyboardCurrentFile)
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else {
            throw ReviewError.unreadable
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReviewError.missing
        }
        guard let bytes = try? Data(contentsOf: url),
              let text = String(data: bytes, encoding: .utf8),
              let storyboard = try? YAMLCoding.decode(Storyboard.self, from: text) else {
            throw ReviewError.unreadable
        }
        return Self(storyboard: storyboard, bytes: bytes, sha256: FileDigest.sha256(of: bytes))
    }

    enum ReviewError: LocalizedError {
        case missing, unreadable
        var errorDescription: String? {
            switch self {
            case .missing: "The storyboard is missing. Ask the agent to create it before approving."
            case .unreadable: "The storyboard could not be read. Ask the agent to repair it before approving."
            }
        }
    }
}

/// How the storyboard on screen relates to the open approval request.
enum StoryboardReviewBinding: String, Sendable {
    case unrelated
    case current
    /// Also covers a storyboard that vanished or became unreadable after the request.
    case changed

    static func resolve(approval: GateApproval?, dataRoot: URL, shown: StoryboardReviewSnapshot?) -> Self {
        guard let approval, approval.phase == "storyboard", !approval.isRewind,
              approval.dataRoot?.standardizedFileURL.path == dataRoot.standardizedFileURL.path else { return .unrelated }
        guard let shown, let fingerprint = approval.artifactFingerprint,
              fingerprint.path == PipelineLayout.storyboardCurrentFile,
              shown.sha256 == fingerprint.sha256,
              fingerprint.matches(dataRoot: dataRoot) else { return .changed }
        return .current
    }
}

@MainActor @Observable
final class GateReviewModel {
    private(set) var isReady = false
    private(set) var readyApprovalID: String?
    private(set) var blocker: String?
    private var generation = 0
    private(set) var isChecking = true

    func refresh(approval: GateApproval, editor: EditorViewModel) async {
        generation += 1
        let token = generation
        isChecking = true
        defer { if token == generation { isChecking = false } }
        isReady = false
        readyApprovalID = nil
        blocker = nil
        guard let root = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: root),
              approval.dataRoot?.standardizedFileURL == dataRoot.standardizedFileURL,
              approval.declaredPack == editor.declaredPluginName,
              approval.declaredBinding == editor.declaredPluginBinding,
              approval.declaredProductionContract == editor.declaredProductionContract else {
            blocker = "This request no longer belongs to the current project. Request a new approval."
            return
        }
        if case .rewind(let expectedHash, _) = approval.action {
            let readiness = await NativeGateWriter.controlReadiness(projectDir: root,
                phase: approval.phase, declaredPack: approval.declaredPack,
                declaredBinding: approval.declaredBinding,
                declaredProductionContract: approval.declaredProductionContract,
                editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator)
            let currentHash = try? FileDigest.sha256(of: PipelineLayout.url(PipelineLayout.gatesFile, in: dataRoot))
            guard token == generation, editor.workingRoot == root, !Task.isCancelled else { return }
            isReady = readiness.mutations.isReady && currentHash == expectedHash
            readyApprovalID = isReady ? approval.id : nil
            blocker = isReady ? nil : "The pipeline changed or is busy. Request a new revision decision."
            return
        }
        if let fingerprint = approval.artifactFingerprint, !fingerprint.matches(dataRoot: dataRoot) {
            blocker = "This revision changed. Request a new approval for the updated artifact."
            return
        }
        let workflow: HostWorkflowKey?
        do {
            workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot,
                expectedPack: approval.declaredBinding, expectedProductionContract: approval.declaredProductionContract)
        } catch { blocker = error.localizedDescription; return }
        var visualStoryboardFingerprint: String?
        var snapshot: StoryboardReviewSnapshot?
        if approval.phase == "storyboard", workflow?.isProductionV2 == true {
            do {
                visualStoryboardFingerprint = try await Task.detached(priority: .utility) {
                    try PlanningWriterIO.storyboard(dataRoot: dataRoot).fingerprint
                }.value
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                blocker = error.localizedDescription
                return
            }
        } else if approval.phase == "storyboard" {
            do {
                snapshot = try await Task.detached(priority: .utility) {
                    try StoryboardReviewSnapshot.read(root: dataRoot)
                }.value
            } catch {
                guard token == generation else { return }
                blocker = error.localizedDescription
                return
            }
            guard token == generation, !Task.isCancelled else { return }
            guard StoryboardReviewBinding.resolve(approval: approval, dataRoot: dataRoot, shown: snapshot) == .current else {
                blocker = "This revision changed. Request a new approval for the updated artifact."
                return
            }
        }
        let readiness = await NativeGateWriter.controlReadiness(
            projectDir: root,
            phase: approval.phase,
            declaredPack: approval.declaredPack,
            declaredBinding: approval.declaredBinding,
            declaredProductionContract: approval.declaredProductionContract,
            editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator
        )
        guard token == generation, !Task.isCancelled else { return }
        guard readiness.mutations.isReady, readiness.approval.isReady else {
            blocker = readiness.approval.userMessage
                ?? "\(approval.phaseLabel) is incomplete or no longer matches its approved source material. Ask the agent to update it."
            return
        }
        if let visualStoryboardFingerprint {
            let current = try? await Task.detached(priority: .utility) {
                try PlanningWriterIO.storyboard(dataRoot: dataRoot).fingerprint
            }.value
            guard token == generation, !Task.isCancelled else { return }
            guard current == visualStoryboardFingerprint else {
                blocker = "The visual Storyboard changed during review. Open the current revision before approving."
                return
            }
        }
        if let snapshot {
            let current = try? await Task.detached(priority: .utility) {
                try StoryboardReviewSnapshot.read(root: dataRoot)
            }.value
            guard token == generation, !Task.isCancelled else { return }
            guard current?.bytes == snapshot.bytes else {
                blocker = "The storyboard changed during review. Open it again before approving."
                return
            }
        }
        guard editor.workingRoot == root,
              editor.declaredPluginBinding == approval.declaredBinding,
              editor.declaredProductionContract == approval.declaredProductionContract else {
            blocker = "The project changed. Request a new approval."
            return
        }
        if let fingerprint = approval.artifactFingerprint, !fingerprint.matches(dataRoot: dataRoot) {
            blocker = "The artifact changed during validation. Request a new approval."
            return
        }
        readyApprovalID = approval.id
        isReady = true
        blocker = nil
    }
}
