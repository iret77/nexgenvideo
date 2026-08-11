import Foundation
import NexGenEngine

// Direct, structured shotlist editing through the same canonical writer as the agent tool.
extension EditorViewModel {
    /// Set one shot's source mode natively and refresh the engine snapshot. No-op (returns false)
    /// when there's no open project, no shotlist, the shot is missing, or the value is unchanged.
    @discardableResult
    func setShotSourceMode(shotId: String, to mode: SourceMode) async -> Bool {
        guard let home = workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: home) else {
            return false
        }
        guard let mutationID = pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: dataRoot,
            label: "Shot List edit"
        ) else {
            let active = pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: dataRoot
            ) ?? "pipeline work"
            mediaPanelToast = MediaPanelToast(
                message: "Can't edit the Shot List while \(active) is running."
            )
            return false
        }
        defer {
            pipelinePhaseRunCoordinator.endMutation(
                projectRoot: dataRoot,
                id: mutationID
            )
        }
        do {
            try pipelineAgentHarness.guardPhaseWork(
                phase: "shotlist",
                dataRoot: dataRoot,
                declaredPack: declaredPluginName
            )
        } catch let error as ToolError {
            mediaPanelToast = MediaPanelToast(message: error.message)
            return false
        } catch {
            mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            return false
        }
        guard let workingCopyKey = openWorkingCopyKey else {
            mediaPanelToast = MediaPanelToast(
                message: "The project working copy is unavailable. Reopen the project before editing."
            )
            return false
        }
        do {
            try ProjectWorkingCopy.markDirty(key: workingCopyKey)
        } catch {
            mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            return false
        }
        let trustedPack = declaredPluginName
        let result: Result<Bool, ToolError> = await Task.detached {
            do {
                return .success(try PipelineShotlistWriter.setSourceMode(
                    shotId: shotId,
                    to: mode,
                    dataRoot: dataRoot,
                    declaredPack: trustedPack
                ))
            } catch let error as ToolError {
                return .failure(error)
            } catch {
                return .failure(ToolError(error.localizedDescription))
            }
        }.value
        let saved: Bool
        switch result {
        case .success(let changed):
            saved = changed
        case .failure(let error):
            mediaPanelToast = MediaPanelToast(message: error.message)
            return false
        }
        guard saved else { return false }
        onPipelineChanged?()
        var invalidated = true
        do {
            try await pipelineAgentHarness.recordPhaseMutation(
                phase: "shotlist",
                dataRoot: dataRoot,
                declaredPack: declaredPluginName
            )
        } catch let error as ToolError {
            invalidated = false
            mediaPanelToast = MediaPanelToast(
                message: "The shot changed, but the pipeline could not be rewound: "
                    + error.message
            )
        } catch {
            invalidated = false
            mediaPanelToast = MediaPanelToast(
                message: "The shot changed, but the pipeline could not be rewound: "
                    + error.localizedDescription
            )
        }
        await refreshEngineState()
        return invalidated
    }
}
