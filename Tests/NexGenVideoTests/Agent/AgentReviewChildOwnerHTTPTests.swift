import Foundation
import Testing
import os

@testable import NexGenVideo

@Suite("Review child HTTP fixture lifetime", .timeLimit(.minutes(1)))
struct AgentReviewChildOwnerHTTPTests {
    @MainActor @Test func stopDuringResponseSuppressesAllLaterCallbacks() async throws {
        let request = try childRequest()
        AgentReviewChildOwnerHTTP.reset()
        defer { AgentReviewChildOwnerHTTP.reset() }
        AgentReviewChildOwnerHTTP.bind(request)
        var http = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        http.setValue(AgentReviewChildOwnerHTTP.key, forHTTPHeaderField: "x-api-key")
        let body = try JSONSerialization.data(withJSONObject: [
            "model": AgentReviewChildOwnerTransport.modelID,
            "messages": [["role": "user", "content": [["type": "text", "text": "Fixture review"]]]]
        ])
        http.httpBody = body
        let client = Client()
        let adapter = AgentReviewChildOwnerHTTP(request: http, cachedResponse: nil, client: client)
        let operation = adapter.startOwnedLoading()
        await operation.value
        #expect(client.events == ["response"])
        #expect(operation.isCancelled)
        let evidence = AgentReviewChildOwnerHTTP.evidence
        #expect(evidence.bodies == [body])
        #expect(evidence.responses.count == 1)
        #expect(evidence.errors.isEmpty)
    }

    @MainActor private func childRequest() throws -> AgentReviewChildRequest {
        let home = URL(fileURLWithPath: "/tmp/isolated-review-http-fixture.ngv")
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
            kind: .page, phase: "render_review", binding: binding, backend: .anthropicAPI,
            modelID: AgentReviewChildOwnerTransport.modelID,
            hostContext: .init(interfaceLanguage: .current, baseInstructions: "Fixture only", pack: nil,
                phaseInstructions: "Fixture review", toolSchemas: tools, authority: [.toolExecution, .toolSchemas]),
            bootstrap: "Read and record the supplied fixture context.",
            bounds: .init(maximumRequests: 3, maximumRequestBytes: 1_000_000,
                maximumToolResultBytes: 100_000, maximumEstimatedInputTokens: 100_000,
                maximumOutputTokens: 1_000, maximumMCPOutputTokens: 1_000, maximumTurns: 3))
    }

    private final class Client: NSObject, URLProtocolClient {
        private let recorded = OSAllocatedUnfairLock(initialState: [String]())
        var events: [String] { recorded.withLock { $0 } }
        private func record(_ event: String) { recorded.withLock { $0.append(event) } }

        func urlProtocol(_ protocolInstance: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
            record("response")
            protocolInstance.stopLoading()
        }
        func urlProtocol(_ protocolInstance: URLProtocol, didLoad data: Data) { record("data") }
        func urlProtocolDidFinishLoading(_ protocolInstance: URLProtocol) { record("finish") }
        func urlProtocol(_ protocolInstance: URLProtocol, didFailWithError error: any Error) { record("failure") }
        func urlProtocol(_ protocolInstance: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { record("unexpected") }
        func urlProtocol(_ protocolInstance: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { record("unexpected") }
        func urlProtocol(_ protocolInstance: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { record("unexpected") }
        func urlProtocol(_ protocolInstance: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { record("unexpected") }
    }
}
