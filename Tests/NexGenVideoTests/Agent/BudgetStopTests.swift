import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@MainActor
@Suite("Central generation budget stop")
struct BudgetStopTests {

    private func project(stop: Double?, log: GenerationLog = GenerationLog()) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = root.appendingPathComponent("pipeline", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try Data("project: demo\nmode: beat\n".utf8).write(
            to: dataRoot.appendingPathComponent(PipelineLayout.projectFile)
        )
        let brief = try Brief(
            project: "demo",
            generated: "2026-01-01",
            mission: .demo,
            targetPlatform: "web",
            aspectRatio: .landscape16x9,
            projectMode: "beat",
            budgetStopEur: stop,
            conceptType: .abstract,
            visualMedium: .liveActionRealistic,
            figures: .none,
            lyricsIntegration: .ignored
        )
        try YAMLArtifactStore(dataRoot: dataRoot).save(brief, to: PipelineLayout.briefFile)
        try Fixtures.prepareProjectPackage(at: root)
        try JSONEncoder().encode(log).write(
            to: root.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        return root
    }

    private func editor(for project: URL) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.projectURL = project
        return editor
    }

    private func cleanup(_ project: URL) {
        if let key = ProjectIdentity.existingKey(for: project) {
            ProjectWorkingCopy.discard(key: key)
        }
        try? FileManager.default.removeItem(at: project)
    }

    private func money(_ eur: Double) -> GenerationMoney {
        GenerationMoney(
            nativeAmount: eur * 1.2,
            nativeCurrency: "USD",
            eurAmount: eur,
            eurPerNativeUnit: 1 / 1.2,
            exchangeRateDate: "2026-07-23",
            pricingSource: "https://provider.example/pricing",
            exchangeRateSource: "https://www.ecb.europa.eu/"
        )
    }

    private func providerThunkProbe(
        onDispatch: @escaping @MainActor () -> Void
    ) -> GenerationRequest {
        GenerationRequest(
            modality: .upscale,
            modelId: "fal-ai/clarity-upscaler",
            intent: "",
            durationSeconds: 1,
            placement: .mediaLibrary(folderId: nil),
            origin: .panel,
            submission: .upscale(run: { _, _, _, _, _, _ in
                onDispatch()
                return "probe-dispatch"
            })
        )
    }

    @Test("over-limit request stops before provider dispatch and leaves the ledger untouched")
    func overLimitStopsBeforeDispatch() async throws {
        let package = try project(stop: 5)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let beforeAssets = editor.mediaAssets.count
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )

        guard case .failure(.budget(let message)) = result else {
            Issue.record("expected budget failure, got \(result)")
            return
        }
        #expect(message.contains("Budget stop reached"))
        #expect(!providerThunkExecuted)
        #expect(editor.mediaAssets.count == beforeAssets)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("unknown monetary price fails closed without a provider dispatch")
    func unknownPriceStops() async throws {
        let package = try project(stop: 100)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let beforeAssets = editor.mediaAssets.count
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in
                throw GenerationBudgetError.blocked("No verified price.")
            }
        )

        guard case .failure(.budget(let message)) = result else {
            Issue.record("expected budget failure, got \(result)")
            return
        }
        #expect(message.contains("verified monetary estimate"))
        #expect(!providerThunkExecuted)
        #expect(editor.mediaAssets.count == beforeAssets)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("no explicit stop allows an unpriced request and records the uncertainty")
    func noStopAllowsUnknownPrice() async throws {
        let package = try project(stop: nil)
        defer { cleanup(package) }
        let editor = editor(for: package)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in
                throw GenerationBudgetError.blocked("No verified price.")
            }
        )

        guard case .success = result else {
            Issue.record("expected dispatch without an explicit stop, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
        #expect(editor.generationLog.spendEvents.first?.kind == .reserved)
        #expect(editor.generationLog.spendEvents.first?.money == nil)
        #expect(editor.generationLog.spendEvents.first?.note?.contains("No verified price") == true)
    }

    @Test("an unreadable brief fails closed before provider dispatch")
    func corruptBriefStops() async throws {
        let package = try project(stop: 100)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let workingRoot = try #require(editor.workingRoot)
        let dataRoot = try #require(DataRootResolver.dataRoot(of: workingRoot))
        let briefURL = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        let corrupt = Data("budget_stop_eur: [broken".utf8)
        try corrupt.write(to: briefURL, options: .atomic)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(1) }
        )

        guard case .failure(.budget(let message)) = result else {
            Issue.record("expected corrupt-brief failure, got \(result)")
            return
        }
        #expect(message.contains("brief.yaml"))
        #expect(!providerThunkExecuted)
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(try Data(contentsOf: briefURL) == corrupt)
    }

    @Test("a reservation is persisted before the provider path can start")
    func reservationPersistsBeforeDispatch() async throws {
        let package = try project(stop: 100)
        defer { cleanup(package) }
        let editor = editor(for: package)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )

        guard case .success = result else {
            Issue.record("expected dispatch, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
        let workingRoot = try #require(editor.workingRoot)
        let persisted = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(Project.generationLogFilename))
        )
        #expect(persisted.spendEvents.first?.kind == .reserved)
        #expect(persisted.spendEvents.first?.money?.eurAmount == 6)
    }

    @Test("live reservations prevent concurrent requests from overspending")
    func reservationsCountAgainstLaterRequests() async throws {
        let package = try project(stop: 10)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let target = GenerationService.dispatchTarget(modelId: "fal-ai/veo3")
        let input = GenerationPricingInput(
            modelId: "fal-ai/veo3",
            modality: .video,
            durationSeconds: 5,
            outputCount: 1,
            resolution: nil,
            quality: nil,
            promptCharacterCount: 5,
            generateAudio: true
        )

        _ = try await GenerationBudgetGuard.authorize(
            input: input,
            target: target,
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )

        await #expect(throws: GenerationBudgetError.self) {
            _ = try await GenerationBudgetGuard.authorize(
                input: input,
                target: target,
                editor: editor,
                quoteLoader: { _, _ in money(6) }
            )
        }
        #expect(editor.generationLog.spendEvents.count == 1)
    }

    @Test("a delayed quote rechecks live reservations before authorizing")
    func delayedQuoteCannotOverwriteConcurrentReservation() async throws {
        let package = try project(stop: 10)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let target = GenerationService.dispatchTarget(modelId: "fal-ai/veo3")
        let input = GenerationPricingInput(
            modelId: "fal-ai/veo3",
            modality: .video,
            durationSeconds: 5,
            outputCount: 1,
            resolution: nil,
            quality: nil,
            promptCharacterCount: 5,
            generateAudio: true
        )
        let (quoteStarted, startedContinuation) = AsyncStream<Void>.makeStream()
        var resumeQuote: CheckedContinuation<Void, Never>?

        let delayed = Task { @MainActor in
            try await GenerationBudgetGuard.authorize(
                input: input,
                target: target,
                editor: editor,
                quoteLoader: { _, _ in
                    startedContinuation.yield()
                    await withCheckedContinuation { resumeQuote = $0 }
                    return money(6)
                }
            )
        }
        var iterator = quoteStarted.makeAsyncIterator()
        _ = await iterator.next()

        _ = try await GenerationBudgetGuard.authorize(
            input: input,
            target: target,
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )
        let continuation = try #require(resumeQuote)
        continuation.resume()

        await #expect(throws: GenerationBudgetError.self) {
            _ = try await delayed.value
        }
        #expect(editor.generationLog.spendEvents.count == 1)
        #expect(editor.generationLog.spendEvents.first?.money?.eurAmount == 6)
    }

    @Test("reruns use the same pre-dispatch budget guard")
    func rerunStopsBeforeDispatch() async throws {
        let package = try project(stop: 5)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let asset = MediaAsset(
            url: package.appendingPathComponent("source.png"),
            type: .image,
            name: "Source",
            duration: 1,
            generationInput: GenerationInput(
                prompt: "",
                model: "fal-ai/clarity-upscaler",
                duration: 1,
                aspectRatio: "",
                resolution: nil,
                imageURLs: ["https://example.test/source.png"]
            )
        )
        let beforeAssets = editor.mediaAssets.count

        do {
            _ = try await EditSubmitter.rerun(
                asset: asset,
                editor: editor,
                quoteLoader: { _, _ in money(6) }
            )
            Issue.record("expected the rerun budget guard to block")
        } catch let error as EditSubmitter.RerunError {
            guard case .budget(let message) = error else {
                Issue.record("expected budget failure, got \(error)")
                return
            }
            #expect(message.contains("Budget stop reached"))
        }

        #expect(editor.mediaAssets.count == beforeAssets)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("an unpriced provider workflow is blocked by an explicit stop")
    func providerWorkflowFailsClosed() throws {
        let package = try project(stop: 100)
        defer { cleanup(package) }
        let editor = editor(for: package)

        #expect(throws: GenerationBudgetError.self) {
            _ = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
                modelId: "remove_background",
                provider: .openart,
                transport: .mcp,
                endpoint: "remove_background",
                editor: editor
            )
        }
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("corrupt spend data blocks and remains untouched")
    func corruptLedgerStops() async throws {
        let package = try project(stop: 100)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let workingRoot = try #require(editor.workingRoot)
        let logURL = workingRoot.appendingPathComponent(Project.generationLogFilename)
        let corrupt = Data("{\"version\":2,\"spendEvents\":[".utf8)
        try corrupt.write(to: logURL, options: .atomic)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(1) }
        )

        guard case .failure(.budget(let message)) = result else {
            Issue.record("expected corrupt-ledger failure, got \(result)")
            return
        }
        #expect(message.contains("generation-log.json"))
        #expect(!providerThunkExecuted)
        #expect(try Data(contentsOf: logURL) == corrupt)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test("legacy credit rows cannot be converted into EUR")
    func legacyCreditsFailClosed() async throws {
        var log = GenerationLog()
        log.entries.append(GenerationLogEntry(
            model: "fal-ai/veo3",
            costCredits: 100,
            createdAt: Date()
        ))
        let package = try project(stop: 100, log: log)
        defer { cleanup(package) }
        let editor = editor(for: package)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(1) }
        )

        guard case .failure(.budget(let message)) = result else {
            Issue.record("expected legacy-ledger failure, got \(result)")
            return
        }
        #expect(message.contains("no verified monetary ledger"))
        #expect(!providerThunkExecuted)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("agent-reported render costs do not authorize provider spend")
    func agentReportedCostsAreNotAuthoritative() throws {
        let tx = UUID().uuidString
        var log = GenerationLog()
        log.spendEvents = [
            GenerationSpendEvent(
                transactionId: tx,
                kind: .reserved,
                model: "fal-ai/veo3",
                provider: .fal,
                transport: .api,
                endpoint: "fal-ai/veo3",
                money: money(3)
            ),
            GenerationSpendEvent(
                transactionId: tx,
                kind: .submitted,
                model: "fal-ai/veo3",
                provider: .fal,
                transport: .api,
                endpoint: "fal-ai/veo3",
                providerRequestId: "request-1",
                money: money(3)
            ),
        ]

        let spend = try GenerationBudgetGuard.verifiedSpend(
            log: log,
            generatedAssets: [],
            requireCompleteMoney: true
        )

        #expect(spend == 3)
    }

    @Test("the verified charge replaces its reservation")
    func chargedAmountReplacesReservation() throws {
        let tx = UUID().uuidString
        var log = GenerationLog()
        log.spendEvents = [
            GenerationSpendEvent(
                transactionId: tx,
                kind: .reserved,
                model: "runway/gen4.5",
                provider: .runway,
                transport: .api,
                endpoint: "runway/gen4.5",
                money: money(3)
            ),
            GenerationSpendEvent(
                transactionId: tx,
                kind: .submitted,
                model: "runway/gen4.5",
                provider: .runway,
                transport: .api,
                endpoint: "runway/gen4.5",
                providerRequestId: "task-1",
                money: money(3)
            ),
            GenerationSpendEvent(
                transactionId: tx,
                kind: .charged,
                model: "runway/gen4.5",
                provider: .runway,
                transport: .api,
                endpoint: "runway/gen4.5",
                money: money(4)
            ),
        ]

        let spend = try GenerationBudgetGuard.verifiedSpend(
            log: log,
            generatedAssets: [],
            requireCompleteMoney: true
        )

        #expect(spend == 4)
    }

    @Test("invalid append-only transitions are rejected")
    func invalidTransitionIsRejected() throws {
        let tx = UUID().uuidString
        var log = GenerationLog()
        log.spendEvents = [
            GenerationSpendEvent(
                transactionId: tx,
                kind: .reserved,
                model: "fal-ai/veo3",
                provider: .fal,
                transport: .api,
                endpoint: "fal-ai/veo3",
                money: money(3)
            ),
            GenerationSpendEvent(
                transactionId: tx,
                kind: .charged,
                model: "fal-ai/veo3",
                provider: .fal,
                transport: .api,
                endpoint: "fal-ai/veo3",
                money: money(3)
            ),
        ]

        #expect(throws: GenerationBudgetError.self) {
            _ = try GenerationBudgetGuard.verifiedSpend(
                log: log,
                generatedAssets: [],
                requireCompleteMoney: true
            )
        }
    }

    @Test("a non-positive stop is rejected by the brief schema")
    func nonPositiveStopIsInvalid() throws {
        #expect(throws: Brief.ValidationError.budgetStopNotPositive(0)) {
            let brief = try Brief(
                project: "demo",
                generated: "2026-01-01",
                mission: .demo,
                targetPlatform: "web",
                aspectRatio: .landscape16x9,
                projectMode: "beat",
                budgetStopEur: 0,
                conceptType: .abstract,
                visualMedium: .liveActionRealistic,
                figures: .none,
                lyricsIntegration: .ignored
            )
            try brief.validate()
        }
    }
}
