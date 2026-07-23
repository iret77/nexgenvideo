import Testing
@testable import NexGenVideo

@Suite("Agent tool semantic contracts")
struct ToolDefinitionContractTests {
    @Test("every object schema is closed or an explicitly typed dynamic map")
    func objectSchemasAreClosed() {
        let dynamicMaps: [String: String] = [
            "apply_effect.effects[].params": "number",
            "run_provider_tool.arguments": "string",
            "save_frame_audit.checks": "object",
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

        let negativeCost = await harness.runRaw("record_render", args: [
            "phase": "preview",
            "shot_id": "s001",
            "cost_eur": -0.01,
        ])
        #expect(ToolHarness.textOf(negativeCost).contains("expected at least 0"))

        let empty = await harness.runRaw("show_blocks", args: ["blocks": []])
        #expect(ToolHarness.textOf(empty).contains("expected at least 1 item"))
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
            .attachSong, .copyProjectFile, .extractScene3dPovs, .writeBrief,
            .setGateState, .cropToAspect, .assembleTimeline,
        ]

        #expect(Set(ToolName.allCases.filter(\.isDurableWrite)) == expected)
    }

    @Test("send_feedback stays honest about local-only diagnostics")
    @MainActor
    func feedbackDoesNotClaimExternalEscalation() async {
        let instructions = AgentInstructions.serverInstructions.lowercased()
        #expect(instructions.contains("send_feedback once to record it in local diagnostics"))
        #expect(instructions.contains("send_feedback once to flag it for the team") == false)

        let harness = ToolHarness()
        let args: [String: Any] = ["category": "failure", "summary": "A test limitation"]
        _ = await harness.runRaw("send_feedback", args: args)
        let duplicate = await harness.runRaw("send_feedback", args: args)
        let text = ToolHarness.textOf(duplicate).lowercased()
        #expect(text.contains("local diagnostics"))
        #expect(text.contains("team") == false)
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
                    failures.append("\(path): additionalProperties must not be true")
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
    }

    private func schemaProperties(_ value: Any?) -> [String: [String: Any]]? {
        if let properties = value as? [String: [String: Any]] {
            return properties
        }
        guard let properties = value as? [String: Any] else { return nil }
        return properties.compactMapValues { $0 as? [String: Any] }
    }
}
