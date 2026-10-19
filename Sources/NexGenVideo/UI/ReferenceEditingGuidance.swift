import NexGenEngine

@MainActor
enum ReferenceEditingGuidance {
    static func message(editor: EditorViewModel, allowedPhases: Set<String>, blocksDuringPhaseJob: Bool = false) -> String? {
        guard let state = editor.projectState else { return "Workflow information is unavailable. If it does not load, reopen the project before changing references." }
        if editor.agentService.isStreaming { return "Wait for the assistant to finish before changing references." }
        if editor.agentService.isComposerBlocked { return "Complete the open assistant decision before changing references." }
        if blocksDuringPhaseJob, let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) {
            _ = editor.pipelinePhaseExecution.snapshot
            if let phase = editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) {
                return "Wait for the \(PhaseDisplay.label(phase)) job to finish before changing references."
            }
        }
        if let next = state.nextPhaseName, allowedPhases.contains(next) { return nil }
        if let phase = state.phases.first(where: { $0.phase == "bible" }), phase.approved {
            return phase.approvalCurrent
                ? "Choose Revise References in the workflow dock to change approved reference assignments."
                : "References no longer matches its approved inputs. Select References in the workflow dock and review its current requirements."
        }
        if let next = state.nextPhaseName {
            return "Finish \(PhaseDisplay.label(next)) in the workflow dock before changing reference assignments."
        }
        return "Select References in the workflow dock and resolve its current requirements before changing assignments."
    }
}
