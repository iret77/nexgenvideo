import Foundation
import Testing
@testable import NexGenVideo

@Suite("Generation batch single-use execution")
@MainActor
struct GenerationBatchTests {
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
        var journal = try GenerationBatchJournal(approving: batch)
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
        var journal = try GenerationBatchJournal(approving: batch)
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
        let journal = try GenerationBatchJournal(approving: batch)
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
        #expect(throws: (any Error).self) { try GenerationBatchJournal(approving: manifest) }
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
}
