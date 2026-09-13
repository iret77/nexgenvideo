import Foundation
import NexGenEngine

enum MusicvideoIdentityRecovery {
    static func prepare(projectURL: URL) throws {
        let registry = EngineRegistry()
        MusicvideoPack().register(registry)
        try prepare(projectURL: projectURL, registry: registry)
    }

    static func prepare(projectURL: URL, registry: EngineRegistry) throws {
        guard let root = DataRootResolver.dataRoot(of: projectURL),
              let binding = try JSONSerialization.jsonObject(with: Data(contentsOf: ProjectLocalFile.resolve("ngv.json", dataRoot: projectURL))) as? [String: Any],
              binding["activePlugin"] as? String == "musicvideo",
              binding["activePluginVersion"] as? String == "0.5.8",
              binding["activePluginProjectSchema"] as? String == "musicvideo/2.0.0" else {
            throw GateBlocked("Identity recovery requires the explicitly selected Music Video 0.5.8 project.")
        }
        let manifestURL = root.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile)
        guard FileManager.default.fileExists(atPath: manifestURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: manifestURL.path)) != nil else { return }
        let originalBytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.confirmedIdentityAssetsFile, dataRoot: root))
        let original = try ConfirmedIdentityAssetStoreV1.load(dataRoot: root)
        try ConfirmedIdentityAssetStoreV1.validate(original, dataRoot: root)
        let aliases = try original.entries.values.filter { $0.path != $0.originalPath }.sorted { $0.path < $1.path }.map { entry in
            let phase = try DerivedIdentityAssetStoreV1.owningPhase(destination: entry.path)
            guard entry.originalPath.hasPrefix("import/"),
                  let source = original.entries[entry.originalPath],
                  source.path == source.originalPath,
                  source.role == entry.role,
                  source.identitySlug == entry.identitySlug,
                  source.identityName == entry.identityName,
                  source.sha256 == entry.sha256,
                  entry.sha256 == entry.originalSHA256,
                  try ConfirmedIdentityAssetStoreV1.isCurrent(entry.path, dataRoot: root) else {
                throw GateBlocked("A legacy identity alias is missing, changed, or ambiguous. Restore its exact source bytes before recovery.")
            }
            return DerivedIdentityAssetV1(phase: phase, source: source, destinationPath: entry.path)
        }
        guard !aliases.isEmpty else { return }
        var recovered = original
        for alias in aliases { recovered.entries.removeValue(forKey: alias.destinationPath) }
        guard recovered.entries.values.allSatisfy({ $0.path.hasPrefix("import/") && $0.path == $0.originalPath }) else {
            throw GateBlocked("The confirmed intake contains an ambiguous legacy identity entry.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recoveredBytes = try encoder.encode(recovered)
        let lineage = try PipelineLineageStore.loadIfPresent(dataRoot: root)
        let lineageURL = root.appendingPathComponent(PipelineLayout.lineageFile)
        let lineageSHA256 = FileManager.default.fileExists(atPath: lineageURL.path)
            ? try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.lineageFile, dataRoot: root)) : nil
        let gatesSHA256 = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.gatesFile, dataRoot: root))
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        var proven: [String: PhaseLineageEntry] = [:]
        var stale: [String] = []
        for (phase, recorded) in (lineage?.phases ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard gates.get(phase).approved else { continue }
            guard let phaseIndex = MusicvideoPipelineLineage.phases.firstIndex(of: phase) else { continue }
            var historical = recovered
            for alias in aliases {
                guard let ownerIndex = MusicvideoPipelineLineage.phases.firstIndex(of: alias.phase), ownerIndex <= phaseIndex else { continue }
                historical.entries[alias.destinationPath] = original.entries[alias.destinationPath]
            }
            let snapshot = try? MusicvideoPipelineLineage.snapshot(
                phase: phase, dataRoot: root, legacyIdentityLayout: true,
                inputOverrides: [PipelineLayout.confirmedIdentityAssetsFile: try encoder.encode(historical)]
            )
            if snapshot == recorded.snapshot { proven[phase] = recorded }
            else { stale.append(phase) }
        }
        for phase in ["production_design", "bible"] where aliases.contains(where: { $0.phase == phase }) {
            let path = try DerivedIdentityAssetStoreV1.relativePath(phase: phase)
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else {
                throw GateBlocked("The legacy project already contains conflicting phase identity provenance.")
            }
        }
        try ConfirmedIdentityAssetStoreV1.save(recovered, dataRoot: root)
        for alias in aliases {
            _ = try DerivedIdentityAssetStoreV1.record(phase: alias.phase, from: alias.sourcePath, to: alias.destinationPath, dataRoot: root)
        }
        var bindings: [String: IdentityRecoveryPhaseBindingV1] = [:]
        for (phase, original) in proven {
            guard let snapshot = try? MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: root) else {
                stale.append(phase)
                continue
            }
            bindings[phase] = IdentityRecoveryPhaseBindingV1(
                original: original,
                recovered: PhaseLineageEntry(snapshot: snapshot, recordedAt: original.recordedAt)
            )
        }
        if let lineage {
            let originalLineageBytes = try Data(contentsOf: lineageURL)
            var prospective = lineage
            for (phase, binding) in bindings { prospective.phases[phase] = binding.recovered }
            do {
                try JSONArtifactStore(dataRoot: root).save(prospective, to: PipelineLayout.lineageFile)
                var predecessorValid = gates.get("project_init").approved
                for phase in MusicvideoPipelineLineage.phases {
                    guard gates.get(phase).approved, predecessorValid,
                          bindings[phase] != nil,
                          let requirement = registry.gateRequirements[phase] else {
                        bindings.removeValue(forKey: phase)
                        if gates.get(phase).approved { stale.append(phase) }
                        predecessorValid = false
                        continue
                    }
                    do { try requirement(root) }
                    catch {
                        bindings.removeValue(forKey: phase)
                        stale.append(phase)
                        predecessorValid = false
                    }
                }
                try originalLineageBytes.write(to: lineageURL, options: .atomic)
            } catch {
                try originalLineageBytes.write(to: lineageURL, options: .atomic)
                throw error
            }
        }
        try IdentityRecoveryReceiptStoreV1.save(IdentityRecoveryReceiptV1(
            projectID: DerivedIdentityAssetStoreV1.projectID(dataRoot: root),
            originalManifestSHA256: FileDigest.sha256(of: originalBytes),
            recoveredManifestSHA256: FileDigest.sha256(of: recoveredBytes),
            originalLineageSHA256: lineageSHA256, gatesSHA256: gatesSHA256,
            aliases: aliases, phases: bindings, stalePhases: Array(Set(stale)).sorted()
        ), dataRoot: root)
    }
}
