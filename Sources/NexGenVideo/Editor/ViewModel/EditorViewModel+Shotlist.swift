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
        let result: Result<Bool, ToolError> = await Task.detached {
            guard var shotlist = (try? loadShotlist(dataRoot: dataRoot)) ?? nil,
                  let index = shotlist.shots.firstIndex(where: { $0.id == shotId }),
                  shotlist.shots[index].sourceMode != mode
            else { return .success(false) }
            shotlist.shots[index].sourceMode = mode
            switch mode {
            case .generated:
                shotlist.shots[index].sourcePath = nil
                if shotlist.shots[index].keyframeStrategy == .none {
                    shotlist.shots[index].keyframeStrategy = .start
                }
            case .imported:
                shotlist.shots[index].sourcePath = nil
                shotlist.shots[index].keyframeStrategy = .none
                shotlist.shots[index].chainWithPreviousEnd = false
            case .aiEnhanced:
                shotlist.shots[index].keyframeStrategy = .none
                shotlist.shots[index].chainWithPreviousEnd = false
                shotlist.shots[index].referenceImageRefs = []
                shotlist.shots[index].seedanceInputMode = .keyframe
            }
            do {
                _ = try PipelineShotlistWriter.write(
                    shotlist,
                    dataRoot: dataRoot
                )
                return .success(true)
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
            try pipelineAgentHarness.recordPhaseMutation(
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
