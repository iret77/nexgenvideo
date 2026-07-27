import Foundation
import NexGenEngine

enum PipelineAgentContract {
    static let musicvideoPhases = [
        "project_init",
        "analysis",
        "brief",
        "production_design",
        "treatment",
        "storyboard",
        "bible",
        "shotlist",
        "sanity",
        "frames",
        "render",
    ]

    static let executableTools: [String: Set<ToolName>] = [
        "analysis": [
            .runPhase,
            .attachSong,
            .writeAnalysisInterpretation,
        ],
        "brief": [.recordAffect, .writeBrief],
        "production_design": [.writeProductionDesign],
        "treatment": [.writeTreatment],
        "storyboard": [.writeStoryboard],
        "bible": [.extractScene3dPovs, .writeBible],
        "shotlist": [.writeShotlist],
        "sanity": [.runSanity],
        "frames": [
            .runPhase,
            .nextRenderShot,
            .recordRender,
            .saveFrameAudit,
        ],
        "render": [
            .runPhase,
            .nextRenderShot,
            .recordRender,
            .assembleTimeline,
        ],
    ]

    static let currentPhaseCapabilities: [String: Set<ToolName>] = [
        "project_init": [],
        "analysis": [],
        "brief": [],
        "production_design": [
            .compilePrompt,
            .generateImage,
            .importMedia,
            .upscaleMedia,
            .copyProjectFile,
            .runProviderTool,
        ],
        "treatment": [],
        "storyboard": [],
        "bible": [
            .compilePrompt,
            .generateImage,
            .importMedia,
            .upscaleMedia,
            .copyProjectFile,
            .runProviderTool,
            .setLedgerAttribute,
            .lockLedgerAttribute,
            .removeLedgerAttribute,
        ],
        "shotlist": [],
        "sanity": [],
        "frames": [
            .compilePrompt,
            .generateImage,
            .importMedia,
            .upscaleMedia,
            .cropToAspect,
            .setLedgerAttribute,
            .lockLedgerAttribute,
            .removeLedgerAttribute,
        ],
        "render": [
            .compilePrompt,
            .generateVideo,
            .generateImage,
            .generateAudio,
            .importMedia,
            .upscaleMedia,
            .runProviderTool,
        ],
    ]

    static let currentPhaseTools: Set<ToolName> = [
        .compilePrompt,
        .generateVideo,
        .generateImage,
        .generateAudio,
        .upscaleMedia,
        .importMedia,
        .runProviderTool,
        .copyProjectFile,
        .cropToAspect,
        .setLedgerAttribute,
        .lockLedgerAttribute,
        .removeLedgerAttribute,
    ]

    static let requiredPhaseToolMentions: [String: Set<ToolName>] = [
        "production_design": [
            .compilePrompt,
            .generateImage,
            .copyProjectFile,
        ],
        "bible": [
            .compilePrompt,
            .generateImage,
            .importMedia,
            .copyProjectFile,
            .extractScene3dPovs,
        ],
        "frames": [
            .compilePrompt,
            .generateImage,
            .getFramesManifest,
            .nextRenderShot,
            .recordRender,
            .saveFrameAudit,
        ],
        "render": [
            .compilePrompt,
            .generateVideo,
            .getFramesManifest,
            .nextRenderShot,
            .recordRender,
            .assembleTimeline,
        ],
    ]

    static func failures(
        registry: EngineRegistry,
        manifest: HardStepManifest,
        phaseDocument: (String) -> String?
    ) -> [String] {
        var failures: [String] = []
        let order = PhaseOrder.merged(packPlacements: registry.phasePlacements)
        if order != musicvideoPhases {
            failures.append(
                "phase order is \(order.joined(separator: ", ")); expected "
                    + musicvideoPhases.joined(separator: ", ")
            )
        }

        let knownTools = Set(ToolDefinitions.all.map(\.name))
        let phaseBoundTools = Set(
            ToolName.allCases.filter {
                $0.advancingPhase(args: [:]) != nil
            }
        ).union([.runPhase])
        let declaredPhaseBoundTools = executableTools.values.reduce(
            into: Set<ToolName>()
        ) {
            $0.formUnion($1)
        }
        if declaredPhaseBoundTools != phaseBoundTools {
            let missing = phaseBoundTools
                .subtracting(declaredPhaseBoundTools)
                .map(\.rawValue)
                .sorted()
            let unexpected = declaredPhaseBoundTools
                .subtracting(phaseBoundTools)
                .map(\.rawValue)
                .sorted()
            failures.append(
                "phase-bound tool coverage differs; missing=\(missing), "
                    + "unexpected=\(unexpected)"
            )
        }
        for phase in musicvideoPhases {
            if registry.gateRequirements[phase] == nil {
                failures.append("\(phase) has no deterministic gate requirement")
            }
            if phase != "project_init",
               registry.phaseLineageProviders[phase] == nil {
                failures.append("\(phase) has no deterministic lineage provider")
            }
            guard let document = phaseDocument(phaseDocumentName(phase)),
                  !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failures.append("\(phase) has no packaged phase document")
                continue
            }
            let requiredMentions = (executableTools[phase] ?? [])
                .union(requiredPhaseToolMentions[phase] ?? [])
            for tool in requiredMentions
            where !document.contains(tool.rawValue) {
                failures.append(
                    "\(phase) instructions don't name required tool \(tool.rawValue)"
                )
            }
            for forbidden in ["shotlist/current.yaml", "`Bash`", ".bak"]
            where document.contains(forbidden) {
                failures.append(
                    "\(phase) instructions contain forbidden stale operation \(forbidden)"
                )
            }
            for tool in executableTools[phase] ?? [] {
                if !knownTools.contains(tool) {
                    failures.append("\(phase) is missing tool \(tool.rawValue)")
                    continue
                }
                let args: [String: Any]
                switch tool {
                case .runPhase:
                    args = ["phase": phase]
                case .nextRenderShot, .recordRender:
                    args = ["phase": phase == "frames" ? "frames" : "final"]
                default:
                    args = [:]
                }
                if tool.advancingPhase(args: args) != phase {
                    failures.append(
                        "\(tool.rawValue) is not hard-gated to \(phase)"
                    )
                }
            }
        }
        if Set(currentPhaseCapabilities.keys) != Set(musicvideoPhases) {
            failures.append(
                "current-phase capability map doesn't cover the canonical phase set"
            )
        }
        for (phase, tools) in currentPhaseCapabilities {
            for tool in tools where !currentPhaseTools.contains(tool) {
                failures.append(
                    "\(phase) grants \(tool.rawValue), which isn't guarded as a current-phase tool"
                )
            }
        }
        for tool in currentPhaseTools where !tool.usesCurrentPipelinePhase {
            failures.append(
                "\(tool.rawValue) does not inherit the current pipeline phase"
            )
        }

        let intakePhases = Set(manifest.allSteps.map(\.phase))
        let allowedIntakePhases: Set<String> = ["project_init", "brief"]
        let unexpected = intakePhases.subtracting(allowedIntakePhases)
        if !unexpected.isEmpty {
            failures.append(
                "host intake is declared in unsupported phase(s): "
                    + unexpected.sorted().joined(separator: ", ")
            )
        }
        if manifest.steps(for: "project_init").map(\.kind) != [.song, .lyrics] {
            failures.append("project_init intake is not exactly Track then optional Lyrics")
        }
        if manifest.steps(for: "brief").map(\.kind)
            != [.script, .character, .location, .style] {
            failures.append(
                "brief intake is not exactly Story, Characters, Locations, Style"
            )
        }
        return failures
    }

    static func allowsCurrentPhaseTool(
        _ tool: ToolName,
        phase: String
    ) -> Bool {
        currentPhaseCapabilities[phase]?.contains(tool) == true
    }

    static func allowsExecutableTool(
        _ tool: ToolName,
        phase: String
    ) -> Bool {
        executableTools[phase]?.contains(tool) == true
    }

    static func phaseDocumentName(_ phase: String) -> String {
        phase == "frames"
            ? "frame"
            : phase.replacingOccurrences(of: "_", with: "-")
    }
}
