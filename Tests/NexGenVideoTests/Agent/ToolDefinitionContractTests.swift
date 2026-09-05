import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Agent tool semantic contracts")
struct ToolDefinitionContractTests {
    @Test("every object schema is closed or an explicitly typed dynamic map")
    func objectSchemasAreClosed() {
        let dynamicMaps: [String: String] = [
            "apply_effect.effects[].params": "number",
            "run_provider_tool.arguments": "string",
            "save_frame_audit.checks": "object",
            "write_phase_extension.payload": "json",
        ]
        var failures: [String] = []
        var seenDynamicMaps: Set<String> = []

        #expect(Set(ToolDefinitions.all.map(\.name)) == Set(ToolName.allCases))
        for tool in ToolDefinitions.all {
            auditObjectSchemas(
                tool.inputSchema,
                path: tool.name.rawValue,
                dynamicMaps: dynamicMaps,
                seenDynamicMaps: &seenDynamicMaps,
                failures: &failures
            )
        }

        if !failures.isEmpty {
            Issue.record("Schema violations: \(failures.joined(separator: "; "))")
        }
        #expect(failures.isEmpty)
        #expect(seenDynamicMaps == Set(dynamicMaps.keys))
    }

    @Test("show_blocks advertises the same versioned closed variants the executor enforces")
    func showBlocksSchemaIsVersionedAndClosed() throws {
        let tool = try #require(
            ToolDefinitions.all.first { $0.name == .showBlocks }
        )
        #expect(Set(tool.inputSchema["required"] as? [String] ?? []) == ["version", "blocks"])
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let version = try #require(properties["version"] as? [String: Any])
        #expect(version["enum"] as? [String] == [AgentBlocks.currentVersion])
        let blocks = try #require(properties["blocks"] as? [String: Any])
        #expect(blocks["maxItems"] as? Int == AgentBlocks.maxBlocks)
        let items = try #require(blocks["items"] as? [String: Any])
        let variants = try #require(items["anyOf"] as? [[String: Any]])
        #expect(variants.count == 5)
        for variant in variants {
            #expect(variant["additionalProperties"] as? Bool == false)
            #expect((variant["required"] as? [String])?.contains("type") == true)
            let fields = try #require(variant["properties"] as? [String: Any])
            #expect(fields["symbol"] == nil)
        }
    }

    @Test("unknown keys are rejected at the tool boundary")
    @MainActor
    func unknownKeysAreRejectedAtBoundary() async {
        let harness = ToolHarness()

        let root = await harness.runRaw("get_media", args: ["bogus": true])
        #expect(root.isError)
        #expect(ToolHarness.textOf(root).contains("get_media: unknown field 'bogus'"))

        let nested = await harness.runRaw("show_dialog", args: [
            "title": "Choose",
            "sections": [[
                "id": "style",
                "label": "Style",
                "type": "choices",
                "options": [[
                    "id": "clean",
                    "label": "Clean",
                    "bogus": true,
                ]],
            ]],
        ])
        #expect(nested.isError)
        #expect(
            ToolHarness.textOf(nested)
                .contains("show_dialog.sections[0].options[0]: unknown field 'bogus'")
        )
    }

    @Test("required fields, types, enums, and array bounds are enforced at the tool boundary")
    @MainActor
    func semanticSchemaConstraintsAreEnforced() async {
        let harness = ToolHarness()

        let missing = await harness.runRaw("approve_gate")
        #expect(ToolHarness.textOf(missing).contains("missing required field 'phase'"))

        let wrongType = await harness.runRaw("get_timeline", args: ["startFrame": "zero"])
        #expect(ToolHarness.textOf(wrongType).contains("get_timeline.startFrame: expected integer"))

        let validTypedInput = await harness.runRaw("get_timeline", args: ["startFrame": 0])
        #expect(validTypedInput.isError == false)

        let badEnum = await harness.runRaw("list_models", args: ["type": "document"])
        #expect(ToolHarness.textOf(badEnum).contains("expected one of video, image, audio, upscale"))

        let badWorkflowDecision = await harness.runRaw("show_dialog", args: [
            "title": "Choose",
            "workflowDecision": "story_direction",
            "textField": ["placeholder": "Direction"],
        ])
        #expect(
            ToolHarness.textOf(badWorkflowDecision)
                .contains("expected one of analysis_tempo, analysis_interpretation_review, analysis_track_replacement, treatment_path")
        )

        let longChoiceLabel = String(
            repeating: "x",
            count: AgentDialog.maxChoiceDisplayLength + 1
        )
        let oversizedChoice = await harness.runRaw("show_dialog", args: [
            "title": "Choose",
            "sections": [[
                "id": "style",
                "label": "Style",
                "type": "choices",
                "options": [
                    ["id": "one", "label": "One", "shortLabel": longChoiceLabel],
                    ["id": "two", "label": "Two"],
                ],
            ]],
        ])
        #expect(
            ToolHarness.textOf(oversizedChoice)
                .contains("show_dialog.sections[0].options[0].shortLabel: expected at most \(AgentDialog.maxChoiceDisplayLength) character(s)")
        )

        let negativeCost = await harness.runRaw("record_render", args: [
            "phase": "preview",
            "shot_id": "s001",
            "cost_eur": -0.01,
        ])
        #expect(ToolHarness.textOf(negativeCost).contains("expected at least 0"))

        let empty = await harness.runRaw("show_blocks", args: [
            "version": AgentBlocks.currentVersion,
            "blocks": [],
        ])
        #expect(ToolHarness.textOf(empty).contains("expected at least 1 item"))

        let unboundGeneration = await harness.runRaw(
            "generate_video",
            args: ["prompt": "compiled"]
        )
        #expect(
            ToolHarness.textOf(unboundGeneration)
                .contains("missing required field 'shotId'")
        )
    }

    @Test("every generation tool requires the compile-time shot binding")
    func generationSchemasRequireShotBinding() throws {
        for name in [
            ToolName.generateVideo,
            .generateImage,
            .generateAudio,
        ] {
            let tool = try #require(
                ToolDefinitions.all.first { $0.name == name }
            )
            let required = Set(
                tool.inputSchema["required"] as? [String] ?? []
            )
            let properties = try #require(
                schemaProperties(tool.inputSchema["properties"])
            )
            #expect(required.contains("shotId"))
            #expect(properties["shotId"] != nil)
        }
    }

    @Test("video duration accepts seconds or automatic mode")
    func videoDurationSchema() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .generateVideo })
        let properties = try #require(schemaProperties(tool.inputSchema["properties"]))
        let duration = try #require(properties["duration"] as? [String: Any])
        let variants = try #require(duration["anyOf"] as? [[String: Any]])
        #expect(variants.contains { $0["type"] as? String == "integer" })
        #expect(variants.contains {
            $0["type"] as? String == "string" && ($0["enum"] as? [String]) == ["auto"]
        })
    }

    @Test("write_shotlist schema binds production plans to generated source modes")
    func shotlistProductionPlanSchema() throws {
        let tool = try #require(
            ToolDefinitions.all.first { $0.name == .writeShotlist }
        )
        let root = try #require(schemaProperties(tool.inputSchema["properties"]))
        let shots = try #require(root["shots"])
        let items = try #require(shots["items"] as? [String: Any])
        let variants = try #require(items["anyOf"] as? [[String: Any]])
        #expect(variants.count == 3)

        for variant in variants {
            let properties = try #require(schemaProperties(variant["properties"]))
            let source = try #require(properties["source_mode"])
            let sourceModes = try #require(source["enum"] as? [String])
            let sourceMode = try #require(sourceModes.first)
            let required = Set(variant["required"] as? [String] ?? [])
            let blocking = try #require(properties["character_blocking"])
            let blockingItems = try #require(blocking["items"] as? [String: Any])
            let blockingRequired = Set(blockingItems["required"] as? [String] ?? [])
            let propViews = try #require(properties["prop_views"])
            let propViewItems = try #require(propViews["items"] as? [String: Any])
            let propViewProperties = try #require(
                propViewItems["properties"] as? [String: [String: Any]]
            )
            let propPattern = try #require(propViewProperties["prop"]?["pattern"] as? String)
            #expect(
                "__ngv_internal.production_plan.v1".range(
                    of: propPattern,
                    options: .regularExpression
                ) == nil
            )
            #expect("hero_prop".range(of: propPattern, options: .regularExpression) != nil)
            if sourceMode == SourceMode.imported.rawValue {
                #expect(properties["production_plan"] == nil)
                #expect(!required.contains("production_plan"))
            } else {
                let plan = try #require(properties["production_plan"])
                #expect(required.contains("production_plan"))
                let planProperties = try #require(schemaProperties(plan["properties"]))
                let planRequired = Set(plan["required"] as? [String] ?? [])
                let primaryAction = try #require(planProperties["primary_action"])
                let primaryActionPattern = try #require(primaryAction["pattern"] as? String)
                let movementDetail = try #require(planProperties["camera_movement_detail"])
                let anchors = try #require(planProperties["blocking_anchors"])
                let anchorItems = try #require(anchors["items"] as? [String: Any])
                let anchorProperties = try #require(
                    anchorItems["properties"] as? [String: [String: Any]]
                )
                let anchor = try #require(anchorProperties["set_anchor"])
                let pattern = try #require(anchor["pattern"] as? String)
                #expect(planRequired.contains("blocking_anchors"))
                #expect(
                    primaryAction["maxLength"] as? Int
                        == ShotProductionPlan.singleDirectiveMaximumLength
                )
                #expect(movementDetail["pattern"] as? String == primaryActionPattern)
                #expect(
                    "The performer opens the door and enters.".range(
                        of: primaryActionPattern,
                        options: .regularExpression
                    ) == nil
                )
                #expect(
                    "The performer opens the door.".range(
                        of: primaryActionPattern,
                        options: .regularExpression
                    ) != nil
                )
                #expect("screen-right".range(of: pattern, options: .regularExpression) == nil)
                #expect("hall doorway".range(of: pattern, options: .regularExpression) != nil)
            }
            #expect(
                required.contains("source_path")
                    == (sourceMode == SourceMode.aiEnhanced.rawValue)
            )
            if sourceMode == SourceMode.aiEnhanced.rawValue {
                #expect(properties["source_path"]?["minLength"] as? Int == 1)
                #expect(properties["source_path"]?["pattern"] != nil)
            }
            #expect(!blockingRequired.contains("set_anchor"))
            if sourceMode == SourceMode.generated.rawValue {
                let blockingProperties = try #require(
                    blockingItems["properties"] as? [String: [String: Any]]
                )
                let relation = try #require(blockingProperties["relation_to_set"])
                #expect(relation["pattern"] != nil)
            }
        }
    }

    @Test("video generation binds AI-enhanced shots to the declared source")
    func videoGenerationSourceContract() throws {
        #expect(throws: Never.self) {
            try ToolExecutor.validateVideoShotSourceContract(
                sourceMode: .aiEnhanced,
                modelRequiresSourceVideo: true,
                submittedSourceId: "declared-source",
                expectedSourceId: "declared-source"
            )
        }
        for submitted in [nil, "substituted-source"] as [String?] {
            #expect(throws: ToolError.self) {
                try ToolExecutor.validateVideoShotSourceContract(
                    sourceMode: .aiEnhanced,
                    modelRequiresSourceVideo: true,
                    submittedSourceId: submitted,
                    expectedSourceId: "declared-source"
                )
            }
        }
        #expect(throws: ToolError.self) {
            try ToolExecutor.validateVideoShotSourceContract(
                sourceMode: .aiEnhanced,
                modelRequiresSourceVideo: false,
                submittedSourceId: "declared-source",
                expectedSourceId: "declared-source"
            )
        }
        #expect(throws: ToolError.self) {
            try ToolExecutor.validateVideoShotSourceContract(
                sourceMode: .generated,
                modelRequiresSourceVideo: true,
                submittedSourceId: "source",
                expectedSourceId: nil
            )
        }
    }

    @Test("write_storyboard schema requires anchors only for generated blocking")
    func storyboardBlockingAnchorSchema() throws {
        let tool = try #require(
            ToolDefinitions.all.first { $0.name == .writeStoryboard }
        )
        let root = try #require(schemaProperties(tool.inputSchema["properties"]))
        let sections = try #require(root["sections"])
        let sectionItems = try #require(sections["items"] as? [String: Any])
        let sectionProperties = try #require(
            schemaProperties(sectionItems["properties"])
        )
        let steps = try #require(sectionProperties["steps"])
        let stepItems = try #require(steps["items"] as? [String: Any])
        let variants = try #require(stepItems["anyOf"] as? [[String: Any]])
        #expect(variants.count == SourceMode.allCases.count)

        for variant in variants {
            let properties = try #require(schemaProperties(variant["properties"]))
            let source = try #require(properties["source_mode"])
            let sourceMode = try #require((source["enum"] as? [String])?.first)
            let blocking = try #require(properties["character_blocking"])
            let blockingItems = try #require(blocking["items"] as? [String: Any])
            let required = Set(blockingItems["required"] as? [String] ?? [])
            #expect(
                required.contains("set_anchor")
                    == (sourceMode == SourceMode.generated.rawValue)
            )
            if sourceMode == SourceMode.generated.rawValue {
                let properties = try #require(
                    blockingItems["properties"] as? [String: [String: Any]]
                )
                let relation = try #require(properties["relation_to_set"])
                let anchor = try #require(properties["set_anchor"])
                #expect(relation["pattern"] != nil)
                let pattern = try #require(anchor["pattern"] as? String)
                #expect("screen-right".range(of: pattern, options: .regularExpression) == nil)
                #expect("hall doorway".range(of: pattern, options: .regularExpression) != nil)
            }
        }
    }

    @Test("agent dialogs cannot claim or replace host workflow intake")
    @MainActor
    func hostWorkflowIntakeIsExclusive() async throws {
        let harness = ToolHarness()
        let claimed = await harness.runRaw("show_dialog", args: [
            "title": "Bring in your track",
            "fileIntake": [
                "accept": ["audio"],
                "attachAs": "song",
            ],
        ])
        #expect(claimed.isError)
        #expect(ToolHarness.textOf(claimed).contains("unknown field 'attachAs'"))

        let hostDialog = AgentDialog(
            id: "hardstep.project_init.song",
            title: "Track",
            symbol: "waveform",
            intro: nil,
            costHint: nil,
            confirmLabel: "Attach track",
            textField: nil,
            sections: [],
            fileIntake: .init(
                accept: ["audio"],
                prompt: nil,
                allowsMultiple: false,
                attachAs: "song",
                namePrompt: nil,
                required: true
            ),
            purpose: .workflowIntake
        )
        try harness.editor.agentService.presentDialog(hostDialog)
        let replacement = await harness.runRaw("show_dialog", args: [
            "title": "Choose cut mode",
            "sections": [[
                "id": "mode",
                "label": "Cut mode",
                "type": "choices",
                "options": [
                    ["id": "beat", "label": "Beat"],
                    ["id": "section", "label": "Section"],
                ],
            ]],
        ])
        #expect(replacement.isError)
        #expect(harness.editor.agentService.pendingDialog?.id == hostDialog.id)
        #expect(ToolHarness.textOf(replacement).contains("Do not replace or duplicate"))
    }

    @Test("suggest_patterns advertises partial ranking and coverage, never a completeness gate")
    func patternFitDescriptionMatchesContract() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .suggestPatterns })
        let description = tool.description.lowercased()

        #expect(description.contains("valid profiles rank immediately"))
        #expect(description.contains("library_coverage"))
        #expect(description.contains("invalid_profiles"))
        #expect(description.contains("no whole-library completeness gate"))
        #expect(description.contains("fully authored") == false)
        #expect(description.contains("fail-closed gate") == false)
    }

    @Test("import_media requires a saved project and durable working-copy import")
    func importMediaDescriptionMatchesStorageContract() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .importMedia })
        let description = tool.description.lowercased()

        #expect(description.contains("project must be saved first"))
        #expect(description.contains("working media store"))
        #expect(description.contains("included in the package on save"))
        #expect(description.contains("never referenced in place"))
    }

    @Test("durable-write classification covers every project filesystem writer")
    func durableWriteClassificationIsExplicit() {
        let expected: Set<ToolName> = [
            .generateVideo, .generateImage, .generateAudio, .upscaleMedia, .importMedia,
            .initProject, .rewind, .runPhase, .recordRender, .recordAffect, .saveFrameAudit,
            .setLedgerAttribute, .lockLedgerAttribute, .removeLedgerAttribute,
            .attachSong, .copyProjectFile, .extractScene3dPovs,
            .writeAnalysisInterpretation, .writeBrief, .writeProductionDesign,
            .writeTreatment, .writeStoryboard, .writeBible, .writeShotlist,
            .writePhaseExtension, .nextRenderShot,
            .cropToAspect, .assembleTimeline, .runSanity,
        ]

        #expect(Set(ToolName.allCases.filter(\.isDurableWrite)) == expected)
    }

    @Test("send_feedback stays honest about local-only diagnostics")
    @MainActor
    func feedbackDoesNotClaimExternalEscalation() async {
        let instructions = AgentInstructions.serverInstructions.lowercased()
        #expect(instructions.contains("send_feedback once to record it in local-only diagnostics"))
        #expect(instructions.contains("send_feedback once to flag it for the team") == false)

        let description = (
            ToolDefinitions.all.first { $0.name == .sendFeedback }?.description ?? ""
        ).lowercased()
        #expect(description.contains("local-only"))
        #expect(description.contains("does not notify a team or send an external report"))

        let harness = ToolHarness()
        let args: [String: Any] = ["category": "failure", "summary": "A test limitation"]
        let recorded = await harness.runRaw("send_feedback", args: args)
        let duplicate = await harness.runRaw("send_feedback", args: args)
        let recordedText = ToolHarness.textOf(recorded).lowercased()
        let duplicateText = ToolHarness.textOf(duplicate).lowercased()
        #expect(recordedText.contains("local-only diagnostics"))
        #expect(recordedText.contains("no external report was sent"))
        #expect(duplicateText.contains("local-only diagnostics"))
        #expect(duplicateText.contains("team") == false)

        for index in 1..<8 {
            _ = await harness.runRaw("send_feedback", args: [
                "category": "failure",
                "summary": "Distinct test limitation \(index)",
            ])
        }
        let limited = await harness.runRaw("send_feedback", args: [
            "category": "failure",
            "summary": "One beyond the local limit",
        ])
        let limitedText = ToolHarness.textOf(limited).lowercased()
        #expect(limitedText.contains("local-only diagnostics limit reached"))
        #expect(limitedText.contains("recording more"))
        #expect(limitedText.contains("sending more") == false)
    }

    private func auditObjectSchemas(
        _ schema: [String: Any],
        path: String,
        dynamicMaps: [String: String],
        seenDynamicMaps: inout Set<String>,
        failures: inout [String]
    ) {
        if schema["type"] as? String == "object" {
            if let additional = schema["additionalProperties"] as? Bool {
                if additional {
                    if dynamicMaps[path] == "json" {
                        seenDynamicMaps.insert(path)
                    } else {
                        failures.append("\(path): additionalProperties must not be true")
                    }
                }
            } else if let additional = schema["additionalProperties"] as? [String: Any] {
                guard let expectedType = dynamicMaps[path] else {
                    failures.append("\(path): typed dynamic map is not allowlisted")
                    return
                }
                let actualType = additional["type"] as? String
                if actualType != expectedType {
                    failures.append(
                        "\(path): dynamic values must be \(expectedType), got \(actualType ?? "untyped")"
                    )
                }
                seenDynamicMaps.insert(path)
                auditObjectSchemas(
                    additional,
                    path: "\(path).*",
                    dynamicMaps: dynamicMaps,
                    seenDynamicMaps: &seenDynamicMaps,
                    failures: &failures
                )
            } else {
                failures.append("\(path): missing additionalProperties policy")
            }

            if let properties = schemaProperties(schema["properties"]) {
                for key in properties.keys.sorted() {
                    guard let child = properties[key] else { continue }
                    auditObjectSchemas(
                        child,
                        path: "\(path).\(key)",
                        dynamicMaps: dynamicMaps,
                        seenDynamicMaps: &seenDynamicMaps,
                        failures: &failures
                    )
                }
            }
        }

        if schema["type"] as? String == "array",
           let items = schema["items"] as? [String: Any] {
            auditObjectSchemas(
                items,
                path: "\(path)[]",
                dynamicMaps: dynamicMaps,
                seenDynamicMaps: &seenDynamicMaps,
                failures: &failures
            )
        }

        for keyword in ["anyOf", "oneOf", "allOf"] {
            if let alternatives = schema[keyword] as? [[String: Any]] {
                for (index, alternative) in alternatives.enumerated() {
                    auditObjectSchemas(
                        alternative,
                        path: "\(path).\(keyword)[\(index)]",
                        dynamicMaps: dynamicMaps,
                        seenDynamicMaps: &seenDynamicMaps,
                        failures: &failures
                    )
                }
            }
        }

        for keyword in ["$defs", "definitions"] {
            if let definitions = schemaProperties(schema[keyword]) {
                for key in definitions.keys.sorted() {
                    guard let definition = definitions[key] else { continue }
                    auditObjectSchemas(
                        definition,
                        path: "\(path).\(keyword).\(key)",
                        dynamicMaps: dynamicMaps,
                        seenDynamicMaps: &seenDynamicMaps,
                        failures: &failures
                    )
                }
            }
        }
    }

    private func schemaProperties(_ value: Any?) -> [String: [String: Any]]? {
        if let properties = value as? [String: [String: Any]] {
            return properties
        }
        guard let properties = value as? [String: Any] else { return nil }
        return properties.compactMapValues { $0 as? [String: Any] }
    }
}
