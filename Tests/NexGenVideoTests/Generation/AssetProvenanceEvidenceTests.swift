import Foundation
import Testing
@testable import NexGenVideo

@Suite("Original media provenance")
@MainActor
struct AssetProvenanceEvidenceTests {
    @Test func chargesBelongToTheRecordedTransactionAndModel() {
        var input = GenerationInput(prompt: "", model: "historical-model", duration: 0, aspectRatio: "")
        input.spendTransactionId = "transaction"
        func event(_ transaction: String, _ model: String, at time: TimeInterval) -> GenerationSpendEvent {
            .init(transactionId: transaction, kind: .charged, model: model, provider: .fal, transport: .api,
                  endpoint: "historical-endpoint", money: GenerationPackageFixture.money(),
                  createdAt: Date(timeIntervalSince1970: time))
        }
        let first = event("transaction", "historical-model", at: 1)
        let second = event("transaction", "historical-model", at: 2)
        let all = [second, event("other", "historical-model", at: 3),
                   event("transaction", "other-model", at: 4), first]
        #expect(AssetProvenanceEvidence.events(for: input, in: all) == [first, second])
        input.spendTransactionId = nil
        #expect(AssetProvenanceEvidence.events(for: input, in: all).isEmpty)
        #expect(AssetProvenanceEvidence.events(for: nil, in: all).isEmpty)
    }

    @Test func immutablePackageMustMatchBothAssetInputAndRecordedIdentity() async throws {
        let (_, package) = try await GenerationPackageFixture.prepare(editor: EditorViewModel())
        var input = package.payload.generationInput
        input.generationPackageID = package.id
        input.createdAt = Date()
        input.spendTransactionId = "transaction"
        #expect(AssetProvenanceEvidence.matches(package, input: input))
        input.prompt += " changed"
        #expect(!AssetProvenanceEvidence.matches(package, input: input))
        input = package.payload.generationInput
        input.generationPackageID = String(repeating: "0", count: 64)
        #expect(!AssetProvenanceEvidence.matches(package, input: input))
    }
    @Test func explicitFrameRolesDoNotDependOnTheCurrentModelCatalog() {
        let image = MediaAsset(id: "frame", url: URL(fileURLWithPath: "/tmp/frame.png"), type: .image, name: "Frame")
        var input = GenerationInput(prompt: "", model: "retired-model", duration: 5, aspectRatio: "16:9")
        input.startFrameAssetId = image.id
        #expect(GenerationReferencesStrip.slots(for: input, in: [image]).map(\.0) == ["First Frame"])
        input.imageURLAssetIds = [image.id]
        #expect(GenerationReferencesStrip.slots(for: input, in: [image]).count == 1)
        input.startFrameAssetId = nil
        #expect(GenerationReferencesStrip.slots(for: input, in: [image]).map(\.0) == ["Reference"])
    }

}
