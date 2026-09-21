import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Generation batch single-use execution")
@MainActor
struct GenerationBatchTests {
    @MainActor
    private final class PendingQuoteFixture {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var didStart = false

        func quote(
            _ target: ResolvedGenerationTarget,
            _ input: GenerationPricingInput
        ) async -> GenerationMoney {
            _ = target
            _ = input
            didStart = true
            await withCheckedContinuation { continuation = $0 }
            return GenerationPackageFixture.money(0.40)
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func runwayInput(
        _ model: String,
        count: Int = 1,
        quality: String? = nil,
        references: Int = 0
    ) -> GenerationPricingInput {
        GenerationPricingInput(
            modelId: "runway/\(model)",
            modality: .image,
            durationSeconds: nil,
            outputCount: count,
            resolution: nil,
            quality: quality,
            promptCharacterCount: 1,
            generateAudio: nil,
            referenceCount: references
        )
    }

    private func fixture() async throws -> (URL, EditorViewModel, GenerationBatch) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-batch-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        let editor = EditorViewModel()
        editor.projectURL = root
        let (generation, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let references = try #require(generation.references)
        try await GenerationPackageInputs.persist(package: package, snapshot: references, editor: editor)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey,
            phase: nil, items: (0..<3).map { index in
                .init(id: UUID().uuidString, purpose: "Character view \(index + 1)", package: package)
            }))
        return (root, editor, batch)
    }

    private func cleanup(_ root: URL) {
        if let projectKey = ProjectIdentity.existingUUID(for: root),
           let authority = try? GenerationExecutionAuthorityStore.live(),
           let records = try? authority.all(projectKey: projectKey) {
            for record in records { try? authority.removeForTesting(projectKey: projectKey, batchID: record.batch.id) }
        }
        if let key = ProjectIdentity.existingKey(for: root) { ProjectWorkingCopy.discard(key: key) }
        try? FileManager.default.removeItem(at: root)
    }

    private func placeholders(_ item: GenerationBatch.Item, transaction: String) -> [MediaManifestEntry] {
        var input = item.package.payload.generationInput
        input.spendTransactionId = transaction
        input.generationPackageID = item.package.id
        let root = URL(fileURLWithPath: "/fixture.ngv")
        return (0..<item.package.payload.outputCount).map { index in
            MediaAsset(id: "output-\(item.id)-\(index)", url: root.appendingPathComponent(Project.mediaDirectoryName + "/fixture-\(index).png"),
                type: .image, name: item.purpose, duration: 1, generationInput: input).toManifestEntry(projectURL: root)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() { await Task.yield() }
    }

    @Test func reviewProjectionGroupsAndNumbersOneThirteenAndFiftyItems() async throws {
        let (root, _, fixtureBatch) = try await fixture()
        defer { cleanup(root) }
        let package = fixtureBatch.payload.items[0].package
        let thirteenPurposes = [
            "Character Mara — front",
            "Character Mara — profile",
            "Ensemble Band — wide",
            "Location Rooftop — dusk",
            "Location Stairwell — landing",
            "Prop Microphone — hero",
            "Prop Cassette recorder — continuity",
            "Look Lighting anchor",
            "Character Drummer — front",
            "Character Guitarist — front",
            "Location Corridor — long lens",
            "Prop Silver lighter — insert",
            "Unclassified texture study",
        ]
        for count in [1, 13, 50] {
            let purposes = (0..<count).map { thirteenPurposes[$0 % thirteenPurposes.count] }
            let batch = try GenerationBatch(payload: .init(
                nonce: UUID(),
                projectKey: package.payload.binding.projectKey,
                phase: nil,
                items: purposes.map {
                    .init(id: UUID().uuidString, purpose: $0, package: package)
                }
            ))
            let projection = GenerationBatchReviewProjection(
                batch: batch,
                modelName: { _ in "Fixture image" }
            )
            #expect(projection.itemCount == count)
            #expect(projection.sections.flatMap(\.items).count == count)
            #expect(projection.sections.flatMap(\.items).map(\.manifestIndex).sorted() == Array(0..<count))
            #expect(projection.routes == [
                .init(id: projection.routes[0].id, label: "Fixture image · fal.ai API", count: count),
            ])
            #expect(projection.commonOutputCount == 1)
            #expect(projection.commonDestinationLabel == "Media library")
            #expect(projection.totalEUR == batch.totalEUR)
            #expect(projection.unknownPriceCount == 0)
        }
        let thirteen = try GenerationBatch(payload: .init(
            nonce: UUID(),
            projectKey: package.payload.binding.projectKey,
            phase: nil,
            items: thirteenPurposes.map {
                .init(id: UUID().uuidString, purpose: $0, package: package)
            }
        ))
        let projection = GenerationBatchReviewProjection(
            batch: thirteen,
            modelName: { _ in "Fixture image" }
        )
        #expect(projection.sections.map(\.group) == [.character, .ensemble, .location, .prop, .look, .other])
        #expect(projection.sections.first(where: { $0.group == .character })?.items.map(\.manifestIndex) == [0, 1, 8, 9])
        #expect(try GenerationBatch(payload: thirteen.payload) == thirteen)
    }

    @Test func recoveryBlocksApprovalButNeverRemoveOrDecline() {
        let controls = GenerationBatchReviewControls(
            hasVerifiedTotal: true,
            hasRetryablePricingFailure: true,
            isCommitting: false,
            isRecovering: true
        )
        #expect(controls.canEdit)
        #expect(!controls.canRetryPricing)
        #expect(!controls.canApprove)
        let committing = GenerationBatchReviewControls(
            hasVerifiedTotal: true,
            hasRetryablePricingFailure: false,
            isCommitting: true,
            isRecovering: false
        )
        #expect(!committing.canEdit)
        #expect(!committing.canApprove)
    }

    @Test func removingARecoveringUnknownItemKeepsThePricedRemainderAtomic() async throws {
        let (root, editor, pricedBatch) = try await fixture()
        defer { cleanup(root) }
        let first = pricedBatch.payload.items[0]
        let unpriced = try first.package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .priceQueryUnavailable,
                provider: first.package.payload.target.provider,
                endpoint: first.package.payload.target.endpoint,
                detail: "fixture pricing outage"
            )
        )
        let snapshot = try await GenerationPackageInputs.restore(package: first.package, editor: editor)
        try await GenerationPackageInputs.persist(package: unpriced, snapshot: snapshot, editor: editor)
        let batch = try pricedBatch.replacingPackage(itemID: first.id, with: unpriced)
        let recoveries = Dictionary(uniqueKeysWithValues: batch.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        try editor.generationBatchCoordinator.present(batch, recoveries: recoveries)
        let quote = PendingQuoteFixture()
        let retry = Task { @MainActor in
            await editor.generationBatchCoordinator.retryPricing(
                editor: editor,
                quoteLoader: quote.quote
            )
        }
        await waitUntil { quote.didStart }
        #expect(editor.generationBatchCoordinator.recoveringItemIDs.contains(first.id))
        editor.generationBatchCoordinator.remove(itemID: first.id, editor: editor)
        let reduced = try #require(editor.generationBatchCoordinator.pending)
        #expect(reduced.id != batch.id)
        #expect(reduced.payload.items.count == 2)
        #expect(reduced.totalEUR == 0.50)
        #expect(!editor.generationBatchCoordinator.recoveringItemIDs.contains(first.id))
        quote.finish()
        await retry.value
        #expect(editor.generationBatchCoordinator.pending == reduced)
        #expect(editor.generationBatchCoordinator.error == nil)
        #expect(!editor.generationBatchCoordinator.isRecovering)
    }

    @Test func removingTheLastItemResolvesWithoutAnEmptyManifest() async throws {
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let item = batch.payload.items[0]
        let single = try GenerationBatch(payload: .init(
            nonce: batch.payload.nonce,
            projectKey: batch.payload.projectKey,
            phase: batch.payload.phase,
            items: [item],
            requestSHA256: batch.payload.requestSHA256
        ))
        let recovery = GenerationBatchRecovery(options: []) { _, _ in item.package }
        try editor.generationBatchCoordinator.present(single, recoveries: [item.id: recovery])
        editor.generationBatchCoordinator.remove(itemID: item.id, editor: editor)
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(!editor.generationBatchCoordinator.isRecovering)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func declineResolvesImmediatelyWhilePricingRecoveryFinishesInTheBackground() async throws {
        let (root, editor, pricedBatch) = try await fixture()
        defer { cleanup(root) }
        let first = pricedBatch.payload.items[0]
        let unpriced = try first.package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .priceQueryUnavailable,
                provider: first.package.payload.target.provider,
                endpoint: first.package.payload.target.endpoint,
                detail: "fixture pricing outage"
            )
        )
        let snapshot = try await GenerationPackageInputs.restore(package: first.package, editor: editor)
        try await GenerationPackageInputs.persist(package: unpriced, snapshot: snapshot, editor: editor)
        let batch = try pricedBatch.replacingPackage(itemID: first.id, with: unpriced)
        let recoveries = Dictionary(uniqueKeysWithValues: batch.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        try editor.generationBatchCoordinator.present(batch, recoveries: recoveries)
        let quote = PendingQuoteFixture()
        let retry = Task { @MainActor in
            await editor.generationBatchCoordinator.retryPricing(
                editor: editor,
                quoteLoader: quote.quote
            )
        }
        await waitUntil { quote.didStart }
        editor.generationBatchCoordinator.decline(editor: editor)
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(!editor.generationBatchCoordinator.isRecovering)
        #expect(editor.generationBatchCoordinator.error == nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
        quote.finish()
        await retry.value
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(editor.generationBatchCoordinator.error == nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func changedManifestAndDeclineStayBoundToTheOriginConversation() async throws {
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let service = editor.agentService
        service.newChat()
        let originSessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: originSessionID,
            mcpSessionID: UUID()
        )
        let recoveries = Dictionary(uniqueKeysWithValues: batch.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        let suspended = try service.presentGenerationBatch(
            batch,
            recoveries: recoveries,
            origin: origin,
            editor: editor
        )
        let marker = try #require(suspended.content.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }.first)
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(toolUseId: "batch-tool", content: [.text(marker)], isError: false),
        ])]
        service.newChat()
        let otherSessionID = try #require(service.currentSessionId)
        editor.generationBatchCoordinator.remove(
            itemID: batch.payload.items[1].id,
            editor: editor
        )
        let changed = try #require(editor.generationBatchCoordinator.pending)
        #expect(changed.id != batch.id)
        editor.generationBatchCoordinator.decline(editor: editor)
        #expect(service.currentSessionId == otherSessionID)
        let originSession = try #require(service.sessions.first { $0.id == originSessionID })
        let result = originSession.messages.flatMap(\.blocks).compactMap { block -> [ToolResult.Block]? in
            guard case .toolResult(let id, let content, let isError) = block,
                  id == "batch-tool", !isError else { return nil }
            return content
        }.first
        #expect(result?.contains(where: { block in
            guard case .text(let text) = block else { return false }
            return text == "The user declined the generation batch. No batch item was submitted."
        }) == true)
        #expect(service.sessionAttention(for: originSessionID) == .unreadResult)
    }

    @Test func duplicateSubmissionsCannotReuseAnItemOrAnotherItemsReservation() async throws {
        let (root, _, batch) = try await fixture()
        defer { cleanup(root) }
        var journal = try GenerationBatchJournal(approving: batch, authorityID: "test-authority")
        let first = batch.payload.items[0], second = batch.payload.items[1]
        try journal.beginSubmission(itemID: first.id, packageID: first.package.id, transactionID: "one", placeholders: placeholders(first, transaction: "one"), batch: batch)
        #expect(throws: (any Error).self) {
            try journal.beginSubmission(itemID: first.id, packageID: first.package.id, transactionID: "two", placeholders: placeholders(first, transaction: "two"), batch: batch)
        }
        #expect(throws: (any Error).self) {
            try journal.beginSubmission(itemID: second.id, packageID: second.package.id, transactionID: "one", placeholders: placeholders(second, transaction: "one"), batch: batch)
        }
        try journal.recordProviderRequest(itemID: first.id, transactionID: "one", requestID: "provider-one")
        let revision = journal.revision
        try journal.recordProviderRequest(itemID: first.id, transactionID: "one", requestID: "provider-one")
        #expect(journal.revision == revision)
        try journal.finish(itemID: first.id, outputAssetIDs: placeholders(first, transaction: "one").map(\.id), batch: batch)
        #expect(throws: (any Error).self) {
            try journal.beginSubmission(itemID: first.id, packageID: first.package.id, transactionID: "three", placeholders: placeholders(first, transaction: "three"), batch: batch)
        }
        try journal.validate(batch: batch)
    }

    @Test func batchPreparationCannotDispatchEvenWhenTheSingleRequestWouldAutoApprove() async throws {
        let (root, editor, _) = try await fixture()
        defer { cleanup(root) }
        let (generation, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let collector = GenerationBatchPreparation()
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)
        let option = SpendOption(modelId: package.payload.target.modelId, modelName: "Fixture", target: package.payload.target,
            credits: 0, requiresCatalogAvailability: false)
        var dispatches = 0
        _ = try await GenerationBatchPreparation.$current.withValue(collector) {
            try await executor.withSpendApproval(editor, currentModelId: option.modelId, currentModelName: option.modelName,
                credits: 0, actionLabel: "Generate", selectionScope: .image, pipelineTool: .generateImage,
                origin: .direct, alternatives: { [] }, exactOptions: { [option] }, recommendedTarget: option.target,
                prepare: { _, _ in
                    AgentPreparedGeneration(package: package, generation: generation) {
                        dispatches += 1
                        return .ok("unexpected paid submission")
                    }
                })
        }
        #expect(dispatches == 0)
        #expect(collector.entries.map { $0.package } == [package])
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.agentService.pendingSpendApproval == nil)
    }

    @Test func cancellationKeepsSubmittedWorkAndFailureDoesNotConsumeOtherItems() async throws {
        let (root, _, batch) = try await fixture()
        defer { cleanup(root) }
        var journal = try GenerationBatchJournal(approving: batch, authorityID: "test-authority")
        let first = batch.payload.items[0], second = batch.payload.items[1]
        try journal.beginSubmission(itemID: first.id, packageID: first.package.id, transactionID: "one", placeholders: placeholders(first, transaction: "one"), batch: batch)
        try journal.stop(itemID: second.id, state: .blocked, detail: "The exact route is unavailable.")
        #expect(journal.executions[2].state == .queued)
        journal.cancelRemaining()
        #expect(journal.executions.map(\.state) == [.submitting, .blocked, .canceled])
        try journal.recordProviderRequest(itemID: first.id, transactionID: "one", requestID: "provider-one")
        try journal.finish(itemID: first.id, outputAssetIDs: placeholders(first, transaction: "one").map(\.id), batch: batch)
        try journal.validate(batch: batch)
    }

    @Test func reopeningKeepsConsumptionAndStaleWritersCannotRewindIt() async throws {
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let initial = try await GenerationBatchStore.approve(batch, editor: editor)
        let home = try #require(editor.workingRoot)
        let manifestURL = home.appendingPathComponent("generation-batches/\(batch.id)/manifest.json")
        let immutableManifest = try Data(contentsOf: manifestURL)
        let item = batch.payload.items[0]
        let submitting = try GenerationBatchStore.update(initial, editor: editor) {
            try $0.beginSubmission(itemID: item.id, packageID: item.package.id, transactionID: "one", placeholders: placeholders(item, transaction: "one"), batch: batch)
        }
        #expect(try Data(contentsOf: manifestURL) == immutableManifest)
        #expect(try GenerationBatchStore.load(id: batch.id, home: home) == submitting)
        #expect(try await GenerationBatchStore.approve(batch, editor: editor) == submitting)
        #expect(throws: (any Error).self) {
            try GenerationBatchStore.update(initial, editor: editor) { $0.cancelRemaining() }
        }
        let resumed = try GenerationBatchStore.update(submitting, editor: editor) {
            try $0.recordProviderRequest(itemID: item.id, transactionID: "one", requestID: "provider-one")
        }
        #expect(resumed.journal.executions[0].state == .running)
        #expect(try GenerationBatchStore.all(home: home).count == 1)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func removalChangesTheApprovalIdentity() async throws {
        let (root, _, batch) = try await fixture()
        defer { cleanup(root) }
        let changed = try batch.removing(itemIDs: [batch.payload.items[0].id])
        #expect(changed.id != batch.id)
        #expect(changed.payload.items.count == 2)
        #expect(changed.totalEUR == 0.5)
        let journal = try GenerationBatchJournal(approving: batch, authorityID: "test-authority")
        #expect(throws: (any Error).self) { try journal.validate(batch: changed) }
    }

    @Test func cancelingQueuedItemsDoesNotInvalidateAnotherItemsCompletion() async throws {
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let initial = try await GenerationBatchStore.approve(batch, editor: editor)
        let home = try #require(editor.workingRoot)
        let first = batch.payload.items[0]
        let outputs = placeholders(first, transaction: "running")
        #expect(throws: (any Error).self) {
            try GenerationBatchStore.updateExecution(initial, itemID: first.id, editor: editor) { $0.cancelRemaining() }
        }
        #expect(try GenerationBatchStore.load(id: batch.id, home: home) == initial)
        let running = try GenerationBatchStore.update(initial, editor: editor) {
            try $0.beginSubmission(itemID: first.id, packageID: first.package.id,
                transactionID: "running", placeholders: outputs, batch: batch)
            try $0.recordProviderRequest(itemID: first.id, transactionID: "running", requestID: "provider-job")
        }
        _ = try GenerationBatchStore.update(running, editor: editor) { $0.cancelRemaining() }
        let completed = try GenerationBatchStore.updateExecution(running, itemID: first.id, editor: editor) {
            try $0.finish(itemID: first.id, outputAssetIDs: outputs.map(\.id), batch: batch)
        }
        #expect(completed.journal.executions.map(\.state) == [.complete, .canceled, .canceled])
        #expect(throws: (any Error).self) {
            try GenerationBatchStore.updateExecution(running, itemID: first.id, editor: editor) {
                try $0.stop(itemID: first.id, state: .blocked, detail: "stale completion")
            }
        }
        #expect(throws: (any Error).self) {
            try GenerationBatchStore.updateExecution(initial, itemID: first.id, editor: editor) { $0.cancelRemaining() }
        }
    }

    @Test func partialOutputsRetainExactBytesAcrossInterruptedJobs() async throws {
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let initial = try await GenerationBatchStore.approve(batch, editor: editor)
        let home = try #require(editor.workingRoot)
        let item = batch.payload.items[0]
        let entries = placeholders(item, transaction: "partial")
        let submitted = try GenerationBatchStore.update(initial, editor: editor) {
            try $0.beginSubmission(itemID: item.id, packageID: item.package.id,
                transactionID: "partial", placeholders: entries, batch: batch)
            try $0.recordProviderRequest(itemID: item.id, transactionID: "partial",
                requestID: "recorded-job", resumable: true)
        }
        let entry = try #require(entries.first)
        guard case .project(let path) = entry.source else { Issue.record("Expected a project output"); return }
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("completed provider output".utf8).write(to: url)
        let asset = MediaAsset(entry: entry, resolvedURL: url)
        editor.mediaAssets.append(asset)
        let authorization = GenerationBatchAuthorization(batchID: batch.id, itemID: item.id)
        try await GenerationBatchOutput.record(asset: asset, authorization: authorization, editor: editor)
        let receipt = try #require(try GenerationBatchOutput.load(
            authorization: authorization,
            assetID: entry.id,
            home: home
        ))
        try await GenerationBatchOutput.record(asset: asset, authorization: authorization, editor: editor)
        _ = try GenerationBatchStore.update(submitted, editor: editor) {
            try $0.stop(itemID: item.id, state: .blocked, detail: "Connection interrupted after download")
        }
        let restored = try await Task.detached {
            try GenerationBatchOutput.load(authorization: authorization, assetID: entry.id, home: home)
        }.value
        #expect(restored == receipt)
        #expect(try GenerationBatchOutput.load(authorization: authorization, assetID: "another-output", home: home) == nil)
        let substitute = home.appendingPathComponent(Project.mediaDirectoryName + "/substitute.png")
        try Data("another output".utf8).write(to: substitute)
        asset.url = substitute
        await #expect(throws: (any Error).self) { try await authorization.settle(editor: editor) }
        asset.url = url
        try await authorization.settle(editor: editor)
        let settled = try GenerationBatchStore.load(id: batch.id, home: home)
        #expect(settled.journal.executions[0].state == .complete)
        #expect(settled.journal.executions[0].detail == nil)
        #expect(settled.journal.executions.dropFirst().allSatisfy { $0.state == .queued })
        try Data("replaced bytes".utf8).write(to: url, options: .atomic)
        #expect(throws: (any Error).self) {
            try GenerationBatchOutput.load(authorization: authorization, assetID: entry.id, home: home)
        }
    }

    @Test func unknownPricingCannotCreateAnUnattendedAuthorization() async throws {
        let (root, _, batch) = try await fixture()
        defer { cleanup(root) }
        let original = batch.payload.items[0].package
        var payloadJSON = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(original.payload)) as? [String: Any])
        payloadJSON.removeValue(forKey: "estimate")
        let payload = try JSONDecoder().decode(GenerationPackageV1.Payload.self, from: JSONSerialization.data(withJSONObject: payloadJSON))
        let unpriced = try GenerationPackageV1(payload: payload)
        let manifest = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: batch.payload.projectKey, phase: nil,
            items: [.init(id: UUID().uuidString, purpose: "Unpriced generation", package: unpriced)]))
        #expect(manifest.totalEUR == nil)
        #expect(throws: (any Error).self) { try GenerationBatchJournal(approving: manifest, authorityID: "test-authority") }
    }

    @Test func thirteenGeminiRequestsHaveOneExactReviewTotalAndApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-gemini-batch-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        defer { cleanup(root) }
        let editor = EditorViewModel()
        editor.projectURL = root
        let (generation, package) = try await GenerationPackageFixture.prepare(
            editor: editor,
            model: "runway/gemini_image3_pro",
            provider: .runway,
            endpoint: "runway/gemini_image3_pro"
        )
        let input = try package.pricingInput()
        #expect(LiveGenerationPricing.runwayCredits(endpoint: package.payload.target.endpoint, input: input) == 20)
        let unsupported4K = GenerationPricingInput(
            modelId: input.modelId,
            modality: input.modality,
            durationSeconds: input.durationSeconds,
            outputCount: input.outputCount,
            resolution: "4K",
            quality: input.quality,
            promptCharacterCount: input.promptCharacterCount,
            generateAudio: input.generateAudio,
            referenceCount: input.referenceCount
        )
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: package.payload.target.endpoint,
            input: unsupported4K
        ) == nil)
        let verifiedPackage = try package.replacingPricing(
            estimate: .init(
                nativeAmount: 0.20,
                nativeCurrency: "USD",
                eurAmount: 0.18,
                eurPerNativeUnit: 0.90,
                exchangeRateDate: "2026-09-21",
                pricingSource: "https://docs.dev.runwayml.com/guides/pricing/",
                exchangeRateSource: "fixture://ecb"
            ),
            failure: nil
        )
        let references = try #require(generation.references)
        try await GenerationPackageInputs.persist(package: verifiedPackage, snapshot: references, editor: editor)
        let items = (0..<13).map {
            GenerationBatch.Item(id: UUID().uuidString, purpose: "Bible view \($0 + 1)", package: verifiedPackage)
        }
        let batch = try GenerationBatch(payload: .init(
            nonce: UUID(),
            projectKey: verifiedPackage.payload.binding.projectKey,
            phase: "bible",
            items: items
        ))
        #expect(batch.payload.items.allSatisfy { $0.package.payload.estimate?.eurAmount == 0.18 })
        #expect(abs((batch.totalEUR ?? 0) - 2.34) < 0.000_001)
        let journal = try GenerationBatchJournal(approving: batch, authorityID: "one-user-approval")
        try journal.validate(batch: batch)
        #expect(journal.executions.count == 13)
        #expect(journal.executions.allSatisfy { $0.state == .queued })
    }

    @Test func officialRunwayImagePricesCoverExactExecutableOptions() {
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/gen4_image_turbo",
            input: runwayInput("gen4_image_turbo")
        ) == 2)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/gen4_image",
            input: runwayInput("gen4_image")
        ) == 8)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/gpt_image_2",
            input: runwayInput("gpt_image_2", count: 4, quality: "high")
        ) == 80)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/seedream5_pro",
            input: runwayInput("seedream5_pro", count: 4)
        ) == 20)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/seedream5_lite",
            input: runwayInput("seedream5_lite", count: 4)
        ) == 16)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/grok_imagine_image_2",
            input: runwayInput("grok_imagine_image_2", count: 4, quality: "medium", references: 2)
        ) == 26)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/grok_imagine_image_2",
            input: runwayInput("grok_imagine_image_2", quality: "low")
        ) == 6)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/gemini_image3_pro",
            input: runwayInput("gemini_image3_pro")
        ) == 20)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/gemini_2.5_flash",
            input: runwayInput("gemini_2.5_flash")
        ) == 5)
        #expect(LiveGenerationPricing.runwayCredits(
            endpoint: "runway/gemini_image3.1_flash",
            input: runwayInput("gemini_image3.1_flash")
        ) == nil)
    }

    @Test func unpricedItemsCanBeRemovedAndTheBatchCanStillBeDeclined() async throws {
        let (root, editor, original) = try await fixture()
        defer { cleanup(root) }
        let unpriced = try original.payload.items[0].package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .unsupportedCombination,
                provider: original.payload.items[0].package.payload.target.provider,
                endpoint: original.payload.items[0].package.payload.target.endpoint,
                detail: "fixture unsupported options"
            )
        )
        let batch = try original.replacingPackage(
            itemID: original.payload.items[0].id,
            with: unpriced
        )
        let recoveries = Dictionary(uniqueKeysWithValues: batch.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        try editor.generationBatchCoordinator.present(batch, recoveries: recoveries)
        #expect(editor.generationBatchCoordinator.pending?.totalEUR == nil)
        editor.generationBatchCoordinator.remove(
            itemID: batch.payload.items[0].id,
            editor: editor
        )
        let reduced = try #require(editor.generationBatchCoordinator.pending)
        #expect(reduced.id != batch.id)
        #expect(reduced.payload.items.count == 2)
        #expect(reduced.totalEUR == 0.50)
        editor.generationBatchCoordinator.decline(editor: editor)
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(!editor.generationBatchCoordinator.isRecovering)
    }

    @Test func pricingRetryRebindsPackageAndManifestWithoutDispatch() async throws {
        let (root, editor, pricedBatch) = try await fixture()
        defer { cleanup(root) }
        let originalItem = pricedBatch.payload.items[0]
        let unpricedPackage = try originalItem.package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .exchangeRateUnavailable,
                provider: nil,
                endpoint: "fixture://ecb",
                detail: "fixture exchange outage"
            )
        )
        let snapshot = try await GenerationPackageInputs.restore(package: originalItem.package, editor: editor)
        try await GenerationPackageInputs.persist(package: unpricedPackage, snapshot: snapshot, editor: editor)
        let item = GenerationBatch.Item(id: originalItem.id, purpose: originalItem.purpose, package: unpricedPackage)
        let batch = try GenerationBatch(payload: .init(
            nonce: pricedBatch.payload.nonce,
            projectKey: pricedBatch.payload.projectKey,
            phase: pricedBatch.payload.phase,
            items: [item],
            requestSHA256: pricedBatch.payload.requestSHA256
        ))
        var routePreparations = 0
        let recovery = GenerationBatchRecovery(options: []) { _, _ in
            routePreparations += 1
            return unpricedPackage
        }
        try editor.generationBatchCoordinator.present(batch, recoveries: [item.id: recovery])
        await editor.generationBatchCoordinator.retryPricing(
            editor: editor,
            quoteLoader: { _, _ in GenerationPackageFixture.money(0.40) }
        )
        let rebound = try #require(editor.generationBatchCoordinator.pending)
        #expect(rebound.id != batch.id)
        #expect(rebound.payload.items[0].package.id != unpricedPackage.id)
        #expect(rebound.payload.items[0].package.payload.estimate?.eurAmount == 0.40)
        #expect(rebound.payload.items[0].package.payload.pricingFailure == nil)
        #expect(rebound.payload.items[0].package.payload.requestParametersJSON
            == unpricedPackage.payload.requestParametersJSON)
        #expect(rebound.payload.items[0].package.payload.references
            == unpricedPackage.payload.references)
        #expect(rebound.payload.requestSHA256 == batch.payload.requestSHA256)
        #expect(routePreparations == 0)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
        let oldApprovedBatch = try batch.replacingPackage(
            itemID: item.id,
            with: originalItem.package
        )
        let oldJournal = try GenerationBatchJournal(
            approving: oldApprovedBatch,
            authorityID: "old-review"
        )
        #expect(throws: (any Error).self) { try oldJournal.validate(batch: rebound) }
    }

    @Test func explicitRouteChangeRepreparesAndRebindsWithoutDispatch() async throws {
        let (root, editor, pricedBatch) = try await fixture()
        defer { cleanup(root) }
        let originalItem = pricedBatch.payload.items[0]
        let unpricedPackage = try originalItem.package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .unsupportedCombination,
                provider: originalItem.package.payload.target.provider,
                endpoint: originalItem.package.payload.target.endpoint,
                detail: "fixture unsupported options"
            )
        )
        let originalSnapshot = try await GenerationPackageInputs.restore(
            package: originalItem.package,
            editor: editor
        )
        try await GenerationPackageInputs.persist(
            package: unpricedPackage,
            snapshot: originalSnapshot,
            editor: editor
        )
        let (replacementGeneration, replacementPackage) = try await GenerationPackageFixture.prepare(
            editor: editor,
            model: "alternate-image",
            provider: .runway,
            endpoint: "runway/gen4_image"
        )
        let option = SpendOption(
            modelId: replacementPackage.payload.target.modelId,
            modelName: "Alternate image",
            target: replacementPackage.payload.target,
            credits: 8,
            requiresCatalogAvailability: false
        )
        var preparations = 0
        let recovery = GenerationBatchRecovery(options: [option]) { editor, selected in
            #expect(selected.id == option.id)
            preparations += 1
            try await GenerationPackageInputs.persist(
                package: replacementPackage,
                snapshot: #require(replacementGeneration.references),
                editor: editor
            )
            return replacementPackage
        }
        let item = GenerationBatch.Item(
            id: originalItem.id,
            purpose: originalItem.purpose,
            package: unpricedPackage
        )
        let batch = try GenerationBatch(payload: .init(
            nonce: pricedBatch.payload.nonce,
            projectKey: pricedBatch.payload.projectKey,
            phase: pricedBatch.payload.phase,
            items: [item],
            requestSHA256: pricedBatch.payload.requestSHA256
        ))
        try editor.generationBatchCoordinator.present(batch, recoveries: [item.id: recovery])
        await editor.generationBatchCoordinator.changeRoute(itemID: item.id, option: option, editor: editor)
        let rebound = try #require(editor.generationBatchCoordinator.pending)
        #expect(preparations == 1)
        #expect(rebound.id != batch.id)
        #expect(rebound.payload.items[0].package.id == replacementPackage.id)
        #expect(rebound.payload.items[0].package.payload.target == option.target)
        #expect(rebound.payload.items[0].package.payload.requestParametersJSON
            == replacementPackage.payload.requestParametersJSON)
        #expect(rebound.payload.requestSHA256 == batch.payload.requestSHA256)
        #expect(rebound.totalEUR == replacementPackage.payload.estimate?.eurAmount)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test func changedArchivedInputsCannotResumeUnderTheOriginalPackage() async throws {
        let (root, editor, _) = try await fixture()
        defer { cleanup(root) }
        let home = try #require(editor.workingRoot)
        let media = home.appendingPathComponent(Project.mediaDirectoryName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = media.appendingPathComponent("reference.png")
        try Data("original reference bytes".utf8).write(to: source)
        let reference = MediaAsset(id: "reference", url: source, type: .image, name: "Reference", duration: 1)
        editor.mediaAssets.append(reference)
        let target = ResolvedGenerationTarget(modelId: "fixture-image", provider: .fal, endpoint: "fixture-image", binding: nil)
        let request = GenerationRequest(modality: .image, modelId: target.modelId, intent: "", aspectRatio: "1:1",
            placement: .mediaLibrary(folderId: nil), origin: .panel, target: target, submission: .image { prompt in
                ImageGenerationSubmission(genInput: .init(prompt: prompt, model: target.modelId, duration: 0, aspectRatio: "1:1"),
                    references: [reference], name: "View", numImages: 1, folderId: nil,
                    buildParams: {
                        .image(.init(
                            prompt: prompt,
                            aspectRatio: "1:1",
                            resolution: nil,
                            quality: nil,
                            imageURLs: $0,
                            numImages: 1
                        ))
                    })
            })
        let generation = try await GenerationController.prepare(request, editor: editor).get()
        let package = try await GenerationController.prepareReviewPackage(generation, editor: editor,
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        try await GenerationPackageInputs.persist(package: package, snapshot: #require(generation.references), editor: editor)
        let restored = try await GenerationPackageInputs.restore(package: package, editor: editor)
        #expect(restored.receipts == package.payload.references)
        let parameters = try package.restoreParameters()
        #expect(try GenerationPackageV1.requestJSON(parameters: parameters, references: restored.receipts) == package.payload.requestParametersJSON)
        let archived = media.appendingPathComponent("generation-inputs/\(package.id)/0.png")
        try Data("changed archived bytes".utf8).write(to: archived, options: .atomic)
        await #expect(throws: (any Error).self) { try await GenerationPackageInputs.restore(package: package, editor: editor) }
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func hostAuthorityRestoresAnOlderProjectWithoutReissuingApproval() async throws {
        let (root, editor, batch) = try await fixture()
        let authorityRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-authority-\(UUID().uuidString)")
        let authority = try GenerationExecutionAuthorityStore(root: authorityRoot, hostID: UUID().uuidString)
        defer {
            cleanup(root)
            try? FileManager.default.removeItem(at: authorityRoot)
        }
        let approved = try await GenerationBatchStore.approve(batch, editor: editor, authority: authority)
        let home = try #require(editor.workingRoot)
        let item = batch.payload.items[0]
        let reservation = GenerationSpendEvent(transactionId: "durable-transaction", kind: .reserved,
            model: item.package.payload.target.modelId, provider: item.package.payload.target.provider,
            transport: item.package.payload.target.transport, endpoint: item.package.payload.target.endpoint,
            money: item.package.payload.estimate)
        let submitting = try GenerationBatchStore.update(approved, editor: editor, authority: authority,
            addingSpendEvents: [reservation]) {
            try $0.beginSubmission(itemID: item.id, packageID: item.package.id,
                transactionID: reservation.transactionId, placeholders: placeholders(item, transaction: reservation.transactionId),
                batch: batch)
        }
        let providerRecorded = try GenerationBatchStore.update(submitting, editor: editor, authority: authority) {
            try $0.recordProviderRequest(itemID: item.id, transactionID: reservation.transactionId,
                requestID: "provider-job", resumable: true)
        }
        try FileManager.default.removeItem(at: home.appendingPathComponent("generation-batches"))
        try FileManager.default.removeItem(at: home.appendingPathComponent("generation-packages"))
        let restored = try #require(try GenerationBatchStore.all(home: home, authority: authority).first)
        #expect(restored == providerRecorded)
        #expect(restored.authorityAvailable)
        #expect(restored.authoritySpendEvents == [reservation])
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(
            "generation-packages/\(item.package.id).json").path))
        try GenerationBatchStore.reconcileRuntime([restored], editor: editor)
        #expect(editor.generationLog.spendEvents.contains(reservation))
    }

    @Test func saveAsAndAnotherHostKeepHistoryWithoutExecutableAuthority() async throws {
        let (root, editor, batch) = try await fixture()
        let authorityRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-authority-\(UUID().uuidString)")
        let host = try GenerationExecutionAuthorityStore(root: authorityRoot, hostID: UUID().uuidString)
        defer {
            cleanup(root)
            try? FileManager.default.removeItem(at: authorityRoot)
        }
        _ = try await GenerationBatchStore.approve(batch, editor: editor, authority: host)
        let home = try #require(editor.workingRoot)

        let copied = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-save-as-\(UUID().uuidString).ngv")
        defer { try? FileManager.default.removeItem(at: copied) }
        try FileManager.default.copyItem(at: home, to: copied)
        _ = try ProjectIdentity.regenerate(at: copied)
        let saveAsHistory = try #require(try GenerationBatchStore.all(home: copied, authority: host).first)
        #expect(!saveAsHistory.authorityAvailable)
        #expect(saveAsHistory.journal.executions.allSatisfy { $0.state == .queued })

        let anotherHost = try GenerationExecutionAuthorityStore(root: authorityRoot, hostID: UUID().uuidString)
        let foreignHistory = try GenerationBatchStore.load(id: batch.id, home: home, authority: anotherHost)
        #expect(!foreignHistory.authorityAvailable)
    }

    @Test func completedOutputBytesSurviveDiscardedRecovery() async throws {
        let (root, editor, batch) = try await fixture()
        let authorityRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-authority-\(UUID().uuidString)")
        let authority = try GenerationExecutionAuthorityStore(root: authorityRoot, hostID: UUID().uuidString)
        defer {
            cleanup(root)
            try? FileManager.default.removeItem(at: authorityRoot)
        }
        let approved = try await GenerationBatchStore.approve(batch, editor: editor, authority: authority)
        let home = try #require(editor.workingRoot)
        let item = batch.payload.items[0]
        let entries = placeholders(item, transaction: "output-transaction")
        let running = try GenerationBatchStore.update(approved, editor: editor, authority: authority) {
            try $0.beginSubmission(itemID: item.id, packageID: item.package.id,
                transactionID: "output-transaction", placeholders: entries, batch: batch)
            try $0.recordProviderRequest(itemID: item.id, transactionID: "output-transaction",
                requestID: "provider-output", resumable: true)
        }
        let entry = try #require(entries.first)
        guard case .project(let path) = entry.source else { Issue.record("Expected a project output"); return }
        let outputURL = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("durable completed output".utf8)
        try bytes.write(to: outputURL)
        let receipt = GenerationBatchOutput(schema: "generation-batch-output/v1", batchID: batch.id,
            itemID: item.id, packageID: item.package.id, transactionID: "output-transaction",
            asset: entry, sha256: FileDigest.sha256(of: bytes))
        try authority.archiveOutput(receipt, home: home)
        try FileManager.default.removeItem(at: outputURL)
        let receiptPath = try GenerationBatchOutput.receiptPath(
            authorization: .init(batchID: batch.id, itemID: item.id), assetID: entry.id)
        try? FileManager.default.removeItem(at: home.appendingPathComponent(receiptPath))
        let restored = try GenerationBatchStore.load(id: batch.id, home: home, authority: authority)
        #expect(restored == running)
        #expect(restored.recoveredOutputs == [receipt])
        #expect(try Data(contentsOf: outputURL) == bytes)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(receiptPath).path))
        try GenerationBatchStore.reconcileRuntime([restored], editor: editor)
        #expect(editor.mediaAssets.contains(where: { $0.id == entry.id && $0.generationStatus == .none }))
        #expect(editor.mediaManifest.entries.contains(entry))
    }
}
