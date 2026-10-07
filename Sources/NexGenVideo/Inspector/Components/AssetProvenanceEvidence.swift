import Foundation

enum AssetProvenanceEvidence {
    static func events(for input: GenerationInput?, in events: [GenerationSpendEvent]) -> [GenerationSpendEvent] {
        guard let input, let transaction = input.spendTransactionId, !transaction.isEmpty else { return [] }
        return events.filter {
            $0.transactionId == transaction && $0.model == input.model
        }.sorted { $0.createdAt < $1.createdAt }
    }

    static func matches(_ package: GenerationPackageV1, input: GenerationInput) -> Bool {
        guard input.generationPackageID == package.id,
              GenerationPackageV1.normalized(input) == package.payload.generationInput else { return false }
        do { try package.validate(); return true } catch { return false }
    }
}
