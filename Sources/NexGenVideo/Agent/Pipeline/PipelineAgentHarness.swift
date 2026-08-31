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
    struct Prepared: Sendable {
        let packName: String?
        let contract: ResolvedPhaseContract?
        let order: [String]
        let manifest: HardStepManifest?
    }

    static func prepare(
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> Prepared {
        let projectURL = FrameInventory.projectHome(of: dataRoot)
        let packName: String?
        do {
            packName = try ProjectPackGate.requireLiveMutation(
                projectURL: projectURL,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
        } catch {
            throw GateBlocked(error.localizedDescription)
        }
        guard let packName else {
            return Prepared(
                packName: nil,
                contract: nil,
                order: coreGatePhases,
                manifest: nil
            )
        }
        return try prepare(packName: packName)
    }

    static func prepare(packName: String?) throws -> Prepared {
        guard let packName else {
            return Prepared(
                packName: nil,
                contract: nil,
                order: coreGatePhases,
                manifest: nil
            )
        }
        guard PackCatalog.pack(named: packName) != nil else {
            throw GateBlocked(
                "The \(packName) workflow contract is unavailable. Reopen the project before continuing."
            )
        }
        let contract: ResolvedPhaseContract
        do {
            guard let resolved = try PhaseContractRuntime.contract(activePack: packName) else {
                throw PhaseContractError.unavailable(packName)
            }
            contract = resolved
        } catch {
            throw GateBlocked(error.localizedDescription)
        }
        return Prepared(
            packName: packName,
            contract: contract,
            order: contract.order,
            manifest: contract.hardSteps
        )
    }

    static func requireCurrentPhaseAndIntake(
        _ phase: String,
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws {
        try requireCurrentPhaseAndIntake(
            phase,
            dataRoot: dataRoot,
            prepared: prepare(
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
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
                order: prepared.order
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
        let contract: ResolvedPhaseContract
        let manifest: HardStepManifest
        let snapshot: ProjectStateBuilder.ProjectState

        var phase: String? { snapshot.nextPhase }

        func agentPrompt() throws -> String? {
            let progress = PackProgress(
                nextPhase: snapshot.nextPhase,
                approvedPhases: snapshot.phases.filter(\.approved).count,
                totalPhases: snapshot.phases.count
            )
            var prompt = pack.starters(for: progress).first?.prompt
            guard let phase = snapshot.nextPhase else { return prompt }
            let instructions = try contract.instructions(for: phase)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = prompt {
                if !instructions.isEmpty, !existing.contains(instructions) {
                    prompt = "\(existing)\n\nFollow these packaged instructions for the current phase:\n\n\(instructions)"
                }
            } else if !instructions.isEmpty {
                prompt = instructions
            }
            guard var prompt else { return nil }
            let registry = PackCatalog.registry(activePack: packName)
            let consumers = try ProductionKnowledgeConsumerRegistryV1(
                registrations: registry.productionKnowledgeConsumers
            )
            guard let registration = consumers.registration(for: packName) else {
                return prompt
            }
            let productionKnowledgeCatalog = try EngineProductionKnowledgeResourcesV1.loadCatalog()
            try consumers.validateResources(in: productionKnowledgeCatalog)
            let descriptor = registration.descriptor
            let metadata: ProductionKnowledgeActivationMetadataV1
            do {
                metadata = try registration.metadataProvider(dataRoot, phase)
            } catch let blocked as GateBlocked {
                throw ToolError(blocked.message)
            } catch {
                throw ToolError(
                    "The \(packName) production-knowledge activation metadata is unavailable: "
                        + error.localizedDescription
                )
            }
            let activeProfiles = Set(
                registry.activeProductionProfileIDs(metadata: metadata.values).map {
                    ProductionProfileDescriptorIDV1(rawValue: $0.rawValue)
                }
            )
            let undeclaredProfiles = activeProfiles.subtracting(descriptor.profileResourceIDs)
            guard undeclaredProfiles.isEmpty else {
                throw ToolError(
                    "The \(packName) production-knowledge descriptor does not declare active profiles: "
                        + undeclaredProfiles.map(\.rawValue).sorted().joined(separator: ", ")
                )
            }
            let selection = descriptor.selection(for: phase)
            let declaredLibraries = Set(selection?.libraryIDs ?? [])
            let activeLibraries: Set<CreativeKnowledgeLibraryIDV1>
            if let requested = metadata.activeLibraryIDs {
                let undeclaredLibraries = requested.subtracting(declaredLibraries)
                guard undeclaredLibraries.isEmpty else {
                    throw ToolError(
                        "The \(packName) activation metadata requested undeclared production libraries: "
                            + undeclaredLibraries.map(\.rawValue).sorted().joined(separator: ", ")
                    )
                }
                activeLibraries = requested
            } else {
                activeLibraries = declaredLibraries
            }
            let assembly = try ProductionKnowledgeContextAssemblerV1(
                catalog: productionKnowledgeCatalog,
                predicates: ProductionMachinePredicateRegistryV1.standard()
            ).assemble(
                ProductionKnowledgeAssemblyQueryV1(
                    packID: packName,
                    phase: selection?.knowledgePhase ?? phase,
                    intentTags: metadata.intentTags.union(selection?.intentTags ?? []),
                    activeProfileIDs: activeProfiles,
                    activeLibraryIDs: activeLibraries,
                    budget: descriptor.budget
                )
            )
            if !assembly.prompt.isEmpty {
                prompt += "\n\nFollow this selected core production knowledge:\n\n\(assembly.prompt)"
            }
            return prompt
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

    enum TreatmentCreationPath: Equatable {
        case agentProposal
        case userSupplied
        case custom
    }

    private var offered: OfferedIntake?
    private var intakeResolution: IntakeResolution?
    private var treatmentCreationPath: TreatmentCreationPath?

    func reset() {
        offered = nil
        intakeResolution = nil
        treatmentCreationPath = nil
    }

    func workflowIntakePhase(dialogID: String) -> String? {
        guard offered?.dialogID == dialogID else { return nil }
        return offered?.step.phase
    }

    func resolveWorkflowIntake(
        dialogID: String,
        didProvideMaterial: Bool,
        editor: EditorViewModel
    ) -> Reconciliation {
        do {
            try validateWorkflowIntake(
                dialogID: dialogID,
                editor: editor,
                materialAlreadyApplied: didProvideMaterial
            )
        } catch {
            return Reconciliation(
                isReady: false,
                agentPrompt: nil,
                failure: error.localizedDescription
            )
        }
        intakeResolution = IntakeResolution(
            dialogID: dialogID,
            didProvideMaterial: didProvideMaterial
        )
        return reconcile(editor: editor)
    }

    func validateWorkflowIntake(
        dialogID: String,
        editor: EditorViewModel,
        materialAlreadyApplied: Bool = false
    ) throws {
        guard let offered, offered.dialogID == dialogID else {
            throw ToolError(
                "The workflow intake changed before the answer could be applied. Try again."
            )
        }
        guard let dataRoot = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }) else {
            throw ToolError("The project is unavailable. Reopen it and try again.")
        }
        if let running = editor.pipelinePhaseRunCoordinator.runningPhase(
            projectRoot: dataRoot
        ) {
            throw ToolError(
                "Wait for \(PhaseDisplay.label(running)) to finish before changing workflow inputs."
            )
        }
        guard let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding
        ) else {
            throw ToolError("The workflow contract is unavailable. Reopen the project and try again.")
        }
        let context = try loadContext(dataRoot: dataRoot, packName: packName)
        guard let phase = context.phase, phase == offered.step.phase else {
            let current = context.phase.map { PhaseDisplay.label($0) }
                ?? "the completed workflow"
            throw ToolError(
                "This \(offered.step.title) card belongs to an earlier phase. Continue with \(current)."
            )
        }
        guard context.manifest.steps(for: phase).contains(where: {
            $0.id == offered.step.id
        }) else {
            throw ToolError(
                "The workflow contract changed before the answer could be applied. Reopen the project."
            )
        }
        let registry = PackCatalog.registry(activePack: packName)
        let order = context.contract.order
        let gates = try loadGates(dataRoot: dataRoot)
        do {
            try GateGuard.requirePriorApproved(gates, order: order, phase: phase)
            if let index = order.firstIndex(of: phase), index > 0 {
                let prior = order[index - 1]
                try GateGuard.checkApprovable(
                    phase: prior,
                    dataRoot: dataRoot,
                    requirement: try PhaseContractRuntime.gateRequirement(
                        activePack: packName,
                        phase: prior,
                        registry: registry
                    )
                )
            }
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
        if !offered.isRepeat, !materialAlreadyApplied {
            let current = IntakePlanner.next(
                context.manifest.steps(for: phase),
                dataRoot: dataRoot,
                ledger: IntakeLedger.load(dataRoot: dataRoot)
            )
            guard current?.id == offered.step.id else {
                throw ToolError(
                    "The workflow intake changed before the answer could be applied. Try again."
                )
            }
        }
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
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding
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
        if context.phase != "treatment" {
            treatmentCreationPath = nil
        }

        var ledger = IntakeLedger.load(dataRoot: dataRoot)
        var repeatStep: (step: HardStep, itemNumber: Int)?
        if let previous = offered {
            guard let resolution = intakeResolution,
                  resolution.dialogID == previous.dialogID else {
                if let failure = present(
                    previous.step,
                    isRepeat: previous.isRepeat,
                    itemNumber: previous.itemNumber,
                    dataRoot: dataRoot,
                    editor: editor
                ) {
                    return Reconciliation(isReady: false, agentPrompt: nil, failure: failure)
                }
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
                    _ = try ProjectPackGate.requireLiveMutation(
                        projectURL: FrameInventory.projectHome(of: dataRoot),
                        declaredPack: editor.declaredPluginName,
                        declaredBinding: editor.declaredPluginBinding
                    )
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
            if let failure = present(
                repeatStep.step,
                isRepeat: true,
                itemNumber: repeatStep.itemNumber,
                dataRoot: dataRoot,
                editor: editor
            ) {
                return Reconciliation(isReady: false, agentPrompt: nil, failure: failure)
            }
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
        if let failure = present(
            step,
            isRepeat: false,
            dataRoot: dataRoot,
            editor: editor
        ) {
            return Reconciliation(isReady: false, agentPrompt: nil, failure: failure)
        }
        return .blocked
    }

    func guardPhaseWork(
        tool: ToolName? = nil,
        phase: String,
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws {
        let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        let registry = PackCatalog.registry(activePack: packName)
        let contract = try PhaseContractRuntime.contract(activePack: packName)
        let order = contract?.order ?? coreGatePhases
        let gates = try loadGates(dataRoot: dataRoot)
        do {
            try PipelinePhaseAccess.requireCurrentPhaseAndIntake(
                phase,
                dataRoot: dataRoot,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
            if let tool,
               let contract,
               !contract.allowsPhaseBound(tool, phase: phase) {
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
                    requirement: try PhaseContractRuntime.gateRequirement(
                        activePack: packName,
                        phase: prior,
                        registry: registry
                    )
                )
            }
        } catch let blocked as GateBlocked {
            throw ToolError(blocked.message)
        }
    }

    func guardCurrentPhaseWork(
        tool: ToolName,
        dataRoot: URL,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) throws -> String? {
        guard let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        ) else { return nil }
        let context = try loadContext(dataRoot: dataRoot, packName: packName)
        guard let phase = context.phase else {
            if context.contract.allowsPostPipeline(tool) {
                return nil
            }
            throw ToolError(
                "Every pipeline phase is approved. Explicitly rewind the phase "
                    + "that owns this work before using \(tool.rawValue)."
            )
        }
        try guardPhaseWork(
            phase: phase,
            dataRoot: dataRoot,
            declaredPack: declaredPack,
            declaredBinding: declaredBinding
        )
        if !context.contract.allowsSupporting(tool, phase: phase) {
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
            declaredPack: nil,
            declaredBinding: nil,
            requireMutationBinding: false
        ) else { return nil }
        return try loadContext(
            dataRoot: dataRoot,
            packName: packName
        ).agentPrompt()
    }

    func guardAgentDecision(
        _ dialog: AgentDialog,
        editor: EditorViewModel
    ) throws {
        guard let dataRoot = editor.workingRoot.flatMap({
            DataRootResolver.dataRoot(of: $0)
        }),
        let packName = try resolvedPack(
            dataRoot: dataRoot,
            declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding
        ) else { return }
        let context = try loadContext(dataRoot: dataRoot, packName: packName)
        guard let phase = context.phase else {
            if dialog.workflowDecision != nil {
                throw ToolError(
                    "This workflow decision belongs to an active pipeline phase, but every phase is approved."
                )
            }
            return
        }
        if let step = IntakePlanner.next(
            context.manifest.steps(for: phase),
            dataRoot: dataRoot,
            ledger: IntakeLedger.load(dataRoot: dataRoot)
        ) {
            throw ToolError(
                "Complete the host-owned \(step.title) card before presenting another decision."
            )
        }
        guard packName == "musicvideo" else { return }
        switch phase {
        case "project_init":
            throw ToolError(
                "Project Init has no agent-authored decisions. Complete it before presenting a dialog."
            )
        case "analysis":
            let analysisDecisions: Set<AgentDialog.WorkflowDecision> = [
                .analysisTempo,
                .analysisInterpretationReview,
                .analysisTrackReplacement,
            ]
            guard dialog.workflowDecision.map(analysisDecisions.contains) == true else {
                throw ToolError(
                    "Audio Analysis accepts only its bounded tempo, interpretation-review, or track-replacement dialog. Do not ask about story, identity, style, or later phases yet."
                )
            }
            try guardPhaseWork(
                phase: phase,
                dataRoot: dataRoot,
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding
            )
            if let running = editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: dataRoot
            ) {
                throw ToolError(
                    "Wait for \(PhaseDisplay.label(running)) to finish before presenting the analysis decision."
                )
            }
        case "treatment":
            let hasTreatment = !TreatmentStore.versions(dataRoot: dataRoot).isEmpty
            if hasTreatment {
                treatmentCreationPath = nil
                if dialog.workflowDecision == .treatmentPath {
                    throw ToolError(
                        "A treatment already exists. Offer continue, revise, or restart instead of asking how to create the first treatment."
                    )
                }
                if dialog.workflowDecision != nil {
                    throw ToolError(
                        "The declared workflow decision is not valid during Treatment."
                    )
                }
                return
            }
            if treatmentCreationPath == nil {
                guard dialog.workflowDecision == .treatmentPath else {
                    throw ToolError(
                        "Before requesting any treatment text, present the Treatment path choice: agent_proposal first (recommended), then user_supplied, with workflowDecision=treatment_path. The user is never required to upload a treatment."
                    )
                }
                try Self.validateTreatmentPathDialog(dialog)
                return
            }
            if dialog.workflowDecision == .treatmentPath {
                throw ToolError(
                    "The Treatment path is already chosen. Continue with that path instead of asking again."
                )
            }
            if dialog.workflowDecision != nil {
                throw ToolError(
                    "The declared workflow decision is not valid during Treatment."
                )
            }
            if treatmentCreationPath == .agentProposal,
               (dialog.fileIntake != nil || dialog.textField?.multiline == true) {
                throw ToolError(
                    "The user chose an agent-proposed treatment. Create 2–3 variants from the approved analysis, lyrics, Brief, and Production Design; do not request a treatment upload or long-form treatment text."
                )
            }
        default:
            if dialog.workflowDecision != nil {
                throw ToolError(
                    "The declared workflow decision is not valid during \(PhaseDisplay.label(phase))."
                )
            }
        }
    }

    func recordAgentDecision(
        _ dialog: AgentDialog,
        result: AgentDialogResult,
        selectedOptionIDs: [String: Set<String>]
    ) throws {
        guard dialog.workflowDecision == .treatmentPath else { return }
        treatmentCreationPath = try Self.resolveTreatmentCreationPath(
            dialog,
            result: result,
            selectedOptionIDs: selectedOptionIDs
        )
    }

    static func resolveTreatmentCreationPath(
        _ dialog: AgentDialog,
        result: AgentDialogResult,
        selectedOptionIDs: [String: Set<String>]
    ) throws -> TreatmentCreationPath {
        try validateTreatmentPathDialog(dialog)
        let explicit = selectedOptionIDs["treatment_path"] ?? []
        let selected: Set<String>
        if explicit.isEmpty {
            let labels = Set(result.labels("treatment_path"))
            guard let section = dialog.sections.first,
                  case .choices(let options, _) = section.kind else {
                throw ToolError("Choose how the Treatment should be created.")
            }
            selected = Set(options.filter { labels.contains($0.label) }.map(\.id))
        } else {
            selected = explicit
        }
        if selected == ["agent_proposal"] {
            return .agentProposal
        } else if selected == ["user_supplied"] {
            return .userSupplied
        } else if selected.isEmpty,
                  result.customValues["treatment_path"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .custom
        } else {
            throw ToolError("Choose one Treatment path before continuing.")
        }
    }

    static func validateTreatmentPathDialog(_ dialog: AgentDialog) throws {
        guard dialog.workflowDecision == .treatmentPath,
              dialog.fileIntake == nil,
              dialog.textField == nil,
              dialog.sections.count == 1,
              let section = dialog.sections.first,
              section.id == "treatment_path",
              section.allowsCustom,
              case .choices(let options, let multiSelect) = section.kind,
              !multiSelect,
              options.map(\.id) == ["agent_proposal", "user_supplied"] else {
            throw ToolError(
                "The Treatment path dialog must contain one single-select treatment_path section with agent_proposal first, user_supplied second, and Other enabled; it must not request text or a file."
            )
        }
    }

    func recordPhaseMutation(
        phase: String,
        dataRoot: URL,
        captureLineage: Bool = true,
        declaredPack: String? = nil,
        declaredBinding: ProjectPackBinding? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            try PipelinePhaseMutationRecorder.record(
                phase: phase,
                dataRoot: dataRoot,
                captureLineage: captureLineage,
                declaredPack: declaredPack,
                declaredBinding: declaredBinding
            )
        }.value
    }

    private func loadContext(dataRoot: URL, packName: String) throws -> Context {
        guard let pack = PackCatalog.pack(named: packName) else {
            throw ToolError(
                "The \(packName) workflow is not loaded. Reopen the project before continuing."
            )
        }
        let prepared: PipelinePhaseAccess.Prepared
        do {
            prepared = try PipelinePhaseAccess.prepare(packName: packName)
        } catch {
            throw ToolError(error.localizedDescription)
        }
        guard let manifest = prepared.manifest else {
            throw ToolError(
                "The \(packName) workflow has no readable hard-step manifest."
            )
        }
        guard let contract = prepared.contract else {
            throw ToolError(
                "The \(packName) workflow has no resolved phase contract."
            )
        }
        let snapshot: ProjectStateBuilder.ProjectState
        do {
            snapshot = try ProjectStateBuilder.buildSnapshot(
                dataRoot: dataRoot,
                order: prepared.order
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
            contract: contract,
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
        declaredPack: String?,
        declaredBinding: ProjectPackBinding?,
        requireMutationBinding: Bool = true
    ) throws -> String? {
        do {
            if requireMutationBinding {
                return try ProjectPackGate.requireLiveMutation(
                    projectURL: FrameInventory.projectHome(of: dataRoot),
                    declaredPack: declaredPack,
                    declaredBinding: declaredBinding
                )
            }
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
    ) -> String? {
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
        do {
            try editor.agentService.presentDialog(dialog)
            return nil
        } catch {
            offered = nil
            return error.localizedDescription
        }
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
