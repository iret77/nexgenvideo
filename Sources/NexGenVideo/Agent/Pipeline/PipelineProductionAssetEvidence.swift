import Foundation
import NexGenEngine

enum PipelineProductionAssetEvidence {
    static func requireBible(_ bible: Bible, dataRoot: URL) throws {
        let requirements = BibleViewProvenanceRequirementsV1.make(bible: bible)
        let proof = try loadPipelineAssetProof(dataRoot: dataRoot, scope: "bible")
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard proof.schema == pipelineAssetProofSchemaVersion, proof.scope == "bible", proof.project == project.project,
              bible.project == project.project else { throw GateBlocked("Bible provenance belongs to another project or scope.") }
        for requirement in requirements {
            let path = requirement.path
            let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            _ = try FrameRasterizer.loadImage(at: url)
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
        if let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: dataRoot) {
            try BibleIdentityVariantStoreV1.validate(variants, bible: bible, dataRoot: dataRoot)
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
