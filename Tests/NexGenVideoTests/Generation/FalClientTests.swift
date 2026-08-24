import Foundation
import Testing

@testable import NexGenVideo

@Suite("fal queue transport", .serialized)
struct FalClientTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        struct Fixture: Sendable {
            let status: Int
            let data: Data
        }

        struct CapturedRequest: Sendable {
            let url: URL?
            let method: String?
            let authorization: String?
            let body: Data?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var fixtures: [URL: Fixture] = [:]
        nonisolated(unsafe) private static var captured: [CapturedRequest] = []

        static func install(_ fixtures: [URL: Fixture]) {
            lock.withLock {
                self.fixtures = fixtures
                captured = []
            }
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
                body: Self.body(of: request)
            )
            guard let url = request.url,
                  let fixture = Self.lock.withLock({ () -> Fixture? in
                      Self.captured.append(capturedRequest)
                      return Self.fixtures[url]
                  }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.data)
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

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func fixture(_ json: String, status: Int = 200) -> FixtureURLProtocol.Fixture {
        FixtureURLProtocol.Fixture(status: status, data: Data(json.utf8))
    }

    @Test("submit keeps the operation path; status and result use the owning app")
    func imageEditLifecycleUsesApplicationRoute() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-123/status"
        )!
        let result = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-123"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-123\"}"),
            status: fixture("{\"status\":\"COMPLETED\"}"),
            result: fixture("{\"images\":[]}"),
        ])
        let client = FalClient(apiKey: "test-key", session: session())
        let input = Data("{\"prompt\":\"compiled\",\"image_urls\":[\"https://ref.invalid/a.png\"]}".utf8)

        let requestID = try await client.submit(endpoint: endpoint, inputBody: input)
        let output = try await client.result(endpoint: endpoint, requestId: requestID)
        let requests = FixtureURLProtocol.requests()

        #expect(String(decoding: output, as: UTF8.self) == "{\"images\":[]}")
        #expect(requests.map(\.url) == [submit, status, result])
        #expect(requests.map(\.method) == ["POST", "GET", "GET"])
        #expect(requests.first?.body == input)
        #expect(requests.allSatisfy { $0.authorization == "Key test-key" })
    }

    @Test("every registered fal modality derives a valid application lifecycle route")
    func everyRegisteredModelUsesApplicationLifecycleRoute() throws {
        let modalities = Set(FalModelRegistry.models.map { $0.entry.kind.rawValue })
        #expect(modalities == ["image", "video", "audio", "upscale"])

        for model in FalModelRegistry.models {
            let endpoint = model.entry.id
            let parts = endpoint.split(separator: "/").map(String.init)
            let rootCount = ["workflows", "comfy"].contains(parts[0]) ? 3 : 2
            let application = parts.prefix(rootCount).joined(separator: "/")
            let route = try FalClient.route(endpoint: endpoint)

            #expect(route.submitURL.absoluteString == "https://queue.fal.run/\(endpoint)")
            #expect(route.application == application)
            #expect(
                try route.lifecycleURL(requestId: "job-123", suffix: "status").absoluteString
                    == "https://queue.fal.run/\(application)/requests/job-123/status"
            )
            #expect(
                try route.lifecycleURL(requestId: "job-123").absoluteString
                    == "https://queue.fal.run/\(application)/requests/job-123"
            )
        }
    }

    @Test("fal namespaces retain the namespace in their owning application route")
    func namespacedRoutes() throws {
        let workflow = try FalClient.route(endpoint: "workflows/owner/app/variant")
        let comfy = try FalClient.route(endpoint: "comfy/owner/app/variant")

        #expect(workflow.application == "workflows/owner/app")
        #expect(comfy.application == "comfy/owner/app")
    }

    @Test("malformed endpoints and request ids fail before network access")
    func invalidRoutesFailClosed() throws {
        for endpoint in ["", "fal-ai", "/fal-ai/app", "fal-ai/app/", "fal-ai//app", "fal-ai/app?x=1", "fal-ai/../app"] {
            #expect(throws: GenerationBackendError.self) {
                _ = try FalClient.route(endpoint: endpoint)
            }
        }
        let route = try FalClient.route(endpoint: "fal-ai/app/edit")
        #expect(throws: GenerationBackendError.self) {
            _ = try route.lifecycleURL(requestId: "../job")
        }
    }

    @Test("HTTP failures name provider, lifecycle step, method, safe route, and status")
    func statusFailureIsActionable() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-405/status"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-405\"}"),
            status: fixture("{\"detail\":\"Method Not Allowed\"}", status: 405),
        ])
        let client = FalClient(apiKey: "test-key", session: session())
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected status failure")
        } catch {
            #expect(
                error.localizedDescription
                    == "fal.ai status GET queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-405/status returned HTTP 405: Method Not Allowed"
            )
        }
    }
}
