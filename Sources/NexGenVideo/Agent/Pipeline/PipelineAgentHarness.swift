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

        func agentPrompt() throws -> String? {
            let progress = PackProgress(
                nextPhase: snapshot.nextPhase,
                approvedPhases: snapshot.phases.filter(\.approved).count,
                totalPhases: snapshot.phases.count
            )
            let prompt = pack.starters(for: progress).first?.prompt
            guard let phase = snapshot.nextPhase else { return prompt }
            guard let prompt else { return nil }
            let briefURL = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
            let brief: Brief?
            if FileManager.default.fileExists(atPath: briefURL.path) {
                do {
                    brief = try YAMLArtifactStore(dataRoot: dataRoot).load(
                        Brief.self,
                        at: PipelineLayout.briefFile
                    )
                } catch {
                    throw ToolError(
                        "The Brief is unreadable. Repair or restore it before continuing: "
                            + error.localizedDescription
                    )
                }
            } else if snapshot.phases.first(where: { $0.phase == "brief" })?.approved == true {
                throw ToolError(
                    "The approved Brief is missing. Repair or restore it before continuing."
                )
            } else {
                brief = nil
            }
            let registry = PackCatalog.registry(activePack: packName)
            let activeIDs = registry.activeProductionProfileIDs(metadata: [
                "concept_type": brief?.conceptType.rawValue ?? "",
            ])
            let guidance = ProductionProfileGuidance.instructions(
                for: phase,
                profiles: registry.productionProfiles.filter {
                    activeIDs.contains($0.id)
                }
            )
            guard !guidance.isEmpty else { return prompt }
            return "\(prompt)\n\nFollow these active core production profiles:\n\n\(guidance)"
        }
    }

    private struct OfferedIntake {
        let step: HardStep
        let isRepeat: Bool
        let itemNumber: Int?
        let dialogID: String
    }

    private struct IntakeResolution {
        let dialogID: String
        let didProvideMaterial: Bool
    }

    private var offered: OfferedIntake?
    private var intakeResolution: IntakeResolution?

    func reset() {
        offered = nil
        intakeResolution = nil
    }

    func resolveWorkflowIntake(
        dialogID: String,
        didProvideMaterial: Bool,
        editor: EditorViewModel
    ) -> Reconciliation {
        guard offered?.dialogID == dialogID else {
            return Reconciliation(
                isReady: false,
                agentPrompt: nil,
                failure: "The workflow intake changed before the answer could be applied. Try again."
            )
        }
        intakeResolution = IntakeResolution(
            dialogID: dialogID,
            didProvideMaterial: didProvideMaterial
        )
        return reconcile(editor: editor)
    }

    func reconcile(editor: EditorViewModel) -> Reconciliation {
        let service = editor.agentService
        if let previous = offered,
           let pending = service.pendingDialog,
           pending.id != previous.dialogID {
            offered = nil
            intakeResolution = nil
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
        var repeatStep: (step: HardStep, itemNumber: Int)?
        if let previous = offered {
            guard let resolution = intakeResolution,
                  resolution.dialogID == previous.dialogID else {
                present(
                    previous.step,
                    isRepeat: previous.isRepeat,
                    itemNumber: previous.itemNumber,
                    dataRoot: dataRoot,
                    editor: editor
                )
                return .blocked
            }
            if resolution.didProvideMaterial {
                if previous.step.repeatable, previous.step.phase == context.phase {
                    repeatStep = (
                        previous.step,
                        (previous.itemNumber ?? 1) + 1
                    )
                }
            } else {
                do {
                    if let key = editor.openWorkingCopyKey {
                        try ProjectWorkingCopy.markDirty(key: key)
                    }
                    ledger = try IntakeLedger.recordDecline(
                        previous.step,
                        dataRoot: dataRoot
                    )
                    editor.onPipelineChanged?()
                } catch {
                    return Reconciliation(
                        isReady: false,
                        agentPrompt: nil,
                        failure: "Couldn't save the \(previous.step.title) decision: "
                            + error.localizedDescription
                    )
                }
            }
            offered = nil
            intakeResolution = nil
        }

        if let repeatStep {
            present(
                repeatStep.step,
                isRepeat: true,
                itemNumber: repeatStep.itemNumber,
                dataRoot: dataRoot,
                editor: editor
            )
            return .blocked
        }
        guard let phase = context.phase,
              let step = IntakePlanner.next(
                  context.manifest.steps(for: phase),
                  dataRoot: dataRoot,
                  ledger: ledger
        ) else {
            let prompt: String?
            do {
                prompt = try context.agentPrompt()
            } catch {
                return Reconciliation(
                    isReady: false,
                    agentPrompt: nil,
                    failure: error.localizedDescription
                )
            }
            return Reconciliation(
                isReady: true,
                agentPrompt: prompt,
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
        ).agentPrompt()
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
        guard let pack = PackCatalog.pack(named: packName) else {
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
        itemNumber: Int? = nil,
        dataRoot: URL,
        editor: EditorViewModel
    ) {
        let fingerprint = IntakeSatisfaction.fingerprint(step.kind, dataRoot: dataRoot)
        let resolvedItemNumber = step.repeatable ? (itemNumber ?? fingerprint + 1) : nil
        let dialog = AgentDialog(
            hardStep: step,
            isRepeat: isRepeat,
            itemNumber: resolvedItemNumber
        )
        offered = OfferedIntake(
            step: step,
            isRepeat: isRepeat,
            itemNumber: resolvedItemNumber,
            dialogID: dialog.id
        )
        editor.agentService.pendingDialog = dialog
        editor.agentPanelVisible = true
    }
}

extension AgentDialog {
    init(hardStep step: HardStep, isRepeat: Bool, itemNumber: Int? = nil) {
        let fallbackItemTitle: String?
        let fallbackDoneLabel: String?
        switch step.kind {
        case .character:
            fallbackItemTitle = "Prepared character"
            fallbackDoneLabel = "Done"
        case .location:
            fallbackItemTitle = "Prepared location"
            fallbackDoneLabel = "Done"
        default:
            fallbackItemTitle = nil
            fallbackDoneLabel = nil
        }
        let resolvedItemNumber = step.repeatable
            ? max(itemNumber ?? (isRepeat ? 2 : 1), 1)
            : nil
        let resolvedTitle = resolvedItemNumber.flatMap { number in
            (step.itemTitle ?? fallbackItemTitle).map { "\($0) \(number)" }
        } ?? step.title
        let completionLabel: String?
        if step.required {
            completionLabel = nil
        } else if step.repeatable {
            completionLabel = isRepeat
                ? (step.doneLabel ?? fallbackDoneLabel ?? "Done")
                : (step.skipLabel ?? "Skip")
        } else {
            completionLabel = step.skipLabel
        }
        self.init(
            id: "hardstep.\(step.id).\(UUID().uuidString)",
            title: resolvedTitle,
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
                required: step.required,
                completionLabel: completionLabel,
                addFileLabel: step.addFileLabel ?? (fallbackItemTitle == nil ? nil : "Add another image…")
            ),
            purpose: .workflowIntake
        )
    }
}
