import Foundation
import MCP

extension ToolExecutor {
    /// Run a provider's non-generative WORKFLOW tool over its MCP (M4 — capability tool-calls).
    /// LLM → NGV → Provider: the agent names a capability (a tool), NGV resolves which activated
    /// provider offers it (cheapest first) and drives that provider's MCP as the client. Both locked
    /// gates hold: content generation is refused here (it must go through the gated generate_* paths
    /// so the prompt engine runs), and the paid call waits for the user's spend approval — the agent
    /// never spends or calls a provider on its own.
    func runProviderTool(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let tool = try args.requireString("tool")
        if Self.looksLikeGeneration(tool) {
            throw ToolError("'\(tool)' looks like content generation — use generate_video / generate_image / generate_audio (or upscale_media). Those enforce the prompt engine and the spend confirmation; run_provider_tool is for non-generative workflow tools only.")
        }

        let providers = ProviderManifest.toolProvidersCheapestFirst()
        guard !providers.isEmpty else {
            throw ToolError("No provider MCP is configured. Add one in Settings \u{2192} Providers (MCP server URL) to use provider workflow tools.")
        }

        let arguments = Self.mcpArguments(args["arguments"])
        var offered: Set<String> = []

        for provider in providers {
            guard let client = await ProviderMCP.client(for: provider) else { continue }
            let tools: [MCPProviderClient.DiscoveredTool]
            do { tools = try await client.discoverTools() }
            catch { await client.disconnect(); continue }
            offered.formUnion(tools.map(\.name))

            guard let match = tools.first(where: { $0.name.caseInsensitiveCompare(tool) == .orderedSame }) else {
                await client.disconnect(); continue
            }

            // Prompt-engine gate: a discovered tool that takes a creative prompt IS generation and must
            // go through the gated generate_* paths (compile_prompt). The name denylist is a cheap
            // pre-filter; this schema/argument check is the robust catch — a provider's own generator
            // (however named) advertises a `prompt`/`lyrics` field, a true workflow tool does not.
            if Self.advertisesPrompt(match.inputSchema) || Self.argumentsCarryPrompt(args["arguments"]) {
                await client.disconnect()
                throw ToolError("'\(match.name)' takes a creative prompt \u{2014} that's generation. Route it through generate_video / generate_image / generate_audio so the prompt engine runs. run_provider_tool is for prompt-free workflow tools only.")
            }

            let authorization: GenerationAuthorization
            do {
                authorization = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
                    modelId: match.name,
                    provider: provider,
                    transport: .mcp,
                    endpoint: match.name,
                    editor: editor
                )
            } catch {
                await client.disconnect()
                throw ToolError(error.localizedDescription)
            }

            // Paid, provider-side action → the user's final word (Cost-Guard), same as any render.
            // Cost is unknown for an arbitrary provider tool, so this always asks.
            let option = SpendOption(
                modelId: match.name,
                modelName: match.name,
                target: authorization.target,
                credits: nil,
                requiresCatalogAvailability: false
            )
            let approval = SpendApproval(
                id: UUID().uuidString,
                recommendedOptionId: option.id,
                options: [option],
                actionLabel: "Run \(match.name)"
            )
            if case .declined = await editor.agentService.requestSpendApproval(approval) {
                try? editor.recordSpendEvent(
                    authorization: authorization,
                    kind: .released,
                    note: "User declined the provider tool."
                )
                await client.disconnect()
                throw ToolError("Tool call declined — the user did not approve running '\(match.name)'.")
            }

            do {
                try editor.recordSpendEvent(
                    authorization: authorization,
                    kind: .submitted,
                    providerRequestId: UUID().uuidString,
                    money: authorization.estimate
                )
                let texts = try await client.callTool(name: match.name, arguments: arguments)
                await client.disconnect()
                let body = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    return .ok("\(match.name) ran on \(provider.displayName) with no text output.")
                }
                return .ok("\(match.name) (\(provider.displayName)):\n\(body)\n\nIf this returned media URLs, import them with import_media before using them on the timeline.")
            } catch {
                await client.disconnect()
                throw ToolError("\(match.name) on \(provider.displayName) failed: \(error.localizedDescription)")
            }
        }

        let seen = offered.isEmpty ? "" : " Tools offered by configured provider MCPs: \(offered.sorted().joined(separator: ", "))."
        throw ToolError("No configured provider MCP offers a tool named '\(tool)'.\(seen)")
    }

    /// Refuse tool names that denote CONTENT GENERATION — those must go through the gated generate_*
    /// paths so the prompt engine + spend confirmation run. Verb/pattern based (not bare media nouns)
    /// so genuine workflow tools like `reframe` or `remove_background` still pass.
    nonisolated static func looksLikeGeneration(_ name: String) -> Bool {
        let n = name.lowercased()
        let markers = [
            "generate", "create_image", "create_video", "create_audio", "txt2", "text2",
            "text-to-", "t2v", "i2v", "t2i", "t2a", "img2img", "image-to-", "tts",
            "text_to_speech", "synthesi", "dream", "upscale", "outpaint", "inpaint", "diffus",
        ]
        return markers.contains { n.contains($0) }
    }

    /// Names that denote a creative prompt to a content model — the prompt-engine gate's concern.
    nonisolated static let promptFieldNames: Set<String> = ["prompt", "multi_prompt", "negative_prompt", "lyrics"]

    /// True when the tool's input schema advertises a creative-prompt field (⇒ it's generation).
    /// Walks the JSON schema structurally (Value is Codable → JSON) so nested `params.properties.prompt`
    /// shapes (as Higgsfield uses) are caught regardless of nesting.
    nonisolated static func advertisesPrompt(_ schema: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(schema),
              let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        return jsonContainsPromptKey(json)
    }

    /// Walk the RAW arguments (before string coercion) for a creative-prompt field — nested objects
    /// like `{ "params": { "prompt": … } }`, and values that are themselves stringified JSON, are
    /// caught, not just top-level keys.
    nonisolated static func argumentsCarryPrompt(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        return jsonContainsPromptKey(raw)
    }

    private nonisolated static func jsonContainsPromptKey(_ any: Any) -> Bool {
        if let dict = any as? [String: Any] {
            for (key, value) in dict {
                if promptFieldNames.contains(key.lowercased()) { return true }
                if jsonContainsPromptKey(value) { return true }
            }
            return false
        }
        if let array = any as? [Any] { return array.contains { jsonContainsPromptKey($0) } }
        // A value may itself be stringified JSON (agent-encoded params) — parse and walk it too.
        if let s = any as? String, let data = s.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data), !(parsed is String) {
            return jsonContainsPromptKey(parsed)
        }
        return false
    }

    nonisolated static func mcpArguments(_ raw: Any?) -> [String: Value] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: Value] = [:]
        for (key, value) in dict { out[key] = mcpValue(value) }
        return out
    }

    private nonisolated static func mcpValue(_ raw: Any) -> Value {
        switch raw {
        case is NSNull: .null
        case let value as Bool: .bool(value)
        case let value as Int: .int(value)
        case let value as Double: .double(value)
        case let value as String: .string(value)
        case let values as [Any]: .array(values.map(mcpValue))
        case let values as [String: Any]: .object(values.mapValues(mcpValue))
        default: .string(String(describing: raw))
        }
    }
}
