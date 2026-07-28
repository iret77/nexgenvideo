import Foundation
import NexGenEngine

enum IntakePlanner {
    static func pending(
        _ steps: [HardStep],
        dataRoot: URL,
        ledger: IntakeLedger
    ) -> [HardStep] {
        steps.filter {
            !ledger.isDeclined($0.id)
                && !IntakeSatisfaction.isSatisfied($0.kind, dataRoot: dataRoot)
        }
    }

    static func next(
        _ steps: [HardStep],
        dataRoot: URL,
        ledger: IntakeLedger
    ) -> HardStep? {
        pending(steps, dataRoot: dataRoot, ledger: ledger).first
    }
}

@MainActor
enum PipelinePhaseAccess {
    private static var manifestCache: [String: HardStepManifest] = [:]

    struct Prepared: Sendable {
        let packName: String?
        let packPlacements: [PhasePlacement]
        let order: [String]
        let manifest: HardStepManifest?
    }

    static func prepare(
        dataRoot: URL,
        declaredPack: String? = nil
    ) throws -> Prepared {
        let projectURL = FrameInventory.projectHome(of: dataRoot)
        let packName: String?
        do {
            packName = try ProjectPluginSettings.resolvedPlugin(
                projectURL: projectURL,
                declaredPack: declaredPack
            )
        } catch {
            throw GateBlocked(error.localizedDescription)
        }
        guard let packName else {
            return Prepared(
                packName: nil,
                packPlacements: [],
                order: [],
                manifest: nil
            )
        }
        let registry = PackCatalog.registry(activePack: packName)
        return try prepare(
            packName: packName,
            registry: registry
        )
    }

    static func prepare(
        packName: String?,
        registry: EngineRegistry
    ) throws -> Prepared {
        guard let packName else {
            return Prepared(
                packName: nil,
                packPlacements: [],
                order: [],
                manifest: nil
            )
        }
        guard let pack = PackCatalog.pack(named: packName) else {
            throw GateBlocked(
                "The \(packName) workflow contract is unavailable. Reopen the project before continuing."
            )
        }
        let cacheKey = "\(pack.name)@\(pack.version)#\(PackCatalog.revision(named: pack.name))"
        let manifest: HardStepManifest
        if let cached = manifestCache[cacheKey] {
            manifest = cached
        } else {
            guard let loaded = HardStepManifest.load(pack: pack) else {
                throw GateBlocked(
                    "The \(packName) workflow contract is unavailable. Reopen the project before continuing."
                )
            }
            manifestCache = manifestCache.filter {
                !$0.key.hasPrefix("\(pack.name)@")
            }
            manifestCache[cacheKey] = loaded
            manifest = loaded
        }
        return Prepared(
            packName: packName,
            packPlacements: registry.phasePlacements,
            order: PhaseOrder.merged(packPlacements: registry.phasePlacements),
            manifest: manifest
        )
    }

    static func requireCurrentPhaseAndIntake(
        _ phase: String,
        dataRoot: URL,
        declaredPack: String? = nil
    ) throws {
        try requireCurrentPhaseAndIntake(
            phase,
            dataRoot: dataRoot,
            prepared: prepare(
                dataRoot: dataRoot,
                declaredPack: declaredPack
            )
        )
    }

    nonisolated static func requireCurrentPhaseAndIntake(
        _ phase: String,
        dataRoot: URL,
        prepared: Prepared
    ) throws {
        guard let packName = prepared.packName else { return }
        guard prepared.order.contains(phase) else {
            throw GateBlocked(
                "The \(packName) workflow has no registered phase named \"\(phase)\"."
            )
        }
        guard let manifest = prepared.manifest else {
            throw GateBlocked(
                "The \(packName) workflow contract is unavailable. Reopen the project before continuing."
            )
        }
        let snapshot: ProjectStateBuilder.ProjectState
        do {
            snapshot = try ProjectStateBuilder.buildSnapshot(
                dataRoot: dataRoot,
                packPlacements: prepared.packPlacements
            )
        } catch {
            throw GateBlocked(
                "The pipeline state is unreadable. Repair or restore the project before continuing: \(error)"
            )
        }
        guard snapshot.nextPhase == phase else {
            if let current = snapshot.nextPhase {
                throw GateBlocked(
                    "Can't work on \"\(phase)\" while \"\(current)\" is the current phase. "
                        + "Complete it first, or explicitly rewind the pipeline."
                )
            }
            throw GateBlocked(
                "Can't work on \"\(phase)\": every pipeline phase is already approved. "
                    + "Explicitly rewind the pipeline before changing an approved artifact."
            )
        }
        guard let step = IntakePlanner.next(
            manifest.steps(for: phase),
            dataRoot: dataRoot,
            ledger: IntakeLedger.load(dataRoot: dataRoot)
        ) else { return }
        throw GateBlocked(
            "Complete the host-owned \(step.title) card before working on \(PhaseDisplay.label(phase))."
        )
    }
}

@MainActor
final class PipelineAgentHarness {
    struct Reconciliation {
        let isReady: Bool
        let agentPrompt: String?
        let failure: String?

        static let blocked = Reconciliation(isReady: false, agentPrompt: nil, failure: nil)
    }

    private struct Context {
        let dataRoot: URL
        let packName: String
        let pack: any Pack
        let manifest: HardStepManifest
        let snapshot: ProjectStateBuilder.ProjectState

        var phase: String? { snapshot.nextPhase }

        var agentPrompt: String? {
            let progress = PackProgress(
                nextPhase: snapshot.nextPhase,
                approvedPhases: snapshot.phases.filter(\.approved).count,
                totalPhases: snapshot.phases.count
            )
            return pack.starters(for: progress).first?.prompt
        }
    }

    private var offered: (step: HardStep, fingerprint: Int, dialogID: String)?
    func reset() {
        offered = nil
    }

    func reconcile(editor: EditorViewModel) -> Reconciliation {
        let service = editor.agentService
        if let previous = offered,
           let pending = service.pendingDialog,
           pending.id != previous.dialogID {
            offered = nil
        }
        guard service.pendingDialog == nil,
              service.pendingSpendApproval == nil,
              service.pendingGateApproval == nil,
              !service.isStreaming else {
            return .blocked
        }
        guard let dataRoot = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }) else {
            return Reconciliation(isReady: true, agentPrompt: nil, failure: nil)
        }
        let context: Context
        do {
            guard let packName = try resolvedPack(
                dataRoot: dataRoot,
                declaredPack: editor.declaredPluginName
            ) else {
                return Reconciliation(
                    isReady: true,
                    agentPrompt: nil,
                    failure: nil
                )
            }
            context = try loadContext(dataRoot: dataRoot, packName: packName)
        } catch {
            return Reconciliation(
                isReady: false,
                agentPrompt: nil,
                failure: error.localizedDescription
            )
        }

        var ledger = IntakeLedger.load(dataRoot: dataRoot)
        var repeatStep: HardStep?
        if let previous = offered {
            offered = nil
            let now = IntakeSatisfaction.fingerprint(previous.step.kind, dataRoot: dataRoot)
            if now == previous.fingerprint {
                do {
                    ledger = try IntakeLedger.recordDecline(
                        previous.step,
                        dataRoot: dataRoot
                    )
                } catch {
                    return Reconciliation(
                        isReady: false,
                        agentPrompt: nil,
                        failure: "Couldn't save the \(previous.step.title) decision: "
                            + error.localizedDescription
                    )
                }
            } else if previous.step.repeatable, previous.step.phase == context.phase {
                repeatStep = previous.step
            }
        }

        if let repeatStep {
            present(repeatStep, isRepeat: true, dataRoot: dataRoot, editor: editor)
            return .blocked
        }
        guard let phase = context.phase,
              let step = IntakePlanner.next(
                  context.manifest.steps(for: phase),
                  dataRoot: dataRoot,
                  ledger: ledger
              ) else {
            return Reconciliation(
                isReady: true,
                agentPrompt: context.agentPrompt,
                failure: nil
            )
        }
        present(step, isRepeat: false, dataRoot: dataRoot, editor: editor)
        return .blocked
    }

    func guardPhaseWork(
        tool: ToolName? = nil,
        phase: String,
        dataRoot: URL,
        declaredPack: String? = nil
    ) throws {
        let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: declaredPack
        )
        let registry = PackCatalog.registry(activePack: packName)
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        let gates = try loadGates(dataRoot: dataRoot)
        do {
            try PipelinePhaseAccess.requireCurrentPhaseAndIntake(
                phase,
                dataRoot: dataRoot,
                declaredPack: declaredPack
            )
            if packName == "musicvideo",
               let tool,
               !PipelineAgentContract.allowsExecutableTool(
                   tool,
                   phase: phase
               ) {
                throw GateBlocked(
                    "\(tool.rawValue) is not part of the "
                        + "\(PhaseDisplay.label(phase)) phase contract."
                )
            }
            try GateGuard.requirePriorApproved(gates, order: order, phase: phase)
            if let index = order.firstIndex(of: phase), index > 0 {
                let prior = order[index - 1]
                try GateGuard.checkApprovable(
                    phase: prior,
                    dataRoot: dataRoot,
                    requirement: registry.gateRequirements[prior]
                )
            }
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
    }

    func guardCurrentPhaseWork(
        tool: ToolName,
        dataRoot: URL,
        declaredPack: String? = nil
    ) throws -> String? {
        guard let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: declaredPack
        ) else { return nil }
        let context = try loadContext(dataRoot: dataRoot, packName: packName)
        guard let phase = context.phase else {
            if packName == "musicvideo" {
                throw ToolError(
                    "Every pipeline phase is approved. Explicitly rewind the phase "
                        + "that owns this work before using \(tool.rawValue)."
                )
            }
            return nil
        }
        try guardPhaseWork(
            phase: phase,
            dataRoot: dataRoot,
            declaredPack: declaredPack
        )
        if packName == "musicvideo",
           !PipelineAgentContract.allowsCurrentPhaseTool(
               tool,
               phase: phase
           ) {
            throw ToolError(
                "\(tool.rawValue) is not part of the \(PhaseDisplay.label(phase)) "
                    + "phase contract. Continue with that phase's registered tools."
            )
        }
        return phase
    }

    func agentPrompt(dataRoot: URL) throws -> String? {
        guard let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: nil
        ) else { return nil }
        return try loadContext(
            dataRoot: dataRoot,
            packName: packName
        ).agentPrompt
    }

    func guardAgentDecision(editor: EditorViewModel) throws {
        guard let dataRoot = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }),
        let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: editor.declaredPluginName
        ) else { return }
        let context = try loadContext(dataRoot: dataRoot, packName: packName)
        guard let phase = context.phase,
              let step = IntakePlanner.next(
                  context.manifest.steps(for: phase),
                  dataRoot: dataRoot,
                  ledger: IntakeLedger.load(dataRoot: dataRoot)
              ) else { return }
        throw ToolError(
            "Complete the host-owned \(step.title) card before presenting another decision."
        )
    }

    func recordPhaseMutation(
        phase: String,
        dataRoot: URL,
        captureLineage: Bool = true,
        declaredPack: String? = nil
    ) async throws {
        let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: declaredPack
        )
        let registry = PackCatalog.registry(activePack: packName)
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        guard let index = order.firstIndex(of: phase) else {
            throw ToolError("The pipeline has no registered phase named '\(phase)'.")
        }
        let lineageSnapshot: PhaseLineageSnapshot?
        let lineageFailure: String?
        if captureLineage,
           let provider = registry.phaseLineageProviders[phase] {
            do {
                lineageSnapshot = try await Task.detached(priority: .utility) {
                    try provider(dataRoot)
                }.value
                lineageFailure = nil
            } catch {
                lineageSnapshot = nil
                lineageFailure = error.localizedDescription
            }
        } else {
            lineageSnapshot = nil
            lineageFailure = nil
        }
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try loadGates(dataRoot: dataRoot)
        let affected = order[index...]
        if affected.contains(where: {
            let gate = gates.get($0)
            return gate.state != .pending || gate.notes != nil
        }) {
            do {
                _ = try GatesOperations.rewindTo(
                    &gates,
                    target: phase,
                    order: order
                )
                try store.save(gates, to: PipelineLayout.gatesFile)
            } catch {
                throw ToolError(
                    "The artifact changed, but its gate chain could not be invalidated: \(error)"
                )
            }
        }
        if let lineageFailure {
            throw ToolError(
                "The artifact changed, but its verified input lineage could not "
                    + "be recorded: \(lineageFailure)"
            )
        }
        if let lineageSnapshot {
            do {
                try PipelineLineageStore.record(
                    phase: phase,
                    snapshot: lineageSnapshot,
                    dataRoot: dataRoot
                )
            } catch {
                throw ToolError(
                    "The artifact changed, but its verified input lineage could not "
                        + "be recorded: \(error)"
                )
            }
        }
    }

    private func loadContext(dataRoot: URL, packName: String) throws -> Context {
        guard PackCatalog.pack(named: packName) != nil else {
            throw ToolError(
                "The \(packName) workflow is not loaded. Reopen the project before continuing."
            )
        }
        let registry = PackCatalog.registry(activePack: packName)
        let prepared: PipelinePhaseAccess.Prepared
        do {
            prepared = try PipelinePhaseAccess.prepare(
                packName: packName,
                registry: registry
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
        guard let manifest = prepared.manifest else {
            throw ToolError(
                "The \(packName) workflow has no readable hard-step manifest."
            )
        }
        let snapshot: ProjectStateBuilder.ProjectState
        do {
            snapshot = try ProjectStateBuilder.buildSnapshot(
                dataRoot: dataRoot,
                packPlacements: prepared.packPlacements
            )
        } catch {
            throw ToolError(
                "The pipeline state is unreadable. Repair or restore the project before continuing: \(error)"
            )
        }
        return Context(
            dataRoot: dataRoot,
            packName: packName,
            pack: pack,
            manifest: manifest,
            snapshot: snapshot
        )
    }

    private func loadGates(dataRoot: URL) throws -> Gates {
        do {
            return try YAMLArtifactStore(dataRoot: dataRoot).load(
                Gates.self,
                at: PipelineLayout.gatesFile
            )
        } catch {
            throw ToolError(
                "Couldn't read gates.yaml. Repair or restore the project before continuing: \(error)"
            )
        }
    }

    private func resolvedPack(
        dataRoot: URL,
        declaredPack: String?
    ) throws -> String? {
        do {
            return try ProjectPluginSettings.resolvedPlugin(
                projectURL: FrameInventory.projectHome(of: dataRoot),
                declaredPack: declaredPack
            )
        } catch {
            throw ToolError(error.localizedDescription)
        }
    }

    private func present(
        _ step: HardStep,
        isRepeat: Bool,
        dataRoot: URL,
        editor: EditorViewModel
    ) {
        let dialog = AgentDialog(hardStep: step, isRepeat: isRepeat)
        offered = (
            step,
            IntakeSatisfaction.fingerprint(step.kind, dataRoot: dataRoot),
            dialog.id
        )
        editor.agentService.pendingDialog = dialog
        editor.agentPanelVisible = true
    }
}

extension AgentDialog {
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
            ),
            purpose: .workflowIntake
        )
    }
}
