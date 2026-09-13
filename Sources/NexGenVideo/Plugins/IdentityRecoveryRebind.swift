import Foundation
import NexGenEngine

enum IdentityRecoveryRebind {
    struct Preview: Sendable, Equatable {
        let receiptSHA256: String
        let phases: [String]
        let stalePhases: [String]
    }

    static func preview(dataRoot: URL, order: [String], registry: EngineRegistry) throws -> Preview? {
        let receiptURL = dataRoot.appendingPathComponent(IdentityRecoveryReceiptStoreV1.relativePath)
        guard FileManager.default.fileExists(atPath: receiptURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: receiptURL.path)) != nil else { return nil }
        let receipt = try IdentityRecoveryReceiptStoreV1.load(dataRoot: dataRoot)
        guard !receipt.phases.isEmpty else { return nil }
        let marker = dataRoot.appendingPathComponent(IdentityRecoveryReceiptStoreV1.rebindPath)
        if FileManager.default.fileExists(atPath: marker.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path)) != nil {
            let safe = try ProjectLocalFile.resolve(IdentityRecoveryReceiptStoreV1.rebindPath, dataRoot: dataRoot)
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: safe)) as? [String: String],
                  object["schema"] == "identity-recovery-rebind/v1",
                  object["receipt_sha256"] == (try FileDigest.sha256(of: ProjectLocalFile.resolve(IdentityRecoveryReceiptStoreV1.relativePath, dataRoot: dataRoot))) else {
                throw GateBlocked("The reviewed Recovery receipt changed.")
            }
            return nil
        }
        _ = try ProjectLocalFile.requireHash(receipt.recoveredManifestSHA256, at: PipelineLayout.confirmedIdentityAssetsFile, dataRoot: dataRoot)
        _ = try ProjectLocalFile.requireHash(receipt.gatesSHA256, at: PipelineLayout.gatesFile, dataRoot: dataRoot)
        guard let lineageHash = receipt.originalLineageSHA256 else {
            throw GateBlocked("The recovered project has no historical lineage to review.")
        }
        _ = try ProjectLocalFile.requireHash(lineageHash, at: PipelineLayout.lineageFile, dataRoot: dataRoot)
        for phase in Set(receipt.aliases.map(\.phase)) {
            let manifest = try DerivedIdentityAssetStoreV1.load(phase: phase, dataRoot: dataRoot)
            try DerivedIdentityAssetStoreV1.validate(manifest, dataRoot: dataRoot)
            for alias in receipt.aliases where alias.phase == phase {
                guard manifest.entries[alias.destinationPath] == alias else {
                    throw GateBlocked("Recovered identity provenance changed after migration.")
                }
            }
        }
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        var phases: [String] = []
        var stale = receipt.stalePhases
        var predecessorProven = true
        for phase in order {
            guard gates.get(phase).approved else { predecessorProven = false; continue }
            if phase == "project_init" { continue }
            guard predecessorProven, let binding = receipt.phases[phase],
                  let provider = registry.phaseLineageProviders[phase],
                  try provider(dataRoot) == binding.recovered.snapshot else {
                stale.append(phase)
                predecessorProven = false
                continue
            }
            phases.append(phase)
        }
        return Preview(
            receiptSHA256: try FileDigest.sha256(of: ProjectLocalFile.resolve(IdentityRecoveryReceiptStoreV1.relativePath, dataRoot: dataRoot)),
            phases: phases, stalePhases: Array(Set(stale)).sorted()
        )
    }

    static func apply(_ reviewed: Preview, dataRoot: URL, order: [String], registry: EngineRegistry) throws {
        guard !reviewed.phases.isEmpty,
              try preview(dataRoot: dataRoot, order: order, registry: registry) == reviewed else {
            throw GateBlocked("The Recovery review changed. Review the current project again.")
        }
        let receipt = try IdentityRecoveryReceiptStoreV1.load(dataRoot: dataRoot)
        let lineageURL = try ProjectLocalFile.resolve(PipelineLayout.lineageFile, dataRoot: dataRoot)
        let originalBytes = try Data(contentsOf: lineageURL)
        var lineage = try JSONDecoder().decode(PipelineLineage.self, from: originalBytes)
        for phase in reviewed.phases {
            guard let binding = receipt.phases[phase], lineage.phases[phase] == binding.original else {
                throw GateBlocked("The historical phase proof changed after Recovery review.")
            }
            lineage.phases[phase] = binding.recovered
        }
        do {
            try JSONArtifactStore(dataRoot: dataRoot).save(lineage, to: PipelineLayout.lineageFile)
            let validity = try ProjectStateBuilder.approvalValidity(dataRoot: dataRoot, order: order, registry: registry)
            guard reviewed.phases.allSatisfy({ validity[$0]?.isCurrent == true }) else {
                throw GateBlocked("A recovered phase failed its shared structural approval gate.")
            }
            _ = try ProjectLocalFile.ensureDirectory("recovery", dataRoot: dataRoot)
            try JSONArtifactStore(dataRoot: dataRoot).save([
                "schema": "identity-recovery-rebind/v1",
                "receipt_sha256": reviewed.receiptSHA256,
                "phases": reviewed.phases.joined(separator: ","),
            ], to: IdentityRecoveryReceiptStoreV1.rebindPath)
        } catch {
            try originalBytes.write(to: lineageURL, options: .atomic)
            throw error
        }
    }
}
