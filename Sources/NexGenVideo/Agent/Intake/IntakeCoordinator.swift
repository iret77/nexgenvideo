import Foundation
import NexGenEngine

/// Which hard steps of a phase are still worth putting in front of the user. Pure — filesystem +
/// ledger in, ordered steps out — so the selection rule is testable without an editor or a pack.
enum IntakePlanner {

    /// Unsatisfied, not-yet-declined steps of `phase`, in the order the pack declared them.
    static func pending(_ steps: [HardStep], dataRoot: URL, ledger: IntakeLedger) -> [HardStep] {
        steps.filter { !ledger.isDeclined($0.id) && !IntakeSatisfaction.isSatisfied($0.kind, dataRoot: dataRoot) }
    }

    static func next(_ steps: [HardStep], dataRoot: URL, ledger: IntakeLedger) -> HardStep? {
        pending(steps, dataRoot: dataRoot, ledger: ledger).first
    }
}

/// Turns a phase's hard steps into dock dialogs, one at a time, before the agent works on the phase.
///
/// The trigger is the WORKFLOW's, not the agent's: a duty that lives only in a phase doc eventually
/// goes unasked (#254 — `import/characters/` stayed empty because nobody asked, not because the user
/// had nothing). Nothing here writes intake; `AgentService.submitDialog` already does that.
@MainActor
final class IntakeCoordinator {

    /// The step currently in the dock, with the material count at the moment it was offered. If the
    /// count hasn't moved by the next pass, the user confirmed with nothing — that's the decline.
    private var offered: (step: HardStep, fingerprint: Int)?
    private var manifestCache: [String: HardStepManifest] = [:]

    /// Called whenever the app re-reads engine state — i.e. whenever the pipeline may have advanced.
    /// Cheap and idempotent: every exit below leaves the dock exactly as it found it.
    func advance(editor: EditorViewModel) {
        let service = editor.agentService
        // Exactly one pending dialog is the locked dock rule; a spend approval owns the dock too.
        guard service.pendingDialog == nil, service.pendingSpendApproval == nil else { return }
        // Mid-turn refreshes come from tool calls; the turn-end refresh (isStreaming true→false, which
        // fires AFTER the flag clears) picks the step up instead, so nothing is lost by waiting.
        guard !service.isStreaming else { return }
        guard let packName = editor.activePluginName,
              let workingRoot = editor.workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: workingRoot),
              let phase = editor.projectState?.nextPhaseName
        else { return }
        // Resolve the outstanding offer FIRST — before any phase-dependent exit below, so an offer can
        // never outlive the phase it was made in and get answered against a later one's files.
        var ledger = IntakeLedger.load(dataRoot: dataRoot)
        var repeatStep: HardStep?
        if let previous = offered {
            offered = nil
            let now = IntakeSatisfaction.fingerprint(previous.step.kind, dataRoot: dataRoot)
            if now == previous.fingerprint {
                // Nothing arrived — an explicit "I don't have one". Required steps can't be declined,
                // so they simply stay pending and are offered again below.
                ledger = IntakeLedger.recordDecline(previous.step, dataRoot: dataRoot)
            } else if previous.step.repeatable, previous.step.phase == phase {
                repeatStep = previous.step
            }
        }

        guard let manifest = manifest(packName: packName) else { return }
        // One identity per dialog: keep offering until the user turns the next one down.
        if let repeatStep {
            present(repeatStep, isRepeat: true, dataRoot: dataRoot, editor: editor)
            return
        }
        guard let step = IntakePlanner.next(manifest.steps(for: phase), dataRoot: dataRoot, ledger: ledger) else {
            return
        }
        present(step, isRepeat: false, dataRoot: dataRoot, editor: editor)
    }

    /// Forget in-flight state when the open project changes — a step offered in the previous project
    /// must never be resolved against the new one's files.
    func reset() { offered = nil }

    private func present(_ step: HardStep, isRepeat: Bool, dataRoot: URL, editor: EditorViewModel) {
        offered = (step, IntakeSatisfaction.fingerprint(step.kind, dataRoot: dataRoot))
        editor.agentService.pendingDialog = AgentDialog(hardStep: step, isRepeat: isRepeat)
        editor.agentPanelVisible = true
    }

    private func manifest(packName: String) -> HardStepManifest? {
        if let hit = manifestCache[packName] { return hit }
        guard let pack = PackCatalog.pack(named: packName),
              let loaded = HardStepManifest.load(pack: pack) else { return nil }
        manifestCache[packName] = loaded
        return loaded
    }
}

extension AgentDialog {

    /// The dock card for a hard step. A fresh `id` per presentation so a repeat offer is a new card.
    init(hardStep step: HardStep, isRepeat: Bool) {
        self.init(
            id: "hardstep.\(step.id).\(UUID().uuidString)",
            title: step.title,
            symbol: step.symbol,
            intro: isRepeat ? (step.addAnotherLabel ?? step.intro) : step.intro,
            costHint: nil,
            confirmLabel: step.confirmLabel,
            textField: step.textField,
            sections: [],
            fileIntake: FileIntake(
                accept: step.accept,
                prompt: step.prompt,
                allowsMultiple: step.multiple,
                attachAs: step.attachAs,
                namePrompt: step.namePrompt,
                required: step.required
            )
        )
    }
}
