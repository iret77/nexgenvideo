import Foundation
import NexGenEngine

enum ProductionWorkflowV2 {
    static let corePhases = [
        "project_init", "brief", "production_design", "treatment", "script", "storyboard", "shot_planning",
        "bible", "shotlist", "sanity", "frames", "render_review", "render",
    ]
    static let musicvideoPhases = ["project_init", "analysis"] + Array(corePhases.dropFirst())
    static let newWriterNames: Set<String> = [
        "write_script", "write_storyboard_bundle", "write_shot_planning_draft", "write_render_review",
    ]

    static func phaseBound(_ phase: String) -> Set<String> {
        switch phase {
        case "script": return ["write_script"]
        case "storyboard": return ["write_storyboard_bundle"]
        case "shot_planning": return ["write_shot_planning_draft"]
        case "render_review": return ["write_render_review"]
        default: return Set((PipelineAgentContract.executableTools[phase] ?? []).map(\.rawValue))
        }
    }

    static func supporting(_ phase: String) -> Set<String> {
        switch phase {
        case "script", "shot_planning": return []
        case "storyboard": return ["compile_prompt", "generate_image", "prepare_generation_batch", "import_media"]
        case "render_review": return ["compile_prompt"]
        default: return Set((PipelineAgentContract.currentPhaseCapabilities[phase] ?? []).map(\.rawValue))
        }
    }

    static func validate(_ contract: ResolvedPhaseContract) throws {
        let musicvideo = contract.manifest.contractID == HostWorkflowKey.musicvideoV2Contract
        guard (musicvideo && contract.packID == "musicvideo"
                && contract.packVersion == HostWorkflowKey.musicvideoV2Version && contract.engineContract == 11)
                || (!musicvideo && contract.manifest.contractID == "core.production.v2" && contract.packID == "core"),
              contract.order == (musicvideo ? musicvideoPhases : corePhases),
              Set(contract.manifest.postPipelineCapabilities)
                == Set(PipelineAgentContract.postPipelineUtilityCapabilities.map(\.rawValue)) else {
            throw PhaseContractError.registryMismatch("the production workflow identity or phase set differs from its supported contract")
        }
        if musicvideo {
            guard contract.hardSteps.declaredPhases == ["project_init", "brief"],
                  contract.hardSteps.steps(for: "project_init").map(\.kind) == [.song, .lyrics],
                  contract.hardSteps.steps(for: "brief").map(\.kind) == [.script, .character, .location, .style] else {
                throw PhaseContractError.registryMismatch("Music Video startup must retain Track, optional Lyrics, approved Analysis and optional existing material")
            }
        } else if !contract.hardSteps.allSteps.isEmpty {
            throw PhaseContractError.registryMismatch("Core production cannot require Music Video intake")
        }
        for phase in contract.phases {
            let id = phase.declaration.id
            guard Set(phase.phaseBoundCapabilities.map(\.rawValue)) == phaseBound(id),
                  Set(phase.supportingCapabilities.map(\.rawValue)) == supporting(id) else {
                throw PhaseContractError.registryMismatch("\(id) capabilities differ from the supported production contract")
            }
            let instructions = try contract.instructions(for: id)
            for tool in phaseBound(id) where !instructions.contains(tool) {
                throw PhaseContractError.registryMismatch("\(id) instructions omit canonical writer \(tool)")
            }
            for stale in ["shotlist/current.yaml", "`Bash`", ".bak"] where instructions.contains(stale) {
                throw PhaseContractError.registryMismatch("\(id) instructions contain stale operation \(stale)")
            }
        }
    }
}
