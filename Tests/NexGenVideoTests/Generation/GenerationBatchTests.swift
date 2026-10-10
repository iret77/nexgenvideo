import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Generation batch single-use execution")
@MainActor
struct GenerationBatchTests {
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

    private func fixture(stop: Double? = nil) async throws -> (URL, EditorViewModel, GenerationBatch) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-batch-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: root)
        if let stop {
            let dataRoot = root.appendingPathComponent("pipeline")
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            try Data("project: demo\nmode: beat\n".utf8).write(to: dataRoot.appendingPathComponent(PipelineLayout.projectFile))
            let brief = try Brief(project: "demo", generated: "2026-10-10", mission: .demo,
                targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat", budgetStopEur: stop,
                conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored)
            try YAMLArtifactStore(dataRoot: dataRoot).save(brief, to: PipelineLayout.briefFile)
        }
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
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let original = batch.payload.items[0].package
        var payloadJSON = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(original.payload)) as? [String: Any])
        payloadJSON.removeValue(forKey: "estimate")
        let payload = try JSONDecoder().decode(GenerationPackageV1.Payload.self, from: JSONSerialization.data(withJSONObject: payloadJSON))
        let unpriced = try GenerationPackageV1(payload: payload)
        let pricedID = UUID().uuidString
        let unpricedID = UUID().uuidString
        let manifest = try GenerationBatch(payload: .init(
            nonce: UUID(),
            projectKey: batch.payload.projectKey,
            phase: nil,
            items: [
                .init(
                    id: pricedID,
                    purpose: "Priced generation",
                    package: original
                ),
                .init(
                    id: unpricedID,
                    purpose: "Unpriced generation",
                    package: unpriced
                ),
            ]
        ))
        #expect(manifest.totalEUR == nil)
        #expect(throws: (any Error).self) { try GenerationBatchJournal(approving: manifest, authorityID: "test-authority") }
        let recoveries = Dictionary(uniqueKeysWithValues: manifest.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        #expect(throws: (any Error).self) {
            try editor.agentService.presentGenerationBatch(
                manifest,
                recoveries: recoveries.filter { $0.key == pricedID },
                origin: .direct,
                editor: editor
            )
        }
        #expect(editor.generationBatchCoordinator.pending == nil)
        let result = try editor.agentService.presentGenerationBatch(
            manifest,
            recoveries: recoveries,
            origin: .direct,
            editor: editor
        )
        #expect(!result.isError)
        #expect(result.turnDisposition == .suspendTurn)
        #expect(editor.generationBatchCoordinator.pending?.id == manifest.id)
        let controls = GenerationBatchReviewControls(
            hasVerifiedTotal: manifest.totalEUR != nil,
            hasRetryablePricingFailure: editor.generationBatchCoordinator.canRetryPricing,
            isBusy: false
        )
        #expect(!controls.canApprove)
        #expect(controls.canApproveWithoutEstimate)
    }

    private func unpricedBatch(_ original: GenerationBatch, editor: EditorViewModel) async throws -> GenerationBatch {
        let item = original.payload.items[0]
        let package = try item.package.replacingPricing(estimate: nil, failure: .init(
            reason: .unsupportedCombination, provider: item.package.payload.target.provider,
            endpoint: item.package.payload.target.endpoint, detail: "No supported estimate"))
        let inputs = try await GenerationPackageInputs.restore(package: item.package, editor: editor)
        try await GenerationPackageInputs.persist(package: package, snapshot: inputs, editor: editor)
        return try original.replacingPackage(itemID: item.id, with: package)
    }

    @Test func unknownCostApprovalPersistsExactItemsAndCannotMoveToAnotherManifest() async throws {
        let (root, editor, original) = try await fixture()
        defer { cleanup(root) }
        let batch = try await unpricedBatch(original, editor: editor)
        await #expect(throws: (any Error).self) {
            try await GenerationBatchStore.approve(batch, editor: editor)
        }
        let approved = try await GenerationBatchStore.approve(batch, editor: editor, approval: .acceptUnknownPrices)
        #expect(approved.journal.pricingOverrideItemIDs == [batch.payload.items[0].id])
        #expect(approved.batch.totalEUR == nil)
        #expect(approved.batch.payload.items[0].package.payload.estimate == nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
        let reopened = try GenerationBatchStore.load(id: batch.id, home: #require(editor.workingRoot))
        #expect(reopened == approved)
        let restored = try JSONDecoder().decode(GenerationBatchJournal.self,
            from: GenerationPackageV1.canonicalData(approved.journal))
        try restored.validate(batch: batch)
        #expect(throws: (any Error).self) { try restored.validate(batch: original) }
        let changed = try batch.removing(itemIDs: [batch.payload.items[2].id])
        #expect(throws: (any Error).self) { try restored.validate(batch: changed) }
        var json = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(restored)) as? [String: Any])
        json["pricingOverrideItemIDs"] = [batch.payload.items[1].id]
        let tampered = try JSONDecoder().decode(GenerationBatchJournal.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: (any Error).self) { try tampered.validate(batch: batch) }
        let legacy = try GenerationBatchJournal(approving: original, authorityID: "legacy")
        let legacyData = try GenerationPackageV1.canonicalData(legacy)
        #expect(!String(decoding: legacyData, as: UTF8.self).contains("pricingOverrideItemIDs"))
        try JSONDecoder().decode(GenerationBatchJournal.self, from: legacyData).validate(batch: original)
    }

    @Test func explicitUnknownCostApprovalReservesUnknownMoneyWithoutDisablingFutureBudgetChecks() async throws {
        let (root, editor, original) = try await fixture(stop: 1)
        defer { cleanup(root) }
        let batch = try await unpricedBatch(original, editor: editor)
        _ = try await GenerationBatchStore.approve(batch, editor: editor, approval: .acceptUnknownPrices)
        let item = batch.payload.items[0]
        let authorization = GenerationBatchAuthorization(batchID: batch.id, itemID: item.id)
        let reserved = try await GenerationBudgetGuard.authorize(input: item.package.pricingInput(),
            target: item.package.payload.target, editor: editor, approvedPackage: item.package,
            requiresVerifiedCeiling: true, batchItem: authorization, quoteLoader: { _, _ in
                throw GenerationBudgetError.blocked("Pricing unavailable")
            })
        #expect(reserved.transactionId != nil)
        #expect(reserved.estimate == nil)
        let event = try #require(editor.generationLog.spendEvents.first)
        #expect(event.kind == .reserved && event.money == nil)
        #expect(event.note?.contains("explicitly approved") == true)
        #expect(editor.mediaAssets.isEmpty)
        let known = batch.payload.items[1]
        let sibling = GenerationBatchAuthorization(batchID: batch.id, itemID: known.id)
        _ = try await GenerationBudgetGuard.authorize(input: known.package.pricingInput(),
            target: known.package.payload.target, editor: editor, approvedPackage: known.package,
            requiresVerifiedCeiling: true, batchItem: sibling,
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        await #expect(throws: (any Error).self) {
            try await GenerationBudgetGuard.authorize(input: known.package.pricingInput(),
                target: known.package.payload.target, editor: editor, approvedPackage: known.package,
                requiresVerifiedCeiling: true, batchItem: sibling,
                quoteLoader: { _, _ in GenerationPackageFixture.money(0.50) })
        }
        await #expect(throws: (any Error).self) {
            try await GenerationBudgetGuard.authorize(input: known.package.pricingInput(),
                target: known.package.payload.target, editor: editor, approvedPackage: known.package,
                quoteLoader: { _, _ in GenerationPackageFixture.money() })
        }
        #expect(editor.generationLog.spendEvents.count == 2)
        let dataRoot = try #require(editor.workingRoot).appendingPathComponent("pipeline")
        let brief = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        #expect(brief.budgetStopEur == 1)
        await #expect(throws: CancellationError.self) {
            try await GenerationBudgetGuard.authorize(input: item.package.pricingInput(),
                target: item.package.payload.target, editor: editor, approvedPackage: item.package,
                requiresVerifiedCeiling: true, batchItem: authorization,
                quoteLoader: { _, _ in throw CancellationError() })
        }
        #expect(editor.generationLog.spendEvents.count == 2)
        let home = try #require(editor.workingRoot)
        let current = try GenerationBatchStore.load(id: batch.id, home: home)
        let transaction = try #require(reserved.transactionId)
        let outputEntries = placeholders(item, transaction: transaction)
        let consumed = try GenerationBatchStore.update(current, editor: editor, addingSpendEvents: [event]) {
            try $0.beginSubmission(itemID: item.id, packageID: item.package.id, transactionID: transaction,
                placeholders: outputEntries, batch: batch)
        }
        let reloaded = try GenerationBatchStore.load(id: batch.id, home: home)
        #expect(reloaded == consumed)
        #expect(reloaded.authoritySpendEvents.first?.money == nil)
        #expect(reloaded.journal.executions[0].state == .submitting)
        #expect(throws: (any Error).self) {
            try GenerationBatchStore.update(reloaded, editor: editor) {
                try $0.beginSubmission(itemID: item.id, packageID: item.package.id, transactionID: transaction,
                    placeholders: outputEntries, batch: batch)
            }
        }
    }

    @Test func overrideDoesNotReuseCanceledExecutionOrAChangedReview() async throws {
        let (root, editor, original) = try await fixture()
        defer { cleanup(root) }
        let batch = try await unpricedBatch(original, editor: editor)
        let stored = try await GenerationBatchStore.approve(batch, editor: editor, approval: .acceptUnknownPrices)
        _ = try GenerationBatchStore.update(stored, editor: editor) { $0.cancelRemaining() }
        let item = batch.payload.items[0]
        #expect(throws: (any Error).self) {
            try GenerationBatchAuthorization(batchID: batch.id, itemID: item.id)
                .pricingOverride(package: item.package, editor: editor)
        }
        let recoveries = Dictionary(uniqueKeysWithValues: batch.payload.items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        })
        try editor.generationBatchCoordinator.present(batch, recoveries: recoveries)
        await editor.generationBatchCoordinator.approve(editor: editor,
            expectedBatchID: original.id, approval: .acceptUnknownPrices)
        #expect(editor.generationBatchCoordinator.pending == batch)
        editor.generationBatchCoordinator.requestRevision(editor: editor)
        #expect(editor.generationBatchCoordinator.pending == nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
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
