import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Generation batch single-use execution")
@MainActor
struct GenerationBatchTests {
    private func pendingFixture() async throws -> (URL, EditorViewModel, GenerationBatch) {
        let (root, editor, priced) = try await fixture()
        let (generation, unpriced) = try await GenerationPackageFixture.prepare(editor: editor,
            quoteLoader: { _, _ in throw GenerationPricingFailure.exchangeRateUnavailable })
        try await GenerationPackageInputs.persist(package: unpriced, snapshot: #require(generation.references), editor: editor)
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: priced.payload.projectKey,
            phase: nil, items: [
                .init(id: UUID().uuidString, purpose: "Retry this image", package: unpriced),
                priced.payload.items[1]
            ], requestSHA256: String(repeating: "a", count: 64)))
        editor.agentService.newChat()
        let chatID = try #require(editor.agentService.currentSessionId)
        _ = try editor.agentService.presentGenerationBatch(batch, origin: .inAppChat(sessionID: chatID), editor: editor)
        editor.agentService.isStreaming = true
        return (root, editor, batch)
    }

    @Test func quoteRetryPreservesExactRequestAndPricedSiblingWithoutAuthority() async throws {
        let (root, editor, batch) = try await pendingFixture()
        defer { cleanup(root) }
        let home = try #require(editor.workingRoot)
        var quotes = 0
        await editor.generationBatchCoordinator.retryPricing(editor: editor, quoteLoader: { target, input in
            quotes += 1
            #expect(target == batch.payload.items[0].package.payload.target)
            #expect(input == (try batch.payload.items[0].package.pricingInput()))
            await Task.yield()
            return GenerationPackageFixture.money(0.3)
        })
        let updated = try #require(editor.generationBatchCoordinator.pending)
        #expect(quotes == 1)
        #expect(updated.id != batch.id)
        #expect(updated.payload.nonce == batch.payload.nonce)
        #expect(updated.payload.items[0].id == batch.payload.items[0].id)
        #expect(updated.payload.items[0].package.id != batch.payload.items[0].package.id)
        #expect(updated.payload.items[0].package.payload.requestParametersJSON == batch.payload.items[0].package.payload.requestParametersJSON)
        #expect(updated.payload.items[1] == batch.payload.items[1])
        #expect(updated.totalEUR == 0.55)
        #expect(try GenerationPackageV1.load(id: batch.payload.items[0].package.id, home: home) == batch.payload.items[0].package)
        _ = try await GenerationPackageInputs.restore(package: updated.payload.items[0].package, editor: editor)
        #expect(try GenerationBatchStore.all(home: home).isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test func concurrentQuoteRetriesDoNotCreateDuplicateWork() async throws {
        let (root, editor, batch) = try await pendingFixture()
        defer { cleanup(root) }
        var quotes = 0
        let loader: GenerationBudgetGuard.QuoteLoader = { _, _ in
            quotes += 1
            await Task.yield()
            throw GenerationPricingFailure.providerPricingUnavailable
        }
        async let first: Void = editor.generationBatchCoordinator.retryPricing(editor: editor, quoteLoader: loader)
        async let second: Void = editor.generationBatchCoordinator.retryPricing(editor: editor, quoteLoader: loader)
        _ = await (first, second)
        #expect(quotes == 1)
        #expect(editor.generationBatchCoordinator.pending == batch)
        #expect(editor.generationBatchCoordinator.pricingFailure(for: batch.payload.items[0].package) == .providerPricingUnavailable)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func repricingCannotRaiseOrReplaceAPricedSibling() async throws {
        let (root, _, batch) = try await pendingFixture()
        defer { cleanup(root) }
        let raised = try batch.payload.items[1].package.replacingEstimate(GenerationPackageFixture.money(0.5))
        #expect(throws: (any Error).self) {
            try batch.replacingPackages([batch.payload.items[0].package, raised])
        }
    }

    @Test func anotherManifestCannotReuseAnApprovedRequestNonce() async throws {
        let (root, editor, batch) = try await fixture()
        defer { cleanup(root) }
        let approved = try await GenerationBatchStore.approve(batch, editor: editor)
        let altered = try batch.removing(itemIDs: [batch.payload.items[0].id])
        await #expect(throws: (any Error).self) { try await GenerationBatchStore.approve(altered, editor: editor) }
        let home = try #require(editor.workingRoot)
        #expect(try GenerationBatchStore.load(id: batch.id, home: home).journal == approved.journal)
        #expect(try GenerationBatchStore.all(home: home).count == 1)
    }

    @Test func routeChangeRetiresPendingRequestAndCombinesOneReplacementBatch() async throws {
        let (root, editor, batch) = try await pendingFixture()
        defer { cleanup(root) }
        let home = try #require(editor.workingRoot)
        editor.generationBatchCoordinator.changeRoute(itemIDs: [batch.payload.items[0].id], editor: editor)
        #expect(editor.generationBatchCoordinator.pending == nil)
        let recovery = try #require(try GenerationBatchStore.retirement(requestID: batch.payload.nonce, home: home))
        #expect(recovery.batch == batch)
        #expect(recovery.continuation.items.map(\.itemID) == [batch.payload.items[0].id])
        #expect(recovery.continuation.items.map(\.failure) == [.exchangeRateUnavailable])
        #expect(recovery.continuation.retainedPackageIDs == [batch.payload.items[1].package.id])
        let result = try await ToolExecutor(editor: editor, enforceHardGates: false)
            .getGenerationBatches(editor, ["batchID": batch.id])
        let restoredRecord = try JSONDecoder().decode(GenerationBatchRetirement.self, from: Data(ToolHarness.textOf(result).utf8))
        #expect(restoredRecord == recovery)
        let (_, replacement) = try await GenerationPackageFixture.prepare(editor: editor, model: "replacement-image")
        let combined = try recovery.replacing(packages: [replacement], requestSHA256: String(repeating: "b", count: 64))
        #expect(combined.payload.items.count == 2)
        #expect(combined.payload.items[0].id == batch.payload.items[0].id)
        #expect(combined.payload.items[0].package == replacement)
        #expect(combined.payload.items[1] == batch.payload.items[1])
        #expect(combined.id != batch.id)
        #expect(throws: (any Error).self) { try recovery.replacing(packages: [], requestSHA256: "wrong") }
        await #expect(throws: (any Error).self) { try await GenerationBatchStore.approve(batch, editor: editor) }
        editor.generationBatchCoordinator.changeRoute(itemIDs: [batch.payload.items[0].id], editor: editor)
        #expect(try GenerationBatchStore.retirement(requestID: batch.payload.nonce, home: home) == recovery)
        #expect(try GenerationBatchStore.all(home: home).isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
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
        #expect(collector.packages == [package])
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
