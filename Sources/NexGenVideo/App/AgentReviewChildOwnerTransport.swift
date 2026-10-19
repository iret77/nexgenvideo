import Foundation
import os

@MainActor
final class AgentReviewChildOwnerTransport {
    nonisolated static let modelID = "fixture-review-model"
    private(set) var children: [AgentReviewChildRequest] = []
    private(set) var cliLines: [String] = []
    private(set) var stoppedCLIChildren = 0
    private(set) var heldRequest: AgentReviewChildRequest?
    private(set) var shutdownHeld = false
    private var returnedPages = Set<String>()
    private var shutdownReleased = false
    private var shutdownWaiter: CheckedContinuation<Void, Never>?
    private var httpSession: URLSession?

    func runtime(_ request: AgentReviewChildRequest) throws -> any AgentReviewChildRuntimeDriving {
        guard WorkspaceUIAcceptance.isRequested else { throw ToolError("Explicit native acceptance is required.") }
        children.append(request)
        let underlying: any AgentReviewChildRuntimeDriving
        if request.backend == .anthropicAPI {
            AgentReviewChildOwnerHTTP.bind(request)
            if httpSession == nil {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [AgentReviewChildOwnerHTTP.self]
                httpSession = URLSession(configuration: configuration)
            }
            guard let httpSession else { throw ToolError("The isolated HTTP fixture has no session.") }
            underlying = AgentReviewChildRuntime(apiClient: AnthropicClient(apiKey: AgentReviewChildOwnerHTTP.key,
                model: .unlisted(Self.modelID), urlSession: httpSession), cliPreflight: { _, _ in throw ToolError("The API fixture cannot launch a CLI.") })
        } else { underlying = CLI(owner: self) }
        return CheckpointRuntime(owner: self, request: request, underlying: underlying)
    }

    func releaseShutdown() { shutdownReleased = true; shutdownWaiter?.resume(); shutdownWaiter = nil }

    func close() { releaseShutdown(); httpSession?.invalidateAndCancel(); httpSession = nil }

    private func returnedWrite(_ request: AgentReviewChildRequest) {
        guard request.kind == .page, returnedPages.insert(request.authID.uuidString + "/" + request.pageID).inserted else { return }
        if returnedPages.count == 3 { heldRequest = request }
    }

    private func waitForCheckpoint(_ request: AgentReviewChildRequest) async {
        guard heldRequest?.authID == request.authID, heldRequest?.pageID == request.pageID, !shutdownReleased else { return }
        shutdownHeld = true
        await withCheckedContinuation { shutdownWaiter = $0 }
        shutdownHeld = false
    }

    @MainActor private final class CheckpointRuntime: AgentReviewChildRuntimeDriving {
        private weak var owner: AgentReviewChildOwnerTransport?
        private let request: AgentReviewChildRequest
        private let underlying: any AgentReviewChildRuntimeDriving
        private var shutdownTask: Task<Void, Never>?

        init(owner: AgentReviewChildOwnerTransport, request: AgentReviewChildRequest,
             underlying: any AgentReviewChildRuntimeDriving) {
            self.owner = owner; self.request = request; self.underlying = underlying
        }

        func start(request: AgentReviewChildRequest, generationID: UUID, sessionID: UUID, turnID: UUID,
                   revalidate: @escaping @MainActor @Sendable () throws -> Void,
                   execute: @escaping AgentRuntimeToolExecutor) async throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            try await underlying.start(request: request, generationID: generationID, sessionID: sessionID,
                turnID: turnID, revalidate: revalidate) { [weak owner = self.owner] id, name, json in
                    let result = await execute(id, name, json)
                    if name == AgentReviewChildRequest.writeTool, !result.isError, result.turnDisposition == .suspendTurn {
                        owner?.returnedWrite(request)
                    }
                    return result
                }
        }

        func evidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence? {
            await underlying.evidence(toolUseID: toolUseID, sessionID: sessionID, turnID: turnID)
        }

        func requireCurrent() throws { try underlying.requireCurrent() }

        func shutdown() async {
            if let shutdownTask { await shutdownTask.value; return }
            let task = Task<Void, Never> { @MainActor [underlying = self.underlying, request = self.request, weak owner = self.owner] in
                await underlying.shutdown()
                await owner?.waitForCheckpoint(request)
            }
            shutdownTask = task
            await task.value
        }
    }

    nonisolated static func submission(_ result: ToolResult, request: AgentReviewChildRequest) throws -> String {
        let texts = result.content.compactMap { block -> String? in if case .text(let value) = block { value } else { nil } }
        var identifiers: [String]?
        for text in texts {
            guard let first = text.firstIndex(of: "{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(text[first...].utf8)) as? [String: Any] else { continue }
            let rows = object["items"] as? [[String: Any]] ?? object["units"] as? [[String: Any]]
            if let rows { identifiers = rows.compactMap { $0["id"] as? String }; break }
        }
        guard !result.isError, let identifiers, !identifiers.isEmpty else { throw ToolError("The transport fixture did not receive actual labelled review inputs.") }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["manifestID": request.manifestID,
            "pageID": request.pageID, "observations": identifiers.map { ["itemID": $0,
                "text": "Fixture response received this exact labelled item. This controlled response proves transport and coverage, not semantic image quality."] }, "findings": []], options: [.sortedKeys]), as: UTF8.self)
    }

    @MainActor private final class CLI: AgentReviewChildRuntimeDriving {
        private weak var owner: AgentReviewChildOwnerTransport?
        private var task: Task<Void, Never>?
        private var stopped = false
        private var responses: [String: AgentModelResponseEvidence] = [:]
        init(owner: AgentReviewChildOwnerTransport) { self.owner = owner }
        func start(request: AgentReviewChildRequest, generationID: UUID, sessionID: UUID, turnID: UUID,
                   revalidate: @escaping @MainActor @Sendable () throws -> Void,
                   execute: @escaping AgentRuntimeToolExecutor) async throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let relay = AgentRuntimeEventRelay(sessionID: sessionID, turnID: turnID)
            task = Task { @MainActor in
                do {
                    @MainActor func call(_ tool: String, input: String) async throws -> ToolResult {
                        try await Task.sleep(for: .milliseconds(150)); try revalidate()
                        let id = UUID().uuidString, message = UUID().uuidString
                        let object: [String: Any] = ["type": "assistant", "message": ["id": message,
                            "model": AgentReviewChildOwnerTransport.modelID, "content": [["type": "tool_use", "id": id,
                                "name": "mcp__nexgen__" + tool, "input": try JSONSerialization.jsonObject(with: Data(input.utf8))]]]]
                        let line = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
                        owner?.cliLines.append(line)
                        var model: String?
                        for event in ClaudeStreamDecoder.decode(line: line) {
                            if case .responseMetadata(let actualMessage, let actualModel) = event, actualMessage == message { model = actualModel }
                            if case .assistantBlock(let actualMessage, .toolUse(let actualID, let actualTool, let json)) = event {
                                guard let model else { throw ToolError("The actual CLI decoder lost response metadata.") }
                                responses[actualID] = try .init(sessionID: sessionID, turnID: turnID, messageID: actualMessage,
                                    modelID: model, toolUseID: actualID, toolName: actualTool, inputJSON: json)
                            }
                        }
                        guard responses[id] != nil else { throw ToolError("The actual CLI decoder did not produce the tool call.") }
                        return await execute(id, tool, input)
                    }
                    let read = try await call(AgentReviewChildRequest.readTool, input: "{}")
                    let write = try await call(AgentReviewChildRequest.writeTool,
                        input: AgentReviewChildOwnerTransport.submission(read, request: request))
                    guard !write.isError, write.turnDisposition == .suspendTurn else { throw ToolError("The actual Host writer rejected the controlled CLI response.") }
                    relay.finish(.completed(.toolUse))
                } catch {
                    relay.yield(.error(.init(kind: .protocolViolation, message: error.localizedDescription)))
                    relay.finish(error is CancellationError ? .cancelled : .failed)
                }
            }
            return relay.stream
        }
        func evidence(toolUseID: String, sessionID: UUID, turnID: UUID) async -> AgentModelResponseEvidence? { responses[toolUseID] }
        func requireCurrent() throws { if stopped { throw CancellationError() } }
        func shutdown() async {
            guard !stopped else { return }
            stopped = true
            task?.cancel(); await task?.value
            owner?.stoppedCLIChildren += 1
        }
    }
}

final class AgentReviewChildOwnerHTTP: URLProtocol, @unchecked Sendable {
    static let key = "ngv-review-http-fixture"
    struct State: Sendable {
        var request: AgentReviewChildRequest?
        var bodies: [Data] = []
        var responses: [Data] = []
        var errors: [String] = []
    }
    private static let storage = OSAllocatedUnfairLock(initialState: State())
    private struct Lifetime { var task: Task<Void, Never>?; var stopped = false }
    private let lifetime = OSAllocatedUnfairLock(initialState: Lifetime())
    static func bind(_ request: AgentReviewChildRequest) { storage.withLock { $0.request = request } }
    static func reset() { storage.withLock { $0 = State() } }
    static var evidence: State { storage.withLock { $0 } }
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let task = Task { [self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard request.url?.absoluteString == "https://api.anthropic.com/v1/messages",
                      request.value(forHTTPHeaderField: "x-api-key") == Self.key else {
                    throw ToolError("The isolated API fixture refused an unexpected endpoint or credential.")
                }
                let body: Data
                if let bytes = request.httpBody { body = bytes }
                else if let input = request.httpBodyStream {
                    input.open(); defer { input.close() }
                    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                    while input.hasBytesAvailable {
                        let count = input.read(&buffer, maxLength: buffer.count)
                        guard count >= 0 else { throw input.streamError ?? CocoaError(.fileReadUnknown) }
                        if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                    }
                    body = bytes
                } else { throw CocoaError(.fileReadUnknown) }
                guard let bound = Self.storage.withLock({ $0.request }),
                      let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      object["model"] as? String == AgentReviewChildOwnerTransport.modelID,
                      let messages = object["messages"] as? [[String: Any]], !messages.isEmpty else {
                    throw ToolError("The actual API fixture request lost its model or messages.")
                }
                let content = messages.last?["content"] as? [[String: Any]] ?? []
                let toolResult = content.first { $0["type"] as? String == "tool_result" }
                let tool: String, json: String
                if let toolResult {
                    let blocks = toolResult["content"] as? [[String: Any]] ?? []
                    let texts = blocks.compactMap { block -> ToolResult.Block? in
                        guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                        return .text(text)
                    }
                    tool = AgentReviewChildRequest.writeTool
                    json = try AgentReviewChildOwnerTransport.submission(.init(content: texts, isError: false), request: bound)
                } else {
                    guard messages.count == 1 else { throw ToolError("A child API context replayed prior conversation messages.") }
                    tool = AgentReviewChildRequest.readTool; json = "{}"
                }
                let id = UUID().uuidString, message = UUID().uuidString
                let rows: [[String: Any]] = [
                    ["type": "message_start", "message": ["id": message, "model": AgentReviewChildOwnerTransport.modelID, "usage": ["input_tokens": 1]]],
                    ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": id, "name": tool, "input": [:]]],
                    ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": json]],
                    ["type": "content_block_stop", "index": 0],
                    ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 1]],
                    ["type": "message_stop"]]
                let wire = try rows.reduce(into: Data()) { bytes, row in
                    bytes.append(Data("data: ".utf8)); bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(Data("\n\n".utf8))
                }
                Self.storage.withLock { $0.bodies.append(body); $0.responses.append(wire) }
                try Task.checkCancellation()
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else { throw CocoaError(.fileReadUnknown) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: wire); client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                Self.storage.withLock { $0.errors.append(error.localizedDescription) }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        lifetime.withLock { value in value.task = task; if value.stopped { task.cancel() } }
    }
    override func stopLoading() { lifetime.withLock { $0.stopped = true; $0.task?.cancel() } }
}
