import Foundation
import Testing

@testable import NexGenVideo

@Suite("Mirelo provider contracts", .serialized)
struct MireloProviderTests {
    private struct ReloadTimeoutError: LocalizedError {
        var errorDescription: String? {
            "The restored working copy did not finish reloading within 5 seconds."
        }
    }

    @MainActor
    private final class ReloadAwaiter {
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        func wait(for editor: EditorViewModel) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await ContinuousClock().sleep(until: deadline)
                    } catch {
                        return
                    }
                    self?.finish(.failure(ReloadTimeoutError()))
                }
                editor.discardRecoveredWork { [weak self] result in
                    self?.finish(result)
                }
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(with: result)
        }
    }

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

    private actor AcceptanceProbe {
        private(set) var records: [MireloExecutionRecord] = []

        func record(_ value: MireloExecutionRecord) {
            records.append(value)
        }

        func snapshot() -> [MireloExecutionRecord] {
            records
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

    private func affordablePreflight(credits: Int = 50) -> MireloPreflight {
        MireloPreflight(
            credits: credits,
            estimatedMs: 9_000,
            creditRecovery: MireloCreditRecovery(
                creditsRequired: credits,
                creditsAvailable: 1_100,
                creditShortfall: 0,
                recoveryAction: nil,
                recoveryURL: nil,
                provisioningState: "ready",
                provisioningDeadline: nil
            )
        )
    }

    @MainActor
    private struct NativeContext {
        let editor: EditorViewModel
        let asset: MediaAsset
        let store: MireloExecutionStore
        let storeRoot: URL
        let project: URL
        let workingRoot: URL
        let workingCopyKey: String
        let projectKey: String
        let logicalID: String
    }

    @MainActor
    private func nativeContext(
        logicalID: String,
        preflight: MireloPreflight
    ) async throws -> NativeContext {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirelo-native-\(UUID().uuidString).ngv", isDirectory: true)
        try Fixtures.prepareProjectPackage(at: project)
        let editor = EditorViewModel()
        editor.projectURL = project
        let workingRoot = try #require(editor.workingRoot)
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let projectKey = try #require(editor.projectId)
        let media = workingRoot.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var input = GenerationInput(
            prompt: "A dry camera shutter",
            model: "mirelo/sfx-1.6",
            duration: 5,
            aspectRatio: ""
        )
        input.spendTransactionId = logicalID
        let asset = MediaAsset(
            id: "native-sfx-\(logicalID.prefix(8))",
            url: media.appendingPathComponent("native-sfx.wav"),
            type: .audio,
            name: "Native SFX",
            duration: 5,
            generationInput: input
        )
        editor.mediaAssets.append(asset)
        editor.persistMediaAsset(asset)
        editor.generationLog.spendEvents = [GenerationSpendEvent(
            transactionId: logicalID,
            kind: .reserved,
            model: input.model,
            provider: .mirelo,
            transport: .api,
            endpoint: "sfx-1.6",
            note: "Mirelo credits"
        )]
        try editor.persistGenerationLog()

        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6",
            prompt: input.prompt,
            durationMS: 5_000,
            numVariants: 1,
            loop: false,
            outputFormat: "wav"
        )
        let (executionStore, storeRoot) = try store()
        let prepared = try await MireloExecutionCoordinator.shared.prepare(
            store: executionStore,
            projectKey: projectKey,
            logicalJobID: logicalID,
            operation: .textToSFX,
            intentBody: body,
            requestBody: body,
            sources: [],
            preflight: preflight
        )
        _ = try await MireloExecutionCoordinator.shared.approve(
            store: executionStore,
            record: prepared,
            spendTransactionID: logicalID
        )
        return NativeContext(
            editor: editor,
            asset: asset,
            store: executionStore,
            storeRoot: storeRoot,
            project: project,
            workingRoot: workingRoot,
            workingCopyKey: workingCopyKey,
            projectKey: projectKey,
            logicalID: logicalID
        )
    }

    private func authorityRecord(
        store: MireloExecutionStore,
        projectKey: String,
        logicalID: String,
        spendTransactionID: String,
        state: MireloExecutionRecord.State,
        providerJobID: String? = nil,
        lastError: String? = nil
    ) async throws -> MireloExecutionRecord {
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6",
            prompt: "A dry camera shutter",
            durationMS: 5_000,
            numVariants: 1,
            loop: false,
            outputFormat: "wav"
        )
        let prepared = try await MireloExecutionCoordinator.shared.prepare(
            store: store,
            projectKey: projectKey,
            logicalJobID: logicalID,
            operation: .textToSFX,
            intentBody: body,
            requestBody: body,
            sources: [],
            preflight: affordablePreflight()
        )
        var current = try await MireloExecutionCoordinator.shared.approve(
            store: store,
            record: prepared,
            spendTransactionID: spendTransactionID
        )
        switch state {
        case .prepared:
            return current
        case .failed:
            return try store.update(current) {
                $0.state = .failed
                $0.lastError = lastError
            }
        case .submitting:
            return try store.update(current) {
                $0.state = .submitting
                $0.lastError = lastError
            }
        case .acceptanceUnknown:
            current = try store.update(current) {
                $0.state = .submitting
            }
            return try store.update(current) {
                $0.state = .acceptanceUnknown
                $0.lastError = lastError
            }
        case .accepted:
            guard let providerJobID else {
                throw GenerationRequestError.storage(
                    "An accepted authority fixture needs a provider job id."
                )
            }
            current = try store.update(current) {
                $0.state = .submitting
            }
            current = try store.update(current) {
                $0.state = .accepted
                $0.providerJobID = providerJobID
                $0.lastProviderStatus = "accepted"
            }
            return current
        case .pollingInterrupted, .providerSucceeded, .completed:
            throw GenerationRequestError.storage(
                "The authority fixture helper does not synthesize terminal provider evidence."
            )
        }
    }

    @MainActor
    private func openProject(
        at package: URL,
        storeProvider: @escaping () throws -> MireloExecutionStore
    ) async throws -> VideoProject {
        let document = try await VideoProject.load(from: package)
        document.editorViewModel.generationService.mireloStoreProvider = storeProvider
        document.makeWindowControllers()
        return document
    }

    @MainActor
    private func releaseProject(_ document: VideoProject) -> String? {
        for controller in document.windowControllers {
            controller.window?.orderOut(nil)
            document.removeWindowController(controller)
        }
        let key = document.editorViewModel.openWorkingCopyKey
        document.editorViewModel.releaseWorkingCopy()
        return key
    }

    @MainActor
    private func discardAndAwaitReload(_ editor: EditorViewModel) async throws {
        try await ReloadAwaiter().wait(for: editor)
    }

    private func writeProjectState(
        package: URL,
        manifest: MediaManifest,
        log: GenerationLog
    ) throws {
        try JSONEncoder().encode(manifest).write(
            to: package.appendingPathComponent(Project.manifestFilename),
            options: .atomic
        )
        try JSONEncoder().encode(log).write(
            to: package.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
    }

    private func preflightFixture(credits: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "credits": credits,
            "estimated_ms": 9_000,
            "credit_recovery": [
                "credits_required": credits,
                "credits_available": 1_100,
                "credit_shortfall": 0,
                "provisioning_state": "ready",
            ],
        ], options: [.sortedKeys])
    }

    @MainActor
    private func publishFixtureCatalog() async throws {
        let accountURL = baseURL.appendingPathComponent("v3/me")
        let modelsURL = baseURL.appendingPathComponent("v3/models")
        FixtureURLProtocol.install([
            accountURL: [.init(data: try fixture("account"))],
            modelsURL: [.init(data: try fixture("models"))],
        ])
        let fixtureSession = session()
        defer { fixtureSession.invalidateAndCancel() }
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: fixtureSession
        )
        async let account = client.account()
        async let models = client.models()
        let (resolvedAccount, resolvedModels) = try await (account, models)
        MireloCapabilityCatalog.shared.publish(
            account: resolvedAccount,
            models: resolvedModels,
            observedAt: Date()
        )
    }

    @MainActor
    private func firstRunRequest() throws -> GenerationRequest {
        let providerModel = try #require(
            MireloCapabilityCatalog.shared.model(id: "sfx-1.6")
        )
        let entry = try #require(MireloCatalogDiscovery.catalogEntry(providerModel))
        guard case .audio(let caps) = entry.uiCapabilities else {
            throw GenerationRequestError.optionsInvalid("Missing Mirelo audio capabilities.")
        }
        let model = AudioModelConfig(entry: entry, caps: caps)
        let target = ResolvedGenerationTarget(
            modelId: entry.id,
            provider: .mirelo,
            endpoint: providerModel.id,
            binding: ProviderBinding(
                provider: .mirelo,
                transport: .api,
                kind: .generation,
                providerRef: providerModel.id,
                billing: .perCall
            )
        )
        let prompt = "A dry camera shutter"
        let params = AudioGenerationParams(
            prompt: prompt,
            voice: nil,
            lyrics: nil,
            styleInstructions: nil,
            instrumental: false,
            durationSeconds: 5
        )
        return GenerationRequest(
            modality: .audio,
            modelId: entry.id,
            intent: "",
            durationSeconds: 5,
            placement: .mediaLibrary(folderId: nil),
            origin: .panel,
            target: target,
            submission: .audio(make: { _ in
                AudioGenerationSubmission.make(
                    genInput: GenerationInput(
                        prompt: prompt,
                        model: entry.id,
                        duration: 5,
                        aspectRatio: ""
                    ),
                    model: model,
                    params: params,
                    name: "First-run Mirelo SFX"
                )
            })
        )
    }

    private func testMoney() -> GenerationMoney {
        GenerationMoney(
            nativeAmount: 1,
            nativeCurrency: "EUR",
            eurAmount: 1,
            eurPerNativeUnit: 1,
            exchangeRateDate: "2026-09-24",
            pricingSource: "https://mirelo.invalid/pricing",
            exchangeRateSource: "https://www.ecb.europa.eu/"
        )
    }

    @MainActor
    private func assertReleasedOnce(_ editor: EditorViewModel) throws {
        let transactionID = try #require(
            editor.generationLog.spendEvents.first(where: { $0.kind == .reserved })?.transactionId
        )
        #expect(editor.generationLog.spendEvents.filter {
            $0.transactionId == transactionID && $0.kind == .released
        }.count == 1)
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: editor.generationLog,
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput)
        )
        #expect(snapshot.activeReservationCount == 0)
    }

    private func wavFixture() -> Data {
        Data([
            0x52, 0x49, 0x46, 0x46, 0x34, 0x00, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20,
            0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
            0x40, 0x1F, 0x00, 0x00, 0x80, 0x3E, 0x00, 0x00,
            0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
            0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
            0x20, 0x00, 0x10, 0x00, 0x00, 0x00, 0xF0, 0xFF,
            0xE0, 0xFF, 0xF0, 0xFF,
        ])
    }

    private func waitForState(
        _ state: MireloExecutionRecord.State,
        store: MireloExecutionStore,
        projectKey: String,
        logicalID: String
    ) async throws -> MireloExecutionRecord {
        for _ in 0..<500 {
            if let record = try store.load(
                projectKey: projectKey,
                logicalJobID: logicalID
            ), record.state == state {
                return record
            }
            await Task.yield()
        }
        return try #require(store.load(
            projectKey: projectKey,
            logicalJobID: logicalID
        ))
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

    @Test("unknown v3 acceptance survives later account and rate-limit responses")
    func unknownAcceptanceReplayPreservesReservation() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let cases = [
            (401, "12121212-1212-4212-8212-121212121212"),
            (402, "13131313-1313-4313-8313-131313131313"),
            (429, "14141414-1414-4414-8414-141414141414"),
        ]
        for (status, logicalID) in cases {
            FixtureURLProtocol.install([
                createURL: [
                    .init(error: .timedOut),
                    .init(
                        status: status,
                        data: Data(#"{"error":{"code":"current_account_state","message":"Current account cannot submit","retryable":false}}"#.utf8)
                    ),
                ],
            ])
            let testSession = session()
            let client = MireloClient(
                apiKey: "fixture-key",
                baseURL: baseURL,
                session: testSession
            )
            let (executionStore, root) = try store()
            let coordinator = MireloExecutionCoordinator()
            let body = try MireloRequestBuilder.textToSFX(
                model: "sfx-1.6",
                prompt: "One durable request",
                durationMS: 5_000,
                numVariants: 1,
                loop: false,
                outputFormat: "wav"
            )
            let prepared = try await coordinator.prepare(
                store: executionStore,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                operation: .textToSFX,
                requestBody: body,
                sources: [],
                preflight: affordablePreflight()
            )
            _ = try await coordinator.approve(
                store: executionStore,
                record: prepared,
                spendTransactionID: "reserved-\(status)"
            )

            for _ in 0..<2 {
                await #expect(throws: (any Error).self) {
                    _ = try await coordinator.execute(
                        store: executionStore,
                        projectKey: "project-fixture",
                        logicalJobID: logicalID,
                        client: client
                    )
                }
            }
            let record = try #require(executionStore.load(
                projectKey: "project-fixture",
                logicalJobID: logicalID
            ))
            #expect(record.state == .acceptanceUnknown)
            #expect(record.providerJobID == nil)
            #expect(record.spendTransactionID == "reserved-\(status)")
            let creates = FixtureURLProtocol.requests().filter { $0.url == createURL }
            #expect(creates.count == 2)
            #expect(creates[0].idempotencyKey == creates[1].idempotencyKey)
            testSession.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("acceptance is observable before a gated terminal poll")
    @MainActor
    func acceptanceCallbackPrecedesPolling() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-accepted")
        let pollGate = FixtureGate()
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-accepted","status":"queued"}"#.utf8)
            )],
            pollURL: [.init(data: try fixture("v3-succeeded"), gate: pollGate)],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (executionStore, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "15151515-1515-4515-8515-151515151515"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
            numVariants: 1, loop: false, outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: executionStore, projectKey: "project-fixture",
            logicalJobID: logicalID, operation: .textToSFX,
            requestBody: body, sources: [], preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: executionStore, record: prepared, spendTransactionID: "spend-fixture"
        )
        let probe = AcceptanceProbe()
        let execution = Task {
            try await coordinator.execute(
                store: executionStore,
                projectKey: "project-fixture",
                logicalJobID: logicalID,
                client: client,
                onAccepted: { record in await probe.record(record) }
            )
        }
        await pollGate.waitUntilStarted()
        let accepted = await probe.snapshot()
        #expect(accepted.count == 1)
        #expect(accepted.first?.providerJobID == "job-accepted")
        #expect(try executionStore.load(
            projectKey: "project-fixture",
            logicalJobID: logicalID
        )?.state == .accepted)
        execution.cancel()
        do {
            _ = try await execution.value
            Issue.record("Expected the only waiter to cancel")
        } catch {
            #expect(error is CancellationError)
        }
        await pollGate.open()
        _ = try await waitForState(
            .pollingInterrupted,
            store: executionStore,
            projectKey: "project-fixture",
            logicalID: logicalID
        )
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

    @Test("canceling one coalesced waiter leaves the other waiter running")
    func oneCanceledWaiterDoesNotCancelSharedJob() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        let pollGate = FixtureGate()
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)
            )],
            pollURL: [.init(data: try fixture("v3-succeeded"), gate: pollGate)],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (executionStore, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "16161616-1616-4616-8616-161616161616"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
            numVariants: 1, loop: false, outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: executionStore, projectKey: "project-fixture",
            logicalJobID: logicalID, operation: .textToSFX,
            requestBody: body, sources: [], preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: executionStore, record: prepared, spendTransactionID: "spend-fixture"
        )
        let first = Task {
            try await coordinator.execute(
                store: executionStore, projectKey: "project-fixture",
                logicalJobID: logicalID, client: client
            )
        }
        await pollGate.waitUntilStarted()
        let second = Task {
            try await coordinator.execute(
                store: executionStore, projectKey: "project-fixture",
                logicalJobID: logicalID, client: client
            )
        }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Expected the first waiter to cancel")
        } catch {
            #expect(error is CancellationError)
        }
        await pollGate.open()
        let outcome = try await second.value

        #expect(outcome.record.state == .providerSucceeded)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 1)
    }

    @Test("canceling the final polling waiter persists an interrupted job that resumes")
    func finalCanceledWaiterResumesWithoutCreate() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        let pollGate = FixtureGate()
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)
            )],
            pollURL: [
                .init(data: try fixture("v3-succeeded"), gate: pollGate),
                .init(data: try fixture("v3-succeeded")),
            ],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (executionStore, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "17171717-1717-4717-8717-171717171717"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
            numVariants: 1, loop: false, outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: executionStore, projectKey: "project-fixture",
            logicalJobID: logicalID, operation: .textToSFX,
            requestBody: body, sources: [], preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: executionStore, record: prepared, spendTransactionID: "spend-fixture"
        )
        let execution = Task {
            try await coordinator.execute(
                store: executionStore, projectKey: "project-fixture",
                logicalJobID: logicalID, client: client
            )
        }
        await pollGate.waitUntilStarted()
        execution.cancel()
        do {
            _ = try await execution.value
            Issue.record("Expected the final waiter to cancel")
        } catch {
            #expect(error is CancellationError)
        }
        await pollGate.open()
        let interrupted = try await waitForState(
            .pollingInterrupted,
            store: executionStore,
            projectKey: "project-fixture",
            logicalID: logicalID
        )
        #expect(interrupted.state == .pollingInterrupted)
        #expect(interrupted.providerJobID == "job-v3")

        let resumed = try await coordinator.execute(
            store: executionStore, projectKey: "project-fixture",
            logicalJobID: logicalID, client: client
        )
        #expect(resumed.record.state == .providerSucceeded)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 2)
    }

    @Test("cancellation before coordinator entry sends no paid request")
    func cancelBeforeSubmissionSendsNothing() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)
            )],
        ])
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let (executionStore, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = MireloExecutionCoordinator()
        let logicalID = "18181818-1818-4818-8818-181818181818"
        let body = try MireloRequestBuilder.textToSFX(
            model: "sfx-1.6", prompt: "One request", durationMS: 5_000,
            numVariants: 1, loop: false, outputFormat: "wav"
        )
        let prepared = try await coordinator.prepare(
            store: executionStore, projectKey: "project-fixture",
            logicalJobID: logicalID, operation: .textToSFX,
            requestBody: body, sources: [], preflight: affordablePreflight()
        )
        _ = try await coordinator.approve(
            store: executionStore, record: prepared, spendTransactionID: "spend-fixture"
        )
        let startGate = FixtureGate()
        let execution = Task {
            await startGate.wait()
            return try await coordinator.execute(
                store: executionStore, projectKey: "project-fixture",
                logicalJobID: logicalID, client: client
            )
        }
        await startGate.waitUntilStarted()
        execution.cancel()
        await startGate.open()
        do {
            _ = try await execution.value
            Issue.record("Expected cancellation before submission")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(FixtureURLProtocol.requests().isEmpty)
        #expect(try executionStore.load(
            projectKey: "project-fixture", logicalJobID: logicalID
        )?.state == .prepared)
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

    @Test("approved native job requotes before its first provider submission")
    @MainActor
    func preparedNativeResumeRequiresFreshQuote() async throws {
        let preflightURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/preflight")
        let accountURL = baseURL.appendingPathComponent("v3/me")
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
            accountURL: [.init(data: try fixture("account"))],
        ])
        let context = try await nativeContext(
            logicalID: "19191919-1919-4919-8919-191919191919",
            preflight: affordablePreflight(credits: 40)
        )
        defer {
            context.editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: context.workingCopyKey)
            try? FileManager.default.removeItem(at: context.project)
            try? FileManager.default.removeItem(at: context.storeRoot)
        }
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let service = GenerationService()
        var reviewedChange: (Int, Int)?

        await #expect(throws: (any Error).self) {
            try await service.performNativeMireloResume(
                asset: context.asset,
                editor: context.editor,
                store: context.store,
                client: client,
                approveCreditChange: { previous, current in
                    reviewedChange = (previous, current)
                    return false
                }
            )
        }
        #expect(reviewedChange?.0 == 40)
        #expect(reviewedChange?.1 == 50)
        #expect(FixtureURLProtocol.requests().contains { $0.url == preflightURL })
        #expect(FixtureURLProtocol.requests().contains { $0.url == accountURL })
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
        let saved = try #require(context.store.load(
            projectKey: context.projectKey,
            logicalJobID: context.logicalID
        ))
        #expect(saved.state == .prepared)
        #expect(saved.preflight.credits == 40)
    }

    @Test("native SFX restoration resumes one accepted job and installs after URL expiry")
    @MainActor
    func nativeSFXRestoresAndResumesWithoutSecondCreate() async throws {
        let preflightURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/preflight")
        let accountURL = baseURL.appendingPathComponent("v3/me")
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/job-v3")
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
            accountURL: [.init(data: try fixture("account"))],
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"job-v3","status":"queued"}"#.utf8)
            )],
            pollURL: [
                .init(
                    status: 503,
                    data: Data(#"{"error":{"code":"temporarily_unavailable","message":"Retry later","retryable":false}}"#.utf8)
                ),
                .init(data: try fixture("v3-succeeded")),
                .init(data: try fixture("v3-succeeded")),
            ],
        ])
        let context = try await nativeContext(
            logicalID: "20202020-2020-4020-8020-202020202020",
            preflight: affordablePreflight()
        )
        defer {
            context.editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: context.workingCopyKey)
            try? FileManager.default.removeItem(at: context.project)
            try? FileManager.default.removeItem(at: context.storeRoot)
        }
        let testSession = session()
        defer { testSession.invalidateAndCancel() }
        let client = MireloClient(apiKey: "fixture-key", baseURL: baseURL, session: testSession)
        let service = GenerationService()

        await #expect(throws: (any Error).self) {
            try await service.performNativeMireloResume(
                asset: context.asset,
                editor: context.editor,
                store: context.store,
                client: client,
                approveCreditChange: { _, _ in
                    Issue.record("The unchanged fresh quote must not ask again")
                    return false
                }
            )
        }
        let interrupted = try #require(context.store.load(
            projectKey: context.projectKey,
            logicalJobID: context.logicalID
        ))
        #expect(interrupted.state == .pollingInterrupted)
        #expect(interrupted.providerJobID == "job-v3")
        #expect(context.editor.generationLog.spendEvents.filter {
            $0.transactionId == context.logicalID && $0.kind == .submitted
        }.count == 1)

        let manifestBytes = try JSONEncoder().encode(context.editor.mediaManifest)
        try manifestBytes.write(
            to: context.workingRoot.appendingPathComponent(Project.manifestFilename),
            options: .atomic
        )
        let restoredManifest = try JSONDecoder().decode(
            MediaManifest.self,
            from: Data(contentsOf: context.workingRoot.appendingPathComponent(Project.manifestFilename))
        )
        let restoredLog = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: context.workingRoot.appendingPathComponent(Project.generationLogFilename))
        )
        let restoredEntry = try #require(restoredManifest.entries.first(where: {
            $0.id == context.asset.id
        }))
        let restoredAsset = MediaAsset(entry: restoredEntry, resolvedURL: context.asset.url)
        context.editor.mediaManifest = restoredManifest
        context.editor.generationLog = restoredLog
        context.editor.mediaAssets = [restoredAsset]
        #expect(!FileManager.default.fileExists(atPath: restoredAsset.url.path))
        service.restoreMireloRecoveryState(
            asset: restoredAsset,
            editor: context.editor,
            store: context.store
        )
        #expect(restoredAsset.mireloResumeAvailable)
        guard case .failed = restoredAsset.generationStatus else {
            Issue.record("Expected the restored placeholder to expose resume")
            return
        }

        await #expect(throws: (any Error).self) {
            try await service.performNativeMireloResume(
                asset: restoredAsset,
                editor: context.editor,
                store: context.store,
                client: client,
                approveCreditChange: { _, _ in false },
                download: { _ in
                    throw RemoteMediaPolicy.PolicyError.httpStatus(403)
                }
            )
        }
        let succeeded = try #require(context.store.load(
            projectKey: context.projectKey,
            logicalJobID: context.logicalID
        ))
        #expect(succeeded.state == .providerSucceeded)
        service.restoreMireloRecoveryState(
            asset: restoredAsset,
            editor: context.editor,
            store: context.store
        )
        #expect(restoredAsset.mireloResumeAvailable)

        let wav = wavFixture()
        try await service.performNativeMireloResume(
            asset: restoredAsset,
            editor: context.editor,
            store: context.store,
            client: client,
            approveCreditChange: { _, _ in false },
            download: { _ in
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("native-mirelo-\(UUID().uuidString).wav")
                try wav.write(to: file, options: .atomic)
                return file
            }
        )

        let completed = try #require(context.store.load(
            projectKey: context.projectKey,
            logicalJobID: context.logicalID
        ))
        #expect(completed.state == .completed)
        #expect(completed.providerJobID == "job-v3")
        #expect(FileManager.default.fileExists(atPath: restoredAsset.url.path))
        #expect(!restoredAsset.mireloResumeAvailable)
        #expect(context.editor.mediaManifest.entries.filter {
            $0.id == restoredAsset.id
        }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == pollURL }.count == 3)
        let events = context.editor.generationLog.spendEvents.filter {
            $0.transactionId == context.logicalID
        }
        #expect(events.filter { $0.kind == .reserved }.count == 1)
        #expect(events.filter { $0.kind == .submitted }.count == 1)
        #expect(Set(events.map(\.transactionId)) == Set([context.logicalID]))
    }

    @Test("project open restores missing native placeholder after ledger reconciliation")
    @MainActor
    func projectOpenRestoresMissingNativePlaceholder() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-open-native-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let projectKey = try #require(ProjectIdentity.existingUUID(for: package))
        let logicalID = "21212121-2121-4121-8121-212121212121"
        let (executionStore, storeRoot) = try store()
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: logicalID,
            spendTransactionID: logicalID,
            state: .accepted,
            providerJobID: "open-native-job"
        )
        var input = GenerationInput(
            prompt: "A dry camera shutter",
            model: "mirelo/sfx-1.6",
            duration: 5,
            aspectRatio: ""
        )
        input.spendTransactionId = logicalID
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: "missing-native",
            name: "Missing Native SFX",
            type: .audio,
            source: .project(relativePath: "media/missing-native.wav"),
            duration: 5,
            generationInput: input,
            mireloExecutionTransactionId: logicalID
        )]
        var log = GenerationLog()
        log.spendEvents = [GenerationSpendEvent(
            transactionId: logicalID,
            kind: .reserved,
            model: input.model,
            provider: .mirelo,
            transport: .api,
            endpoint: "sfx-1.6"
        )]
        try writeProjectState(package: package, manifest: manifest, log: log)
        var workingCopyKey: String?
        defer {
            if let workingCopyKey { ProjectWorkingCopy.discard(key: workingCopyKey) }
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let document = try await openProject(at: package) { executionStore }
        workingCopyKey = document.editorViewModel.openWorkingCopyKey
        let restored = try #require(document.editorViewModel.mediaAssets.first)
        #expect(restored.mireloResumeAvailable)
        #expect(document.editorViewModel.generationService.isMireloResumeActionAvailable(
            for: restored
        ))
        guard case .failed(let message) = restored.generationStatus else {
            Issue.record("Expected project open to expose the saved Mirelo resume path")
            return
        }
        #expect(message.contains("accepted"))
        let submitted = document.editorViewModel.generationLog.spendEvents.filter {
            $0.transactionId == logicalID && $0.kind == .submitted
        }
        #expect(submitted.count == 1)
        #expect(submitted.first?.providerRequestId == "open-native-job")
        _ = releaseProject(document)
    }

    @Test("rejected native reservation detaches atomically and remains rejected after reopen")
    @MainActor
    func rejectedNativeReleaseSurvivesReopen() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-rejected-native-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let projectKey = try #require(ProjectIdentity.existingUUID(for: package))
        let logicalID = "22222222-2222-4222-8222-222222222222"
        let rejection = "Mirelo rejected the exact request before creating a job."
        let (executionStore, storeRoot) = try store()
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: logicalID,
            spendTransactionID: logicalID,
            state: .failed,
            lastError: rejection
        )
        var input = GenerationInput(
            prompt: "A dry camera shutter",
            model: "mirelo/sfx-1.6",
            duration: 5,
            aspectRatio: ""
        )
        input.spendTransactionId = logicalID
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: "rejected-native",
            name: "Rejected Native SFX",
            type: .audio,
            source: .project(relativePath: "media/rejected-native.wav"),
            duration: 5,
            generationInput: input,
            mireloExecutionTransactionId: logicalID
        )]
        var log = GenerationLog()
        log.entries = [GenerationLogEntry(
            model: input.model,
            costCredits: 50,
            createdAt: Date(),
            spendTransactionId: logicalID
        )]
        log.spendEvents = [GenerationSpendEvent(
            transactionId: logicalID,
            kind: .reserved,
            model: input.model,
            provider: .mirelo,
            transport: .api,
            endpoint: "sfx-1.6"
        )]
        try writeProjectState(package: package, manifest: manifest, log: log)
        var workingCopyKey: String?
        defer {
            if let workingCopyKey { ProjectWorkingCopy.discard(key: workingCopyKey) }
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let firstDocument = try await openProject(at: package) { executionStore }
        workingCopyKey = firstDocument.editorViewModel.openWorkingCopyKey
        let firstAsset = try #require(firstDocument.editorViewModel.mediaAssets.first)
        guard case .failed(let firstMessage) = firstAsset.generationStatus else {
            Issue.record("Expected the provider rejection to remain visible")
            return
        }
        #expect(firstMessage == rejection)
        #expect(firstAsset.generationInput?.spendTransactionId == nil)
        #expect(firstAsset.mireloExecutionTransactionId == logicalID)
        #expect(firstDocument.editorViewModel.generationLog.entries.allSatisfy {
            $0.spendTransactionId != logicalID
        })
        #expect(firstDocument.editorViewModel.generationLog.spendEvents.filter {
            $0.transactionId == logicalID && $0.kind == .released
        }.count == 1)
        let releasedSpend = try GenerationBudgetGuard.spendSnapshot(
            log: firstDocument.editorViewModel.generationLog,
            generatedInputs: firstDocument.editorViewModel.mediaAssets.compactMap(\.generationInput)
        )
        #expect(releasedSpend.activeReservationCount == 0)
        #expect(releasedSpend.legacyGenerationCount == 0)
        let workingRoot = try #require(firstDocument.editorViewModel.workingRoot)
        let persistedManifest = try JSONDecoder().decode(
            MediaManifest.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(Project.manifestFilename))
        )
        let persistedLog = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(Project.generationLogFilename))
        )
        #expect(persistedManifest.entries.first?.generationInput?.spendTransactionId == nil)
        #expect(persistedManifest.entries.first?.mireloExecutionTransactionId == logicalID)
        #expect(persistedLog.spendEvents.last?.kind == .released)
        _ = releaseProject(firstDocument)

        let secondDocument = try await openProject(at: package) { executionStore }
        let reopened = try #require(secondDocument.editorViewModel.mediaAssets.first)
        guard case .failed(let reopenedMessage) = reopened.generationStatus else {
            Issue.record("Expected the rejection after reopening the recovery copy")
            return
        }
        #expect(reopenedMessage == rejection)
        #expect(!reopenedMessage.contains("could not be reconciled"))
        #expect(secondDocument.editorViewModel.generationLog.spendEvents.filter {
            $0.transactionId == logicalID && $0.kind == .released
        }.count == 1)
        _ = releaseProject(secondDocument)
    }

    @Test("project open reconciles accepted agent job without a media placeholder")
    @MainActor
    func projectOpenReconcilesAcceptedAgentJob() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-open-agent-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let projectKey = try #require(ProjectIdentity.existingUUID(for: package))
        let logicalID = "23232323-2323-4323-8323-232323232323"
        let transactionID = "24242424-2424-4424-8424-242424242424"
        let (executionStore, storeRoot) = try store()
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: logicalID,
            spendTransactionID: transactionID,
            state: .accepted,
            providerJobID: "agent-job-without-placeholder"
        )
        var log = GenerationLog()
        log.spendEvents = [GenerationSpendEvent(
            transactionId: transactionID,
            kind: .reserved,
            model: "mirelo/sfx-1.6",
            provider: .mirelo,
            transport: .api,
            endpoint: MireloOperation.textToSFX.createPath
        )]
        try writeProjectState(package: package, manifest: MediaManifest(), log: log)
        var workingCopyKey: String?
        defer {
            if let workingCopyKey { ProjectWorkingCopy.discard(key: workingCopyKey) }
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let document = try await openProject(at: package) { executionStore }
        workingCopyKey = document.editorViewModel.openWorkingCopyKey
        #expect(document.editorViewModel.mediaAssets.isEmpty)
        let submitted = document.editorViewModel.generationLog.spendEvents.filter {
            $0.transactionId == transactionID && $0.kind == .submitted
        }
        #expect(submitted.count == 1)
        #expect(submitted.first?.providerRequestId == "agent-job-without-placeholder")
        _ = releaseProject(document)
    }

    @Test("budget guard identifies and repairs an accepted Mirelo reservation")
    @MainActor
    func budgetGuardClassifiesAcceptedReservationAsRepairable() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-repairable-submission-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let projectKey = try #require(editor.projectId)
        let transactionID = "25252525-2525-4525-8525-252525252525"
        let conflictID = "26262626-2626-4626-8626-262626262626"
        let (executionStore, storeRoot) = try store()
        defer {
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: transactionID,
            spendTransactionID: transactionID,
            state: .accepted,
            providerJobID: "repairable-job"
        )
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: conflictID,
            spendTransactionID: conflictID,
            state: .accepted,
            providerJobID: "authority-conflict-job"
        )
        editor.generationLog.spendEvents = [
            GenerationSpendEvent(
                transactionId: transactionID,
                kind: .reserved,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath
            ),
            GenerationSpendEvent(
                transactionId: conflictID,
                kind: .reserved,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath
            ),
            GenerationSpendEvent(
                transactionId: conflictID,
                kind: .submitted,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath,
                providerRequestId: "ledger-conflict-job"
            ),
        ]
        try editor.persistGenerationLog()
        editor.generationService.mireloStoreProvider = { executionStore }

        do {
            _ = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
                modelId: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath,
                editor: editor
            )
            Issue.record("Expected the budget guard to stop for missing submitted spend")
        } catch {
            #expect(error.localizedDescription.contains("Reopen the project to retry repair"))
            #expect(error.localizedDescription.contains("budget remains stopped"))
            #expect(error.localizedDescription.contains("cannot safely repair"))
        }

        try editor.generationService.reconcileMireloAcceptedSpend(
            editor: editor,
            store: executionStore,
            onlyTransactionID: transactionID
        )
        #expect(editor.generationLog.spendEvents.filter {
            $0.transactionId == transactionID
        }.map(\.kind) == [.reserved, .submitted])
        #expect(editor.generationLog.spendEvents.first {
            $0.transactionId == transactionID && $0.kind == .submitted
        }?.providerRequestId == "repairable-job")
        #expect(editor.generationLog.spendEvents.filter {
            $0.transactionId == conflictID && $0.kind == .submitted
        }.map(\.providerRequestId) == ["ledger-conflict-job"])
        #expect(editor.mireloSpendRecoveryMessage?.contains("cannot safely repair") == true)
        #expect(editor.mireloSpendRecoveryMessage?.contains("retry repair") == false)
    }

    @Test("project open reconciles valid authority beside orphan and conflict")
    @MainActor
    func projectOpenClassifiesOrphanWithoutBlockingValidReconciliation() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-open-orphan-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let projectKey = try #require(ProjectIdentity.existingUUID(for: package))
        let validTransactionID = "26262626-2626-4626-8626-262626262626"
        let orphanTransactionID = "27272727-2727-4727-8727-272727272727"
        let conflictingTransactionID = "34343434-3434-4434-8434-343434343434"
        let unknownTransactionID = "36363636-3636-4636-8636-363636363636"
        let (executionStore, storeRoot) = try store()
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: "28282828-2828-4828-8828-282828282828",
            spendTransactionID: validTransactionID,
            state: .accepted,
            providerJobID: "valid-open-job"
        )
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: "29292929-2929-4929-8929-292929292929",
            spendTransactionID: orphanTransactionID,
            state: .accepted,
            providerJobID: "orphan-open-job"
        )
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: "35353535-3535-4535-8535-353535353535",
            spendTransactionID: conflictingTransactionID,
            state: .accepted,
            providerJobID: "authority-conflict-job"
        )
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: "37373737-3737-4737-8737-373737373737",
            spendTransactionID: unknownTransactionID,
            state: .acceptanceUnknown,
            lastError: "Provider acceptance is unknown."
        )
        var log = GenerationLog()
        log.spendEvents = [
            GenerationSpendEvent(
                transactionId: validTransactionID,
                kind: .reserved,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath
            ),
            GenerationSpendEvent(
                transactionId: conflictingTransactionID,
                kind: .reserved,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath
            ),
            GenerationSpendEvent(
                transactionId: conflictingTransactionID,
                kind: .submitted,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath,
                providerRequestId: "ledger-conflict-job"
            ),
            GenerationSpendEvent(
                transactionId: unknownTransactionID,
                kind: .reserved,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath
            ),
        ]
        try writeProjectState(package: package, manifest: MediaManifest(), log: log)
        var workingCopyKey: String?
        defer {
            if let workingCopyKey { ProjectWorkingCopy.discard(key: workingCopyKey) }
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let document = try await openProject(at: package) { executionStore }
        workingCopyKey = document.editorViewModel.openWorkingCopyKey
        let editor = document.editorViewModel
        #expect(editor.generationLog.spendEvents.contains {
            $0.transactionId == validTransactionID
                && $0.kind == .submitted
                && $0.providerRequestId == "valid-open-job"
        })
        #expect(editor.generationLog.spendEvents.allSatisfy {
            $0.transactionId != orphanTransactionID
        })
        #expect(editor.generationLog.spendEvents.filter {
            $0.transactionId == conflictingTransactionID
                && $0.kind == .submitted
        }.map(\.providerRequestId) == ["ledger-conflict-job"])
        #expect(editor.generationLog.spendEvents.filter {
            $0.transactionId == unknownTransactionID
        }.map(\.kind) == [.reserved])
        #expect(editor.mireloSpendRecoveryMessage?.contains("unresolved acceptance") == true)
        #expect(editor.mireloSpendRecoveryMessage?.contains("cannot safely repair") == true)
        #expect(editor.mireloSpendRecoveryMessage?.contains("originating project") == true)
        let eventCount = editor.generationLog.spendEvents.count
        #expect(throws: GenerationBudgetError.self) {
            _ = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
                modelId: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath,
                editor: editor
            )
        }
        #expect(editor.generationLog.spendEvents.count == eventCount)
        _ = releaseProject(document)
    }

    @Test("duplicated package with empty ledger reports orphan without copying spend")
    @MainActor
    func duplicatedPackageEmptyLedgerKeepsAuthorityOutOfProject() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-duplicate-source-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        let duplicate = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-duplicate-copy-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: original)
        try FileManager.default.copyItem(at: original, to: duplicate)
        let projectKey = try #require(ProjectIdentity.existingUUID(for: duplicate))
        let orphanTransactionID = "30303030-3030-4030-8030-303030303030"
        let (executionStore, storeRoot) = try store()
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: "31313131-3131-4131-8131-313131313131",
            spendTransactionID: orphanTransactionID,
            state: .accepted,
            providerJobID: "duplicate-copy-job"
        )
        var workingCopyKey: String?
        defer {
            if let workingCopyKey { ProjectWorkingCopy.discard(key: workingCopyKey) }
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: duplicate)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let document = try await openProject(at: duplicate) { executionStore }
        workingCopyKey = document.editorViewModel.openWorkingCopyKey
        #expect(document.editorViewModel.generationLog.spendEvents.isEmpty)
        #expect(document.editorViewModel.mireloSpendRecoveryMessage != nil)
        #expect(document.editorViewModel.mediaPanelToast?.message.contains(
            "no safe in-app recovery exists"
        ) == true)
        _ = releaseProject(document)
    }

    @Test("discard completion fails when no document reload binding exists")
    @MainActor
    func discardWithoutReloadBindingDoesNotHang() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-discard-unbound-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        defer {
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
        }

        do {
            try await discardAndAwaitReload(editor)
            Issue.record("Expected discard to fail without a document reload binding")
        } catch {
            #expect(error.localizedDescription.contains("cannot reload"))
        }
    }

    @Test("discard recovery reload classifies accepted authority missing from saved ledger")
    @MainActor
    func discardRecoveryReloadDoesNotBackcopyAuthoritySpend() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-discard-recovery-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let projectKey = try #require(ProjectIdentity.existingUUID(for: package))
        let workingCopyKey = try #require(ProjectIdentity.existingKey(for: package))
        let recovery = try ProjectWorkingCopy.open(
            key: workingCopyKey,
            packageURL: package
        )
        let transactionID = "32323232-3232-4232-8232-323232323232"
        var recoveryLog = GenerationLog()
        recoveryLog.spendEvents = [GenerationSpendEvent(
            transactionId: transactionID,
            kind: .reserved,
            model: "mirelo/sfx-1.6",
            provider: .mirelo,
            transport: .api,
            endpoint: MireloOperation.textToSFX.createPath
        )]
        try JSONEncoder().encode(recoveryLog).write(
            to: recovery.home.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        try ProjectWorkingCopy.markDirty(key: workingCopyKey)
        let (executionStore, storeRoot) = try store()
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: "33333333-3333-4333-8333-333333333333",
            spendTransactionID: transactionID,
            state: .accepted,
            providerJobID: "discarded-recovery-job"
        )
        defer {
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let document = try await openProject(at: package) { executionStore }
        #expect(document.editorViewModel.recoveredUnsavedWork)
        #expect(document.editorViewModel.generationLog.spendEvents.contains {
            $0.kind == .submitted && $0.providerRequestId == "discarded-recovery-job"
        })
        try await discardAndAwaitReload(document.editorViewModel)
        #expect(document.editorViewModel.generationLog.spendEvents.isEmpty)
        #expect(document.editorViewModel.mireloSpendRecoveryMessage != nil)
        _ = releaseProject(document)
    }

    @Test("non-Mirelo asset remains unrelated when the authority audit is unavailable")
    @MainActor
    func nonMireloAssetIgnoresMireloStoreFailure() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "non-mirelo-open-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let media = package.appendingPathComponent("media/non-mirelo.wav")
        try FileManager.default.createDirectory(
            at: media.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wavFixture().write(to: media)
        let transactionID = UUID().uuidString
        var input = GenerationInput(
            prompt: "A non-Mirelo sound",
            model: "fal-ai/stable-audio-25/text-to-audio",
            duration: 5,
            aspectRatio: ""
        )
        input.spendTransactionId = transactionID
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(
            id: "non-mirelo",
            name: "Non-Mirelo",
            type: .audio,
            source: .project(relativePath: "media/non-mirelo.wav"),
            duration: 5,
            generationInput: input
        )]
        var log = GenerationLog()
        log.spendEvents = [GenerationSpendEvent(
            transactionId: transactionID,
            kind: .reserved,
            model: input.model,
            provider: .fal,
            transport: .api,
            endpoint: "stable-audio"
        )]
        try writeProjectState(package: package, manifest: manifest, log: log)
        var storeOpenCount = 0
        var workingCopyKey: String?
        defer {
            if let workingCopyKey { ProjectWorkingCopy.discard(key: workingCopyKey) }
            try? FileManager.default.removeItem(at: package)
        }

        let document = try await openProject(at: package) {
            storeOpenCount += 1
            throw CocoaError(.fileReadCorruptFile)
        }
        workingCopyKey = document.editorViewModel.openWorkingCopyKey
        let restored = try #require(document.editorViewModel.mediaAssets.first)
        #expect(storeOpenCount == 1)
        #expect(document.editorViewModel.mireloSpendRecoveryMessage == nil)
        #expect(restored.generationStatus == .none)
        #expect(!restored.mireloResumeAvailable)
        #expect(restored.mireloExecutionTransactionId == nil)
        _ = releaseProject(document)
    }

    @Test("active native job hides the UI resume consumer")
    @MainActor
    func activeNativeJobGuardsResumeConsumer() {
        let editor = EditorViewModel()
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/active-mirelo.wav"),
            type: .audio,
            name: "Active Mirelo"
        )
        asset.mireloResumeAvailable = true
        asset.generationStatus = .generating
        editor.mediaAssets = [asset]
        var storeOpenCount = 0
        editor.generationService.mireloStoreProvider = {
            storeOpenCount += 1
            throw CocoaError(.fileReadCorruptFile)
        }

        #expect(!editor.generationService.isMireloResumeActionAvailable(for: asset))
        editor.generationService.resumeMireloGeneration(asset: asset, editor: editor)
        #expect(storeOpenCount == 0)
        #expect(asset.generationStatus == .generating)
        asset.generationStatus = .failed("Polling stopped")
        #expect(editor.generationService.isMireloResumeActionAvailable(for: asset))
    }

    @Test("cancelled native consumer waits for authority settlement before exposing resume")
    @MainActor
    func nativeCancellationReconcilesSettledState() async throws {
        let preflightURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/preflight")
        let accountURL = baseURL.appendingPathComponent("v3/me")
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let createGate = FixtureGate()
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
            accountURL: [.init(data: try fixture("account"))],
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"cancelled-native-job","status":"queued"}"#.utf8),
                gate: createGate
            )],
        ])
        let context = try await nativeContext(
            logicalID: "25252525-2525-4525-8525-252525252525",
            preflight: affordablePreflight()
        )
        defer {
            context.editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: context.workingCopyKey)
            try? FileManager.default.removeItem(at: context.project)
            try? FileManager.default.removeItem(at: context.storeRoot)
        }
        let fixtureSession = session()
        defer { fixtureSession.invalidateAndCancel() }
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: fixtureSession
        )
        let service = context.editor.generationService
        service.mireloStoreProvider = { context.store }
        service.mireloAPIKeyProvider = { "fixture-key" }
        service.mireloClientProvider = { _ in client }
        context.asset.mireloResumeAvailable = true
        context.asset.generationStatus = .failed("Resume")

        service.resumeMireloGeneration(asset: context.asset, editor: context.editor)
        await createGate.waitUntilStarted()
        #expect(service.cancelGeneration(placeholderId: context.asset.id))
        #expect(!service.isMireloResumeActionAvailable(for: context.asset))
        #expect(context.asset.isGenerating)
        await createGate.open()
        await service.waitForGeneration(placeholderId: context.asset.id)

        let settled = try #require(context.store.load(
            projectKey: context.projectKey,
            logicalJobID: context.logicalID
        ))
        #expect(settled.state != .prepared)
        #expect(settled.state != .submitting)
        #expect(context.asset.mireloResumeAvailable)
        #expect(service.isMireloResumeActionAvailable(for: context.asset))
        guard case .failed = context.asset.generationStatus else {
            Issue.record("Expected a settled recovery message after cancellation")
            return
        }
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
    }

    @Test("cancel reconciliation ignores a second live Mirelo flight")
    @MainActor
    func cancelledJobDoesNotClassifyParallelFlightAsRecovery() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-parallel-cancel-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let projectKey = try #require(editor.projectId)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        let executeGate = FixtureGate()
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let createGate = FixtureGate()
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
            createURL: [.init(
                error: .networkConnectionLost,
                gate: createGate
            )],
        ])
        let parallelID = "42424242-4242-4242-8242-424242424242"
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.generationService.mireloBeforeFirstExecute = nil
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        _ = try await authorityRecord(
            store: executionStore,
            projectKey: projectKey,
            logicalID: parallelID,
            spendTransactionID: parallelID,
            state: .prepared
        )
        editor.generationLog.spendEvents.append(GenerationSpendEvent(
            transactionId: parallelID,
            kind: .reserved,
            model: "mirelo/sfx-1.6",
            provider: .mirelo,
            transport: .api,
            endpoint: MireloOperation.textToSFX.createPath
        ))
        try editor.persistGenerationLog()
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: fixtureSession
        )
        editor.generationService.mireloStoreProvider = { executionStore }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in client }
        editor.generationService.mireloBeforeFirstExecute = {
            await executeGate.wait()
        }
        let active = Task {
            try await MireloExecutionCoordinator.shared.execute(
                store: executionStore,
                projectKey: projectKey,
                logicalJobID: parallelID,
                client: client
            )
        }
        await createGate.waitUntilStarted()
        let submission = await GenerationController.submit(
            try firstRunRequest(),
            editor: editor,
            quoteLoader: { _, _ in testMoney() }
        )
        let outcome = try submission.get()
        let cancelledTransactionID = try #require(editor.mediaAssets.first {
            $0.id == outcome.placeholderId
        }?.generationInput?.spendTransactionId)
        await executeGate.waitUntilStarted()
        #expect(editor.generationService.cancelGeneration(
            placeholderId: outcome.placeholderId
        ))
        await executeGate.open()
        await editor.generationService.waitForGeneration(
            placeholderId: outcome.placeholderId
        )

        #expect(editor.mireloSpendRecoveryMessage == nil)
        #expect(editor.generationLog.spendEvents.filter {
            $0.transactionId == cancelledTransactionID
        }.map(\.kind) == [.reserved, .released])
        active.cancel()
        await createGate.open()
        _ = await active.result
        _ = try await MireloExecutionCoordinator.shared.awaitSettlement(
            store: executionStore,
            projectKey: projectKey,
            logicalJobID: parallelID
        )
        try editor.generationService.refreshMireloSpendRecovery(
            editor: editor,
            store: executionStore
        )
        #expect(editor.mireloSpendRecoveryMessage?.contains(
            "unresolved acceptance"
        ) == true)
    }

    @Test("native resume clears only its unknown acceptance issue")
    @MainActor
    func unknownResumeKeepsIndependentConflict() async throws {
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let pollURL = baseURL.appendingPathComponent(
            "v3/text-to-sfx/generations/resumed-unknown-job"
        )
        FixtureURLProtocol.install([
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"resumed-unknown-job","status":"queued"}"#.utf8)
            )],
            pollURL: [.init(data: try fixture("v3-succeeded"))],
        ])
        let context = try await nativeContext(
            logicalID: "43434343-4343-4343-8343-434343434343",
            preflight: affordablePreflight()
        )
        let conflictID = "44444444-4444-4444-8444-444444444444"
        defer {
            context.editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: context.workingCopyKey)
            try? FileManager.default.removeItem(at: context.project)
            try? FileManager.default.removeItem(at: context.storeRoot)
        }
        let prepared = try #require(context.store.load(
            projectKey: context.projectKey,
            logicalJobID: context.logicalID
        ))
        let submitting = try context.store.update(prepared) {
            $0.state = .submitting
        }
        _ = try context.store.update(submitting) {
            $0.state = .acceptanceUnknown
            $0.lastError = "Provider acceptance is unknown."
        }
        _ = try await authorityRecord(
            store: context.store,
            projectKey: context.projectKey,
            logicalID: conflictID,
            spendTransactionID: conflictID,
            state: .accepted,
            providerJobID: "authority-conflict-job"
        )
        context.editor.generationLog.spendEvents.append(contentsOf: [
            GenerationSpendEvent(
                transactionId: conflictID,
                kind: .reserved,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath
            ),
            GenerationSpendEvent(
                transactionId: conflictID,
                kind: .submitted,
                model: "mirelo/sfx-1.6",
                provider: .mirelo,
                transport: .api,
                endpoint: MireloOperation.textToSFX.createPath,
                providerRequestId: "ledger-conflict-job"
            ),
        ])
        try context.editor.persistGenerationLog()
        let service = context.editor.generationService
        try service.refreshMireloSpendRecovery(
            editor: context.editor,
            store: context.store
        )
        #expect(context.editor.mireloSpendRecoveryMessage?.contains(
            "unresolved acceptance"
        ) == true)
        #expect(context.editor.mireloSpendRecoveryMessage?.contains(
            "cannot safely repair"
        ) == true)
        let fixtureSession = session()
        defer { fixtureSession.invalidateAndCancel() }
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: fixtureSession
        )
        let wav = wavFixture()
        try await service.performNativeMireloResume(
            asset: context.asset,
            editor: context.editor,
            store: context.store,
            client: client,
            approveCreditChange: { _, _ in false },
            download: { _ in
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("resumed-unknown-\(UUID().uuidString).wav")
                try wav.write(to: file, options: .atomic)
                return file
            }
        )

        #expect(context.editor.generationLog.spendEvents.contains {
            $0.transactionId == context.logicalID
                && $0.kind == .submitted
                && $0.providerRequestId == "resumed-unknown-job"
        })
        #expect(context.editor.mireloSpendRecoveryMessage?.contains(
            "unresolved acceptance"
        ) == false)
        #expect(context.editor.mireloSpendRecoveryMessage?.contains(
            "cannot safely repair"
        ) == true)
    }

    @Test("unsubmitted shared reservation releases persisted and memory-only placeholders atomically")
    @MainActor
    func sharedReservationReleaseHandlesPartiallyPersistedPlaceholders() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-reservation-release-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        defer {
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
        }
        let authorization = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "fal-ai/stable-audio-25/text-to-audio",
            provider: .fal,
            transport: .api,
            endpoint: "stable-audio",
            editor: editor
        )
        let transactionID = try #require(authorization.transactionId)
        let workingRoot = try #require(editor.workingRoot)
        var input = GenerationInput(
            prompt: "A dry camera shutter",
            model: authorization.target.modelId,
            duration: 5,
            aspectRatio: ""
        )
        input.spendTransactionId = transactionID
        let media = try editor.prepareWorkingMediaDirectory()
        let first = MediaAsset(
            id: "shared-first",
            url: media.appendingPathComponent("shared-first.wav"),
            type: .audio,
            name: "Shared First",
            duration: 5,
            generationInput: input
        )
        let second = MediaAsset(
            id: "shared-second",
            url: media.appendingPathComponent("shared-second.wav"),
            type: .audio,
            name: "Shared Second",
            duration: 5,
            generationInput: input
        )
        editor.mediaAssets = [first, second]
        editor.persistMediaAsset(first)

        try wavFixture().write(to: first.url)
        #expect(throws: GenerationRequestError.self) {
            try editor.releaseUnsubmittedSpendReservation(
                authorization: authorization,
                placeholders: [first, second],
                note: "Preparation failed."
            )
        }
        #expect(editor.generationLog.spendEvents.last?.kind == .reserved)
        try FileManager.default.removeItem(at: first.url)

        try editor.releaseUnsubmittedSpendReservation(
            authorization: authorization,
            placeholders: [first, second],
            note: "Preparation failed."
        )

        #expect(first.generationInput == nil)
        #expect(second.generationInput == nil)
        #expect(first.mireloExecutionTransactionId == nil)
        #expect(second.mireloExecutionTransactionId == nil)
        try assertReleasedOnce(editor)
        let persistedManifest = try JSONDecoder().decode(
            MediaManifest.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(
                Project.manifestFilename
            ))
        )
        let persistedLog = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(
                Project.generationLogFilename
            ))
        )
        #expect(persistedManifest.entries.count == 1)
        #expect(persistedManifest.entries.first?.generationInput == nil)
        #expect(persistedManifest.entries.first?.mireloExecutionTransactionId == nil)
        #expect(persistedLog.spendEvents.filter {
            $0.transactionId == transactionID && $0.kind == .released
        }.count == 1)
    }

    @Test("undo restore strips released spend without changing active or charged inputs")
    @MainActor
    func undoRestoreDoesNotReviveReleasedSpend() throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "released-spend-undo-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        defer {
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
        }
        let released = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "fal-ai/stable-audio-25/text-to-audio",
            provider: .fal,
            transport: .api,
            endpoint: "released-fixture",
            editor: editor
        )
        let active = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "fal-ai/stable-audio-25/text-to-audio",
            provider: .fal,
            transport: .api,
            endpoint: "active-fixture",
            editor: editor
        )
        let charged = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "fal-ai/stable-audio-25/text-to-audio",
            provider: .fal,
            transport: .api,
            endpoint: "charged-fixture",
            editor: editor
        )
        try editor.recordSpendEvent(
            authorization: charged,
            kind: .submitted,
            providerRequestId: "charged-job"
        )
        try editor.recordSpendEvent(
            authorization: charged,
            kind: .charged,
            money: testMoney()
        )
        let media = try editor.prepareWorkingMediaDirectory()
        func asset(
            id: String,
            authorization: GenerationAuthorization
        ) throws -> MediaAsset {
            var input = GenerationInput(
                prompt: id,
                model: authorization.target.modelId,
                duration: 5,
                aspectRatio: ""
            )
            input.spendTransactionId = try #require(authorization.transactionId)
            return MediaAsset(
                id: id,
                url: media.appendingPathComponent("\(id).wav"),
                type: .audio,
                name: id,
                duration: 5,
                generationInput: input
            )
        }
        let releasedAsset = try asset(id: "released", authorization: released)
        let activeAsset = try asset(id: "active", authorization: active)
        let chargedAsset = try asset(id: "charged", authorization: charged)
        let detachedReleasedPlaceholder = try asset(
            id: releasedAsset.id,
            authorization: released
        )
        editor.mediaAssets = [releasedAsset, activeAsset, chargedAsset]
        for value in editor.mediaAssets { editor.persistMediaAsset(value) }
        let undoManager = UndoManager()
        editor.undoManager = undoManager

        editor.deleteMediaAssets(ids: [releasedAsset.id])
        try editor.releaseUnsubmittedSpendReservation(
            authorization: released,
            placeholders: [detachedReleasedPlaceholder],
            note: "Preparation failed."
        )
        #expect(releasedAsset.generationInput?.spendTransactionId
            == released.transactionId)
        undoManager.undo()

        #expect(editor.mediaAssets.first {
            $0.id == releasedAsset.id
        }?.generationInput == nil)
        #expect(editor.mediaManifest.entries.first {
            $0.id == releasedAsset.id
        }?.generationInput == nil)
        #expect(editor.mediaAssets.first {
            $0.id == activeAsset.id
        }?.generationInput?.spendTransactionId == active.transactionId)
        #expect(editor.mediaAssets.first {
            $0.id == chargedAsset.id
        }?.generationInput?.spendTransactionId == charged.transactionId)
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: editor.generationLog,
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput)
        )
        #expect(snapshot.activeReservationCount == 1)
        undoManager.redo()
        #expect(!editor.mediaAssets.contains { $0.id == releasedAsset.id })
        undoManager.undo()
        #expect(editor.mediaAssets.first {
            $0.id == releasedAsset.id
        }?.generationInput == nil)
    }

    @Test("first-run definitive create rejection releases its reservation once")
    @MainActor
    func firstRunDefinitiveRejectionReleasesReservation() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-first-reject-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        editor.generationService.mireloStoreProvider = { executionStore }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in
            MireloClient(
                apiKey: "fixture-key",
                baseURL: self.baseURL,
                session: fixtureSession
            )
        }
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        let createURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.createPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
            createURL: [.init(
                status: 400,
                data: Data(#"{"detail":"request rejected"}"#.utf8)
            )],
        ])
        var failureCount = 0
        let submission = await GenerationController.submit(
            try firstRunRequest(),
            editor: editor,
            onFailure: { failureCount += 1 },
            quoteLoader: { _, _ in testMoney() }
        )
        let outcome = try submission.get()
        await editor.generationService.waitForGeneration(
            placeholderId: outcome.placeholderId
        )

        try assertReleasedOnce(editor)
        #expect(failureCount == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)
        let transactionID = try #require(
            editor.generationLog.spendEvents.first?.transactionId
        )
        let record = try #require(executionStore.load(
            projectKey: try #require(editor.projectId),
            logicalJobID: transactionID
        ))
        #expect(record.state == .failed)
        #expect(record.providerJobID == nil)
    }

    @Test("first-run preflight cancellation releases before approval")
    @MainActor
    func firstRunPreflightCancellationReleasesReservation() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-first-preflight-cancel-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        let preflightGate = FixtureGate()
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        editor.generationService.mireloStoreProvider = { executionStore }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in
            MireloClient(
                apiKey: "fixture-key",
                baseURL: self.baseURL,
                session: fixtureSession
            )
        }
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        let createURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.createPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(
                data: try fixture("preflight-v3"),
                gate: preflightGate
            )],
        ])
        var failureCount = 0
        let submission = await GenerationController.submit(
            try firstRunRequest(),
            editor: editor,
            onFailure: { failureCount += 1 },
            quoteLoader: { _, _ in testMoney() }
        )
        let outcome = try submission.get()
        await preflightGate.waitUntilStarted()
        #expect(editor.generationService.cancelGeneration(
            placeholderId: outcome.placeholderId
        ))
        await preflightGate.open()
        await editor.generationService.waitForGeneration(
            placeholderId: outcome.placeholderId
        )

        try assertReleasedOnce(editor)
        #expect(failureCount == 1)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
    }

    @Test("first-run cancellation after approval releases without create and resolves agent")
    @MainActor
    func firstRunApprovedCancellationResolvesAgentAfterAssetRemoval() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-first-approved-cancel-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let undoManager = UndoManager()
        editor.undoManager = undoManager
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        let executeGate = FixtureGate()
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.generationService.mireloBeforeFirstExecute = nil
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        editor.generationService.mireloStoreProvider = { executionStore }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in
            MireloClient(
                apiKey: "fixture-key",
                baseURL: self.baseURL,
                session: fixtureSession
            )
        }
        editor.generationService.mireloBeforeFirstExecute = {
            await executeGate.wait()
        }
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        let createURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.createPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
        ])
        var failureCount = 0
        var placeholderID: String?
        let agentTask = Task { @MainActor in
            try await AgentGenerationAwaiter.waitForSubmission(
                start: { awaiter in
                    let submission = await GenerationController.submit(
                        try firstRunRequest(),
                        editor: editor,
                        onSuccess: { awaiter.resolve(.succeeded($0)) },
                        onFailure: {
                            failureCount += 1
                            awaiter.resolve(.failed(nil))
                        },
                        quoteLoader: { _, _ in testMoney() }
                    )
                    let submittedID = try submission.get().placeholderId
                    placeholderID = submittedID
                    return submittedID
                },
                cancel: { placeholderID in
                    editor.generationService.cancelGeneration(
                        placeholderId: placeholderID
                    )
                }
            )
        }
        await executeGate.waitUntilStarted()
        agentTask.cancel()
        let removedID = try #require(placeholderID)
        editor.deleteMediaAssets(ids: [removedID])
        await executeGate.open()
        let result = try await agentTask.value

        guard case .failed(let message) = result.completion else {
            Issue.record("Expected the cancelled agent generation to fail")
            return
        }
        #expect(message == "Generation cancelled.")
        try assertReleasedOnce(editor)
        #expect(failureCount == 1)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
        undoManager.undo()
        let restored = try #require(editor.mediaAssets.first {
            $0.id == removedID
        })
        #expect(restored.generationInput?.spendTransactionId == nil)
        #expect(editor.mediaManifest.entries.first {
            $0.id == removedID
        }?.generationInput?.spendTransactionId == nil)
        undoManager.redo()
        #expect(!editor.mediaAssets.contains { $0.id == removedID })
        undoManager.undo()
        #expect(editor.mediaAssets.first {
            $0.id == removedID
        }?.generationInput?.spendTransactionId == nil)
        try assertReleasedOnce(editor)
    }

    @Test("working-copy reload ends an approved cancelled agent generation")
    @MainActor
    func firstRunReloadResolvesAgentWithoutRestoringDiscardedSpend() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-reload-cancel-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let (executionStore, storeRoot) = try store()
        let document = try await openProject(at: package) { executionStore }
        let editor = document.editorViewModel
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let fixtureSession = session()
        let executeGate = FixtureGate()
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.generationService.mireloBeforeFirstExecute = nil
            _ = releaseProject(document)
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in
            MireloClient(
                apiKey: "fixture-key",
                baseURL: self.baseURL,
                session: fixtureSession
            )
        }
        editor.generationService.mireloBeforeFirstExecute = {
            await executeGate.wait()
        }
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        let createURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.createPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
        ])
        var failureCount = 0
        let agentTask = Task { @MainActor in
            try await AgentGenerationAwaiter.waitForSubmission(
                start: { awaiter in
                    let submission = await GenerationController.submit(
                        try firstRunRequest(),
                        editor: editor,
                        onSuccess: { awaiter.resolve(.succeeded($0)) },
                        onFailure: {
                            failureCount += 1
                            awaiter.resolve(.failed(nil))
                        },
                        quoteLoader: { _, _ in testMoney() }
                    )
                    return try submission.get().placeholderId
                },
                cancel: { placeholderID in
                    editor.generationService.cancelGeneration(
                        placeholderId: placeholderID
                    )
                }
            )
        }
        await executeGate.waitUntilStarted()
        agentTask.cancel()
        try await discardAndAwaitReload(editor)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
        await executeGate.open()
        let result = try await agentTask.value

        guard case .failed(let message) = result.completion else {
            Issue.record("Expected the reloaded agent generation to fail")
            return
        }
        #expect(message == "Generation cancelled.")
        #expect(failureCount == 1)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: editor.generationLog,
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput)
        )
        #expect(snapshot.activeReservationCount == 0)
        let records = try executionStore.all(
            projectKey: try #require(editor.projectId)
        )
        #expect(records.count == 1)
        #expect(records.first?.state == .failed)
    }

    @Test("scope switch ends cancelled agent without mutating the new project")
    @MainActor
    func firstRunScopeSwitchResolvesAgentWithoutForeignMutation() async throws {
        try await publishFixtureCatalog()
        let firstProject = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-scope-first-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        let secondProject = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-scope-second-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: firstProject)
        try Fixtures.prepareProjectPackage(at: secondProject)
        let editor = EditorViewModel()
        editor.projectURL = firstProject
        let firstWorkingCopyKey = try #require(editor.openWorkingCopyKey)
        let firstWorkingRoot = try #require(editor.workingRoot)
        let firstProjectKey = try #require(editor.projectId)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        let executeGate = FixtureGate()
        var secondWorkingCopyKey: String?
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.generationService.mireloBeforeFirstExecute = nil
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: firstWorkingCopyKey)
            if let secondWorkingCopyKey {
                ProjectWorkingCopy.discard(key: secondWorkingCopyKey)
            }
            try? FileManager.default.removeItem(at: firstProject)
            try? FileManager.default.removeItem(at: secondProject)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        editor.generationService.mireloStoreProvider = { executionStore }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in
            MireloClient(
                apiKey: "fixture-key",
                baseURL: self.baseURL,
                session: fixtureSession
            )
        }
        editor.generationService.mireloBeforeFirstExecute = {
            await executeGate.wait()
        }
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        let createURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.createPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try fixture("preflight-v3"))],
        ])
        var failureCount = 0
        let agentTask = Task { @MainActor in
            try await AgentGenerationAwaiter.waitForSubmission(
                start: { awaiter in
                    let submission = await GenerationController.submit(
                        try firstRunRequest(),
                        editor: editor,
                        onSuccess: { awaiter.resolve(.succeeded($0)) },
                        onFailure: {
                            failureCount += 1
                            awaiter.resolve(.failed(nil))
                        },
                        quoteLoader: { _, _ in testMoney() }
                    )
                    return try submission.get().placeholderId
                },
                cancel: { placeholderID in
                    editor.generationService.cancelGeneration(
                        placeholderId: placeholderID
                    )
                }
            )
        }
        await executeGate.waitUntilStarted()
        agentTask.cancel()
        editor.projectURL = secondProject
        secondWorkingCopyKey = editor.openWorkingCopyKey
        let secondWorkingRoot = try #require(editor.workingRoot)
        await executeGate.open()
        let result = try await agentTask.value

        guard case .failed(let message) = result.completion else {
            Issue.record("Expected the scope-switched agent generation to fail")
            return
        }
        #expect(message == "Generation cancelled.")
        #expect(failureCount == 1)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
        let records = try executionStore.all(projectKey: firstProjectKey)
        #expect(records.count == 1)
        #expect(records.first?.state == .failed)
        let originalLog = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: firstWorkingRoot.appendingPathComponent(
                Project.generationLogFilename
            ))
        )
        #expect(originalLog.spendEvents.last?.kind == .reserved)
        let newLog = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: secondWorkingRoot.appendingPathComponent(
                Project.generationLogFilename
            ))
        )
        #expect(newLog.spendEvents.isEmpty)

        let recoveredDocument = try await openProject(at: firstProject) {
            executionStore
        }
        #expect(recoveredDocument.editorViewModel.recoveredUnsavedWork)
        try assertReleasedOnce(recoveredDocument.editorViewModel)
        _ = releaseProject(recoveredDocument)
    }

    @Test("first-run credit mismatch releases before create")
    @MainActor
    func firstRunCreditMismatchReleasesReservation() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-first-credit-mismatch-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        defer {
            MireloCapabilityCatalog.shared.clear()
            fixtureSession.invalidateAndCancel()
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        editor.generationService.mireloStoreProvider = { executionStore }
        editor.generationService.mireloAPIKeyProvider = { "fixture-key" }
        editor.generationService.mireloClientProvider = { _ in
            MireloClient(
                apiKey: "fixture-key",
                baseURL: self.baseURL,
                session: fixtureSession
            )
        }
        let preflightURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.preflightPath
        )
        let createURL = baseURL.appendingPathComponent(
            MireloOperation.textToSFX.createPath
        )
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try preflightFixture(credits: 40))],
        ])
        var failureCount = 0
        let submission = await GenerationController.submit(
            try firstRunRequest(),
            editor: editor,
            onFailure: { failureCount += 1 },
            quoteLoader: { _, _ in testMoney() }
        )
        let outcome = try submission.get()
        await editor.generationService.waitForGeneration(
            placeholderId: outcome.placeholderId
        )

        try assertReleasedOnce(editor)
        #expect(failureCount == 1)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
    }

    @Test("first-run missing key releases before opening Mirelo authority")
    @MainActor
    func firstRunMissingKeyReleasesReservation() async throws {
        try await publishFixtureCatalog()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-first-missing-key-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        defer {
            MireloCapabilityCatalog.shared.clear()
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
        }
        var storeOpenCount = 0
        editor.generationService.mireloAPIKeyProvider = { nil }
        editor.generationService.mireloStoreProvider = {
            storeOpenCount += 1
            throw CocoaError(.fileNoSuchFile)
        }
        var failureCount = 0
        let submission = await GenerationController.submit(
            try firstRunRequest(),
            editor: editor,
            onFailure: { failureCount += 1 },
            quoteLoader: { _, _ in testMoney() }
        )
        let outcome = try submission.get()
        await editor.generationService.waitForGeneration(
            placeholderId: outcome.placeholderId
        )

        try assertReleasedOnce(editor)
        #expect(failureCount == 1)
        #expect(storeOpenCount == 0)
    }

    @Test("run_mirelo_audio rechecks approved prepared jobs before first create")
    @MainActor
    func agentPreparedResumeRequotesBeforeCreate() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirelo-agent-prepared-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingCopyKey = try #require(editor.openWorkingCopyKey)
        let projectKey = try #require(editor.projectId)
        let (executionStore, storeRoot) = try store()
        let fixtureSession = session()
        let client = MireloClient(
            apiKey: "fixture-key",
            baseURL: baseURL,
            session: fixtureSession
        )
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)
        executor.mireloStoreProvider = { executionStore }
        executor.mireloAPIKeyProvider = { "fixture-key" }
        executor.mireloClientProvider = { _ in client }
        let rawPromptKey = PromptCompiler.rawPromptsDefaultsKey
        let priorRawPrompt = UserDefaults.standard.object(forKey: rawPromptKey)
        let priorAutoApprove = UserDefaults.standard.object(forKey: CostGuard.autoApproveKey)
        UserDefaults.standard.set(true, forKey: rawPromptKey)
        UserDefaults.standard.set(0, forKey: CostGuard.autoApproveKey)
        try await publishFixtureCatalog()
        defer {
            fixtureSession.invalidateAndCancel()
            MireloCapabilityCatalog.shared.clear()
            if let priorRawPrompt {
                UserDefaults.standard.set(priorRawPrompt, forKey: rawPromptKey)
            } else {
                UserDefaults.standard.removeObject(forKey: rawPromptKey)
            }
            if let priorAutoApprove {
                UserDefaults.standard.set(priorAutoApprove, forKey: CostGuard.autoApproveKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CostGuard.autoApproveKey)
            }
            editor.releaseWorkingCopy()
            ProjectWorkingCopy.discard(key: workingCopyKey)
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: storeRoot)
        }

        let preflightURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations/preflight")
        let accountURL = baseURL.appendingPathComponent("v3/me")
        let createURL = baseURL.appendingPathComponent("v3/text-to-sfx/generations")
        let failedJobURL = baseURL.appendingPathComponent(
            "v3/text-to-sfx/generations/agent-prepared-job"
        )
        let unchangedID = "26262626-2626-4626-8626-262626262626"
        let unchangedArgs: [String: Any] = [
            "operation": MireloOperation.textToSFX.rawValue,
            "logicalJobId": unchangedID,
            "model": "sfx-1.6",
            "prompt": "A dry camera shutter",
            "durationMs": 5_000,
            "rawPrompt": true,
            "shotId": "none",
        ]
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try preflightFixture(credits: 50))],
        ])
        _ = try await executor.runMireloAudio(editor, unchangedArgs, origin: .direct)
        #expect(editor.agentService.pendingSpendApproval != nil)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
        editor.agentService.declineSpend()
        let unchangedAuthorization = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "mirelo/sfx-1.6",
            provider: .mirelo,
            transport: .api,
            endpoint: MireloOperation.textToSFX.createPath,
            editor: editor
        )
        let unchangedPrepared = try #require(executionStore.load(
            projectKey: projectKey,
            logicalJobID: unchangedID
        ))
        _ = try await MireloExecutionCoordinator.shared.approve(
            store: executionStore,
            record: unchangedPrepared,
            spendTransactionID: try #require(unchangedAuthorization.transactionId)
        )

        FixtureURLProtocol.install([
            preflightURL: [.init(data: try preflightFixture(credits: 50))],
            accountURL: [.init(data: try fixture("account"))],
            createURL: [.init(
                status: 202,
                data: Data(#"{"id":"agent-prepared-job","status":"queued"}"#.utf8)
            )],
            failedJobURL: [.init(data: Data(
                #"{"id":"agent-prepared-job","status":"failed","errors":[{"message":"fixture provider failure"}]}"#.utf8
            ))],
        ])
        await #expect(throws: ToolError.self) {
            _ = try await executor.runMireloAudio(
                editor,
                unchangedArgs,
                origin: .direct
            )
        }
        #expect(FixtureURLProtocol.requests().filter { $0.url == preflightURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == accountURL }.count == 1)
        #expect(FixtureURLProtocol.requests().filter { $0.url == createURL }.count == 1)

        let changedID = "27272727-2727-4727-8727-272727272727"
        let changedArgs: [String: Any] = [
            "operation": MireloOperation.textToSFX.rawValue,
            "logicalJobId": changedID,
            "model": "sfx-1.6",
            "prompt": "A short mechanical click",
            "durationMs": 4_000,
            "rawPrompt": true,
            "shotId": "none",
        ]
        FixtureURLProtocol.install([
            preflightURL: [.init(data: try preflightFixture(credits: 40))],
        ])
        _ = try await executor.runMireloAudio(editor, changedArgs, origin: .direct)
        #expect(editor.agentService.pendingSpendApproval != nil)
        editor.agentService.declineSpend()
        let changedAuthorization = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "mirelo/sfx-1.6",
            provider: .mirelo,
            transport: .api,
            endpoint: MireloOperation.textToSFX.createPath,
            editor: editor
        )
        let changedPrepared = try #require(executionStore.load(
            projectKey: projectKey,
            logicalJobID: changedID
        ))
        _ = try await MireloExecutionCoordinator.shared.approve(
            store: executionStore,
            record: changedPrepared,
            spendTransactionID: try #require(changedAuthorization.transactionId)
        )

        FixtureURLProtocol.install([
            preflightURL: [.init(data: try preflightFixture(credits: 50))],
            accountURL: [.init(data: try fixture("account"))],
        ])
        let result = try await executor.runMireloAudio(
            editor,
            changedArgs,
            origin: .direct
        )
        #expect(result.turnDisposition == .suspendTurn)
        #expect(editor.agentService.pendingSpendApproval != nil)
        #expect(FixtureURLProtocol.requests().allSatisfy { $0.url != createURL })
        let stillPrepared = try #require(executionStore.load(
            projectKey: projectKey,
            logicalJobID: changedID
        ))
        #expect(stillPrepared.state == .prepared)
        #expect(stillPrepared.preflight.credits == 40)
        editor.agentService.declineSpend()
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
