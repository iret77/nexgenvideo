import Foundation
import MCP
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("MCP HTTP server", .serialized, .timeLimit(.minutes(1)))
struct MCPHTTPServerTests {
    @Test("fragmented request waits for its complete body")
    func fragmentedRequest() throws {
        let partial = Data(
            "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe".utf8
        )
        guard case .incomplete = MCPHTTPServer.decodeRequest(partial) else {
            Issue.record("A partial body was accepted as a complete request")
            return
        }

        let complete = partial + Data("llo".utf8)
        guard case .complete(let request, let remaining) =
                MCPHTTPServer.decodeRequest(complete)
        else {
            Issue.record("A complete request was not decoded")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.body == Data("hello".utf8))
        #expect(remaining.isEmpty)
    }

    @Test("case-differing duplicate headers are rejected")
    func duplicateHeaders() {
        let request = Data(
            """
            POST /mcp HTTP/1.1\r
            Content-Length: 2\r
            content-length: 4\r
            \r
            test
            """.utf8
        )
        guard case .invalid(let status) = MCPHTTPServer.decodeRequest(request)
        else {
            Issue.record("Conflicting Content-Length headers were accepted")
            return
        }
        #expect(status == 400)
    }

    @Test("whitespace before a header colon is rejected")
    func paddedHeaderName() {
        let request = Data(
            "POST /mcp HTTP/1.1\r\nContent-Length : 0\r\n\r\n".utf8
        )
        guard case .invalid(let status) = MCPHTTPServer.decodeRequest(request)
        else {
            Issue.record("A padded HTTP header name was accepted")
            return
        }
        #expect(status == 400)
    }

    @Test("an overflowing content length is rejected")
    func overflowingContentLength() {
        let request = Data(
            "POST /mcp HTTP/1.1\r\nContent-Length: \(Int.max)\r\n\r\n".utf8
        )
        guard case .invalid(let status) = MCPHTTPServer.decodeRequest(request)
        else {
            Issue.record("An overflowing Content-Length was accepted")
            return
        }
        #expect(status == 413)
    }

    @MainActor
    @Test("a disconnected long call is rejoined after MCP reinitializes")
    func longCallSurvivesReconnect() async throws {
        let port: UInt16 = 29_989
        let retryJoined = TestAsyncSignal()
        let runnerLatch = PhaseRunnerLatch()
        let runCount = MCPRunCounter()
        let coordinator = PipelinePhaseRunCoordinator()
        let executionState = PipelinePhaseExecutionState()
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let runner: EngineRegistry.PhaseRunner = { _ in
            runCount.increment()
            runnerLatch.block()
        }
        let server = MCPHTTPServer(port: port, makeServer: {
            let server = Server(
                name: "mcp-http-test",
                version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: false))
            )
            await server.withMethodHandler(CallTool.self) { params in
                guard params.name == "slow" else {
                    return .init(content: [.text("unknown")], isError: true)
                }
                let outcome = await coordinator.run(
                    projectRoot: projectRoot,
                    phase: "analysis",
                    sourceFilename: "Original Song.wav",
                    runner: runner,
                    progressRunner: nil,
                    state: executionState,
                    onJoin: {
                        await retryJoined.signal()
                    }
                )
                return switch outcome {
                case .completed:
                    .init(content: [.text("finished")], isError: false)
                case .blocked(let message):
                    .init(content: [.text(message)], isError: true)
                case .failed(let message):
                    .init(content: [.text(message)], isError: true)
                case .refused(let activePhase):
                    .init(content: [.text("busy: \(activePhase)")], isError: true)
                }
            }
            return server
        })
        try await server.start()
        var callTask: Task<(data: Data, statusCode: Int), Error>?
        do {
            let endpoint = try #require(
                URL(string: "http://127.0.0.1:\(port)/mcp")
            )
            let initialize = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
            """
            let initializeResponse = try await post(
                initialize,
                to: endpoint,
                protocolVersion: nil
            )
            #expect(initializeResponse.statusCode == 200)

            let call = """
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow","arguments":{}}}
            """
            callTask = Task {
                try await post(
                    call,
                    to: endpoint,
                    protocolVersion: "2025-03-26"
                )
            }
            await runnerLatch.waitUntilEntered()
            #expect(runCount.value == 1)

            callTask?.cancel()
            if let disconnectedCall = callTask {
                _ = try? await disconnectedCall.value
            }
            callTask = nil

            let reinitialize = """
            {"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test-reconnect","version":"1"}}}
            """
            let reinitializeResponse = try await post(
                reinitialize,
                to: endpoint,
                protocolVersion: nil
            )
            #expect(reinitializeResponse.statusCode == 200)
            #expect(
                !String(decoding: reinitializeResponse.data, as: UTF8.self)
                    .contains("\"error\"")
            )

            let retry = """
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow","arguments":{}}}
            """
            callTask = Task {
                try await post(
                    retry,
                    to: endpoint,
                    protocolVersion: "2025-03-26"
                )
            }
            await retryJoined.wait()
            #expect(coordinator.runningPhase(projectRoot: projectRoot) == "analysis")
            #expect(runCount.value == 1)

            var getRequest = URLRequest(url: endpoint)
            getRequest.httpMethod = "GET"
            getRequest.setValue(
                "text/event-stream",
                forHTTPHeaderField: "Accept"
            )
            let (_, rawGetResponse) = try await URLSession.shared.data(
                for: getRequest
            )
            let getResponse = try #require(rawGetResponse as? HTTPURLResponse)
            #expect(getResponse.statusCode == 405)
            #expect(runCount.value == 1)

            runnerLatch.allowCompletion()
            let activeCall = try #require(callTask)
            let response = try await activeCall.value
            #expect(response.statusCode == 200)
            #expect(
                String(decoding: response.data, as: UTF8.self)
                    .contains("finished")
            )
            #expect(runCount.value == 1)
            await server.stop()
        } catch {
            runnerLatch.allowCompletion()
            if let callTask {
                _ = try? await callTask.value
            }
            await server.stop()
            throw error
        }
    }

    private func post(
        _ json: String,
        to endpoint: URL,
        protocolVersion: String?
    ) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "http://127.0.0.1:\(endpoint.port!)",
            forHTTPHeaderField: "Origin"
        )
        if let protocolVersion {
            request.setValue(
                protocolVersion,
                forHTTPHeaderField: "MCP-Protocol-Version"
            )
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, rawResponse) = try await session.data(for: request)
        let response = try #require(rawResponse as? HTTPURLResponse)
        return (data, response.statusCode)
    }
}

private final class MCPRunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock {
            storedValue += 1
        }
    }
}

actor TestAsyncSignal {
    private var isSignaled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        isSignaled = true
        waiters.values.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignaled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isSignaled || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
