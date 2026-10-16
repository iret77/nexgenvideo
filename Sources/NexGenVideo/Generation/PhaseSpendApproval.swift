import Foundation
import NexGenEngine
import Observation

/// The user's single approval for every paid agent run of one pipeline phase in one project. Only
/// the native approval cards grant it; no agent tool can create, extend or read it as a setting.
struct PhaseSpendApproval: Equatable, Sendable {
    struct Run: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let detail: String
        let at: Date
    }

    let projectKey: String
    let phase: String
    let grantedAt: Date
    /// Every gate's approval plus the phase's own verdict at grant time; any approval, rewind or
    /// revision request changes it.
    let gateFingerprint: String
    var runs: [Run]
    /// Tells this grant apart from a later grant for the same phase.
    let id = UUID()
}

/// The exact grant an automatic start relied on no longer covers its phase.
struct PhaseSpendApprovalEnded: LocalizedError {
    var errorDescription: String? { "The phase approval ended before this run started." }
}

/// Where a granted phase approval lives between uses. Host-side persistence (surviving relaunch,
/// never travelling with a copied project) waits on a docs/PROJECT_STORAGE.md decision, so the only
/// implementation keeps the grant for the running session.
@MainActor
protocol PhaseSpendApprovalStorage: AnyObject {
    func load(projectKey: String) -> PhaseSpendApproval?
    func save(_ approval: PhaseSpendApproval?, projectKey: String)
}

@MainActor
final class SessionPhaseSpendApprovalStorage: PhaseSpendApprovalStorage {
    private var approvals: [String: PhaseSpendApproval] = [:]

    func load(projectKey: String) -> PhaseSpendApproval? { approvals[projectKey] }

    func save(_ approval: PhaseSpendApproval?, projectKey: String) {
        approvals[projectKey] = approval
    }
}

@MainActor
@Observable
final class PhaseSpendApprovalController {
    private(set) var current: PhaseSpendApproval?
    private let storage: PhaseSpendApprovalStorage

    init(storage: PhaseSpendApprovalStorage) {
        self.storage = storage
    }

    convenience init() {
        self.init(storage: SessionPhaseSpendApprovalStorage())
    }

    /// Grants the approval for the phase the pipeline is currently in. Called only from the native
    /// approval cards in response to the user's click.
    @discardableResult
    func grant(phase: String, editor: EditorViewModel, at date: Date = Date()) -> PhaseSpendApproval? {
        guard let projectKey = editor.projectId,
              let dataRoot = Self.dataRoot(editor: editor),
              let fingerprint = Self.gateFingerprint(dataRoot: dataRoot, phase: phase),
              Self.phaseIsOpen(phase, dataRoot: dataRoot) else { return nil }
        let approval = PhaseSpendApproval(projectKey: projectKey, phase: phase, grantedAt: date,
            gateFingerprint: fingerprint, runs: [])
        storage.save(approval, projectKey: projectKey)
        current = approval
        return approval
    }

    /// The approval that covers `phase` right now, or nil. An approval that no longer matches the
    /// project's gates ends here and never comes back.
    func active(phase: String?, editor: EditorViewModel) -> PhaseSpendApproval? {
        guard let phase, let approval = load(editor: editor) else { return nil }
        guard isValid(approval, editor: editor) else {
            end(editor: editor)
            return nil
        }
        return approval.phase == phase ? approval : nil
    }

    /// True only while this exact grant still covers its phase; a later re-grant does not count.
    func isActive(_ grant: PhaseSpendApproval, editor: EditorViewModel) -> Bool {
        active(phase: grant.phase, editor: editor)?.id == grant.id
    }

    func withdraw(editor: EditorViewModel) {
        end(editor: editor)
    }

    /// Ends an approval once its phase was approved or rewound or the project moved to another phase.
    func reconcile(editor: EditorViewModel) {
        guard let approval = load(editor: editor) else {
            current = nil
            return
        }
        if isValid(approval, editor: editor) {
            current = approval
        } else {
            end(editor: editor)
        }
    }

    func recordRun(label: String, detail: String, editor: EditorViewModel, at date: Date = Date()) {
        guard var approval = load(editor: editor) else { return }
        approval.runs.append(.init(id: UUID().uuidString, label: label, detail: detail, at: date))
        storage.save(approval, projectKey: approval.projectKey)
        current = approval
    }

    private func load(editor: EditorViewModel) -> PhaseSpendApproval? {
        guard let projectKey = editor.projectId else {
            current = nil
            return nil
        }
        return storage.load(projectKey: projectKey)
    }

    private func end(editor: EditorViewModel) {
        if let projectKey = editor.projectId { storage.save(nil, projectKey: projectKey) }
        current = nil
    }

    private func isValid(_ approval: PhaseSpendApproval, editor: EditorViewModel) -> Bool {
        guard approval.projectKey == editor.projectId,
              let dataRoot = Self.dataRoot(editor: editor),
              Self.gateFingerprint(dataRoot: dataRoot, phase: approval.phase) == approval.gateFingerprint else { return false }
        return Self.phaseIsOpen(approval.phase, dataRoot: dataRoot)
    }

    private static func dataRoot(editor: EditorViewModel) -> URL? {
        editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
    }

    private static func phaseIsOpen(_ phase: String, dataRoot: URL) -> Bool {
        guard let gates = try? YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile) else {
            return false
        }
        return !gates.get(phase).approved
    }

    static func gateFingerprint(dataRoot: URL, phase: String) -> String? {
        guard let gates = try? YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile) else {
            return nil
        }
        let chain = gates.gates.keys.sorted().map { key -> String in
            let gate = gates.get(key)
            return key + "=" + (gate.approved ? (gate.approvedAt ?? "approved") : "-")
        }
        let own = gates.get(phase)
        let verdict = "\(phase):\(own.state.rawValue):\(own.notes ?? "")"
        return FileDigest.sha256(of: Data((chain + [verdict]).joined(separator: "\n").utf8))
    }
}
