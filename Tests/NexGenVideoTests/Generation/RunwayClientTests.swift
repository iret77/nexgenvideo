import Foundation
import Testing

@testable import NexGenVideo

@Suite("Runway task transport", .serialized)
struct RunwayClientTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        enum StubResult: Sendable {
            case response(status: Int, body: String)
            case urlError(URLError.Code)
            case cancellation
        }

        struct Stub: Sendable {
            let method: String
            let pathSuffix: String
            let result: StubResult
        }

        struct CapturedRequest: Sendable {
            let url: URL?
            let method: String?
            let authorization: String?
            let version: String?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var captured: [CapturedRequest] = []
        nonisolated(unsafe) private static var deleteStatus = 204
        nonisolated(unsafe) private static var stubs: [Stub] = []

        static func reset() {
            lock.withLock {
                captured = []
                deleteStatus = 204
                stubs = []
            }
        }

        static func enqueue(
            method: String,
            pathSuffix: String,
            result: StubResult
        ) {
            lock.withLock {
                stubs.append(Stub(method: method, pathSuffix: pathSuffix, result: result))
            }
        }

        static func failCancellation(with status: Int) {
            lock.withLock { deleteStatus = status }
        }

        static func requests() -> [CapturedRequest] {
            lock.withLock { captured }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let capturedRequest = CapturedRequest(
                url: request.url,
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                version: request.value(forHTTPHeaderField: "X-Runway-Version")
            )
            Self.lock.withLock { Self.captured.append(capturedRequest) }
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let stub = Self.lock.withLock { () -> Stub? in
                guard let index = Self.stubs.firstIndex(where: {
                    $0.method == request.httpMethod && url.path.hasSuffix($0.pathSuffix)
                }) else { return nil }
                return Self.stubs.remove(at: index)
            }
            if let stub {
                switch stub.result {
                case .response(let status, let body):
                    respond(url: url, status: status, data: Data(body.utf8))
                case .urlError(let code):
                    client?.urlProtocol(self, didFailWithError: URLError(code))
                case .cancellation:
                    client?.urlProtocol(self, didFailWithError: CancellationError())
                }
                return
            }
            let status: Int
            let data: Data
            switch request.httpMethod {
            case "GET":
                status = 200
                data = Data(#"{"status":"RUNNING"}"#.utf8)
            case "DELETE":
                status = Self.lock.withLock { Self.deleteStatus }
                data = Data(#"{"error":"cannot cancel"}"#.utf8)
            default:
                status = 405
                data = Data()
            }
            respond(url: url, status: status, data: data)
        }

        private func respond(url: URL, status: Int, data: Data) {
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func organizationAuthenticationFailureIsAnAPIError() async throws {
        FixtureURLProtocol.reset()
        FixtureURLProtocol.enqueue(
            method: "GET",
            pathSuffix: "/organization",
            result: .response(status: 401, body: #"{"error":"invalid key"}"#)
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(apiKey: "bad-key", session: testSession)

        do {
            _ = try await client.availableModelIds()
            Issue.record("Expected Runway authentication failure")
        } catch let error as GenerationBackendError {
            guard case .api(let status, _, let message) = error else {
                Issue.record("Expected an API error, got \(error)")
                return
            }
            #expect(status == 401)
            #expect(message.contains("invalid key"))
        }
    }

    @Test func malformedOrganizationCatalogIsNotAnEmptySuccess() async throws {
        FixtureURLProtocol.reset()
        FixtureURLProtocol.enqueue(
            method: "GET",
            pathSuffix: "/organization",
            result: .response(status: 200, body: #"{"tier":{"name":"pro"}}"#)
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(apiKey: "runway-secret", session: testSession)

        do {
            _ = try await client.availableModelIds()
            Issue.record("Expected malformed Runway catalog to fail")
        } catch let error as GenerationBackendError {
            guard case .transport(let message) = error else {
                Issue.record("Expected a transport error, got \(error)")
                return
            }
            #expect(message.contains("malformed organization model catalog"))
        }
    }

    @Test func transientPollingFailuresRecoverWithoutCancellingTheTask() async throws {
        FixtureURLProtocol.reset()
        FixtureURLProtocol.enqueue(
            method: "GET",
            pathSuffix: "/tasks/task-recovers",
            result: .response(status: 503, body: #"{"error":"busy"}"#)
        )
        FixtureURLProtocol.enqueue(
            method: "GET",
            pathSuffix: "/tasks/task-recovers",
            result: .urlError(.timedOut)
        )
        FixtureURLProtocol.enqueue(
            method: "GET",
            pathSuffix: "/tasks/task-recovers",
            result: .response(
                status: 200,
                body: #"{"status":"SUCCEEDED","output":["https://example.com/render.mp4"]}"#
            )
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(
            apiKey: "runway-secret",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 5,
            maxPollRetries: 3
        )

        let output = try await client.output(taskId: "task-recovers")

        #expect(output == ["https://example.com/render.mp4"])
        let requests = FixtureURLProtocol.requests()
        #expect(requests.filter { $0.method == "GET" }.count == 3)
        #expect(!requests.contains { $0.method == "DELETE" })
    }

    @Test func exhaustedPollingRetriesCancelTheProviderTask() async throws {
        FixtureURLProtocol.reset()
        for _ in 0..<2 {
            FixtureURLProtocol.enqueue(
                method: "GET",
                pathSuffix: "/tasks/task-abandoned",
                result: .response(status: 503, body: #"{"error":"busy"}"#)
            )
        }
        FixtureURLProtocol.enqueue(
            method: "DELETE",
            pathSuffix: "/tasks/task-abandoned",
            result: .response(status: 204, body: "")
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(
            apiKey: "runway-secret",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 5,
            maxPollRetries: 1
        )

        do {
            _ = try await client.output(taskId: "task-abandoned")
            Issue.record("Expected exhausted Runway polling to fail")
        } catch {
            #expect(error.localizedDescription.contains("polling remained unavailable"))
            #expect(error.localizedDescription.contains("cancelled the provider task"))
        }
        #expect(FixtureURLProtocol.requests().filter { $0.method == "DELETE" }.count == 1)
    }

    @Test func cancelledSubmissionWithoutReceiptHasUnknownOutcome() async throws {
        FixtureURLProtocol.reset()
        FixtureURLProtocol.enqueue(
            method: "POST",
            pathSuffix: "/image_to_video",
            result: .cancellation
        )
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(apiKey: "runway-secret", session: testSession)

        do {
            _ = try await client.createImageToVideo(
                model: "gen4_turbo",
                promptImage: "https://example.com/frame.png",
                promptText: "Move slowly",
                ratio: "1280:720",
                duration: 5
            )
            Issue.record("Expected ambiguous Runway submission failure")
        } catch let error as RunwayClient.SubmissionOutcomeUnknownError {
            #expect(error.ledgerRequestID.hasPrefix("runway-unknown-"))
            #expect(error.localizedDescription.contains("may still be running"))
        }
        #expect(!FixtureURLProtocol.requests().contains { $0.method == "DELETE" })
    }

    @Test func taskCancellationDeletesProviderTaskExactlyOnce() async throws {
        FixtureURLProtocol.reset()
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(apiKey: "runway-secret", session: testSession)
        let task = Task { try await client.output(taskId: "task-cancel") }

        for _ in 0..<400 {
            if FixtureURLProtocol.requests().contains(where: { $0.method == "GET" }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(FixtureURLProtocol.requests().contains(where: { $0.method == "GET" }))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let requests = FixtureURLProtocol.requests()
        #expect(requests.map(\.method) == ["GET", "DELETE"])
        #expect(requests.last?.url?.absoluteString == "https://api.dev.runwayml.com/v1/tasks/task-cancel")
        #expect(requests.last?.authorization == "Bearer runway-secret")
        #expect(requests.last?.version == "2024-11-06")
        #expect(requests.filter { $0.method == "DELETE" }.count == 1)
    }

    @Test func failedProviderCancellationRemainsVisible() async throws {
        FixtureURLProtocol.reset()
        FixtureURLProtocol.failCancellation(with: 503)
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = RunwayClient(apiKey: "runway-secret", session: testSession)
        let task = Task { try await client.output(taskId: "task-cancel-fails") }

        for _ in 0..<400 {
            if FixtureURLProtocol.requests().contains(where: { $0.method == "GET" }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected failed Runway cancellation to remain visible")
        } catch {
            #expect(error.localizedDescription.contains("Runway task cancellation failed"))
            #expect(error.localizedDescription.contains("may still run and incur charges"))
        }
        #expect(FixtureURLProtocol.requests().filter { $0.method == "DELETE" }.count == 1)
    }
}
