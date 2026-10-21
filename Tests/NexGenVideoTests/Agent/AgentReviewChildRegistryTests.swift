import Foundation
import Testing
@testable import NexGenVideo

@MainActor
private final class ReviewChildFixtureRuntime: AgentReviewChildRuntimeDriving {
    var responseModel = "fixture-model"
    var foreignTurn = false
    var sameResponse = false
    var repeatRead = false
    var repeatWrite = false
    var shutDown = false
    var callResults: [ToolResult] = []
    var savedExecute: AgentRuntimeToolExecutor?
    var beforeShutdown: (@MainActor () -> Void)?
    private var responses: [String: AgentModelResponseEvidence] = [:]
    private var task: Task<Void, Never>?

    func start(request: AgentReviewChildRequest, generationID: UUID, sessionID: UUID, turnID: UUID,
               revalidate: @escaping @MainActor @Sendable () throws -> Void,
               execute: @escaping AgentRuntimeToolExecutor) async throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        savedExecute = execute
        let relay = AgentRuntimeEventRelay(sessionID: sessionID, turnID: turnID)
        task = Task { @MainActor in
            do {
                var calls = repeatRead
                    ? [("read", AgentReviewChildRequest.readTool), ("read-again", AgentReviewChildRequest.readTool), ("write", AgentReviewChildRequest.writeTool)]
                    : [("read", AgentReviewChildRequest.readTool), ("write", AgentReviewChildRequest.writeTool)]
                if repeatWrite { calls.append(("write-again", AgentReviewChildRequest.writeTool)) }
                for (id, name) in calls {
                    responses[id] = try .init(sessionID: sessionID, turnID: foreignTurn ? UUID() : turnID,
                        messageID: sameResponse ? "one-response" : id + "-response", modelID: responseModel,
                        toolUseID: id, toolName: name, inputJSON: "{}")
                    callResults.append(await execute(id, name, "{}"))
                }
                relay.finish(.completed(.toolUse))
            } catch {
                relay.yield(.error(.init(kind: .protocolViolation, message: error.localizedDescription)))
                relay.finish(.failed)
            }
        }
        return relay.stream
    }

    func evidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence? {
        responses[toolUseID]
    }

    func requireCurrent() throws {
        if shutDown { throw CancellationError() }
    }

    func shutdown() async {
        beforeShutdown?()
        task?.cancel()
        await task?.value
        await Task.yield()
        shutDown = true
    }
}

@MainActor
@Suite("Isolated review child registry")
struct AgentReviewChildRegistryTests {
    private func request() throws -> AgentReviewChildRequest {
        let home = URL(fileURLWithPath: "/tmp/isolated-review-fixture.ngv")
        let tools = [AgentReviewChildRequest.readTool, AgentReviewChildRequest.writeTool].map {
            AgentRuntimeToolSchema(name: $0, description: "Isolated fixture tool",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false])
        }
        let binding = AgentReviewChildBinding(originalChatID: UUID(), projectID: UUID().uuidString,
            projectGenerationID: UUID(), workingCopyKey: "fixture", workingCopyGeneration: UUID(),
            projectRoot: home, dataRoot: home.appendingPathComponent("pipeline"),
            trustedDeclaration: .init(packName: nil, binding: nil, productionContract: .current),
            workflow: try .core(.current), mutationLeaseID: UUID())
        return .init(runID: UUID(), authID: UUID(), manifestID: "fixture-manifest", pageID: "fixture-page",
            kind: .page, phase: "render_review", binding: binding, backend: .anthropicAPI, modelID: "fixture-model",
            hostContext: .init(interfaceLanguage: .current, baseInstructions: "Fixture only", pack: nil,
                phaseInstructions: "Fixture review", toolSchemas: tools, authority: [.toolExecution, .toolSchemas]),
            bootstrap: "Read and record the supplied fixture context.",
            bounds: .init(maximumRequests: 3, maximumRequestBytes: 1_000_000,
                maximumToolResultBytes: 100_000, maximumEstimatedInputTokens: 100_000,
                maximumOutputTokens: 1_000, maximumMCPOutputTokens: 1_000, maximumTurns: 3))
    }

    @Test func completionWaitsForOwnedShutdownAndLateCallsFailClosed() async throws {
        let runtime = ReviewChildFixtureRuntime()
        let registry = AgentReviewChildRegistry { _ in runtime }
        let request = try request()
        var calls: [AgentReviewChildCallEvidence] = []
        var shutDownObservedWhileActive = false
        runtime.beforeShutdown = { shutDownObservedWhileActive = registry.activeRunID == request.runID }
        let completion = try await registry.perform(request, revalidate: {}, handler: { name, json, evidence in
            try evidence.requireRecordedCall(request: request, toolName: name, canonicalJSON: json)
            calls.append(evidence)
            return name == AgentReviewChildRequest.writeTool ? .suspended("Recorded") : .ok("Fixture page")
        }, progress: { _ in })
        #expect(runtime.shutDown)
        #expect(shutDownObservedWhileActive)
        #expect(registry.activeRunID == nil)
        #expect(completion.calls == calls)
        #expect(completion.modelID == "fixture-model")
        let late = await runtime.savedExecute?("read", AgentReviewChildRequest.readTool, "{}")
        #expect(late?.isError == true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let archived = try JSONDecoder().decode(AgentReviewChildCallEvidence.self, from: encoder.encode(calls[0]))
        #expect(archived.response == calls[0].response)
        #expect(try encoder.encode(archived) == encoder.encode(calls[0]))
        try archived.requireRecordedCall(request: request, toolName: AgentReviewChildRequest.readTool, canonicalJSON: "{}")
    }

    @Test func liveAuthorityIsOnlyValidInsideItsCurrentHandler() async throws {
        let runtime = ReviewChildFixtureRuntime()
        let registry = AgentReviewChildRegistry { _ in runtime }
        var previous: AgentReviewChildCallEvidence?
        var current = true
        _ = try await registry.perform(request(), revalidate: {
            guard current else { throw CancellationError() }
        }, handler: { name, _, evidence in
            try registry.requireCurrent(evidence)
            let decoded = try JSONDecoder().decode(AgentReviewChildCallEvidence.self,
                from: JSONEncoder().encode(evidence))
            #expect(throws: (any Error).self) { try registry.requireCurrent(decoded) }
            if let previous { #expect(throws: (any Error).self) { try registry.requireCurrent(previous) } }
            current = false
            #expect(throws: (any Error).self) { try registry.requireCurrent(evidence) }
            current = true
            previous = evidence
            return name == AgentReviewChildRequest.writeTool ? .suspended("Recorded") : .ok("Fixture page")
        }, progress: { _ in })
    }

    @Test(arguments: [false, true]) func returnedWriteCannotBeRetriedAfterInvalidResult(oversized: Bool) async throws {
        let runtime = ReviewChildFixtureRuntime()
        runtime.repeatWrite = true
        let registry = AgentReviewChildRegistry { _ in runtime }
        var writes = 0
        do {
            _ = try await registry.perform(request(), revalidate: {}, handler: { name, _, _ in
                if name == AgentReviewChildRequest.writeTool {
                    writes += 1
                    if oversized { return .suspended(String(repeating: "x", count: 100_001)) }
                }
                return .ok("Committed fixture, but missing turn suspension")
            }, progress: { _ in })
            Issue.record("An invalid writer result completed a page.")
        } catch { }
        #expect(writes == 1)
        #expect(runtime.callResults.count == 3)
        #expect(runtime.callResults[1].isError && runtime.callResults[2].isError)
    }

    @Test func cancellingParentClosesAdmissionBeforeChildDrain() async throws {
        let runtime = ReviewChildFixtureRuntime()
        let registry = AgentReviewChildRegistry { _ in runtime }
        let request = try request()
        var releaseRead: CheckedContinuation<Void, Never>?
        var entered = false
        var writes = 0
        let owner = Task { @MainActor in
            try await registry.perform(request, revalidate: {}, handler: { name, _, _ in
                if name == AgentReviewChildRequest.readTool {
                    entered = true
                    await withCheckedContinuation { releaseRead = $0 }
                    return .ok("Fixture page")
                }
                writes += 1
                return .suspended("Unexpected")
            }, progress: { _ in })
        }
        for _ in 0..<100 where !entered { await Task.yield() }
        #expect(entered)
        owner.cancel()
        releaseRead?.resume()
        do { _ = try await owner.value; Issue.record("Cancelled parent completed a page.") } catch { }
        #expect(writes == 0)
        #expect(runtime.shutDown)
        #expect(registry.activeRunID == nil)
    }

    @Test func foreignTurnCannotReachDedicatedHandler() async throws {
        let runtime = ReviewChildFixtureRuntime()
        runtime.foreignTurn = true
        let registry = AgentReviewChildRegistry { _ in runtime }
        var handled = 0
        do {
            _ = try await registry.perform(request(), revalidate: {}, handler: { _, _, _ in
                handled += 1; return .suspended("Unexpected")
            }, progress: { _ in })
            Issue.record("Foreign child evidence completed a page.")
        } catch { }
        #expect(handled == 0)
        #expect(runtime.shutDown)
    }

    @Test func modelChangeCannotReachDedicatedHandler() async throws {
        let runtime = ReviewChildFixtureRuntime()
        runtime.responseModel = "another-model"
        let registry = AgentReviewChildRegistry { _ in runtime }
        var handled = 0
        do {
            _ = try await registry.perform(request(), revalidate: {}, handler: { _, _, _ in
                handled += 1; return .suspended("Unexpected")
            }, progress: { _ in })
            Issue.record("A changed model completed the page.")
        } catch { }
        #expect(handled == 0)
        #expect(runtime.shutDown)
    }

    @Test func sameResponseCannotClaimItSawItsOwnReadResult() async throws {
        let runtime = ReviewChildFixtureRuntime()
        runtime.sameResponse = true
        let registry = AgentReviewChildRegistry { _ in runtime }
        var writes = 0
        do {
            _ = try await registry.perform(request(), revalidate: {}, handler: { name, _, _ in
                if name == AgentReviewChildRequest.writeTool { writes += 1; return .suspended("Unexpected") }
                return .ok("Fixture image page")
            }, progress: { _ in })
            Issue.record("A response recorded observations before receiving its read result.")
        } catch { }
        #expect(writes == 0)
        #expect(runtime.callResults.last?.isError == true)
    }

    @Test func repeatedReadDoesNotDeliverImagesAgain() async throws {
        let runtime = ReviewChildFixtureRuntime()
        runtime.repeatRead = true
        let registry = AgentReviewChildRegistry { _ in runtime }
        var reads = 0
        _ = try await registry.perform(request(), revalidate: {}, handler: { name, _, _ in
            if name == AgentReviewChildRequest.writeTool { return .suspended("Recorded") }
            reads += 1
            return .init(content: [.image(base64: "AA==", mediaType: "image/png")], isError: false)
        }, progress: { _ in })
        #expect(reads == 1)
        #expect(runtime.callResults.count == 3)
        #expect(runtime.callResults[1].content.allSatisfy { if case .text = $0 { true } else { false } })
    }

    @Test func requestAuthorityLossRejectsAllFurtherCalls() async throws {
        let runtime = ReviewChildFixtureRuntime()
        let registry = AgentReviewChildRegistry { _ in runtime }
        var current = true
        var writes = 0
        do {
            _ = try await registry.perform(request(), revalidate: {
                guard current else { throw CancellationError() }
            }, handler: { name, _, _ in
                if name == AgentReviewChildRequest.writeTool { writes += 1 }
                current = false
                return .ok("Fixture page")
            }, progress: { _ in })
            Issue.record("A stale project completed a review.")
        } catch { }
        #expect(writes == 0)
        #expect(runtime.shutDown)
    }

    @Test func childLaunchHasNoOrdinaryResumeReadPluginsOrProjectDirectory() throws {
        let request = try request()
        let args = AgentReviewChildCLIRuntime.arguments(request: request, port: 49152, sessionID: UUID(), generationID: UUID())
        #expect(!args.contains("--resume"))
        #expect(!args.contains("--plugin-dir"))
        #expect(!args.contains("--add-dir"))
        #expect(!args.contains("Read"))
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--system-prompt"))
        #expect(AgentReviewChildCLIRuntime.environment(request: request)["MAX_MCP_OUTPUT_TOKENS"] == "1000")
    }
}
