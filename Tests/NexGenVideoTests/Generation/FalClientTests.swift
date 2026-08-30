import Foundation
import Testing

@testable import NexGenVideo

@Suite("fal queue transport", .serialized)
struct FalClientTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        struct Fixture: Sendable {
            let status: Int
            let data: Data
            let headers: [String: String]
            let delaySeconds: TimeInterval
        }

        struct CapturedRequest: Sendable {
            let url: URL?
            let method: String?
            let authorization: String?
            let body: Data?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var fixtures: [URL: [Fixture]] = [:]
        nonisolated(unsafe) private static var captured: [CapturedRequest] = []

        static func install(_ fixtures: [URL: Fixture]) {
            installSequence(fixtures.mapValues { [$0] })
        }

        static func installSequence(_ fixtures: [URL: [Fixture]]) {
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
                      guard var sequence = Self.fixtures[url], !sequence.isEmpty else {
                          return nil
                      }
                      let fixture = sequence.removeFirst()
                      Self.fixtures[url] = sequence
                      return fixture
                  }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var headers = fixture.headers
            headers["Content-Type"] = "application/json"
            if fixture.delaySeconds > 0 {
                Thread.sleep(forTimeInterval: fixture.delaySeconds)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
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

    private func fixture(
        _ json: String,
        status: Int = 200,
        headers: [String: String] = [:],
        delaySeconds: TimeInterval = 0
    ) -> FixtureURLProtocol.Fixture {
        FixtureURLProtocol.Fixture(
            status: status,
            data: Data(json.utf8),
            headers: headers,
            delaySeconds: delaySeconds
        )
    }

    private static let expectedApplications = [
        "fal-ai/flux/schnell": "fal-ai/flux",
        "fal-ai/flux/dev": "fal-ai/flux",
        "fal-ai/flux-pro/v1.1": "fal-ai/flux-pro",
        "fal-ai/flux-pro/v1.1-ultra": "fal-ai/flux-pro",
        "fal-ai/recraft/v3/text-to-image": "fal-ai/recraft",
        "fal-ai/ideogram/v3": "fal-ai/ideogram",
        "fal-ai/imagen4": "fal-ai/imagen4",
        "fal-ai/qwen-image": "fal-ai/qwen-image",
        "fal-ai/stable-diffusion-v35-large": "fal-ai/stable-diffusion-v35-large",
        "fal-ai/nano-banana": "fal-ai/nano-banana",
        "fal-ai/nano-banana-2": "fal-ai/nano-banana-2",
        "fal-ai/nano-banana-pro": "fal-ai/nano-banana-pro",
        "fal-ai/gpt-image-2": "fal-ai/gpt-image-2",
        "fal-ai/flux-pro/kontext": "fal-ai/flux-pro",
        "fal-ai/gemini-25-flash-image/edit": "fal-ai/gemini-25-flash-image",
        "fal-ai/nano-banana-2/edit": "fal-ai/nano-banana-2",
        "fal-ai/nano-banana-pro/edit": "fal-ai/nano-banana-pro",
        "fal-ai/gpt-image-2/edit": "fal-ai/gpt-image-2",
        "fal-ai/kling-video/v2.5-turbo/pro/text-to-video": "fal-ai/kling-video",
        "fal-ai/bytedance/seedance/v1/pro/text-to-video": "fal-ai/bytedance",
        "bytedance/seedance-2.0/text-to-video": "bytedance/seedance-2.0",
        "bytedance/seedance-2.0/reference-to-video": "bytedance/seedance-2.0",
        "fal-ai/veo3": "fal-ai/veo3",
        "fal-ai/minimax/hailuo-02/standard/text-to-video": "fal-ai/minimax",
        "fal-ai/kling-video/v2.5-turbo/pro/image-to-video": "fal-ai/kling-video",
        "fal-ai/bytedance/seedance/v1/pro/image-to-video": "fal-ai/bytedance",
        "bytedance/seedance-2.0/image-to-video": "bytedance/seedance-2.0",
        "bytedance/seedance-2.5/text-to-video": "bytedance/seedance-2.5",
        "bytedance/seedance-2.5/image-to-video": "bytedance/seedance-2.5",
        "bytedance/seedance-2.5/reference-to-video": "bytedance/seedance-2.5",
        "fal-ai/elevenlabs/tts/multilingual-v2": "fal-ai/elevenlabs",
        "fal-ai/elevenlabs/sound-effects": "fal-ai/elevenlabs",
        "fal-ai/stable-audio": "fal-ai/stable-audio",
        "fal-ai/elevenlabs/music": "fal-ai/elevenlabs",
        "fal-ai/clarity-upscaler": "fal-ai/clarity-upscaler",
        "fal-ai/topaz/upscale/video": "fal-ai/topaz",
    ]

    @Test("image catalog pages both active fal.ai image categories with the saved key")
    func discoversCurrentImageInventory() async throws {
        func catalogURL(category: String) -> URL {
            var components = URLComponents(string: "https://api.fal.ai/v1/models")!
            components.queryItems = [
                URLQueryItem(name: "category", value: category),
                URLQueryItem(name: "status", value: "active"),
                URLQueryItem(name: "limit", value: "100"),
            ]
            return components.url!
        }
        let textURL = catalogURL(category: "text-to-image")
        let editURL = catalogURL(category: "image-to-image")
        FixtureURLProtocol.install([
            textURL: fixture(#"{"models":[{"endpoint_id":"fal-ai/nano-banana-2"},{"endpoint_id":"openai/gpt-image-2"}],"has_more":false}"#),
            editURL: fixture(#"{"models":[{"endpoint_id":"fal-ai/nano-banana-pro/edit"}],"has_more":false}"#),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }

        let ids = try await FalClient(
            apiKey: "test-key",
            session: testSession
        ).availableImageModelIds()

        #expect(ids == [
            "fal-ai/nano-banana-2",
            "openai/gpt-image-2",
            "fal-ai/nano-banana-pro/edit",
        ])
        #expect(FixtureURLProtocol.requests().allSatisfy {
            $0.authorization == "Key test-key" && $0.method == "GET"
        })
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
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(apiKey: "test-key", session: testSession)
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

    @Test("every registered fal endpoint has an independently pinned application route")
    func everyRegisteredModelUsesPinnedApplicationLifecycleRoute() throws {
        let modalities = Set(FalModelRegistry.models.map { $0.entry.kind.rawValue })
        #expect(modalities == ["image", "video", "audio", "upscale"])
        #expect(Set(FalModelRegistry.models.map(\.entry.id)) == Set(Self.expectedApplications.keys))
        for model in FalModelRegistry.models {
            let endpoint = model.entry.id
            let application = try #require(Self.expectedApplications[endpoint])
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
        #expect(
            try workflow.lifecycleURL(requestId: "job-123", suffix: "status").absoluteString
                == "https://queue.fal.run/workflows/owner/app/requests/job-123/status"
        )
        #expect(
            try comfy.lifecycleURL(requestId: "job-123").absoluteString
                == "https://queue.fal.run/comfy/owner/app/requests/job-123"
        )
    }

    @Test("malformed endpoints and request ids fail before network access")
    func invalidRoutesFailClosed() throws {
        for endpoint in [
            "", "fal-ai", "/fal-ai/app", "fal-ai/app/", "fal-ai//app",
            "fal-ai/app?x=1", "fal-ai/../app", "fal-ai/café", "fal-ai/app%2Fedit",
            "workflows/owner", "comfy/owner",
        ] {
            #expect(throws: GenerationBackendError.self) {
                _ = try FalClient.route(endpoint: endpoint)
            }
        }
        let route = try FalClient.route(endpoint: "fal-ai/app/edit")
        for requestId in ["", ".", "..", "job/unsafe", "job café", "job%2Funsafe"] {
            #expect(throws: GenerationBackendError.self) {
                _ = try route.lifecycleURL(requestId: requestId)
            }
        }
        #expect(
            try route.lifecycleURL(requestId: "job+token==").absoluteString
                == "https://queue.fal.run/fal-ai/app/requests/job+token=="
        )
    }

    @Test("unsafe provider request ids fail immediately after submission")
    func unsafeProviderRequestIDsFailClosed() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job/unsafe\"}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(apiKey: "test-key", session: testSession)

        await #expect(throws: FalClient.SubmissionAcknowledgedError.self) {
            _ = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        }
        #expect(FixtureURLProtocol.requests().map(\.url) == [submit])
    }

    @Test("a successful submit without a request id remains an acknowledged submission")
    func missingProviderRequestIDIsAcknowledged() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        FixtureURLProtocol.install([submit: fixture("{}")])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(apiKey: "test-key", session: testSession)

        do {
            _ = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
            Issue.record("Expected acknowledged submission error")
        } catch let error as FalClient.SubmissionAcknowledgedError {
            #expect(error.ledgerRequestID == "missing-request-id")
        }
        #expect(FixtureURLProtocol.requests().map(\.method) == ["POST"])
    }

    @Test("submit is never retried after a retryable HTTP failure")
    func submitFailureIsNotRetried() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        FixtureURLProtocol.installSequence([
            submit: [
                fixture("{\"detail\":\"temporary\"}", status: 503),
                fixture("{\"request_id\":\"must-not-run\"}"),
            ],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            retryBaseDelayNanoseconds: 0
        )

        await #expect(throws: GenerationBackendError.self) {
            _ = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        }
        let requests = FixtureURLProtocol.requests()
        #expect(requests.map(\.method) == ["POST"])
        #expect(requests.map(\.url) == [submit])
    }

    @Test("a lost submit response is treated as an uncertain accepted request")
    func lostSubmitResponseIsNotSafeToRetry() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        FixtureURLProtocol.install([:])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(apiKey: "test-key", session: testSession)

        do {
            _ = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
            Issue.record("Expected uncertain submission error")
        } catch let error as FalClient.SubmissionOutcomeUnknownError {
            #expect(error.ledgerRequestID.hasPrefix("unknown-"))
            #expect(error.localizedDescription.contains("will not retry"))
        }
        #expect(FixtureURLProtocol.requests().map(\.method) == ["POST"])
        #expect(FixtureURLProtocol.requests().map(\.url) == [submit])
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
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            retryBaseDelayNanoseconds: 0
        )
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

    @Test("submit response lifecycle URLs are used instead of reconstructed routes")
    func serverLifecycleURLsAreAuthoritative() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/custom-lifecycle/requests/job-server/status"
        )!
        let response = URL(
            string: "https://queue.fal.run/custom-lifecycle/requests/job-server/response"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/custom-lifecycle/requests/job-server/cancel"
        )!
        let submitBody = #"{"request_id":"job-server","status_url":"\#(status.absoluteString)","response_url":"\#(response.absoluteString)","cancel_url":"\#(cancel.absoluteString)"}"#
        FixtureURLProtocol.install([
            submit: fixture(submitBody),
            status: fixture("{\"status\":\"COMPLETED\"}"),
            response: fixture("{\"images\":[]}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0
        )

        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        _ = try await client.result(endpoint: endpoint, requestId: requestID)

        #expect(FixtureURLProtocol.requests().map(\.url) == [submit, status, response])
    }

    @Test("untrusted lifecycle URL falls back to the provider route")
    func untrustedLifecycleURLIsRejected() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let fallbackStatus = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-safe/status"
        )!
        let fallbackResponse = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-safe"
        )!
        FixtureURLProtocol.install([
            submit: fixture(#"{"request_id":"job-safe","status_url":"https://example.com/requests/job-safe/status"}"#),
            fallbackStatus: fixture("{\"status\":\"COMPLETED\"}"),
            fallbackResponse: fixture("{\"images\":[]}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0
        )

        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        _ = try await client.result(endpoint: endpoint, requestId: requestID)

        #expect(FixtureURLProtocol.requests().map(\.url) == [submit, fallbackStatus, fallbackResponse])
    }

    @Test("transient empty status responses are retried before completion")
    func transientEmptyStatusRetries() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-retry/status"
        )!
        let result = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-retry"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-retry\"}")],
            status: [
                fixture(""),
                fixture("{}"),
                fixture("{\"status\":\"IN_PROGRESS\"}"),
                fixture("{\"status\":\"COMPLETED\"}"),
            ],
            result: [fixture("{\"images\":[]}")],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0
        )

        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        _ = try await client.result(endpoint: endpoint, requestId: requestID)

        #expect(FixtureURLProtocol.requests().filter { $0.url == status }.count == 4)
    }

    @Test("cancelled provider states fail immediately")
    func cancelledProviderStateFailsImmediately() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-cancelled/status"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-cancelled\"}"),
            status: fixture("{\"status\":\"CANCELLED\",\"error\":\"provider cancelled\"}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected terminal status failure")
        } catch {
            #expect(error.localizedDescription.contains("provider cancelled"))
            #expect(FixtureURLProtocol.requests().filter { $0.url == status }.count == 1)
        }
    }

    @Test("repeated unknown provider states cancel the provider job")
    func repeatedUnknownStateCancelsProviderJob() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-unknown/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-unknown/cancel"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-unknown\"}")],
            status: [
                fixture("{\"status\":\"PAUSED\"}"),
                fixture("{\"status\":\"PAUSED\"}"),
            ],
            cancel: [fixture("{}")],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxInvalidStatusResponses: 2
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected unknown status failure")
        } catch {
            #expect(error.localizedDescription.contains("unsupported state 'PAUSED' after 2 attempts"))
            #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "GET", "GET", "PUT"])
            #expect(FixtureURLProtocol.requests().last?.url == cancel)
        }
    }

    @Test("repeated invalid status responses cancel the provider job")
    func repeatedInvalidStatusCancelsProviderJob() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-invalid/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-invalid/cancel"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-invalid\"}")],
            status: [fixture(""), fixture("{}")],
            cancel: [fixture("{}")],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxInvalidStatusResponses: 2
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected invalid status failure")
        } catch {
            #expect(error.localizedDescription.contains("no valid state after 2 attempts"))
            #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "GET", "GET", "PUT"])
            #expect(FixtureURLProtocol.requests().last?.url == cancel)
        }
    }

    @Test("retryable status and result failures recover without resubmitting")
    func retryableLifecycleFailuresRecover() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-503/status"
        )!
        let result = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-503"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-503\"}")],
            status: [
                fixture("{\"detail\":\"temporary\"}", status: 500),
                fixture("{\"status\":\"COMPLETED\"}"),
            ],
            result: [
                fixture("{\"detail\":\"temporary\"}", status: 500),
                fixture("{\"images\":[]}"),
            ],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0
        )

        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        _ = try await client.result(endpoint: endpoint, requestId: requestID)
        let requests = FixtureURLProtocol.requests()

        #expect(requests.filter { $0.url == submit }.count == 1)
        #expect(requests.filter { $0.url == status }.count == 2)
        #expect(requests.filter { $0.url == result }.count == 2)
    }

    @Test("exhausted retryable status failures cancel the provider job")
    func exhaustedStatusRetriesCancelProviderJob() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-status-500/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-status-500/cancel"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-status-500\"}")],
            status: Array(repeating: fixture("{\"detail\":\"temporary\"}", status: 500), count: 6),
            cancel: [fixture("{}")],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        await #expect(throws: GenerationBackendError.self) {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
        }
        #expect(FixtureURLProtocol.requests().filter { $0.url == status }.count == 6)
        #expect(FixtureURLProtocol.requests().last?.url == cancel)
        #expect(FixtureURLProtocol.requests().last?.method == "PUT")
    }

    @Test("timeout cancels the provider job")
    func timeoutCancelsProviderJob() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-timeout/cancel"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-timeout\"}"),
            cancel: fixture("{}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 0
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "PUT"])
            #expect(FixtureURLProtocol.requests().last?.url == cancel)
        }
    }

    @Test("lifecycle retry backoff cannot exceed the generation deadline")
    func lifecycleRetryStopsAtDeadline() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-deadline/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-deadline/cancel"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-deadline\"}"),
            status: fixture("{\"detail\":\"temporary\"}", status: 500),
            cancel: fixture("{}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 1_000_000_000,
            maxWaitSeconds: 0.1
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "GET", "PUT"])
            #expect(FixtureURLProtocol.requests().last?.url == cancel)
        }
    }

    @Test("Retry-After is honored within the generation deadline")
    func retryAfterStopsAtDeadline() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-retry-after/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-retry-after/cancel"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-retry-after\"}"),
            status: fixture(
                "{\"detail\":\"rate limited\"}",
                status: 429,
                headers: ["Retry-After": "1"]
            ),
            cancel: fixture("{}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 0.1
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "GET", "PUT"])
            #expect(FixtureURLProtocol.requests().last?.url == cancel)
        }
    }

    @Test("poll delay cannot exceed the generation deadline")
    func pollingStopsAtDeadline() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-poll-deadline/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-poll-deadline/cancel"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-poll-deadline\"}")],
            status: [
                fixture("{\"status\":\"IN_PROGRESS\"}"),
                fixture("{\"status\":\"IN_PROGRESS\"}"),
            ],
            cancel: [fixture("{}")],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 1_000_000_000,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 0.1
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        do {
            _ = try await client.result(endpoint: endpoint, requestId: requestID)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
            #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "GET", "GET", "PUT"])
            #expect(FixtureURLProtocol.requests().last?.url == cancel)
        }
    }

    @Test("the deadline reserves one final status poll")
    func finalStatusPollCanComplete() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-final-poll/status"
        )!
        let result = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-final-poll"
        )!
        FixtureURLProtocol.installSequence([
            submit: [fixture("{\"request_id\":\"job-final-poll\"}")],
            status: [
                fixture("{\"status\":\"IN_PROGRESS\"}"),
                fixture("{\"status\":\"COMPLETED\"}"),
            ],
            result: [fixture("{\"images\":[]}")],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 1_000_000_000,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 0.1
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        _ = try await client.result(endpoint: endpoint, requestId: requestID)

        #expect(FixtureURLProtocol.requests().map(\.method) == ["POST", "GET", "GET", "GET"])
        #expect(FixtureURLProtocol.requests().last?.url == result)
    }

    @Test("a completed response received after the wait deadline is preserved")
    func completedResponsePastDeadlineIsPreserved() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-late-complete/status"
        )!
        let result = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-late-complete"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-late-complete\"}"),
            status: fixture(
                "{\"status\":\"COMPLETED\"}",
                delaySeconds: 0.15
            ),
            result: fixture("{\"images\":[]}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 0,
            retryBaseDelayNanoseconds: 0,
            maxWaitSeconds: 0.1
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))

        _ = try await client.result(endpoint: endpoint, requestId: requestID)

        #expect(FixtureURLProtocol.requests().map(\.url) == [submit, status, result])
    }

    @Test("task cancellation cancels the provider job")
    func taskCancellationCancelsProviderJob() async throws {
        let endpoint = "fal-ai/gemini-25-flash-image/edit"
        let submit = URL(string: "https://queue.fal.run/\(endpoint)")!
        let status = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-task-cancel/status"
        )!
        let cancel = URL(
            string: "https://queue.fal.run/fal-ai/gemini-25-flash-image/requests/job-task-cancel/cancel"
        )!
        FixtureURLProtocol.install([
            submit: fixture("{\"request_id\":\"job-task-cancel\"}"),
            status: fixture("{\"status\":\"IN_PROGRESS\"}"),
            cancel: fixture("{}"),
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = FalClient(
            apiKey: "test-key",
            session: testSession,
            pollIntervalNanoseconds: 60_000_000_000,
            retryBaseDelayNanoseconds: 0
        )
        let requestID = try await client.submit(endpoint: endpoint, inputBody: Data("{}".utf8))
        let resultTask = Task {
            try await client.result(endpoint: endpoint, requestId: requestID)
        }
        for _ in 0..<400 {
            if FixtureURLProtocol.requests().contains(where: { $0.url == status }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(FixtureURLProtocol.requests().contains(where: { $0.url == status }))

        resultTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await resultTask.value
        }
        for _ in 0..<400 {
            if FixtureURLProtocol.requests().contains(where: { $0.url == cancel }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(FixtureURLProtocol.requests().last?.url == cancel)
        #expect(FixtureURLProtocol.requests().last?.method == "PUT")
    }
}
