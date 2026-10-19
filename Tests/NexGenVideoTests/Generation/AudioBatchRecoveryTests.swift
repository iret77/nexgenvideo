import Foundation
import Testing
@testable import NexGenVideo

@Suite("Audio batch resumes the exact approved request")
@MainActor
struct AudioBatchRecoveryTests {
    @Test func queuedAudioSurvivesCloseAndReopenWithoutNewApprovalOrDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-batch-" + UUID().uuidString)
        let root = directory.appendingPathComponent("Audio.ngv")
        try Fixtures.prepareProjectPackage(at: root)
        let editor = EditorViewModel(); editor.projectURL = root
        defer {
            if let id = ProjectIdentity.existingUUID(for: root),
               let authority = try? GenerationExecutionAuthorityStore.live(),
               let records = try? authority.all(projectKey: id) {
                for record in records { try? authority.removeForTesting(projectKey: id, batchID: record.batch.id) }
            }
            if let key = ProjectIdentity.existingKey(for: root) { ProjectWorkingCopy.discard(key: key) }
            try? FileManager.default.removeItem(at: directory)
        }
        let catalog = ModelCatalog(); catalog.load(entries: ModelCatalog.launchEntries)
        let preferencesSuite = "Audio batch recovery " + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: preferencesSuite))
        defer { defaults.removePersistentDomain(forName: preferencesSuite) }
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: [.init(provider: .fal, transport: .api)]) },
            quoteLoader: { _, _ in GenerationPackageFixture.money() })
        let model = try #require(catalog.audio.first { $0.id == "fal-ai/elevenlabs/music" && services.target($0.id).binding != nil })
        let target = services.target(model.id)
        let request = GenerationRequest(modality: .audio, modelId: model.id, intent: "A restrained instrumental piano motif", durationSeconds: 8,
            placement: .mediaLibrary(folderId: nil), origin: .panel, target: target,
            submission: .audio { prompt in
                .make(genInput: .init(prompt: prompt, model: model.id, duration: 8, aspectRatio: ""), model: model,
                    params: .init(prompt: prompt, voice: nil, lyrics: nil,
                        styleInstructions: nil, instrumental: true, durationSeconds: 8))
            })
        let prepared = try await GenerationController.prepare(request, editor: editor).get()
        let package = try await GenerationController.prepareReviewPackage(prepared, editor: editor,
            quoteLoader: services.quoteLoader)
        let actualResult = Data(#"{"audio":{"url":"https://output.invalid/restored-audio.wav"}}"#.utf8)
        #expect(try FalOutput.urls(from: actualResult, shape: GenerationService.resumedFalOutputShape(package: package))
            == ["https://output.invalid/restored-audio.wav"])
        #expect(try package.pricingInput().modality == .audio)
        #expect(try package.pricingInput().durationSeconds == 8)
        try await GenerationPackageInputs.persist(package: package, snapshot: #require(prepared.references), editor: editor)
        let itemID = UUID().uuidString
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: package.payload.binding.projectKey,
            phase: nil, items: [.init(id: itemID, purpose: "Recorded audio direction", package: package)]))
        _ = try await GenerationBatchStore.approve(batch, editor: editor)
        let authorization = GenerationBatchAuthorization(batchID: batch.id, itemID: itemID)
        editor.projectURL = nil; editor.projectURL = root
        editor.generationBatchCoordinator.modelCatalog = catalog
        editor.generationBatchCoordinator.providerActivation = services.activation
        let spend = editor.generationLog.spendEvents
        let restored = try await GenerationController.restoreApprovedBatchItem(authorization, editor: editor)
        #expect(restored.reviewedPackage == package)
        guard case .audio(let submission, let parameters) = restored.submission else {
            Issue.record("The saved audio item was not restored as audio."); return
        }
        #expect(submission.genInput == package.payload.generationInput)
        #expect(submission.params.voice == nil)
        #expect(submission.params.lyrics == nil)
        #expect(submission.params.styleInstructions == nil)
        #expect(submission.params.instrumental == true)
        #expect(submission.params.durationSeconds == 8)
        #expect(try GenerationPackageV1.requestJSON(parameters: parameters, references: []) == package.payload.requestParametersJSON)
        #expect(editor.generationLog.spendEvents == spend)
        #expect(editor.mediaAssets.isEmpty)
        let stored = try GenerationBatchStore.load(id: batch.id, home: #require(editor.workingRoot))
        #expect(stored.journal.executions.first?.state == .queued)
        editor.generationBatchCoordinator.providerActivation = { .init() }
        await #expect(throws: (any Error).self) {
            try await GenerationController.restoreApprovedBatchItem(authorization, editor: editor)
        }
        #expect(try GenerationBatchStore.load(id: batch.id, home: #require(editor.workingRoot)).journal == stored.journal)
        #expect(editor.generationLog.spendEvents == spend)
    }
}
