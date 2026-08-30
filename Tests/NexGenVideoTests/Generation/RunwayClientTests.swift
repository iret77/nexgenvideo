import Foundation
import Testing

@testable import NexGenVideo

@Suite("Runway task transport", .serialized)
struct RunwayClientTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        struct CapturedRequest: Sendable {
            let url: URL?
            let method: String?
            let authorization: String?
            let version: String?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var captured: [CapturedRequest] = []
        nonisolated(unsafe) private static var deleteStatus = 204

        static func reset() {
            lock.withLock {
                captured = []
                deleteStatus = 204
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
