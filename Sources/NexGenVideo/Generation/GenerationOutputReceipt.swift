import AVFoundation
import Foundation
import NexGenEngine

struct GenerationOutputReceipt: Codable, Sendable, Equatable {
    let schema: String
    let projectKey: String
    let assetID: String
    let modality: String
    let output: CanonicalArtifactReferenceV1
    let package: CanonicalArtifactReferenceV1
    let input: GenerationInput
    let activity: GenerationLogEntry
    let spendEvents: [GenerationSpendEvent]

    var providerRequestID: String? {
        spendEvents.first { $0.kind == .submitted && $0.providerRequestResumable == true }?.providerRequestId
    }

    static func path(assetID: String) -> String {
        "generation-output-receipts/" + FileDigest.sha256(of: Data(assetID.utf8)) + ".v1.json"
    }

    @MainActor
    static func record(asset: MediaAsset, editor: EditorViewModel) async throws {
        guard let input = asset.generationInput, let packageID = input.generationPackageID,
              let home = editor.workingRoot else { return }
        guard let transaction = input.spendTransactionId,
              let projectKey = ProjectIdentity.existingUUID(for: home), editor.projectId == projectKey,
              asset.generationStatus == .none, editor.mediaAssets.contains(where: { $0 === asset }),
              let activity = editor.generationLog.entries.last(where: { $0.spendTransactionId == transaction && $0.model == input.model }),
              case .project(let sourcePath) = asset.toManifestEntry(projectURL: home).source else { throw invalid() }
        let scope = try GenerationProjectMutationScope(projectHome: home, editor: editor)
        let source = try ProjectLocalFile.resolve(sourcePath, dataRoot: home)
        let mediaType = asset.type
        let hash = try await Task.detached(priority: .userInitiated) {
            switch mediaType {
            case .image: _ = try FrameRasterizer.loadImage(at: source)
            case .video, .audio:
                let media = AVURLAsset(url: source)
                let duration = try await media.load(.duration)
                guard duration.isNumeric, duration.value > 0,
                      !(try await media.loadTracks(withMediaType: mediaType == .video ? .video : .audio)).isEmpty else { throw invalid() }
                if mediaType == .video { _ = try await AVAssetImageGenerator(asset: media).image(at: .zero) }
            default: throw invalid()
            }
            return try FileDigest.sha256(of: source)
        }.value
        try scope.requireCurrent(editor: editor)
        guard asset.generationInput == input, asset.url.standardizedFileURL == source.standardizedFileURL else { throw invalid() }
        let relative = path(assetID: asset.id)
        let candidate = home.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            let existing = try load(assetID: asset.id, home: home)
            guard existing.output.path == sourcePath, existing.output.sha256 == hash,
                  existing.input == GenerationPackageV1.normalized(input) else { throw invalid() }
            return
        }
        let packagePath = "generation-packages/\(packageID).json"
        let package = try GenerationPackageV1.load(id: packageID, home: home)
        guard package.payload.modality == asset.type.rawValue, package.payload.binding.projectKey == projectKey,
              package.payload.generationInput == GenerationPackageV1.normalized(input) else { throw invalid() }
        let events = editor.generationLog.spendEvents.filter { $0.transactionId == transaction }
        guard events.first?.kind == .reserved, events.contains(where: { $0.kind == .submitted }),
              !events.contains(where: { $0.kind == .released }), events.allSatisfy({
                  $0.model == package.payload.target.modelId && $0.provider == package.payload.target.provider
                    && $0.transport == package.payload.target.transport && $0.endpoint == package.payload.target.endpoint
              }) else { throw invalid() }
        let receipt = Self(schema: "generation-output-receipt/v1", projectKey: projectKey, assetID: asset.id,
            modality: asset.type.rawValue,
            output: .init(id: asset.id, role: "host.generated-output", path: sourcePath, sha256: hash),
            package: .init(id: packageID, role: "host.generation-package", path: packagePath,
                sha256: try FileDigest.sha256(of: ProjectLocalFile.resolve(packagePath, dataRoot: home))),
            input: GenerationPackageV1.normalized(input), activity: activity, spendEvents: events)
        if let key = editor.openWorkingCopyKey { try ProjectWorkingCopy.markDirty(key: key) }
        _ = try ProjectLocalFile.ensureDirectory("generation-output-receipts", dataRoot: home)
        try GenerationPackageV1.canonicalData(receipt).write(to: candidate, options: .withoutOverwriting)
        _ = try load(assetID: asset.id, home: home)
    }

    static func load(assetID: String, home: URL) throws -> Self {
        let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path(assetID: assetID), dataRoot: home))
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.schema == "generation-output-receipt/v1", value.assetID == assetID,
              value.projectKey == ProjectIdentity.existingUUID(for: home),
              try GenerationPackageV1.canonicalData(value) == bytes,
              let transaction = value.activity.spendTransactionId,
              value.package.path == "generation-packages/\(value.package.id).json",
              value.spendEvents.first?.kind == .reserved,
              value.spendEvents.contains(where: { $0.kind == .submitted }),
              value.spendEvents.allSatisfy({ $0.transactionId == transaction && $0.kind != .released }) else { throw invalid() }
        _ = try ProjectLocalFile.requireHash(value.output.sha256, at: value.output.path, dataRoot: home)
        _ = try ProjectLocalFile.requireHash(value.package.sha256, at: value.package.path, dataRoot: home)
        let package = try GenerationPackageV1.load(id: value.package.id, home: home)
        guard package.payload.binding.projectKey == value.projectKey, package.payload.modality == value.modality,
              package.payload.generationInput == value.input, value.input.model == value.activity.model,
              value.spendEvents.allSatisfy({ $0.model == value.input.model && $0.provider == package.payload.target.provider
                && $0.transport == package.payload.target.transport && $0.endpoint == package.payload.target.endpoint }) else { throw invalid() }
        return value
    }

    private static func invalid() -> GateBlocked { GateBlocked("The generated output has no matching completed host request and exact media receipt.") }
}
