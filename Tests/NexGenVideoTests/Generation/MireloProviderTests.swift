import Foundation
import Testing

@testable import NexGenVideo

@Suite("Mirelo provider contracts", .serialized)
struct MireloProviderTests {
    private actor FixtureGate {
        private var opened = false
        private var started = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !opened else { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            opened = true
            let waiters = openWaiters
            openWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        struct Fixture: Sendable {
            let status: Int
            let data: Data
            let headers: [String: String]
            let error: URLError.Code?
            let gate: FixtureGate?

            init(
                status: Int = 200,
                data: Data = Data(),
                headers: [String: String] = [:],
                error: URLError.Code? = nil,
                gate: FixtureGate? = nil
            ) {
                self.status = status
                self.data = data
                self.headers = headers
                self.error = error
                self.gate = gate
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

        private static func body(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16_384)
            defer { buffer.deallocate() }
            while true {
                let count = stream.read(buffer, maxLength: 16_384)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }

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
                body: Self.body(of: request)
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
            Task { [fixture] in
                await fixture.gate?.wait()
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
        guard case .audio(let caps) = entry.uiCapabilities else {
            Issue.record("Expected Mirelo audio capabilities")
            return
        }
        #expect(caps.inputs == ["text"])
        #expect(GenerationService.mireloGenericOperation(model: model, hasVideoSource: false) == .textToSFX)
        #expect(GenerationService.mireloGenericOperation(model: model, hasVideoSource: true) == .videoToSFX)
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

    @Test("Mirelo raw prompts stop at the shared gate while the pro toggle is off")
    @MainActor
    func rawPromptGate() async {
        let key = PromptCompiler.rawPromptsDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        FixtureURLProtocol.install([:])
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)

        await #expect(throws: ToolError.self) {
            _ = try await executor.validatedMireloPrompt(
                args: ["rawPrompt": true, "shotId": "none"],
                prompt: "uncompiled sound prompt",
                modelID: "mirelo/sfx-1.6",
                editor: editor
            )
        }
        #expect(FixtureURLProtocol.requests().isEmpty)
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

    @Test("a logical job rejects changed immutable intent before replay")
    func immutableIntent() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "55555555-5555-4555-8555-555555555555"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6",
            prompt: "First prompt",
            durationMS: 5_000,
            numVariants: 1,
            loop: false,
            outputFormat: "wav"
        )
        _ = try await coordinator.prepare(
            store: store,
            projectKey: "project-fixture",
            logicalJobID: logicalID,
            operation: .textToSFX,
            intentBody: Data(#"{"model":"sfx-1.6","prompt":"First prompt"}"#.utf8),
            requestBody: body,
            sources: [],
            preflight: affordablePreflight()
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.prepare(
                store: store,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                operation: .textToSFX,
                intentBody: Data(#"{"model":"sfx-1.6","prompt":"Changed prompt"}"#.utf8),
                requestBody: body,
                sources: [],
                preflight: affordablePreflight()
            )
        }
    }

    @Test("concurrent execute callers share one create and poll")
    func concurrentExecuteCoalesces() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        let gate = FixtureGate()
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8),
                gate: gate
            )],
            pollURL: [.init(data: try fixture("v3-succeeded"))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "66666666-6666-4666-8666-666666666666"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
            numVariants: 1, loop: false, outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: store, projectKey: "project-fixture", logicalJobID: logicalID,
            operation: .textToSFX, requestBody: body, sources: [],
            preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: store, record: prepared, spendTransactionID: "spend-fixture"
        )

        async let first = coordinator.execute(
            store: store, projectKey: "project-fixture",
            logicalJobID: logicalID, client: client
        )
        await gate.waitUntilStarted()
        async let second = coordinator.execute(
            store: store, projectKey: "project-fixture",
            logicalJobID: logicalID, client: client
        )
        await gate.open()
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 1)
    }

    @Test("concurrent MIDI execute callers preserve one accepted provider job")
    func concurrentMIDIExecuteCoalesces() async throws {
        let createURL = baseURL.appendingPathComponent("v2/audio-to-midi/v1.0/jobs")
        let pollURL = baseURL.appendingPathComponent("v2/audio-to-midi/v1.0/jobs/job-midi")
        let gate = FixtureGate()
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"job_id":"job-midi","status":"processing"}"#.utf8),
                gate: gate
            )],
            pollURL: [.init(data: Data(
                #"{"job_id":"job-midi","status":"succeeded","result":{"notes":[]}}"#.utf8
            ))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
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
            store: store, projectKey: "project-fixture", logicalJobID: logicalID,
            operation: .audioToMIDI, requestBody: body, sources: [],
            preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: store, record: prepared, spendTransactionID: "spend-fixture"
        )

        async let first = coordinator.execute(
            store: store, projectKey: "project-fixture",
            logicalJobID: logicalID, client: client
        )
        await gate.waitUntilStarted()
        async let second = coordinator.execute(
            store: store, projectKey: "project-fixture",
            logicalJobID: logicalID, client: client
        )
        await gate.open()
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(a.record.providerJobID == "job-midi")
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 1)
    }

    @Test("ambiguous create HTTP statuses preserve acceptance uncertainty")
    func ambiguousCreateStatusIsNotRejection() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let cases = [
            (408, "77777777-7777-4777-8777-777777777777"),
            (409, "dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
        ]
        for (status, logicalID) in cases {
            FixtureURLProtocol.install([
                createURL: [.init(
                    status: status,
                    data: Data(#"{"error":{"code":"acceptance_ambiguous","message":"Still resolving","retryable":false}}"#.utf8)
                )],
            ])
            let testSession = session()
            let client = MireloClient(
                apiKey: "fixture-key",
                baseURL: baseURL,
                session: testSession
            )
            let (store, root) = try store()
            let coordinator = MireloExecutionCoordinator()
            let body = try MireloRequestBuilder.textToSFX(
                model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
                numVariants: 1, loop: false, outputFormat: "wav"
            )
            let prepared = try await coordinator.prepare(
                store: store, projectKey: "project-fixture",
                logicalJobID: logicalID, operation: .textToSFX,
                requestBody: body, sources: [], preflight: affordablePreflight()
            )
            _ = try await coordinator.approve(
                store: store, record: prepared, spendTransactionID: "spend-fixture"
            )

            await #expect(throws: (any Error).self) {
                _ = try await coordinator.execute(
                    store: store, projectKey: "project-fixture",
                    logicalJobID: logicalID, client: client
                )
            }
            let record = try #require(store.load(
                projectKey: "project-fixture", logicalJobID: logicalID
            ))
            #expect(record.state == .acceptanceUnknown)
            #expect(record.providerJobID == nil)
            testSession.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("failed status with an empty errors array uses the status fallback")
    func emptyErrorsFallback() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)
            )],
            pollURL: [.init(data: Data(#"{"id":"job-v3","status":"failed","errors":[]}"#.utf8))],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "99999999-9999-4999-8999-999999999999"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
            numVariants: 1, loop: false, outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: store, projectKey: "project-fixture", logicalJobID: logicalID,
            operation: .textToSFX, requestBody: body, sources: [],
            preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: store, record: prepared, spendTransactionID: "spend-fixture"
        )
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.execute(
                store: store, projectKey: "project-fixture",
                logicalJobID: logicalID, client: client
            )
        }
        let record = try #require(store.load(
            projectKey: "project-fixture", logicalJobID: logicalID
        ))
        #expect(record.lastError?.contains("ended with status failed") == true)
    }

    @Test("refreshed result URLs do not change stable MIDI artifacts")
    func stableMIDIArtifactsAcrossRefresh() throws {
        var originalRoot = try object(try fixture("midi-succeeded"))
        var originalResult = try #require(originalRoot["result"] as? [String: Any])
        if var pdfs = originalResult["score_pdfs"] as? [[String: Any]],
           let first = pdfs.first {
            var duplicate = first
            duplicate["url"] = "https://results.example/duplicate-full-score.pdf"
            pdfs.append(duplicate)
            originalResult["score_pdfs"] = pdfs
        }
        originalRoot["result"] = originalResult
        let original = try JSONSerialization.data(
            withJSONObject: originalRoot,
            options: [.sortedKeys]
        )
        var root = originalRoot
        var result = try #require(root["result"] as? [String: Any])
        result["midi_url"] = "https://refresh.example/transcription.mid?signature=new"
        result["musicxml_url"] = "https://refresh.example/score.musicxml?signature=new"
        result["score_manifest_url"] = "https://refresh.example/manifest.json?signature=new"
        if var pdfs = result["score_pdfs"] as? [[String: Any]], !pdfs.isEmpty {
            for index in pdfs.indices {
                pdfs[index]["url"] = "https://refresh.example/full-score-\(index).pdf?signature=new"
            }
            result["score_pdfs"] = pdfs
        }
        root["result"] = result
        let refreshed = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        let first = try MireloResultParser.descriptors(
            operation: .audioToMIDI, terminalResponse: original
        )
        let second = try MireloResultParser.descriptors(
            operation: .audioToMIDI, terminalResponse: refreshed
        )
        #expect(
            first.first { $0.kind == .noteJSON }?.embeddedData
                == second.first { $0.kind == .noteJSON }?.embeddedData
        )
        #expect(second.filter { $0.kind == .scorePDF }.map(\.filename)
            == ["score-001.pdf", "score-002.pdf"])
        let manifestA = Data(#"{"parts":[{"name":"score","url":"https://results.example/a?sig=1","sha256":"abc"}]}"#.utf8)
        let manifestB = Data(#"{"parts":[{"name":"score","url":"https://results.example/a?sig=2","sha256":"abc"}]}"#.utf8)
        let stableManifestA = try MireloResultParser.stableJSONArtifact(manifestA)
        let stableManifestB = try MireloResultParser.stableJSONArtifact(manifestB)
        #expect(stableManifestA == stableManifestB)
    }

    @Test("non-expiry download failures retain their precise policy error")
    @MainActor
    func nonExpiryDownloadFailureIsNotRefreshed() async throws {
        let terminal = Data(
            #"{"job_id":"midi-job","status":"succeeded","result":{"midi_url":"https://results.example/transcription.mid","notes":[]}}"#.utf8
        )
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)

        do {
            _ = try await executor.installMireloArtifacts(
                operation: .audioToMIDI,
                logicalJobID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                terminalResponse: terminal,
                editor: editor,
                folderID: nil,
                workingRoot: FileManager.default.temporaryDirectory,
                workingCopyKey: "unused-before-download",
                mutationScope: nil,
                download: { _, _, _ in
                    throw RemoteMediaPolicy.PolicyError.responseTooLarge
                }
            )
            Issue.record("Expected the download policy error to propagate")
        } catch let error as RemoteMediaPolicy.PolicyError {
            #expect(error == .responseTooLarge)
        }
    }

    @Test("refreshed MIDI URLs reinstall the same partial artifact set")
    @MainActor
    func refreshedMIDIArtifactsInstallIdempotently() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirelo-idempotent-\(UUID().uuidString).ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: project)
        let editor = EditorViewModel()
        editor.projectURL = project
        let workingRoot = try #require(editor.workingRoot)
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let scope = try GenerationProjectMutationScope(projectHome: workingRoot, editor: editor)
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)
        let logicalID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        defer {
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: project)
        }

        func terminal(signature: String) -> Data {
            Data(
                #"{"job_id":"midi-job","status":"succeeded","result":{"midi_url":"https://results.example/transcription.mid?signature=\#(signature)","score_manifest_url":"https://results.example/score-manifest.json?signature=\#(signature)","notes":[{"pitch":60,"start":0,"end":1}]}}"#.utf8
            )
        }
        let download: MireloResultDownload = { url, _, _ in
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mirelo-result-\(UUID().uuidString).\(url.pathExtension)")
            if url.pathExtension == "mid" {
                try Data("MThd-idempotent".utf8).write(to: file)
            } else {
                let manifest = try JSONSerialization.data(withJSONObject: [
                    "parts": [[
                        "name": "score",
                        "url": url.absoluteString,
                        "sha256": "stable",
                    ]],
                ], options: [.sortedKeys])
                try manifest.write(to: file)
            }
            return RemoteMediaDownloader.Download(
                temporaryURL: file,
                response: HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }

        let first = try await executor.installMireloArtifacts(
            operation: .audioToMIDI,
            logicalJobID: logicalID,
            terminalResponse: terminal(signature: "first"),
            editor: editor,
            folderID: nil,
            workingRoot: workingRoot,
            workingCopyKey: workingCopyKey,
            mutationScope: scope,
            download: download
        )
        let second = try await executor.installMireloArtifacts(
            operation: .audioToMIDI,
            logicalJobID: logicalID,
            terminalResponse: terminal(signature: "refreshed"),
            editor: editor,
            folderID: nil,
            workingRoot: workingRoot,
            workingCopyKey: workingCopyKey,
            mutationScope: scope,
            download: download
        )

        #expect(first == second)
        #expect(Set(first.map(\.kind)) == [.midi, .noteJSON, .scoreManifest])
    }

    @Test("project switch during a suspended result download performs no project write")
    @MainActor
    func projectSwitchDuringDownload() async throws {
        let firstProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirelo-project-a-\(UUID().uuidString).ngv", isDirectory: true)
        let secondProject = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirelo-project-b-\(UUID().uuidString).ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: firstProject)
        try Fixtures.prepareProjectPackage(at: secondProject)
        let editor = EditorViewModel()
        editor.projectURL = firstProject
        let firstKey = try #require(editor.openWorkingCopyKey)
        let firstRoot = try #require(editor.workingRoot)
        let scope = try GenerationProjectMutationScope(projectHome: firstRoot, editor: editor)
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)
        let gate = FixtureGate()
        let terminal = Data(
            #"{"job_id":"midi-job","status":"succeeded","result":{"midi_url":"https://results.example/transcription.mid","notes":[]}}"#.utf8
        )
        defer {
            let secondKey = editor.openWorkingCopyKey
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: firstKey)
            if let secondKey { ProjectWorkingCopy.discard(key: secondKey) }
            try? FileManager.default.removeItem(at: firstProject)
            try? FileManager.default.removeItem(at: secondProject)
        }

        let install = Task { @MainActor in
            try await executor.installMireloArtifacts(
                operation: .audioToMIDI,
                logicalJobID: "88888888-8888-4888-8888-888888888888",
                terminalResponse: terminal,
                editor: editor,
                folderID: nil,
                workingRoot: firstRoot,
                workingCopyKey: firstKey,
                mutationScope: scope,
                download: { url, _, _ in
                    await gate.wait()
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("mirelo-midi-\(UUID().uuidString).mid")
                    try Data("MThd-fixture".utf8).write(to: file)
                    return RemoteMediaDownloader.Download(
                        temporaryURL: file,
                        response: HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: nil
                        )!
                    )
                }
            )
        }
        await gate.waitUntilStarted()
        editor.projectURL = secondProject
        let secondRoot = try #require(editor.workingRoot)
        await gate.open()

        await #expect(throws: (any Error).self) {
            _ = try await install.value
        }
        #expect(editor.mediaAssets.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: secondRoot.appendingPathComponent("media/Mirelo").path
        ))
    }
}
