import Foundation
import NexGenEngine
import Observation

struct StoryboardReviewSnapshot: Sendable {
    let storyboard: Storyboard
    let bytes: Data

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
        return Self(storyboard: storyboard, bytes: bytes)
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

@MainActor @Observable
final class GateReviewModel {
    private(set) var isReady = false
    private(set) var blocker: String? = "Checking the current phase…"
    private(set) var storyboard: Storyboard?
    private var generation = 0

    func refresh(approval: GateApproval, editor: EditorViewModel) async {
        generation += 1
        let token = generation
        isReady = false
        storyboard = nil
        blocker = "Checking the current phase…"
        guard let root = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: root),
              approval.dataRoot?.standardizedFileURL == dataRoot.standardizedFileURL,
              approval.declaredPack == editor.declaredPluginName,
              approval.declaredBinding == editor.declaredPluginBinding else {
            blocker = "This request no longer belongs to the current project. Request a new approval."
            return
        }
        var snapshot: StoryboardReviewSnapshot?
        if approval.phase == "storyboard" {
            do {
                snapshot = try await Task.detached(priority: .utility) {
                    try StoryboardReviewSnapshot.read(root: dataRoot)
                }.value
            } catch {
                guard token == generation else { return }
                blocker = error.localizedDescription
                return
            }
        }
        let readiness = await NativeGateWriter.controlReadiness(
            projectDir: root,
            phase: approval.phase,
            declaredPack: approval.declaredPack,
            declaredBinding: approval.declaredBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator
        )
        guard token == generation, !Task.isCancelled else { return }
        guard readiness.mutations.isReady, readiness.approval.isReady else {
            blocker = "\(approval.phaseLabel) is incomplete or no longer matches its approved source material. Ask the agent to update it."
            return
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
            storyboard = snapshot.storyboard
        }
        guard editor.workingRoot == root,
              editor.declaredPluginBinding == approval.declaredBinding else {
            blocker = "The project changed. Request a new approval."
            return
        }
        isReady = true
        blocker = nil
    }
}
