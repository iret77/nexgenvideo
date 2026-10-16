import Foundation
import Testing

@testable import NexGenVideo

/// One serialized suite owns the shared HTTP fixture, so parallel suites never see each other's stubs.
@Suite("Provider submission and status evidence", .serialized)
struct ProviderStatusTests {
    final class Fixture: URLProtocol, @unchecked Sendable {
        enum Reply: Sendable {
            case response(status: Int, body: String)
            case urlError(URLError.Code)
        }

        private struct Stub: Sendable {
            let method: String
            let pathSuffix: String
            let reply: Reply
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var stubs: [Stub] = []
        nonisolated(unsafe) private static var captured: [String] = []

        static func reset() {
            lock.withLock {
                stubs = []
                captured = []
            }
        }

        static func stub(_ method: String, _ pathSuffix: String, _ reply: Reply) {
            lock.withLock { stubs.append(Stub(method: method, pathSuffix: pathSuffix, reply: reply)) }
        }

        /// "METHOD path" of every request in order.
        static func requests() -> [String] {
            lock.withLock { captured }
        }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Fixture.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let method = request.httpMethod ?? "GET"
            let stub = Self.lock.withLock { () -> Stub? in
                Self.captured.append("\(method) \(url.path)")
                guard let index = Self.stubs.firstIndex(where: {
                    $0.method == method && url.path.hasSuffix($0.pathSuffix)
                }) else { return nil }
                return Self.stubs.remove(at: index)
            }
            switch stub?.reply ?? .urlError(.resourceUnavailable) {
            case .response(let status, let body):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .urlError(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }

        override func stopLoading() {}
    }

    @Test func marbleSubmissionWithoutReceiptOrOperationIDIsUnknownNotUnsent() async throws {
        Fixture.reset()
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let client = MarbleClient(apiKey: "marble-secret", session: session)

        Fixture.stub("POST", "/worlds:generate", .urlError(.networkConnectionLost))
        do {
            _ = try await client.submit(body: Data("{}".utf8))
            Issue.record("Expected a lost submission response to fail")
        } catch {
            #expect(error is MarbleClient.SubmissionOutcomeUnknownError)
            #expect(!GenerationService.providerRunEnded(after: error))
        }

        Fixture.stub("POST", "/worlds:generate", .response(status: 200, body: #"{"done":false}"#))
        do {
            _ = try await client.submit(body: Data("{}".utf8))
            Issue.record("Expected a submission without an operation id to fail")
        } catch {
            #expect(error is MarbleClient.SubmissionAcknowledgedError)
            #expect(!GenerationService.providerRunEnded(after: error))
        }

        Fixture.stub("POST", "/worlds:generate", .response(status: 422, body: #"{"message":"invalid prompt"}"#))
        await #expect(throws: GenerationBackendError.self) {
            _ = try await client.submit(body: Data("{}".utf8))
        }
        #expect(Fixture.requests().count == 3)
    }
}
