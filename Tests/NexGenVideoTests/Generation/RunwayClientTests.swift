import Foundation
import Testing

@testable import NexGenVideo

@Suite("Runway task transport", .serialized)
struct RunwayClientTests {
    @Test @MainActor func exactRunwayPricesUseOfficialCreditsAndReferenceBilling() throws {
        let fixtures: [(String, String, String?, Int, Int, Int)] = [
            ("gemini_image3_pro", "1K", nil, 1, 0, 20),
            ("gemini_image3_pro", "2K", nil, 1, 14, 20),
            ("gemini_image3_pro", "4K", nil, 1, 1, 40),
            ("grok_imagine_image_2", "1K", "medium", 4, 2, 26),
            ("grok_imagine_image_2", "2K", "medium", 4, 3, 35),
            ("gpt_image_2", "2K", "high", 4, 16, 80),
            ("gen4_image", "720p", nil, 1, 0, 5),
            ("gen4_image", "1080p", nil, 1, 3, 8)
        ]
        for (model, resolution, quality, count, references, credits) in fixtures {
            let input = GenerationPricingInput(modelId: "runway/" + model, modality: .image,
                durationSeconds: nil, outputCount: count, resolution: resolution, quality: quality,
                promptCharacterCount: 0, generateAudio: nil,
                referenceRoles: Array(repeating: "image_reference", count: references))
            #expect(try LiveGenerationPricing.runwayCredits(endpoint: input.modelId, input: input) == credits)
        }
    }

    @Test @MainActor func unsupportedPricesAndMissingReferenceFactsRemainTypedStops() {
        for model in ["gemini_image3.1_flash", "unknown_model", "grok_imagine_image_2"] {
            let input = GenerationPricingInput(modelId: "runway/" + model, modality: .image,
                durationSeconds: nil, outputCount: 1, resolution: "1K", quality: nil,
                promptCharacterCount: 0, generateAudio: nil)
            #expect(throws: GenerationPricingFailure.unsupportedOption) {
                try LiveGenerationPricing.runwayCredits(endpoint: input.modelId, input: input)
            }
        }
    }

    @Test @MainActor func pricingUsesTheSamePixelRatioAsTheRunwayRequest() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/gemini_image3_pro"))
        let params = ImageGenerationParams(prompt: "Fixture", aspectRatio: "16:9", resolution: nil,
            quality: nil, imageURLs: ["fixture://first", "fixture://second"], numImages: 1)
        let body = try RunwayClient.textToImageBody(model: model, params: params)
        let input = GenerationPricingInput.image(modelID: model.entry.id, parameters: params)
        #expect(body["ratio"] as? String == "1344:768")
        #expect(input.pixelWidth == 1344)
        #expect(input.pixelHeight == 768)
        #expect(input.referenceRoles == ["image_reference", "image_reference"])
        #expect(try LiveGenerationPricing.runwayCredits(endpoint: model.entry.id, input: input) == 20)
        let routed = GenerationPricingInput.image(modelID: "provider-neutral-image", parameters: params, endpoint: model.entry.id)
        #expect(routed.modelId == "provider-neutral-image")
        #expect(routed.pixelWidth == 1344)
        #expect(try LiveGenerationPricing.runwayCredits(endpoint: model.entry.id, input: routed) == 20)
    }

    @Test func pricingTransportAndExchangeFailuresRemainDistinct() async throws {
        FixtureURLProtocol.reset()
        defer { FixtureURLProtocol.reset() }
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = ProviderMoneyClient(session: testSession)
        let input = GenerationPricingInput(modelId: "fixture", modality: .image, durationSeconds: nil,
            outputCount: 1, resolution: nil, quality: nil, promptCharacterCount: 0, generateAudio: nil)
        FixtureURLProtocol.enqueue(method: "GET", pathSuffix: "/models/pricing", result: .urlError(.notConnectedToInternet))
        await #expect(throws: GenerationPricingFailure.providerPricingUnavailable) {
            try await client.falQuote(endpoint: "fixture", input: input, apiKey: "fixture-key")
        }
        FixtureURLProtocol.enqueue(method: "GET", pathSuffix: "/eurofxref-daily.xml", result: .urlError(.timedOut))
        await #expect(throws: GenerationPricingFailure.exchangeRateUnavailable) {
            try await client.normalize(nativeAmount: 0.2, currency: "USD", pricingSource: "fixture://price")
        }
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.method == "GET" })
    }

    @Test @MainActor func falNanoBananaProQuotesLiteralResolutionPricesAndExactOutputCounts() async throws {
        FixtureURLProtocol.reset()
        defer { FixtureURLProtocol.reset() }
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = ProviderMoneyClient(session: testSession)
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        FixtureURLProtocol.enqueue(method: "GET", pathSuffix: "/eurofxref-daily.xml",
            result: .response(status: 200, body: "<Cube time='\(date)'><Cube currency='USD' rate='1'/></Cube>"))
        let fixtures: [(String, String?, Int, Int, Double)] = [
            ("fal-ai/nano-banana-pro", nil, 1, 0, 0.15),
            ("fal-ai/nano-banana-pro", "1K", 1, 0, 0.15),
            ("fal-ai/nano-banana-pro", "2K", 1, 0, 0.15),
            ("fal-ai/nano-banana-pro", "4K", 1, 0, 0.30),
            ("fal-ai/nano-banana-pro", "4K", 4, 0, 1.20),
            ("fal-ai/nano-banana-pro/edit", "1K", 1, 1, 0.15),
            ("fal-ai/nano-banana-pro/edit", "2K", 1, 14, 0.15),
            ("fal-ai/nano-banana-pro/edit", "4K", 1, 2, 0.30),
            ("fal-ai/nano-banana-pro/edit", "4K", 4, 14, 1.20),
        ]
        for (endpoint, resolution, count, references, expectedUSD) in fixtures {
            enqueueFalPrice(endpoint: endpoint)
            let parameters = ImageGenerationParams(prompt: "Fixture", aspectRatio: "16:9", resolution: resolution,
                quality: nil, imageURLs: Array(repeating: "fixture://image", count: references), numImages: count)
            let input = GenerationPricingInput.image(modelID: "provider-neutral-image", parameters: parameters, endpoint: endpoint)
            let money = try await client.falQuote(endpoint: endpoint, input: input, apiKey: "fixture-key")
            #expect(money.nativeAmount == expectedUSD)
            #expect(money.nativeCurrency == "USD")
            #expect(money.eurAmount == expectedUSD)
        }
        #expect(FixtureURLProtocol.requests().allSatisfy {
            $0.method == "GET" && ($0.url?.path == "/v1/models/pricing" || $0.url?.path.hasSuffix("/eurofxref-daily.xml") == true)
        })
    }

    @Test @MainActor func falNanoBananaProRequestCannotEnableUnpricedOptionalFeatures() throws {
        for endpoint in ["fal-ai/nano-banana-pro", "fal-ai/nano-banana-pro/edit"] {
            let model = try #require(FalModelRegistry.model(for: endpoint))
            let references = endpoint.hasSuffix("/edit") ? ["fixture://image"] : []
            let parameters = ImageGenerationParams(prompt: "Fixture", aspectRatio: "16:9", resolution: "4K",
                quality: nil, imageURLs: references, numImages: 4)
            let body = FalInputBuilder.imageInput(parameters, model: model, count: parameters.numImages)
            var expectedKeys: Set<String> = ["prompt", "aspect_ratio", "resolution", "num_images"]
            if !references.isEmpty { expectedKeys.insert("image_urls") }
            #expect(Set(body.keys) == expectedKeys)
            #expect(body["resolution"] as? String == "4K")
            #expect(body["num_images"] as? Int == 4)
            #expect(body["enable_web_search"] == nil)
            #expect(body["limit_generations"] == nil)
        }
    }

    @Test func falUnprovenOptionsAndReferenceFactsFailBeforeExchangeLookup() async throws {
        FixtureURLProtocol.reset()
        defer { FixtureURLProtocol.reset() }
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = ProviderMoneyClient(session: testSession)
        let generate = "fal-ai/nano-banana-pro"
        let edit = generate + "/edit"
        let fixtures: [(String, GenerationPricingInput)] = [
            (generate, falPricingInput(resolution: "8K")),
            (generate, falPricingInput(resolution: "1k")),
            (generate, falPricingInput(quality: "high")),
            (generate, falPricingInput(generateAudio: true)),
            (generate, falPricingInput(generateAudio: false)),
            (generate, falPricingInput(duration: 1)),
            (generate, falPricingInput(count: 0)),
            (generate, falPricingInput(count: 5)),
            (generate, falPricingInput(pixelWidth: 1024)),
            (generate, falPricingInput(pixelHeight: 1024)),
            (generate, falPricingInput(references: nil)),
            (generate, falPricingInput(references: ["image_reference"])),
            (edit, falPricingInput(references: nil)),
            (edit, falPricingInput(references: [])),
            (edit, falPricingInput(references: ["audio_reference"])),
            (edit, falPricingInput(references: ["video_reference"])),
            (edit, falPricingInput(references: Array(repeating: "image_reference", count: 15))),
            (generate, falPricingInput(modality: .video)),
            (generate, falPricingInput(modality: .audio)),
        ]
        for (endpoint, input) in fixtures {
            enqueueFalPrice(endpoint: endpoint)
            await #expect(throws: GenerationPricingFailure.unsupportedOption) {
                try await client.falQuote(endpoint: endpoint, input: input, apiKey: "fixture-key")
            }
        }
        for (unit, unitPrice, currency) in [("request", 0.15, "USD"), ("image", 0.2, "USD"), ("image", 0.15, "EUR")] {
            enqueueFalPrice(endpoint: generate, unit: unit, unitPrice: unitPrice, currency: currency)
            await #expect(throws: GenerationPricingFailure.unsupportedOption) {
                try await client.falQuote(endpoint: generate, input: falPricingInput(), apiKey: "fixture-key")
            }
        }
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.method == "GET" && $0.url?.path == "/v1/models/pricing" })
    }

    @Test @MainActor func falUnitsAndUnauditedCatalogEndpointsNeverAuthorizeGenericMultiplication() async throws {
        FixtureURLProtocol.reset()
        defer { FixtureURLProtocol.reset() }
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = ProviderMoneyClient(session: testSession)
        let units = ["request", "requests", "call", "calls", "image", "images", "video", "videos", "output",
            "second", "seconds", "video_second", "video_seconds", "output_second", "output_seconds",
            "audio_second", "audio_seconds", "minute", "minutes", "audio_minute", "audio_minutes",
            "character", "characters", "thousand_characters", "1000_characters", "megapixel"]
        for unit in units {
            enqueueFalPrice(endpoint: "fal-ai/unknown", unit: unit)
            await #expect(throws: GenerationPricingFailure.unsupportedOption) {
                try await client.falQuote(endpoint: "fal-ai/unknown",
                    input: falPricingInput(resolution: "4K", quality: "high", generateAudio: true, duration: 8), apiKey: "fixture-key")
            }
        }
        for model in FalModelRegistry.models where !["fal-ai/nano-banana-pro", "fal-ai/nano-banana-pro/edit"].contains(model.entry.id) {
            enqueueFalPrice(endpoint: model.entry.id)
            await #expect(throws: GenerationPricingFailure.unsupportedOption) {
                try await client.falQuote(endpoint: model.entry.id, input: falPricingInput(), apiKey: "fixture-key")
            }
        }
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.method == "GET" && $0.url?.path == "/v1/models/pricing" })
    }

    private func falPricingInput(resolution: String? = "1K", quality: String? = nil, generateAudio: Bool? = nil,
                                 duration: Double? = nil, count: Int = 1, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                                 references: [String]? = [], modality: GenerationRequest.Modality = .image) -> GenerationPricingInput {
        GenerationPricingInput(modelId: "provider-neutral-image", modality: modality, durationSeconds: duration,
            outputCount: count, resolution: resolution, quality: quality, promptCharacterCount: 10,
            generateAudio: generateAudio, pixelWidth: pixelWidth, pixelHeight: pixelHeight, referenceRoles: references)
    }

    private func enqueueFalPrice(endpoint: String, unit: String = "image", unitPrice: Double = 0.15, currency: String = "USD") {
        FixtureURLProtocol.enqueue(method: "GET", pathSuffix: "/models/pricing", result: .response(status: 200,
            body: "{\"prices\":[{\"endpoint_id\":\"\(endpoint)\",\"unit_price\":\(unitPrice),\"unit\":\"\(unit)\",\"currency\":\"\(currency)\"}]}"))
    }

    @Test @MainActor func imageRerunQuotesExactPixelsAndReferenceCountBeforeDispatch() async throws {
        let editor = EditorViewModel()
        let source = MediaAsset(url: URL(fileURLWithPath: "/fixture/generated.png"), type: .image,
            name: "Generated", duration: 1, generationInput: .init(prompt: "Fixture", model: "runway/grok_imagine_image_2",
                duration: 0, aspectRatio: "16:9", imageURLs: ["https://example.test/first.png", "https://example.test/second.png"]))
        var quoted: GenerationPricingInput?
        await #expect(throws: (any Error).self) {
            try await EditSubmitter.rerun(asset: source, editor: editor, quoteLoader: { _, input in
                quoted = input
                throw GenerationPricingFailure.exchangeRateUnavailable
            })
        }
        let input = try #require(quoted)
        #expect(input.pixelWidth == 1280)
        #expect(input.pixelHeight == 720)
        #expect(input.referenceRoles == ["image_reference", "image_reference"])
        #expect(try LiveGenerationPricing.runwayCredits(endpoint: source.generationInput!.model, input: input) == 8)
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

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
