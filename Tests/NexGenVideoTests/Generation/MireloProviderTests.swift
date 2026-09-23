import Foundation
import Testing

@testable import NexGenVideo

@Suite("Mirelo provider contracts", .serialized)
struct MireloProviderTests {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        struct Fixture: Sendable {
            let status: Int
            let data: Data
            let headers: [String: String]
            let error: URLError.Code?

            init(
                status: Int = 200,
                data: Data = Data(),
                headers: [String: String] = [:],
                error: URLError.Code? = nil
            ) {
                self.status = status
                self.data = data
                self.headers = headers
                self.error = error
            }
        }

        struct Captured: Sendable {
            let url: URL
            let method: String?
            let authorization: String?
            let mireloVersion: String?
            let idempotencyKey: String?
            let body: Data?
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var fixtures: [URL: [Fixture]] = [:]
        nonisolated(unsafe) private static var captured: [Captured] = []

        static func install(_ values: [URL: [Fixture]]) {
            lock.withLock {
                fixtures = values
                captured = []
            }
        }

        static func requests() -> [Captured] {
            lock.withLock { captured }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let value = Captured(
                url: url,
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                mireloVersion: request.value(forHTTPHeaderField: "Mirelo-Version"),
                idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"),
                body: request.httpBody
            )
            guard let fixture = Self.lock.withLock({ () -> Fixture? in
                Self.captured.append(value)
                guard var queue = Self.fixtures[url], !queue.isEmpty else { return nil }
                let fixture = queue.removeFirst()
                Self.fixtures[url] = queue
                return fixture
            }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            if let error = fixture.error {
                client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            var headers = fixture.headers
            headers["Content-Type"] = "application/json"
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
    }

    private let baseURL = URL(string: "https://mirelo.invalid")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/Mirelo/\(name).json")
            .standardizedFileURL
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func store() throws -> (MireloExecutionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MireloProviderTests-\(UUID().uuidString)", isDirectory: true)
        let authority = try GenerationExecutionAuthorityStore(
            root: root,
            hostID: "11111111-1111-4111-8111-111111111111"
        )
        return (MireloExecutionStore(authority: authority), root)
    }

    private func affordablePreflight() -> MireloPreflight {
        MireloPreflight(
            credits: 50,
            estimatedMs: 9_000,
            creditRecovery: MireloCreditRecovery(
                creditsRequired: 50,
                creditsAvailable: 1_100,
                creditShortfall: 0,
                recoveryAction: nil,
                recoveryURL: nil,
                provisioningState: "ready",
                provisioningDeadline: nil
            )
        )
    }

    @Test("authenticated account and model discovery decode the current v3 contract")
    @MainActor
    func discoveryContract() async throws {
        FixtureURLProtocol.install([
            baseURL.appendingPathComponent("v3/me"): [.init(data: try fixture("account"))],
            baseURL.appendingPathComponent("v3/models"): [.init(data: try fixture("models"))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)

        async let account = client.account()
        async let models = client.models()
        let (resolvedAccount, resolvedModels) = try await (account, models)

        #expect(resolvedAccount.email == "editor@example.com")
        #expect(resolvedAccount.spendCapacity == 1_100)
        let model = try #require(resolvedModels.first)
        #expect(model.id == "sfx-1.6")
        #expect(model.operations.keys.sorted() == ["extend", "inpaint", "text-to-sfx", "video-to-sfx"])
        let entry = try #require(MireloCatalogDiscovery.catalogEntry(model))
        #expect(entry.id == "mirelo/sfx-1.6")
        #expect(entry.allowedEndpoints == ["extend", "inpaint", "text-to-sfx", "video-to-sfx"])
        #expect(entry.offers?.first?.provider == .mirelo)
        #expect(FixtureURLProtocol.requests().allSatisfy {
            $0.authorization == "Bearer fixture-key" && $0.mireloVersion == "2026-08-28"
        })
    }

    @Test("v3 preflight and create use the exact body and durable idempotency key")
    func v3PreflightAndCreate() async throws {
        let preflightURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/preflight")
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
            createURL: [.init(status: 202, data: Data(#"{"id":"job-v3","status":"queued","estimated_ms":9000}"#.utf8))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6",
            prompt: "A dry camera shutter",
            durationMS: 5_000,
            numVariants: 1,
            loop: false,
            outputFormat: "wav"
        )

        let quote = try await client.preflight(operation: .textToSFX, body: body)
        let receipt = try await client.create(
            operation: .textToSFX,
            body: body,
            idempotencyKey: "authority-key"
        )

        #expect(quote.credits == 50)
        #expect(quote.creditRecovery?.canFundRequest == true)
        #expect(receipt.id == "job-v3")
        let requests = FixtureURLProtocol.requests()
        #expect(requests.map(\.body) == [body, body])
        #expect(requests.last?.idempotencyKey == "authority-key")
    }

    @Test("private asset discovery uses the current v3 ticket contract")
    func privateAssetTicket() async throws {
        let assetsURL = baseURL.appendingPathComponent("v3/assets")
        FixtureURLProtocol.install([
            assetsURL: [.init(status: 201, data: try fixture("asset-ticket"))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: testSession
        )

        let ticket = try await client.createAsset(
            for: URL(fileURLWithPath: "/tmp/private-source.wav")
        )

        #expect(ticket.id == "5f99d26e-0fbb-46d4-b6e0-51dbf221c7b2")
        #expect(ticket.maxBytes == 67_108_864)
        #expect(ticket.fields["policy"] == "fixture-policy")
        let request = try #require(FixtureURLProtocol.requests().last)
        let body = try object(try #require(request.body))
        #expect((body["content_type"] as? String)?.hasPrefix("audio/") == true)
        #expect(request.authorization == "Bearer fixture-key")
        #expect(request.mireloVersion == "2026-08-28")
    }

    @Test("Audio-to-MIDI uses free duration preflight, no idempotency header, and structured outputs")
    func midiContract() async throws {
        var preflight = URLComponents(
            url: baseURL.appendingPathComponent("v2/audio-to-midi/v1.0/preflight"),
            resolvingAgainstBaseURL: false
        )!
        preflight.queryItems = [URLQueryItem(name: "duration_ms", value: "120000")]
        let createURL = baseURL.appendingPathComponent("v2/audio-to-midi/v1.0/jobs")
        FixtureURLProtocol.install([
            preflight.url!: [.init(data: try fixture("preflight-midi"))],
            createURL: [.init(status: 202, data: Data(#"{"job_id":"4d8b7360-2b42-4f25-a3fa-c9bcc7daf322","job_url":"/v2/audio-to-midi/v1.0/jobs/4d8b7360-2b42-4f25-a3fa-c9bcc7daf322","estimated_ms":24000}"#.utf8))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let body = try MireloRequestBuilder.audioToMIDI(
            assetID: "asset-private",
            timing: "performance",
            subdivision: "automatic",
            timeSignatureNumerator: 6,
            timeSignatureDenominator: 8,
            fixedTempo: true,
            fixedTempoBPM: nil,
            optimizeMusicXML: true,
            scorePDFs: true,
            pageSize: "a4",
            instruments: ["acoustic_piano"]
        )

        let quote = try await client.preflight(
            operation: .audioToMIDI,
            body: body,
            durationMS: 120_000
        )
        _ = try await client.create(operation: .audioToMIDI, body: body, idempotencyKey: nil)
        let descriptors = try MireloResultParser.descriptors(
            operation: .audioToMIDI,
            terminalResponse: try fixture("midi-succeeded")
        )

        #expect(quote.credits == 300)
        #expect(quote.billingMode == "metered")
        #expect(FixtureURLProtocol.requests().last?.idempotencyKey == nil)
        let request = try object(body)
        #expect((request["audio"] as? [String: String])?["asset_id"] == "asset-private")
        #expect((request["tempo"] as? [String: String])?["mode"] == "fixed")
        let expectedKinds: Set<MireloArtifact.Kind> = [
            .midi, .musicXML, .noteJSON, .scorePDF, .scoreBundle, .scoreManifest,
        ]
        #expect(Set(descriptors.map(\.kind)) == expectedKinds)
        let notes = try #require(descriptors.first { $0.kind == .noteJSON }?.embeddedData)
        #expect((try object(notes)["notes"] as? [[String: Any]])?.first?["instrument"] as? String == "acoustic_piano")
    }

    @Test("dynamic model limits and Audio-to-MIDI meter rules fail before submission")
    func requestValidation() throws {
        struct Models: Decodable { let data: [MireloModel] }
        let model = try #require(JSONDecoder().decode(Models.self, from: fixture("models")).data.first)
        #expect(throws: (any Error).self) {
            try MireloRequestBuilder.validate(
                operation: .textToSFX,
                model: model,
                durationMS: 500,
                appendDurationMS: nil,
                regionStartMS: nil,
                regionEndMS: nil,
                numVariants: 1,
                prompt: "loop",
                loop: true,
                preserveSpeech: false
            )
        }
        #expect(throws: (any Error).self) {
            _ = try MireloRequestBuilder.audioToMIDI(
                assetID: "asset",
                timing: "performance",
                subdivision: nil,
                timeSignatureNumerator: 4,
                timeSignatureDenominator: 8,
                fixedTempo: false,
                fixedTempoBPM: nil,
                optimizeMusicXML: false,
                scorePDFs: false,
                pageSize: "a4",
                instruments: nil
            )
        }
    }

    @Test("v2 uncertain acceptance is persisted and never automatically resubmitted")
    func midiUnknownAcceptance() async throws {
        let createURL = baseURL.appendingPathComponent("v2/audio-to-midi/v1.0/jobs")
        FixtureURLProtocol.install([
            createURL: [.init(error: .timedOut)],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "22222222-2222-4222-8222-222222222222"
        let body = try MireloRequestBuilder.audioToMIDI(
            assetID: "asset-private",
            timing: "performance",
            subdivision: nil,
            timeSignatureNumerator: nil,
            timeSignatureDenominator: nil,
            fixedTempo: false,
            fixedTempoBPM: nil,
            optimizeMusicXML: false,
            scorePDFs: false,
            pageSize: "a4",
            instruments: nil
        )
        let prepared = try await coordinator.prepare(
            store: store,
            projectKey: "project-fixture",
            logicalJobID: logicalID,
            operation: .audioToMIDI,
            requestBody: body,
            sources: [],
            preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: store,
            record: prepared,
            spendTransactionID: "spend-fixture"
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.execute(
                store: store,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                client: client
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.execute(
                store: store,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                client: client
            )
        }

        #expect(try store.load(projectKey: "project-fixture", logicalJobID: logicalID)?.state == .acceptanceUnknown)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
    }

    @Test("v3 retry recovers the same idempotent logical job")
    func v3IdempotentRecovery() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        FixtureURLProtocol.install([
            createURL: [
                .init(error: .networkConnectionLost),
                .init(status: 202, data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)),
            ],
            pollURL: [
                .init(data: try fixture("v3-succeeded")),
                .init(data: try fixture("v3-succeeded")),
            ],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "33333333-3333-4333-8333-333333333333"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6",
            prompt: "A dry camera shutter",
            durationMS: 5_000,
            numVariants: 1,
            loop: false,
            outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: store,
            projectKey: "project-fixture",
            logicalJobID: logicalID,
            operation: .textToSFX,
            requestBody: body,
            sources: [],
            preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: store,
            record: prepared,
            spendTransactionID: "spend-fixture"
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.execute(
                store: store,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                client: client
            )
        }
        let outcome = try await coordinator.execute(
            store: store,
            projectKey: "project-fixture",
            logicalJobID: logicalID,
            client: client
        )
        let refreshed = try await coordinator.refreshResult(
            store: store,
            record: outcome.record,
            client: client
        )

        #expect(outcome.record.state == .providerSucceeded)
        #expect(refreshed.record.providerJobID == outcome.record.providerJobID)
        let creates = FixtureURLProtocol.requests().filter { $0.url == createURL }
        #expect(creates.count == 2)
        #expect(creates[0].idempotencyKey == creates[1].idempotencyKey)
        #expect(creates[0].idempotencyKey?.isEmpty == false)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 2)
    }

    @Test("interrupted polling resumes the accepted job without another create")
    func interruptedPollingResume() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        FixtureURLProtocol.install([
            createURL: [
                .init(status: 202, data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)),
            ],
            pollURL: [
                .init(
                    status: 503,
                    data: Data(#"{"error":{"code":"temporarily_unavailable","message":"Retry later","retryable":false}}"#.utf8)
                ),
                .init(data: try fixture("v3-succeeded")),
            ],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: testSession
        )
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "44444444-4444-4444-8444-444444444444"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6",
            prompt: "A dry camera shutter",
            durationMS: 5_000,
            numVariants: 1,
            loop: false,
            outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: store,
            projectKey: "project-fixture",
            logicalJobID: logicalID,
            operation: .textToSFX,
            requestBody: body,
            sources: [],
            preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: store,
            record: prepared,
            spendTransactionID: "spend-fixture"
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.execute(
                store: store,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                client: client
            )
        }
        #expect(try store.load(
            projectKey: "project-fixture",
            logicalJobID: logicalID
        )?.state == .pollingInterrupted)
        let outcome = try await coordinator.execute(
            store: store,
            projectKey: "project-fixture",
            logicalJobID: logicalID,
            client: client
        )

        #expect(outcome.record.state == .providerSucceeded)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 2)
    }

    @Test("authentication, credit recovery, and rate limits retain actionable HTTP evidence")
    func failureContracts() async throws {
        let accountURL = baseURL.appendingPathComponent("v3/me")
        FixtureURLProtocol.install([
            accountURL: [
                .init(status: 401, data: Data(#"{"error":{"code":"unauthorized","message":"Invalid API key"}}"#.utf8)),
                .init(status: 402, data: Data(#"{"error":{"code":"insufficient_credits","message":"Insufficient credits","credits_required":500,"credits_available":100,"credit_shortfall":400,"recovery_action":"view_plans","recovery_url":"https://mirelo.ai/pricing","provisioning_state":"ready","provisioning_deadline":null}}"#.utf8)),
                .init(status: 429, data: Data(#"{"error":{"code":"rate_limited","message":"Slow down"}}"#.utf8), headers: ["Retry-After": "7"]),
            ],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)

        for expectedStatus in [401, 402, 429] {
            do {
                _ = try await client.account()
                Issue.record("Expected Mirelo HTTP \(expectedStatus)")
            } catch let error as MireloHTTPError {
                #expect(error.status == expectedStatus)
                if expectedStatus == 402 {
                    #expect(error.creditRecovery?.creditShortfall == 400)
                    #expect(error.creditRecovery?.recoveryAction == "view_plans")
                }
                if expectedStatus == 429 { #expect(error.retryAfterSeconds == 7) }
            }
        }
    }
}
