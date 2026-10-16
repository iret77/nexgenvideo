import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

@MainActor
@Suite("Generation spend guard")
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

    private func billed(_ eur: Double, request: String = "request") -> GenerationMoney {
        GenerationMoney(
            nativeAmount: eur * 1.2,
            nativeCurrency: "USD",
            eurAmount: eur,
            eurPerNativeUnit: 1 / 1.2,
            exchangeRateDate: "2026-07-23",
            pricingSource: "https://api.fal.ai/v1/models/billing-events?request_id=\(request)",
            exchangeRateSource: "https://www.ecb.europa.eu/"
        )
    }

    private func event(
        _ transaction: String,
        _ kind: GenerationSpendEvent.Kind,
        provider: GenerationProvider = .fal,
        money: GenerationMoney? = nil,
        request: String? = nil,
        cost: GenerationProviderCost? = nil
    ) -> GenerationSpendEvent {
        GenerationSpendEvent(
            transactionId: transaction,
            kind: kind,
            model: "\(provider.rawValue)/model",
            provider: provider,
            transport: .api,
            endpoint: "\(provider.rawValue)/model",
            providerRequestId: request,
            money: money,
            providerCost: cost
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

    @Test("a stored budget stop never blocks a known price above it")
    func storedStopNeverBlocksKnownPrice() async throws {
        let package = try project(stop: 5)
        defer { cleanup(package) }
        let editor = editor(for: package)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )

        guard case .success = result else {
            Issue.record("expected dispatch despite the stored stop, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
        #expect(editor.generationLog.spendEvents.first?.kind == .reserved)
        #expect(editor.generationLog.spendEvents.first?.money?.eurAmount == 6)
    }

    @Test("a stored budget stop never blocks a request whose price is unknown")
    func unknownPriceRunsUnderStoredStop() async throws {
        let package = try project(stop: 100)
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
            Issue.record("expected dispatch under a stop without a known price, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
        #expect(editor.generationLog.spendEvents.first?.kind == .reserved)
        #expect(editor.generationLog.spendEvents.first?.money == nil)
        #expect(editor.generationLog.spendEvents.first?.note?.contains("No verified price") == true)
    }

    @Test("spend above a stored stop never blocks known or unknown prices")
    func spendAboveStoredStopNeverBlocks() async throws {
        let package = try project(stop: 6)
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
            generateAudio: true,
            referenceCount: 0
        )
        _ = try await GenerationBudgetGuard.authorize(
            input: input,
            target: target,
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )
        var providerThunkExecuted = false

        let unknown = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in
                throw GenerationBudgetError.blocked("No verified price.")
            }
        )

        guard case .success = unknown else {
            Issue.record("expected the unknown-price request to dispatch, got \(unknown)")
            return
        }
        #expect(providerThunkExecuted)
        let known = try await GenerationBudgetGuard.authorize(
            input: input,
            target: target,
            editor: editor,
            quoteLoader: { _, _ in money(10) }
        )
        #expect(known.estimate?.eurAmount == 10)
        #expect(editor.generationLog.spendEvents.count == 3)
    }

    @Test("an unpriced reservation in the history never locks later known-price work")
    func unpricedHistoryNeverLocksLaterWork() async throws {
        var log = GenerationLog()
        log.spendEvents = [GenerationSpendEvent(
            transactionId: UUID().uuidString,
            kind: .reserved,
            model: "openart/tool",
            provider: .openart,
            transport: .mcp,
            endpoint: "openart/tool"
        )]
        let package = try project(stop: 100, log: log)
        defer { cleanup(package) }
        let editor = editor(for: package)
        var providerThunkExecuted = false

        let result = await GenerationController.submit(
            providerThunkProbe { providerThunkExecuted = true },
            editor: editor,
            quoteLoader: { _, _ in money(1) }
        )

        guard case .success = result else {
            Issue.record("expected the known-price request to dispatch, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
        #expect(editor.generationLog.spendEvents.contains(where: { $0.money?.eurAmount == 1 }))
    }

    @Test("upscale pricing receives the exact duration and target resolution")
    func upscalePricingReceivesTarget() async throws {
        let package = try project(stop: nil)
        defer { cleanup(package) }
        let editor = editor(for: package)
        var pricedInput: GenerationPricingInput?
        let request = GenerationRequest(
            modality: .upscale,
            modelId: "bria/video/increase-resolution",
            intent: "",
            durationSeconds: 7.25,
            outputResolution: "8K",
            placement: .mediaLibrary(folderId: nil),
            origin: .panel,
            submission: .upscale(run: { _, _, _, _, _, _ in "upscale-placeholder" })
        )

        let result = await GenerationController.submit(
            request,
            editor: editor,
            quoteLoader: { _, input in
                pricedInput = input
                return money(1)
            }
        )

        guard case .success = result else {
            Issue.record("expected priced upscale submission, got \(result)")
            return
        }
        #expect(pricedInput?.durationSeconds == 7.25)
        #expect(pricedInput?.resolution == "8K")
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

    @Test("an unreadable brief does not take part in spend authorization")
    func unreadableBriefDoesNotAffectSpend() async throws {
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

        guard case .success = result else {
            Issue.record("expected dispatch, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
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

    @Test("concurrent requests each record their own reservation")
    func concurrentReservationsAreAllRecorded() async throws {
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
            generateAudio: true,
            referenceCount: 0
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

        let first = try await GenerationBudgetGuard.authorize(
            input: input,
            target: target,
            editor: editor,
            quoteLoader: { _, _ in money(6) }
        )
        let continuation = try #require(resumeQuote)
        continuation.resume()
        let second = try await delayed.value

        #expect(first.transactionId != second.transactionId)
        #expect(editor.generationLog.spendEvents.count == 2)
        #expect(Set(editor.generationLog.spendEvents.map(\.transactionId)).count == 2)
    }

    @Test("reruns use the same pre-dispatch ledger guard")
    func rerunStopsOnCorruptLedgerBeforeDispatch() async throws {
        let package = try project(stop: nil)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let workingRoot = try #require(editor.workingRoot)
        let logURL = workingRoot.appendingPathComponent(Project.generationLogFilename)
        let corrupt = Data("{\"version\":2,\"spendEvents\":[".utf8)
        try corrupt.write(to: logURL, options: .atomic)
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
            Issue.record("expected the rerun ledger guard to block")
        } catch let error as EditSubmitter.RerunError {
            guard case .budget(let message) = error else {
                Issue.record("expected a ledger failure, got \(error)")
                return
            }
            #expect(message.contains("generation-log.json"))
        }

        #expect(editor.mediaAssets.count == beforeAssets)
        #expect(try Data(contentsOf: logURL) == corrupt)
    }

    @Test("a trimmed upscale rerun prices and replays the recorded source range")
    func trimmedUpscaleRerunUsesRecordedRange() async throws {
        let package = try project(stop: nil)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let source = MediaAsset(
            id: "project-video",
            url: package.appendingPathComponent("source.mp4"),
            type: .video,
            name: "Source",
            duration: 60
        )
        editor.mediaAssets.append(source)
        var input = GenerationInput(
            prompt: "",
            model: "fal-ai/topaz/upscale/video",
            duration: 10,
            aspectRatio: "",
            resolution: nil
        )
        input.sourceVideoAssetId = source.id
        input.sourceRange = GenerationSourceRange(trim: GenerationSourceTrim(
            trimStartFrame: 240,
            trimEndFrame: 960,
            sourceFramesConsumed: 240,
            fps: 24
        ))
        let upscaled = MediaAsset(
            url: package.appendingPathComponent("upscaled.mp4"),
            type: .video,
            name: "Upscaled",
            duration: 10,
            generationInput: input
        )
        var pricedDuration: Double?

        do {
            _ = try await EditSubmitter.rerun(
                asset: upscaled,
                editor: editor,
                quoteLoader: { _, pricing in
                    pricedDuration = pricing.durationSeconds
                    throw CancellationError()
                }
            )
            Issue.record("expected the cancelled pricing to stop the rerun before dispatch")
        } catch let error as EditSubmitter.RerunError {
            guard case .budget = error else {
                Issue.record("expected a pre-dispatch failure, got \(error)")
                return
            }
        }

        #expect(pricedDuration == 10)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("an upscale without a recorded source range never substitutes the project source")
    func unrecordedTrimmedUpscaleRerunIsRefused() async throws {
        let package = try project(stop: nil)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let source = MediaAsset(
            id: "project-video",
            url: package.appendingPathComponent("source.mp4"),
            type: .video,
            name: "Source",
            duration: 60
        )
        editor.mediaAssets.append(source)
        var input = GenerationInput(
            prompt: "",
            model: "fal-ai/topaz/upscale/video",
            duration: 10,
            aspectRatio: "",
            resolution: nil
        )
        input.sourceVideoAssetId = source.id
        let upscaled = MediaAsset(
            url: package.appendingPathComponent("upscaled.mp4"),
            type: .video,
            name: "Upscaled",
            duration: 10,
            generationInput: input
        )
        var quoted = false

        do {
            _ = try await EditSubmitter.rerun(
                asset: upscaled,
                editor: editor,
                quoteLoader: { _, _ in
                    quoted = true
                    return money(1)
                }
            )
            Issue.record("expected the rerun without a recorded range or upload to be refused")
        } catch let error as EditSubmitter.RerunError {
            guard case .missingSource = error else {
                Issue.record("expected a missing source, got \(error)")
                return
            }
        }

        #expect(quoted == false)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test("an unpriced provider workflow is never blocked by a stored stop")
    func providerWorkflowRunsUnderStoredStop() throws {
        let package = try project(stop: 1)
        defer { cleanup(package) }
        let editor = editor(for: package)

        let authorization = try GenerationBudgetGuard.authorizeUnknownPaidOperation(
            modelId: "remove_background",
            provider: .openart,
            transport: .mcp,
            endpoint: "remove_background",
            editor: editor
        )

        #expect(authorization.transactionId != nil)
        #expect(authorization.estimate == nil)
        #expect(editor.generationLog.spendEvents.count == 1)
        #expect(editor.generationLog.spendEvents.first?.kind == .reserved)
        #expect(editor.generationLog.spendEvents.first?.money == nil)
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

    @Test("legacy credit rows stay unconverted and never block generation")
    func legacyCreditsNeverBlock() async throws {
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

        guard case .success = result else {
            Issue.record("expected dispatch despite legacy history, got \(result)")
            return
        }
        #expect(providerThunkExecuted)
        let workingRoot = try #require(editor.workingRoot)
        let persisted = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(Project.generationLogFilename))
        )
        let snapshot = try GenerationBudgetGuard.spendSnapshot(log: persisted, generatedInputs: [])
        #expect(snapshot.legacyGenerationCount == 1)
        #expect(!snapshot.isComplete)
        #expect(snapshot.verifiedEur == 0)
        #expect(snapshot.inFlightCount == 1)
    }

    @Test("an estimate on a run in flight is never booked as spend")
    func inFlightEstimateIsNotSpend() throws {
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

        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: log,
            generatedInputs: []
        )

        #expect(snapshot.verifiedEur == 0)
        #expect(snapshot.inFlightCount == 1)
        #expect(!snapshot.isComplete)
    }

    @Test("the billed charge replaces its reservation")
    func billedChargeReplacesReservation() throws {
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
                money: billed(4)
            ),
        ]

        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: log,
            generatedInputs: []
        )

        #expect(snapshot.verifiedEur == 4)
        #expect(snapshot.isComplete)
    }

    @Test("one ledger totals billed Bible work, frame roles and retakes; open runs stay in flight")
    func billedProjectSpendSnapshot() throws {
        func events(
            _ transaction: String,
            model: String,
            amount: Double,
            charged: Bool
        ) -> [GenerationSpendEvent] {
            var result = [GenerationSpendEvent(
                transactionId: transaction,
                kind: .reserved,
                model: model,
                provider: .fal,
                transport: .api,
                endpoint: model,
                money: money(amount)
            )]
            guard charged else { return result }
            result.append(GenerationSpendEvent(
                transactionId: transaction,
                kind: .submitted,
                model: model,
                provider: .fal,
                transport: .api,
                endpoint: model,
                providerRequestId: "request-\(transaction)",
                money: money(amount)
            ))
            result.append(GenerationSpendEvent(
                transactionId: transaction,
                kind: .charged,
                model: model,
                provider: .fal,
                transport: .api,
                endpoint: model,
                money: billed(amount, request: transaction)
            ))
            return result
        }

        let jobs = [
            ("bible-character", "image/bible", 1.0, true),
            ("lighting-anchor", "image/lighting", 2.0, true),
            ("frame-start", "image/frame", 3.0, true),
            ("frame-end", "image/frame", 4.0, true),
            ("retake-one", "video/final", 5.0, true),
            ("retake-two", "video/final", 6.0, true),
            ("unrecorded-render", "video/final", 7.0, false),
        ]
        var log = GenerationLog()
        log.spendEvents = jobs.flatMap {
            events($0.0, model: $0.1, amount: $0.2, charged: $0.3)
        }
        log.spendEvents += [
            GenerationSpendEvent(
                transactionId: "submitted-failure",
                kind: .reserved,
                model: "video/final",
                provider: .fal,
                transport: .api,
                endpoint: "video/final",
                money: money(8)
            ),
            GenerationSpendEvent(
                transactionId: "submitted-failure",
                kind: .submitted,
                model: "video/final",
                provider: .fal,
                transport: .api,
                endpoint: "video/final",
                providerRequestId: "failed-request",
                money: money(8),
                note: "Provider failed after accepting the request."
            ),
        ]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: log,
            generatedInputs: []
        )

        #expect(snapshot.verifiedEur == 21)
        #expect(!snapshot.isComplete)
        #expect(snapshot.inFlightCount == 2)
        #expect(snapshot.unknownCostCount == 0)
        #expect(snapshot.legacyGenerationCount == 0)
    }

    @Test("unknown and legacy costs make the project total incomplete")
    func incompleteProjectSpendSnapshot() throws {
        var log = GenerationLog()
        log.entries = [GenerationLogEntry(
            model: "legacy/image",
            costCredits: 50,
            createdAt: Date()
        )]
        log.spendEvents = [GenerationSpendEvent(
            transactionId: "unknown-render",
            kind: .reserved,
            model: "video/unknown",
            provider: .fal,
            transport: .api,
            endpoint: "video/unknown"
        )]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: log,
            generatedInputs: []
        )

        #expect(snapshot.verifiedEur == 0)
        #expect(!snapshot.isComplete)
        #expect(snapshot.inFlightCount == 1)
        #expect(snapshot.unknownCostCount == 0)
        #expect(snapshot.legacyGenerationCount == 1)
    }

    @Test("a finished run without a reported cost settles instead of staying open")
    func settledRunWithoutCostIsFinished() throws {
        var log = GenerationLog()
        log.spendEvents = [
            event("settled", .reserved, money: money(3)),
            event("settled", .submitted, money: money(3), request: "job"),
            event("settled", .settled),
        ]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(log: log, generatedInputs: [])
        let outcome = try #require(try GenerationSpendLedger.outcomes(log: log, generatedInputs: []).first)

        #expect(snapshot.inFlightCount == 0)
        #expect(snapshot.unknownCostCount == 1)
        #expect(snapshot.verifiedEur == 0)
        #expect(!snapshot.isComplete)
        #expect(outcome.status == .finished)
        #expect(outcome.billedMoney == nil)
        #expect(outcome.estimate?.eurAmount == 3)
    }

    @Test("provider credits are kept per provider in their own unit, never converted to money")
    func settledProviderCostsStayInProviderUnits() throws {
        let runway = GenerationProviderCost(amount: 120, unit: "credits", source: "runway task cost.credits")
        let marble = GenerationProviderCost(amount: 1500, unit: "credits", source: "marble operation cost.total_credits")
        var log = GenerationLog()
        log.spendEvents = [
            event("runway-a", .reserved, provider: .runway),
            event("runway-a", .submitted, provider: .runway, request: "task-a"),
            event("runway-a", .settled, provider: .runway, cost: runway),
            event("runway-b", .reserved, provider: .runway),
            event("runway-b", .submitted, provider: .runway, request: "task-b"),
            event("runway-b", .settled, provider: .runway, cost: runway),
            event("marble", .reserved, provider: .marble),
            event("marble", .submitted, provider: .marble, request: "operation"),
            event("marble", .settled, provider: .marble, cost: marble),
        ]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(log: log, generatedInputs: [])

        #expect(snapshot.verifiedEur == 0)
        #expect(snapshot.unknownCostCount == 0)
        let expected = [
            ProjectSpendSnapshot.ProviderCredits(provider: .runway, unit: "credits", amount: 240, runs: 2),
            ProjectSpendSnapshot.ProviderCredits(provider: .marble, unit: "credits", amount: 1500, runs: 1),
        ]
        #expect(snapshot.providerCredits == expected)
        #expect(snapshot.creditOnlyCount == 3)
        #expect(!snapshot.isComplete)
    }

    @Test("a late provider bill replaces a settlement without money")
    func lateBillReplacesUnknownSettlement() throws {
        var log = GenerationLog()
        log.spendEvents = [
            event("late", .reserved, money: money(2)),
            event("late", .submitted, money: money(2), request: "job"),
            event("late", .settled),
            event("late", .charged, money: billed(2.5, request: "job")),
        ]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(log: log, generatedInputs: [])

        #expect(snapshot.verifiedEur == 2.5)
        #expect(snapshot.unknownCostCount == 0)
        #expect(snapshot.isComplete)
        log.spendEvents.append(event("late", .settled))
        #expect(throws: GenerationBudgetError.self) {
            _ = try GenerationBudgetGuard.spendSnapshot(log: log, generatedInputs: [])
        }
    }

    @Test("an estimate booked as a charge by older builds is not counted as billed spend")
    func estimateChargeIsNotBilledSpend() throws {
        var log = GenerationLog()
        log.spendEvents = [
            event("estimate", .reserved, provider: .runway, money: money(1.2)),
            event("estimate", .submitted, provider: .runway, money: money(1.2), request: "task"),
            event("estimate", .charged, provider: .runway, money: money(1.2)),
        ]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(log: log, generatedInputs: [])
        let outcome = try #require(try GenerationSpendLedger.outcomes(log: log, generatedInputs: []).first)

        #expect(snapshot.verifiedEur == 0)
        #expect(snapshot.unknownCostCount == 1)
        #expect(outcome.status == .finished)
        #expect(outcome.estimate?.eurAmount == 1.2)
    }

    @Test("old open runs whose output or batch completed count as finished with unknown cost")
    func completedOldSubmittedRunsMigrateToFinished() throws {
        var log = GenerationLog()
        log.version = 2
        log.spendEvents = [
            event("asset-proven", .reserved),
            event("asset-proven", .submitted, request: "job-a"),
            event("batch-proven", .reserved, money: money(1)),
            event("batch-proven", .submitted, money: money(1), request: "job-b"),
            event("unproven", .reserved),
            event("unproven", .submitted, request: "job-c"),
        ]
        log.entries = [GenerationLogEntry(
            model: "fal/model",
            costCredits: nil,
            createdAt: Date(),
            spendTransactionId: "asset-proven"
        )]
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: log,
            generatedInputs: [],
            completedTransactionIDs: ["batch-proven"]
        )

        #expect(snapshot.unknownCostCount == 2)
        #expect(snapshot.inFlightCount == 1)
        #expect(snapshot.verifiedEur == 0)
        #expect(snapshot.legacyGenerationCount == 0)
    }

    @Test("settled runs stamp log version 3; logs without them keep version 2")
    func settledLogVersionIsStampedOnlyWhenNeeded() async throws {
        var plain = GenerationLog()
        plain.spendEvents = [event("plain", .reserved, money: money(1))]
        plain.stampVersion()
        #expect(plain.version == 2)

        let package = try project(stop: nil)
        defer { cleanup(package) }
        let editor = editor(for: package)
        let authorization = try await GenerationBudgetGuard.authorize(
            input: GenerationPricingInput(
                modelId: "fal-ai/veo3",
                modality: .video,
                durationSeconds: 5,
                outputCount: 1,
                resolution: nil,
                quality: nil,
                promptCharacterCount: 5,
                generateAudio: true,
                referenceCount: 0
            ),
            target: GenerationService.dispatchTarget(modelId: "fal-ai/veo3"),
            editor: editor,
            quoteLoader: { _, _ in money(2) }
        )
        #expect(editor.generationLog.version == 2)
        try editor.recordSpendEvent(authorization: authorization, kind: .submitted,
            providerRequestId: "job", money: authorization.estimate)
        try editor.recordSpendEvent(authorization: authorization, kind: .settled,
            providerCost: GenerationProviderCost(amount: 7, unit: "credits", source: "fixture"))
        #expect(editor.generationLog.version == 3)
        let workingRoot = try #require(editor.workingRoot)
        let persisted = try JSONDecoder().decode(
            GenerationLog.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent(Project.generationLogFilename))
        )
        #expect(persisted.version == 3)
        #expect(try GenerationBudgetGuard.spendSnapshot(log: persisted, generatedInputs: []).providerCredits.count == 1)

        var future = persisted
        future.version = 4
        #expect(throws: GenerationBudgetError.self) {
            _ = try GenerationBudgetGuard.spendSnapshot(log: future, generatedInputs: [])
        }
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
            try GenerationBudgetGuard.validateLedger(
                log: log,
                generatedAssets: []
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
