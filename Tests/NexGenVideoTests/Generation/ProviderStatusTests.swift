import Foundation
import MCP
import Testing

@testable import NexGenVideo

/// One serialized suite owns the shared HTTP fixture, so parallel suites never see each other's stubs.
@Suite("Provider submission and status evidence", .serialized)
struct ProviderStatusTests {
    final class Fixture: URLProtocol, @unchecked Sendable {
        enum Reply: Sendable {
            case response(status: Int, body: String, headers: [String: String] = [:])
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
            case .response(let status, let body, let headers):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: headers.merging(["Content-Type": "application/json"]) { current, _ in current })!
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

        Fixture.stub("POST", "/worlds:generate", .response(status: 502, body: #"{"message":"bad gateway"}"#))
        await #expect(throws: MarbleClient.SubmissionOutcomeUnknownError.self) {
            _ = try await client.submit(body: Data("{}".utf8))
        }

        Fixture.stub("POST", "/worlds:generate", .response(status: 422, body: #"{"message":"invalid prompt"}"#))
        await #expect(throws: GenerationBackendError.self) {
            _ = try await client.submit(body: Data("{}".utf8))
        }
        #expect(Fixture.requests().count == 4)
    }

    private struct MCPStatusStub: MCPStatusClient {
        let payloads: [String: String]
        var results: [String: String] = [:]
        var failingStatus: Set<String> = []

        func callTool(name: String, arguments: [String: Value]) async throws -> [String] {
            if name == "generate_image" { throw GenerationBackendError.transport("Resume must never submit") }
            if name == "job_status", failingStatus.contains(where: { arguments.values.contains(.string($0)) }) {
                throw MCPProviderClient.ClientError.toolFailed("status service unavailable")
            }
            let source = name == "job_result" ? results : payloads
            guard let job = source.keys.first(where: { arguments.values.contains(.string($0)) }) else {
                throw GenerationBackendError.transport("Unknown job")
            }
            return [source[job] ?? ""]
        }

        func discoverTools() async throws -> [MCPProviderClient.DiscoveredTool] {
            let jobInput: Value = .object([
                "properties": .object(["job_id": .object(["type": .string("string")])]),
                "required": .array([.string("job_id")]),
            ])
            let media: Value = .object([
                "type": .string("object"),
                "properties": .object([
                    "result": .object([
                        "type": .string("object"),
                        "properties": .object(["url": .object(["type": .string("string")])]),
                    ]),
                ]),
            ])
            return [
                MCPProviderClient.DiscoveredTool(name: "job_status", description: nil, inputSchema: jobInput,
                    outputSchema: media),
                MCPProviderClient.DiscoveredTool(name: "job_result", description: nil, inputSchema: jobInput),
            ]
        }

        func disconnect() async {}
    }

    @MainActor
    private func projectEditor() throws -> (URL, EditorViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-reconcile-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        let editor = EditorViewModel()
        editor.projectURL = root
        return (root, editor)
    }

    @MainActor
    private func cleanup(_ root: URL) {
        if let key = ProjectIdentity.existingKey(for: root) { ProjectWorkingCopy.discard(key: key) }
        try? FileManager.default.removeItem(at: root)
    }

    private func openRun(
        _ transaction: String,
        _ provider: GenerationProvider,
        transport: ProviderTransport = .api,
        endpoint: String,
        request: String,
        resumable: Bool
    ) -> [GenerationSpendEvent] {
        [
            GenerationSpendEvent(transactionId: transaction, kind: .reserved, model: endpoint, provider: provider,
                transport: transport, endpoint: endpoint),
            GenerationSpendEvent(transactionId: transaction, kind: .submitted, model: endpoint, provider: provider,
                transport: transport, endpoint: endpoint, providerRequestId: request,
                providerRequestResumable: resumable),
        ]
    }

    @MainActor
    private func closing(_ transaction: String, in editor: EditorViewModel) -> GenerationSpendEvent? {
        editor.generationLog.spendEvents.last {
            $0.transactionId == transaction && [.charged, .settled, .released].contains($0.kind)
        }
    }

    @MainActor
    private func reconciliation(
        _ session: URLSession,
        falCharge: @escaping @Sendable (String, String, String) async -> GenerationMoney? = { _, _, _ in nil },
        mcpClient: @escaping @Sendable (GenerationProvider) async -> (any MCPStatusClient)? = { _ in nil }
    ) -> ProviderRunReconciliation {
        ProviderRunReconciliation(session: session, minimumInterval: 60, providerKey: { _ in "provider-key" },
            falCharge: falCharge, mcpClient: mcpClient)
    }

    @MainActor
    @Test func falReconciliationReadsStatusOnlyIsRateLimitedAndBooksTheBill() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let bill = GenerationMoney(nativeAmount: 3, nativeCurrency: "USD", eurAmount: 2.5, eurPerNativeUnit: 2.5 / 3,
            exchangeRateDate: "2026-10-16",
            pricingSource: "https://api.fal.ai/v1/models/billing-events?request_id=fal-req",
            exchangeRateSource: "https://www.ecb.europa.eu/")
        let service = editor.generationService
        service.reconciliation = reconciliation(session, falCharge: { _, _, _ in bill })
        editor.generationLog.spendEvents = openRun("fal-run", .fal, endpoint: "fal-ai/veo3",
            request: "fal-req", resumable: true)
        let start = Date()

        Fixture.stub("GET", "/requests/fal-req/status", .response(status: 200, body: #"{"status":"IN_PROGRESS"}"#))
        #expect(await service.reconcileOpenRuns(editor: editor, now: start) == 0)
        #expect(closing("fal-run", in: editor) == nil)

        Fixture.stub("GET", "/requests/fal-req/status", .response(status: 200, body: #"{"status":"COMPLETED"}"#))
        #expect(await service.reconcileOpenRuns(editor: editor, now: start.addingTimeInterval(30)) == 0)
        #expect(Fixture.requests() == ["GET /fal-ai/veo3/requests/fal-req/status"])

        #expect(await service.reconcileOpenRuns(editor: editor, now: start.addingTimeInterval(61)) == 1)
        let closed = try #require(closing("fal-run", in: editor))
        #expect(closed.kind == .charged)
        #expect(closed.money == bill)
        #expect(Fixture.requests().allSatisfy { $0.hasPrefix("GET ") })
        #expect(Fixture.requests().count == 2)
    }

    @MainActor
    @Test func runwayReconciliationSettlesAConfirmedFailureWithItsCreditsAndIgnoresATimeout() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        editor.generationService.reconciliation = reconciliation(session)
        editor.generationLog.spendEvents =
            openRun("runway-failed", .runway, endpoint: "runway/gen4", request: "task-failed", resumable: true)
            + openRun("runway-slow", .runway, endpoint: "runway/gen4", request: "task-slow", resumable: true)
        Fixture.stub("GET", "/tasks/task-failed", .response(status: 200,
            body: #"{"id":"task-failed","status":"FAILED","failure":"Content moderation","cost":{"credits":5}}"#))
        Fixture.stub("GET", "/tasks/task-slow", .urlError(.timedOut))

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor) == 1)
        let failed = try #require(closing("runway-failed", in: editor))
        #expect(failed.kind == .settled)
        #expect(failed.providerCost?.amount == 5)
        #expect(closing("runway-slow", in: editor) == nil)
        #expect(Fixture.requests() == ["GET /v1/tasks/task-failed", "GET /v1/tasks/task-slow"])
    }

    @MainActor
    @Test func marbleReconciliationSettlesFinishedAndFailedOperationsWithReportedCredits() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        editor.generationService.reconciliation = reconciliation(session)
        editor.generationLog.spendEvents =
            openRun("marble-done", .marble, endpoint: "marble/marble-1.1", request: "op-done", resumable: true)
            + openRun("marble-error", .marble, endpoint: "marble/marble-1.1", request: "op-error", resumable: true)
            + openRun("marble-running", .marble, endpoint: "marble/marble-1.1", request: "op-running", resumable: true)
        Fixture.stub("GET", "/operations/op-done", .response(status: 200,
            body: #"{"done":true,"cost":{"total_credits":12}}"#))
        Fixture.stub("GET", "/operations/op-error", .response(status: 200,
            body: #"{"done":true,"error":{"message":"World generation failed"}}"#))
        Fixture.stub("GET", "/operations/op-running", .response(status: 200, body: #"{"done":false}"#))

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor) == 2)
        #expect(closing("marble-done", in: editor)?.providerCost?.amount == 12)
        #expect(closing("marble-error", in: editor)?.kind == .settled)
        #expect(closing("marble-running", in: editor) == nil)
    }

    @MainActor
    @Test func mcpReconciliationUsesTheStatusToolAndSettlesOnlyATerminalJob() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let stub = MCPStatusStub(payloads: [
            "job-failed": #"{"status":"failed","message":"provider rejected the render"}"#,
            "job-queued": #"{"status":"queued"}"#,
        ])
        editor.generationService.reconciliation = reconciliation(session, mcpClient: { _ in stub })
        editor.generationLog.spendEvents =
            openRun("mcp-failed", .higgsfield, transport: .mcp, endpoint: "higgsfield/video",
                request: "job-failed", resumable: true)
            + openRun("mcp-queued", .higgsfield, transport: .mcp, endpoint: "higgsfield/video",
                request: "job-queued", resumable: true)

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor) == 1)
        #expect(closing("mcp-failed", in: editor)?.kind == .settled)
        #expect(closing("mcp-queued", in: editor) == nil)
        #expect(Fixture.requests().isEmpty)
    }

    @MainActor
    @Test func runsWithoutAQueryableReceiptStayUnconfirmedAndActiveRunsAreNeverQueried() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        editor.generationService.reconciliation = reconciliation(session)
        let active = "active-\(UUID().uuidString)"
        editor.generationLog.spendEvents =
            openRun("no-receipt", .fal, endpoint: "fal-ai/veo3", request: "unknown-receipt", resumable: false)
            + openRun(active, .fal, endpoint: "fal-ai/veo3", request: "fal-active", resumable: true)
        ActiveSpendTransactions.begin(active)
        defer { ActiveSpendTransactions.end(active) }

        let awaitingApproval = "reserved-\(UUID().uuidString)"
        defer { ActiveSpendTransactions.end(awaitingApproval) }
        try editor.recordSpendEvent(
            authorization: GenerationAuthorization(
                transactionId: awaitingApproval,
                target: ResolvedGenerationTarget(modelId: "fal-ai/veo3", provider: .fal, endpoint: "fal-ai/veo3",
                    binding: nil),
                estimate: nil
            ),
            kind: .reserved
        )

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor) == 0)
        #expect(Fixture.requests().isEmpty)
        let snapshot = try GenerationBudgetGuard.spendSnapshot(log: editor.generationLog, generatedInputs: [],
            activeTransactionIDs: ActiveSpendTransactions.current)
        #expect(snapshot.unresolvedCount == 1)
        #expect(snapshot.inFlightCount == 2)
        #expect(!snapshot.isComplete)
        let fields = NativeCockpitReader.spendFields(snapshot)
        #expect(fields["unresolved_runs"] as? Int == 1)
        #expect(fields["in_flight_runs"] as? Int == 2)
        #expect(fields["active_reservations"] as? Int == 3)
    }

    @Test func statusReadsNeedAnExplicitTerminalStateAndIgnoreJSONNull() async throws {
        Fixture.reset()
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let marble = MarbleClient(apiKey: "marble-secret", session: session)
        Fixture.stub("GET", "/operations/op-null", .response(status: 200, body: #"{"done":false,"error":null}"#))
        Fixture.stub("GET", "/operations/op-finished", .response(status: 200,
            body: #"{"done":true,"error":null,"cost":{"total_credits":4}}"#))
        Fixture.stub("GET", "/operations/op-undecided", .response(status: 200,
            body: #"{"error":{"message":"World generation failed"}}"#))
        Fixture.stub("GET", "/operations/op-numeric", .response(status: 200, body: #"{"done":1}"#))

        #expect(try await marble.status(operationId: "op-null") == .running)
        #expect(try await marble.status(operationId: "op-finished") == .completed(GenerationProviderCost(
            amount: 4, unit: "credits", source: "Marble GET /marble/v1/operations/{id} cost.total_credits")))
        await #expect(throws: GenerationBackendError.self) {
            _ = try await marble.status(operationId: "op-undecided")
        }
        await #expect(throws: GenerationBackendError.self) {
            _ = try await marble.status(operationId: "op-numeric")
        }

        let mediaOnly = MCPStatusStub(payloads: ["job-media": #"{"job_id":"job-media","result":{"url":"https://output.invalid/a.png"}}"#])
        await #expect(throws: GenerationBackendError.self) {
            _ = try await MCPGenerationExecutor.status(jobID: "job-media", tools: try await mediaOnly.discoverTools(),
                client: mediaOnly)
        }
    }

    @MainActor
    @Test func interruptedMCPBatchJobsResumeWithTheirMediaAndNeverResubmit() async throws {
        let service = EditorViewModel().generationService
        let stub = MCPStatusStub(
            payloads: [
                "job-media": #"{"status":"completed","result":{"url":"https://output.invalid/resumed.png"}}"#,
                "job-result": #"{"status":"completed"}"#,
                "job-failed": #"{"status":"failed","message":"provider rejected the render"}"#,
                "job-queued": #"{"status":"queued"}"#,
            ],
            results: ["job-result": #"{"result":{"url":"https://output.invalid/from-result.png"}}"#]
        )
        service.reconciliation = ProviderRunReconciliation(mcpClient: { _ in stub })

        #expect(try await service.resumedMCPOutput(provider: .higgsfield, jobID: "job-media").urls
            == ["https://output.invalid/resumed.png"])
        #expect(try await service.resumedMCPOutput(provider: .higgsfield, jobID: "job-result").urls
            == ["https://output.invalid/from-result.png"])
        do {
            _ = try await service.resumedMCPOutput(provider: .higgsfield, jobID: "job-failed")
            Issue.record("Expected a failed MCP job to end")
        } catch {
            #expect(GenerationService.providerRunEnded(after: error))
            #expect(error.localizedDescription.contains("provider rejected the render"))
        }
        do {
            _ = try await service.resumedMCPOutput(provider: .higgsfield, jobID: "job-queued")
            Issue.record("Expected a running MCP job to stay open")
        } catch {
            #expect(!GenerationService.providerRunEnded(after: error))
        }

        service.reconciliation = ProviderRunReconciliation(mcpClient: { _ in nil })
        await #expect(throws: GenerationRequestError.self) {
            _ = try await service.resumedMCPOutput(provider: .higgsfield, jobID: "job-media")
        }
    }

    private final class GatedCharge: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        var isWaiting: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { continuation in park(continuation) }
        }

        func release() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    @MainActor
    @Test func reconciliationNeverWritesIntoAProjectThatReplacedTheQueriedOne() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-other-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: other)
        defer {
            cleanup(root)
            cleanup(other)
        }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let gate = GatedCharge()
        editor.generationService.reconciliation = reconciliation(session, falCharge: { _, _, _ in
            await gate.wait()
            return nil
        })
        let events = openRun("fal-shared", .fal, endpoint: "fal-ai/veo3", request: "fal-shared-req", resumable: true)
        editor.generationLog.spendEvents = events
        Fixture.stub("GET", "/requests/fal-shared-req/status", .response(status: 200, body: #"{"status":"COMPLETED"}"#))

        let reconciling = Task { await editor.generationService.reconcileOpenRuns(editor: editor) }
        for _ in 0..<400 where !gate.isWaiting { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(gate.isWaiting)
        editor.projectURL = other
        editor.generationLog.spendEvents = events
        gate.release()

        #expect(await reconciling.value == 0)
        #expect(closing("fal-shared", in: editor) == nil)
    }

    @Test func confirmedProviderFailuresCarryTheCostTheirResponseReports() async throws {
        Fixture.reset()
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        Fixture.stub("GET", "/operations/op-failed", .response(status: 200,
            body: #"{"done":true,"error":{"message":"World generation failed"},"cost":{"total_credits":3}}"#))
        do {
            _ = try await MarbleClient(apiKey: "marble-secret", session: session).result(operationId: "op-failed")
            Issue.record("Expected a failed Marble operation to throw")
        } catch let failure as ProviderRunEndedError {
            #expect(failure.message == "World generation failed")
            #expect(failure.cost?.amount == 3)
        }

        Fixture.stub("POST", "/sound-generation", .response(status: 422, body: #"{"detail":"text too long"}"#,
            headers: ["character-cost": "18"]))
        do {
            _ = try await ElevenLabsClient(apiKey: "eleven-secret", session: session)
                .soundEffect(text: "Rain on glass", durationSeconds: 2)
            Issue.record("Expected a rejected ElevenLabs request to throw")
        } catch let failure as ProviderRunEndedError {
            #expect(failure.cost?.amount == 18)
            #expect(failure.cost?.unit == "characters")
        }
    }

    @MainActor
    @Test func aConfirmedFalFailureIsBookedWithItsBill() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let bill = GenerationMoney(nativeAmount: 1.2, nativeCurrency: "USD", eurAmount: 1, eurPerNativeUnit: 1 / 1.2,
            exchangeRateDate: "2026-10-16",
            pricingSource: "https://api.fal.ai/v1/models/billing-events?request_id=fal-failed-req",
            exchangeRateSource: "https://www.ecb.europa.eu/")
        editor.generationService.reconciliation = reconciliation(session, falCharge: { _, _, _ in bill })
        editor.generationLog.spendEvents = openRun("fal-failed", .fal, endpoint: "fal-ai/veo3",
            request: "fal-failed-req", resumable: true)
        Fixture.stub("GET", "/requests/fal-failed-req/status", .response(status: 200,
            body: #"{"status":"FAILED","error":"Out of memory"}"#))

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor) == 1)
        let closed = try #require(closing("fal-failed", in: editor))
        #expect(closed.kind == .charged)
        #expect(closed.money == bill)
    }

    @MainActor
    @Test func aResumedRunWithEveryOutputStillReadsItsTerminalCost() async throws {
        Fixture.reset()
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let service = EditorViewModel().generationService
        service.reconciliation = ProviderRunReconciliation(session: session)
        Fixture.stub("GET", "/tasks/task-done", .response(status: 200,
            body: #"{"id":"task-done","status":"SUCCEEDED","output":["https://example.com/a.mp4"],"cost":{"credits":40}}"#))
        Fixture.stub("GET", "/operations/op-done", .response(status: 200,
            body: #"{"done":true,"cost":{"total_credits":9}}"#))
        Fixture.stub("GET", "/tasks/task-lost", .urlError(.timedOut))

        #expect(await service.terminalCost(provider: .runway, transport: .api, requestID: "task-done",
            apiKey: "runway-secret")?.amount == 40)
        #expect(await service.terminalCost(provider: .marble, transport: .api, requestID: "op-done",
            apiKey: "marble-secret")?.amount == 9)
        #expect(await service.terminalCost(provider: .runway, transport: .api, requestID: "task-lost",
            apiKey: "runway-secret") == nil)
        #expect(await service.terminalCost(provider: .higgsfield, transport: .mcp, requestID: "job",
            apiKey: "") == nil)
        #expect(Fixture.requests() == ["GET /v1/tasks/task-done", "GET /marble/v1/operations/op-done",
            "GET /v1/tasks/task-lost"])
    }

    private final class BillLookups: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }

        func record(_ id: String) {
            lock.lock()
            ids.append(id)
            lock.unlock()
        }
    }

    @MainActor
    @Test func aSettledFalRunWithoutMoneyPicksUpALateBill() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let bill = GenerationMoney(nativeAmount: 0.6, nativeCurrency: "USD", eurAmount: 0.5, eurPerNativeUnit: 0.5 / 0.6,
            exchangeRateDate: "2026-10-16",
            pricingSource: "https://api.fal.ai/v1/models/billing-events?request_id=fal-late",
            exchangeRateSource: "https://www.ecb.europa.eu/")
        let lookups = BillLookups()
        editor.generationService.reconciliation = reconciliation(session, falCharge: { requestID, _, _ in
            lookups.record(requestID)
            return requestID == "fal-late" ? bill : nil
        })
        let start = Date()
        func settled(_ transaction: String, at date: Date) -> GenerationSpendEvent {
            GenerationSpendEvent(transactionId: transaction, kind: .settled, model: "fal-ai/veo3", provider: .fal,
                transport: .api, endpoint: "fal-ai/veo3", createdAt: date)
        }
        editor.generationLog.spendEvents =
            openRun("late", .fal, endpoint: "fal-ai/veo3", request: "fal-late", resumable: true)
            + [settled("late", at: start)]
            + openRun("old", .fal, endpoint: "fal-ai/veo3", request: "fal-old", resumable: true)
            + [settled("old", at: start.addingTimeInterval(-8 * 24 * 60 * 60))]
            + openRun("unbilled", .fal, endpoint: "fal-ai/veo3", request: "fal-unbilled", resumable: true)
            + [settled("unbilled", at: start)]

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor, now: start) == 1)
        let charged = try #require(closing("late", in: editor))
        #expect(charged.kind == .charged)
        #expect(charged.money == bill)
        #expect(lookups.recorded == ["fal-late", "fal-unbilled"])

        #expect(await editor.generationService.reconcileOpenRuns(editor: editor, now: start.addingTimeInterval(30)) == 0)
        #expect(lookups.recorded == ["fal-late", "fal-unbilled"])
        #expect(await editor.generationService.reconcileOpenRuns(editor: editor, now: start.addingTimeInterval(61)) == 0)
        #expect(lookups.recorded == ["fal-late", "fal-unbilled", "fal-unbilled"])
        #expect(Fixture.requests().isEmpty)
    }

    @MainActor
    @Test func aFailedStatusQueryNeverEndsAnMCPJob() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let stub = MCPStatusStub(payloads: ["job-dark": #"{"status":"failed","message":"never read"}"#],
            failingStatus: ["job-dark"])
        let service = editor.generationService
        service.reconciliation = reconciliation(session, mcpClient: { _ in stub })

        do {
            _ = try await service.resumedMCPOutput(provider: .higgsfield, jobID: "job-dark")
            Issue.record("Expected the failed status query to throw")
        } catch {
            #expect(!GenerationService.providerRunEnded(after: error))
            #expect(error.localizedDescription.contains("status service unavailable"))
        }

        editor.generationLog.spendEvents = openRun("mcp-dark", .higgsfield, transport: .mcp,
            endpoint: "higgsfield/video", request: "job-dark", resumable: true)
        #expect(await service.reconcileOpenRuns(editor: editor) == 0)
        #expect(closing("mcp-dark", in: editor) == nil)
    }

    @MainActor
    @Test func aFailedReceiptWriteIsRetriedBeforeTheRunClosesOrStaysOpen() async throws {
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let service = editor.generationService
        let target = ResolvedGenerationTarget(modelId: "fal-ai/veo3", provider: .fal, endpoint: "fal-ai/veo3", binding: nil)
        let finished = GenerationAuthorization(transactionId: "receipt-finished", target: target, estimate: nil)
        let unknown = GenerationAuthorization(transactionId: "receipt-unknown", target: target, estimate: nil)
        func reserved(_ transaction: String) -> GenerationSpendEvent {
            GenerationSpendEvent(transactionId: transaction, kind: .reserved, model: "fal-ai/veo3", provider: .fal,
                transport: .api, endpoint: "fal-ai/veo3")
        }

        // Without a reservation the ledger refuses the receipt, standing in for any failed write.
        #expect(!service.markSubmitted(authorization: finished, providerRequestId: "fal-finished", resumable: true,
            editor: editor))
        #expect(!service.markSubmitted(authorization: unknown, providerRequestId: "fal-unknown", resumable: true,
            editor: editor))
        #expect(editor.generationLog.spendEvents.isEmpty)
        editor.generationLog.spendEvents = [reserved("receipt-finished"), reserved("receipt-unknown")]

        service.markFinished(authorization: finished, editor: editor)
        service.recordSubmittedRunFailure(
            FalClient.SubmissionOutcomeUnknownError(ledgerRequestID: "fal-unknown", message: "No receipt"),
            message: "No receipt", authorization: unknown, editor: editor)

        let finishedEvents = editor.generationLog.spendEvents.filter { $0.transactionId == "receipt-finished" }
        #expect(finishedEvents.map(\.kind) == [.reserved, .submitted, .settled])
        #expect(finishedEvents.first { $0.kind == .submitted }?.providerRequestId == "fal-finished")
        let unknownEvents = editor.generationLog.spendEvents.filter { $0.transactionId == "receipt-unknown" }
        #expect(unknownEvents.map(\.kind) == [.reserved, .submitted])
        #expect(GenerationService.reconcilableRuns(in: editor.generationLog, excluding: []).map(\.requestID)
            == ["fal-unknown"])
        #expect(service.markSubmitted(authorization: unknown, providerRequestId: "fal-unknown", resumable: true,
            editor: editor))
        #expect(editor.generationLog.spendEvents.filter { $0.kind == .submitted }.count == 2)
    }

    @MainActor
    @Test func reconciliationFirstWritesAReceiptThatFailedEarlierThenQueriesIt() async throws {
        Fixture.reset()
        let (root, editor) = try projectEditor()
        defer { cleanup(root) }
        let session = Fixture.session()
        defer { session.invalidateAndCancel() }
        let service = editor.generationService
        service.reconciliation = reconciliation(session)
        let authorization = GenerationAuthorization(
            transactionId: "receipt-late",
            target: ResolvedGenerationTarget(modelId: "fal-ai/veo3", provider: .fal, endpoint: "fal-ai/veo3", binding: nil),
            estimate: nil
        )
        #expect(!service.markSubmitted(authorization: authorization, providerRequestId: "fal-late-receipt",
            resumable: true, editor: editor))
        editor.generationLog.spendEvents = [GenerationSpendEvent(transactionId: "receipt-late", kind: .reserved,
            model: "fal-ai/veo3", provider: .fal, transport: .api, endpoint: "fal-ai/veo3")]
        Fixture.stub("GET", "/requests/fal-late-receipt/status", .response(status: 200, body: #"{"status":"IN_PROGRESS"}"#))

        #expect(await service.reconcileOpenRuns(editor: editor) == 0)
        let receipt = editor.generationLog.spendEvents.first { $0.kind == .submitted }
        #expect(receipt?.providerRequestId == "fal-late-receipt")
        #expect(receipt?.providerRequestResumable == true)
        #expect(Fixture.requests() == ["GET /fal-ai/veo3/requests/fal-late-receipt/status"])
        #expect(service.flushPendingReceipts(editor: editor) == 0)
    }

    @Test func providerToolAnswersEndTheRunOnlyOnAConfirmedEnd() {
        let statusTool = MCPProviderClient.DiscoveredTool(
            name: "job_status",
            description: nil,
            inputSchema: .object([
                "properties": .object(["job_id": .object(["type": .string("string")])]),
                "required": .array([.string("job_id")]),
            ])
        )
        func outcome(_ payload: String, tools: [MCPProviderClient.DiscoveredTool]? = nil) -> ToolExecutor.ProviderToolOutcome {
            ToolExecutor.providerToolOutcome(payloads: [payload], tools: tools ?? [statusTool])
        }

        #expect(outcome(#"{"job_id":"j-1","status":"queued"}"#) == .init(jobID: "j-1", queryable: true, ended: false))
        #expect(outcome(#"{"job_id":"j-2"}"#) == .init(jobID: "j-2", queryable: true, ended: false))
        #expect(outcome(#"{"job_id":"j-3","status":null,"url":"https://output.invalid/preview.png"}"#)
            == .init(jobID: "j-3", queryable: true, ended: false))
        #expect(outcome(#"{"job_id":"j-4","status":"failed","message":"rejected"}"#)
            == .init(jobID: "j-4", queryable: true, ended: true))
        #expect(outcome(#"{"status":"completed","url":"https://output.invalid/done.png"}"#).ended)
        #expect(outcome("Background removed: https://output.invalid/cutout.png")
            == .init(jobID: nil, queryable: false, ended: true))
        #expect(outcome(#"{"status":"queued"}"#) == .init(jobID: nil, queryable: false, ended: false))
        #expect(outcome(#"{"job_id":"j-5","status":"queued"}"#, tools: [])
            == .init(jobID: "j-5", queryable: false, ended: false))
    }
}
