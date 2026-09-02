import Foundation
import NexGenEngine

// Direct, structured shotlist editing through the same canonical writer as the agent tool.
extension EditorViewModel {
    func canSetShotSourceMode(shotId: String, to mode: SourceMode) async -> Bool {
        guard let home = workingRoot,
              let dataRoot = DataRootResolver.dataRoot(of: home),
              pipelinePhaseRunCoordinator.runningPhase(projectRoot: dataRoot) == nil else {
            return false
        }
        do {
            try pipelineAgentHarness.guardPhaseWork(
                phase: "shotlist",
                dataRoot: dataRoot,
                declaredPack: declaredPluginName,
                declaredBinding: declaredPluginBinding
            )
        } catch {
            return false
        }
        let trustedPack = declaredPluginName
        let trustedBinding = declaredPluginBinding
        return await Task.detached {
            PipelineShotlistWriter.canSetSourceMode(
                shotId: shotId,
                to: mode,
                dataRoot: dataRoot,
                declaredPack: trustedPack,
                declaredBinding: trustedBinding
            )
        }.value
    }

    /// Set one shot's source mode natively and refresh the engine snapshot. No-op (returns false)
    /// when there's no open project, no shotlist, the shot is missing, or the value is unchanged.
    @discardableResult
    func setShotSourceMode(shotId: String, to mode: SourceMode) async -> Bool {
        await Task.yield()
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
                declaredPack: declaredPluginName,
                declaredBinding: declaredPluginBinding
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
        let trustedPack = declaredPluginName
        let trustedBinding = declaredPluginBinding
        let result: Result<Bool, ToolError>
        do {
            result = .success(try ProjectWorkingCopy.transactChange(
                key: workingCopyKey,
                validateCurrent: { currentRoot in
                    _ = try ProjectPackGate.requireMutation(
                        projectURL: currentRoot,
                        declaredPack: trustedPack,
                        declaredBinding: trustedBinding
                    )
                }
            ) { stagingRoot in
                guard let stagingDataRoot = DataRootResolver.dataRoot(
                    of: stagingRoot
                ) else {
                    throw ToolError(
                        "The project pipeline is unavailable. Reopen the project before editing."
                    )
                }
                let changed = try PipelineShotlistWriter.setSourceMode(
                    shotId: shotId,
                    to: mode,
                    dataRoot: stagingDataRoot,
                    declaredPack: trustedPack,
                    declaredBinding: trustedBinding
                )
                if changed {
                    try PipelinePhaseMutationRecorder.record(
                        phase: "shotlist",
                        dataRoot: stagingDataRoot,
                        captureLineage: true,
                        declaredPack: trustedPack,
                        declaredBinding: trustedBinding
                    )
                }
                return changed
            })
        } catch let error as ToolError {
            result = .failure(error)
        } catch {
            result = .failure(ToolError(error.localizedDescription))
        }
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
        await refreshEngineState()
        return true
    }
}
