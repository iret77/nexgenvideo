import Foundation
import NaturalLanguage
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Existing Claude backends live smoke", .serialized)
struct AgentBackendLiveAcceptanceTests {
    @Test func actualBackendRoundTripAndCancellation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NGV_AGENT_BACKEND_LIVE_ACCEPTANCE"] == "1" else { return }
        guard env["CI"] == "true", env["NGV_AGENT_BACKEND_SPEND_APPROVED"] == "1",
              let backend = env["NGV_AGENT_LIVE_BACKEND"].flatMap(AgentBackend.init(rawValue:)),
              AgentBackend.selectableCases.contains(backend), let output = env["NGV_AGENT_LIVE_EVIDENCE"] else {
            throw SmokeFailure("The live backend smoke requires its separately approved Actions configuration.")
        }
        let key = env["NGV_BACKEND_API_KEY"] ?? ""
        let model: AnthropicModelInfo?
        let installedCLIVersion: String?
        if backend == .anthropicAPI {
            guard !key.isEmpty, let id = env["NGV_BACKEND_MODEL_ID"], !id.isEmpty else {
                throw SmokeFailure("The dedicated CI API key and exact model selection are required.")
            }
            do {
                let models = try await AnthropicModelsAPI.fetchAll(apiKey: key, transport: AnthropicModelsAPI.liveTransport)
                model = models.first { $0.id == id && $0.isActive }
            } catch { throw SmokeFailure("Live Anthropic model discovery failed; no fallback model was submitted.") }
            guard model != nil else { throw SmokeFailure("The selected API model is absent from actual discovery.") }
            installedCLIVersion = nil
        } else {
            guard key.isEmpty, env["ANTHROPIC_API_KEY"]?.isEmpty != false,
                  env["CLAUDE_CODE_OAUTH_TOKEN"]?.isEmpty == false,
                  env["CLAUDE_CONFIG_DIR"]?.isEmpty == false else {
                throw SmokeFailure("The CLI smoke requires its isolated CI subscription authentication without an API-key fallback.")
            }
            let status = await Task.detached { ClaudeCodeLocator.status() }.value
            guard let expected = env["NGV_EXPECTED_CLAUDE_VERSION"], !expected.isEmpty,
                  let actual = status.version, status.found, status.isAuthenticated, actual == expected else {
                throw SmokeFailure("The actual installed CLI version or authentication did not match the approved smoke.")
            }
            model = nil
            installedCLIVersion = status.version
        }
        var cases: [[String: Any]] = []
        for operation in ["echo", "hold"] {
            cases.append(try await run(operation: operation, backend: backend, key: key, model: model))
        }
        let result: [String: Any] = ["schema": "agent-backend-live/v1", "backend": backend.rawValue,
            "sourceSHA": env["GITHUB_SHA"] ?? "", "processID": ProcessInfo.processInfo.processIdentifier,
            "liveProvider": true, "mediaGeneration": false, "nativeUI": false,
            "installedCLIVersion": installedCLIVersion as Any? ?? NSNull(),
            "discoveredAPIModelID": model?.id as Any? ?? NSNull(), "cases": cases]
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: destination, options: .atomic)
    }

    private struct SmokeFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func run(operation: String, backend: AgentBackend, key: String, model: AnthropicModelInfo?) async throws -> [String: Any] {
        let tool = AgentBackendLiveMCP()
        let language = AgentInterfaceLanguage.current
        guard ["en", "de"].contains(String(language.identifier.prefix(2))) else {
            throw SmokeFailure("This live smoke only has an independent English/German response-language oracle.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-live-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let adapter: any AgentRuntimeAdapter
        let control: AgentReviewChildStreamControl?
        if let model {
            let owned = AgentReviewChildStreamControl { bytes in
                guard let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      body["model"] as? String == model.id, body["max_tokens"] as? Int == 1024 else {
                    throw SmokeFailure("The live API request changed its discovered model or output envelope.")
                }
            }
            control = owned
            adapter = AnthropicRuntimeAdapter(client: AnthropicClient(apiKey: key, model: model, maxTokens: 1024, reviewStreamControl: owned))
        }
        else { control = nil; adapter = ClaudeCodeRuntimeAdapter() }
        var reader: Task<[AgentRuntimeEventEnvelope], Never>?
        var stage = "subscription authentication"
        do {
            if backend == .claudeCode {
                guard let executable = ClaudeCodeLocator.locateOnly() else { throw SmokeFailure("The approved CLI is absent.") }
                _ = try await AgentReviewChildCLIIsolation.accountStatus(executable: executable, workingDirectory: directory)
            }
            stage = "session and transport startup"
            let port = backend == .claudeCode ? try await tool.start() : 0
            let context = AgentRuntimeHostContext(interfaceLanguage: language,
                baseInstructions: AgentInstructions.serverInstructions(language: language), pack: nil,
                phaseInstructions: nil, toolSchemas: [tool.schema], authority: [.toolSchemas, .toolExecution])
            let request = AgentRuntimeSessionRequest(sessionID: tool.sessionID, runtimeGenerationID: tool.generationID,
                providerSessionID: nil, priorMessages: [], hostContext: context, workingDirectory: directory,
                pluginDirectories: [], providerExtensions: [], mcpPort: port,
                executeTool: { id, name, json in await tool.invoke(id: id, name: name, json: json) })
            try adapter.start(request)
            let prompt: String
            if language.identifier.hasPrefix("de") {
                prompt = "Call acceptance_echo exactly once with operation \(operation) and nonce \(tool.nonce). After receiving a receipt, include that exact receipt and briefly explain what this test checked and that no media was generated."
            } else {
                prompt = "Rufe acceptance_echo genau einmal mit operation \(operation) und nonce \(tool.nonce) auf. Gib nach dem Empfang den vollständigen Beleg wieder und erkläre kurz, was geprüft wurde und dass keine Medien erzeugt wurden."
            }
            let message = AgentRuntimeMessage(role: .user, content: [.text(prompt)])
            let turnID = UUID()
            let stream = try adapter.send(.init(sessionID: tool.sessionID, turnID: turnID, messages: [message], currentMessage: message,
                toolSearchPinnedTools: [tool.schema.name]))
            stage = "actual model roundtrip"
            let collecting = Task { @MainActor in
                var values: [AgentRuntimeEventEnvelope] = []
                for await event in stream { values.append(event) }
                return values
            }
            reader = collecting
            var cancellationEvidence: AgentModelResponseEvidence?
            var stoppedDuringHold = false
            if operation == "hold" {
                stage = "cancellable tool arrival"
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                while !tool.holdStarted, ContinuousClock.now < deadline {
                    guard adapter.state == .running(sessionID: tool.sessionID, turnID: turnID) else {
                        throw SmokeFailure("The live model stopped before reaching the cancellable tool operation.")
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard tool.holdStarted else { throw SmokeFailure("The actual live model did not reach the cancellable operation.") }
                guard let call = tool.calls.first else { throw SmokeFailure("The in-flight tool has no actual call ID.") }
                if let cli = adapter as? ClaudeCodeRuntimeAdapter {
                    cancellationEvidence = await cli.awaitModelResponseEvidence(toolUseID: call.id, sessionID: tool.sessionID, turnID: turnID)
                } else { cancellationEvidence = adapter.modelResponseEvidence(toolUseID: call.id) }
                guard cancellationEvidence != nil else { throw SmokeFailure("The cancellable call lacks actual response evidence.") }
                stage = "runtime shutdown during the pending tool"
                stoppedDuringHold = await stop(adapter, sessionID: tool.sessionID)
                tool.releaseHold()
            }
            let events = await collecting.value
            stage = "originating model and tool evidence"
            guard events.allSatisfy({ $0.sessionID == tool.sessionID && $0.turnID == turnID }), tool.calls.count == 1,
                  events.filter({ if case .toolCall = $0.event { true } else { false } }).count == 1,
                  let call = tool.calls.first, let response = cancellationEvidence ?? adapter.modelResponseEvidence(toolUseID: call.id),
                  response.sessionID == tool.sessionID, response.turnID == turnID, response.matchesHostTool(tool.schema.name),
                  model.map({ $0.id == response.modelID }) ?? true,
                  response.toolUseID == call.id, response.toolInputSHA256 == (try AgentModelResponseEvidence.inputHash(call.json)) else {
                throw SmokeFailure("The live request lacks exact originating model/tool evidence.")
            }
            let terminals = events.compactMap { envelope -> AgentRuntimeTerminal? in
                if case .terminal(let terminal) = envelope.event { return terminal }; return nil
            }
            var texts: [String: String] = [:]
            for event in events {
                if case .text(let id, let value, let delta) = event.event {
                    let id = id ?? "response"; texts[id] = delta ? (texts[id] ?? "") + value : value
                }
            }
            let text = texts.values.joined(separator: "\n")
            stage = "terminal result and interface language"
            if operation == "echo" {
                guard terminals == [.completed(.endTurn)], text.contains(tool.receipt), text.count >= 40 else {
                    throw SmokeFailure("The real model did not consume and return the actual host receipt.")
                }
                let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
                guard recognizer.dominantLanguage?.rawValue == String(language.identifier.prefix(2)) else {
                    throw SmokeFailure("The live response followed the foreign-language fixture instead of the host interface language.")
                }
            } else {
                guard terminals == [.cancelled] else { throw SmokeFailure("The in-flight live operation did not end with exactly one cancellation.") }
            }
            stage = "owned runtime and MCP teardown"
            let stopped: Bool
            if operation == "hold" { stopped = stoppedDuringHold }
            else { stopped = await stop(adapter, sessionID: tool.sessionID) }
            await control?.shutdown()
            await tool.stop()
            guard stopped, tool.stopped else { throw SmokeFailure("The owned live runtime or MCP listener did not finish shutdown.") }
            try FileManager.default.removeItem(at: directory)
            return ["operation": operation, "sessionID": tool.sessionID.uuidString, "turnID": turnID.uuidString,
                "modelID": response.modelID, "messageID": response.messageID, "toolUseID": call.id,
                "toolName": response.toolName, "inputSHA256": response.toolInputSHA256,
                "toolInputJSON": response.toolInputJSON, "nonce": tool.nonce, "receipt": tool.receipt,
                "responseText": text,
                "usesLocalMCP": backend == .claudeCode, "mcpPort": port,
                "interfaceLanguage": language.identifier, "receiptReturned": operation == "echo",
                "cancelledWhileToolPending": operation == "hold", "ownedRuntimeStopped": stopped,
                "mcpStopped": tool.stopped, "schemaValidated": true]
        } catch {
            tool.releaseHold()
            _ = await stop(adapter, sessionID: tool.sessionID)
            await control?.shutdown()
            await tool.stop(); reader?.cancel(); _ = await reader?.value
            try? FileManager.default.removeItem(at: directory)
            let failure = (error as? SmokeFailure) ?? SmokeFailure("The live backend smoke failed during \(stage). No fallback was attempted.")
            if let path = ProcessInfo.processInfo.environment["NGV_AGENT_LIVE_EVIDENCE"] {
                let destination = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("live-backend-failure.json")
                let evidence = ["schema": "agent-backend-live-failure/v1", "backend": backend.rawValue,
                    "operation": operation, "stage": stage, "reason": failure.message]
                try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: destination, options: .atomic)
            }
            throw failure
        }
    }

    private func stop(_ adapter: any AgentRuntimeAdapter, sessionID: UUID) async -> Bool {
        if let cli = adapter as? ClaudeCodeRuntimeAdapter { return await cli.endAndWait(sessionID: sessionID) }
        if let api = adapter as? AnthropicRuntimeAdapter {
            await api.endAndWait(sessionID: sessionID)
            return api.state == .ended(sessionID: sessionID)
        }
        return false
    }
}
