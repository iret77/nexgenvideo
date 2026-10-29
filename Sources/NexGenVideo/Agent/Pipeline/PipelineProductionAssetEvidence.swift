import Foundation
import NexGenEngine

enum PipelineProductionAssetEvidence {
    private struct SpatialAdoption: Decodable {
        let schema: String
        let id: UUID
        let projectID: String
        let proof: CanonicalArtifactReferenceV1
        let image: CanonicalArtifactReferenceV1?
        let media: [String: CanonicalArtifactReferenceV1]?
    }

    static func requireReferencePurpose(path: String, sha256: String, semanticJobID: String,
                                        dataRoot: URL, geometry: Bool = false) throws {
        _ = try ProjectLocalFile.requireHash(sha256, at: path, dataRoot: dataRoot)
        let relative = "pipeline/spatial-adoptions"
        let directory = dataRoot.appendingPathComponent(relative).standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil else { return }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL else {
            throw GateBlocked("The native spatial evidence folder cannot be read safely.")
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            guard name.hasSuffix(".v1.json") else { continue }
            let url = try ProjectLocalFile.resolve(relative + "/" + name, dataRoot: dataRoot)
            let record = try JSONDecoder().decode(SpatialAdoption.self, from: Data(contentsOf: url))
            let references = [record.image].compactMap { $0 } + Array((record.media ?? [:]).values)
            guard references.contains(where: { $0.path == path || $0.sha256 == sha256 }) else { continue }
            guard record.projectID == project.project else { throw GateBlocked("The spatial reference belongs to another project.") }
            let bytes = try Data(contentsOf: ProjectLocalFile.requireHash(record.proof.sha256, at: record.proof.path, dataRoot: dataRoot))
            let outputs: [SpatialClayOutput]
            switch record.schema {
            case "spatial-bible-view-adoption/v1", "spatial-derivation-adoption/v1":
                let proof = try JSONDecoder().decode(SpatialDerivationProof.self, from: bytes)
                guard proof.id == record.id, proof.purpose == "geometry" else { throw GateBlocked("The spatial image provenance changed.") }
                outputs = proof.outputs
            case "spatial-sequence-adoption/v1":
                let proof = try JSONDecoder().decode(SpatialClaySequenceProof.self, from: bytes)
                guard proof.id == record.id, proof.schema == "spatial-derivation-sequence/v1" else { throw GateBlocked("The spatial sequence provenance changed.") }
                outputs = proof.outputs
            default: throw GateBlocked("The spatial reference has unsupported provenance.")
            }
            guard outputs.contains(where: { $0.sha256 == sha256 }) else { throw GateBlocked("The spatial reference no longer matches its rendered image or video.") }
            guard geometry else {
                throw GateBlocked("A neutral Clay view cannot provide \(semanticJobID). Assign it as geometry and provide a separate appearance reference.")
            }
        }
    }

    static func requireBible(_ bible: Bible, dataRoot: URL, validateVariants: Bool = true) throws {
        let requirements = BibleViewProvenanceRequirementsV1.make(bible: bible)
        let proof = try loadPipelineAssetProof(dataRoot: dataRoot, scope: "bible")
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard proof.schema == pipelineAssetProofSchemaVersion, proof.scope == "bible", proof.project == project.project,
              bible.project == project.project else { throw GateBlocked("Bible provenance belongs to another project or scope.") }
        for requirement in requirements {
            let path = requirement.path
            let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            _ = try FrameRasterizer.loadImage(at: url)
            if let location = bible.locations.first(where: { $0.id == requirement.identityID }) {
                var nativeView = false
                for viewID in location.sheets.keys.sorted() where location.sheets[viewID] == path {
                    if try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: viewID, dataRoot: dataRoot) != nil {
                        nativeView = true
                    }
                }
                if nativeView { continue }
            }
            if let entry = proof.entries[path], entry.path == path,
               entry.sha256 == (try FileDigest.sha256(of: url)),
               !entry.providerPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !entry.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !entry.sourceMediaId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let role = requirement.confirmedRole, let identityID = requirement.identityID,
                  let name = requirement.identityName,
                  try ConfirmedIdentityAssetStoreV1.matchesCurrent(path, role: role,
                    identityID: identityID, identityName: name, dataRoot: dataRoot) else {
                throw GateBlocked("Bible asset \(path) needs current generated provenance or an explicit native identity assignment.")
            }
        }
        if validateVariants, let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: dataRoot) {
            try BibleIdentityVariantStoreV1.validate(variants, bible: bible, dataRoot: dataRoot)
        }
    }

    static func spatialBibleReferences(_ bible: Bible, _ dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        try bible.locations.flatMap { location in
            try location.sheets.keys.sorted().flatMap { viewID in
                try PipelineSpatialDerivationWriter.bibleViewReferences(location: location, viewID: viewID, dataRoot: dataRoot) ?? []
            }
        }
    }

    static func requireDesign(dataRoot: URL) throws {
        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let project = try store.load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let brief = try store.load(Brief.self, at: PipelineLayout.briefFile)
        let design = try store.load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
        try design.validate()
        guard design.project == project.project, brief.project == project.project,
              design.visualMedium == brief.visualMedium,
              design.visualMediumNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                == (brief.visualMediumNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
              Set(design.refs.map(\.path)).count == design.refs.count else {
            throw GateBlocked("Production Design must preserve this project's approved Brief and unique references.")
        }
        for path in design.refs.map(\.path) + (design.lightingAnchor.isEmpty ? [] : [design.lightingAnchor]) {
            _ = try FrameRasterizer.loadImage(at: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        }
        _ = try ProductionStyleStoreV1.load(dataRoot: dataRoot)
        try PipelineSpatialSceneAuthority.requireCurrent(dataRoot: dataRoot)
    }
}
