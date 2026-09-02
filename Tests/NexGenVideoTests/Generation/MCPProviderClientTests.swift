import Foundation
import MCP
import Testing

@testable import NexGenVideo

@Suite("MCP provider request cancellation", .serialized)
struct MCPProviderClientTests {
    private final class ModernURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var captured: [URLRequest] = []

        static func reset() {
            lock.withLock { captured = [] }
        }

        static func requests() -> [URLRequest] {
            lock.withLock { captured }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Self.body(of: request)
            Self.lock.withLock { Self.captured.append(request) }
            guard let body,
                  let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let method = envelope["method"] as? String,
                  let id = envelope["id"] else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
                return
            }
            let result: [String: Any]
            switch method {
            case "server/discover":
                result = [
                    "resultType": "complete",
                    "supportedVersions": [MCP20260728.version],
                    "capabilities": ["tools": [:]],
                    "ttlMs": 60_000,
                    "cacheScope": "private",
                ]
            case "tools/list":
                result = [
                    "resultType": "complete",
                    "tools": [[
                        "name": "generate",
                        "description": "Generate media",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "routing": [
                                    "type": "object",
                                    "properties": [
                                        "region": [
                                            "type": "string",
                                            "x-mcp-header": "Region",
                                        ],
                                    ],
                                ],
                                "prompt": ["type": "string"],
                            ],
                        ],
                        "_meta": [
                            "ui": ["resourceUri": "ui://provider/widget"],
                        ],
                    ]],
                    "ttlMs": 60_000,
                    "cacheScope": "private",
                ]
            case "tools/call":
                result = [
                    "resultType": "complete",
                    "content": [
                        ["type": "text", "text": "generation-42"],
                        [
                            "type": "resource_link",
                            "uri": "https://cdn.example/video.mp4",
                            "name": "video.mp4",
                            "mimeType": "video/mp4",
                        ],
                        ["type": "ui", "resource": ["uri": "ui://provider/widget"]],
                    ],
                    "structuredContent": ["status": "complete"],
                ]
            default:
                result = ["resultType": "complete"]
            }
            let responseObject: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": result,
            ]
            let responseBody = try! JSONSerialization.data(
                withJSONObject: responseObject,
                options: [.sortedKeys]
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func body(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { return nil }
                if count == 0 { return data }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    private func modernSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModernURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private actor CancellationRecorder {
        private(set) var requestIDs: [ID] = []

        func record(_ requestID: ID) {
            requestIDs.append(requestID)
        }
    }

    private struct CancellationFailure: LocalizedError {
        var errorDescription: String? { "protocol transport unavailable" }
    }

    @Test("modern provider discovery and calls mirror routing metadata without rendering Apps")
    func modernProviderTransport() async throws {
        ModernURLProtocol.reset()
        let session = modernSession()
        defer { session.invalidateAndCancel() }
        let client = MCPProviderClient(
            config: .init(
                endpoint: URL(string: "https://provider.example/mcp")!,
                bearerToken: "provider-token"
            ),
            urlSession: session
        )

        let tools = try await client.discoverTools()
        #expect(tools.map(\.name) == ["generate"])
        let payloads = try await client.callTool(
            name: "generate",
            arguments: [
                "routing": .object(["region": .string("eu-west-1")]),
                "prompt": .string("A quiet harbor at blue hour"),
            ]
        )

        #expect(payloads.contains("generation-42"))
        #expect(payloads.contains { $0.contains("https://cdn.example/video.mp4") })
        #expect(payloads.contains { $0.contains("\"status\":\"complete\"") })
        #expect(!payloads.contains { $0.contains("ui://provider/widget") })

        let requests = ModernURLProtocol.requests()
        #expect(requests.count == 3)
        let call = try #require(requests.last)
        #expect(call.value(forHTTPHeaderField: "Authorization") == "Bearer provider-token")
        #expect(
            call.value(forHTTPHeaderField: MCP20260728.protocolVersionHeader)
                == MCP20260728.version
        )
        #expect(
            call.value(forHTTPHeaderField: MCP20260728.methodHeader)
                == "tools/call"
        )
        #expect(call.value(forHTTPHeaderField: MCP20260728.nameHeader) == "generate")
        #expect(call.value(forHTTPHeaderField: "Mcp-Param-Region") == "eu-west-1")
    }

    @Test("legacy method-not-found discovery response triggers compatibility fallback")
    func legacyDiscoveryFallback() throws {
        let id = MCP20260728.WireValue.string("discovery")
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "discovery",
            "error": [
                "code": -32601,
                "message": "Method not found",
            ],
        ])
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://provider.example/mcp")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))

        do {
            _ = try MCP20260728.decodeResponse(
                data: body,
                response: response,
                expectedID: id
            )
            Issue.record("Expected JSON-RPC method-not-found")
        } catch let error as MCP20260728.RemoteError {
            #expect(error.code == -32601)
            #expect(MCPProviderClient.shouldFallbackToLegacy(after: error))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("modern protocol errors never trigger legacy fallback")
    func modernProtocolErrorDoesNotFallback() {
        let error = MCP20260728.RemoteError(
            status: 400,
            code: -32022,
            message: "Unsupported protocol version",
            data: nil,
            recognizedModern: true
        )

        #expect(!MCPProviderClient.shouldFallbackToLegacy(after: error))
    }

    @Test func cancelledAwaitForwardsOriginalRequestExactlyOnce() async {
        let requestID: ID = "provider-request-373"
        let requestTask = Task<String, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late result"
        }
        let context = RequestContext(requestID: requestID, requestTask: requestTask)
        let recorder = CancellationRecorder()
        let awaitingTask = Task {
            try await MCPProviderClient.awaitRequest(context) { forwardedID in
                await recorder.record(forwardedID)
                requestTask.cancel()
            }
        }

        awaitingTask.cancel()
        awaitingTask.cancel()

        do {
            _ = try await awaitingTask.value
            Issue.record("Expected the cancelled request await to stop")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await recorder.requestIDs == [requestID])
    }

    @Test func completedAwaitDoesNotSendCancellation() async throws {
        let requestID: ID = "provider-request-complete"
        let context = RequestContext(
            requestID: requestID,
            requestTask: Task<String, Error> { "result" }
        )
        let recorder = CancellationRecorder()

        let result = try await MCPProviderClient.awaitRequest(context) { forwardedID in
            await recorder.record(forwardedID)
        }

        #expect(result == "result")
        #expect(await recorder.requestIDs.isEmpty)
    }

    @Test func successfulProtocolCancellationSettlesWithoutProviderResponse() async {
        let requestID: ID = "provider-request-no-response"
        let requestTask = Task<String, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late result"
        }
        defer { requestTask.cancel() }
        let context = RequestContext(requestID: requestID, requestTask: requestTask)
        let recorder = CancellationRecorder()
        let awaitingTask = Task {
            try await MCPProviderClient.awaitRequest(context) { forwardedID in
                await recorder.record(forwardedID)
            }
        }

        awaitingTask.cancel()

        do {
            _ = try await awaitingTask.value
            Issue.record("Expected protocol cancellation to settle the await")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await recorder.requestIDs == [requestID])
    }

    @Test func failedProtocolCancellationSurfacesPossibleCharge() async {
        let requestID: ID = "provider-request-cancel-fails"
        let requestTask = Task<String, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "late result"
        }
        defer { requestTask.cancel() }
        let context = RequestContext(requestID: requestID, requestTask: requestTask)
        let recorder = CancellationRecorder()
        let awaitingTask = Task {
            try await MCPProviderClient.awaitRequest(context) { forwardedID in
                await recorder.record(forwardedID)
                throw CancellationFailure()
            }
        }

        awaitingTask.cancel()
        awaitingTask.cancel()

        do {
            _ = try await awaitingTask.value
            Issue.record("Expected failed protocol cancellation")
        } catch let error as MCPProviderClient.ClientError {
            #expect(error.localizedDescription.contains("could not be cancelled"))
            #expect(error.localizedDescription.contains("may still run and incur charges"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await recorder.requestIDs == [requestID])
    }
}
