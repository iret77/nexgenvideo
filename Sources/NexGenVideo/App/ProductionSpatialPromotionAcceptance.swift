import Foundation
import NexGenEngine

enum ProductionSpatialPromotionAcceptance {
    static func verify(location: Location, viewID: String, bible: Bible, dataRoot: URL) throws -> [String: Bool] {
        guard let path = location.sheets[viewID] else { throw GateBlocked("The native spatial Bible view is missing.") }
        let image = try AssetGraphContentAddressV1.reidentified(.init(id: "pending", version: 1, path: path,
            sha256: FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot)), modality: .image,
            entityID: location.id, viewID: viewID, approval: .approved,
            provenance: .init(kindID: "core.planning-asset", recordedAt: "acceptance"),
            allowedUseIDs: [CoreReferenceSemanticJobIDV1.referenceAnchor]))
        let actual = try PipelineShotPlanningPromotionStore.normalizeAsset(image, bible: bible, dataRoot: dataRoot)
        guard actual.provenance.kindID == PlanningSpatialAssetV1.provenanceKindID,
              actual.provenance.sourceShotID == nil, actual.provenance.sourceProofPath != nil else {
            throw GateBlocked("The native geometry proof did not survive asset normalization.")
        }
        let graph = AssetGraphV1(id: try AssetGraphContentAddressV1.graphID(projectID: bible.project, assets: [actual]),
            projectID: bible.project, assets: [actual])
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
        for kind in [ShotPlanningDraftV1.Obligation.Kind.look, .locationAppearance] {
            var rejected = false
            do {
                try PlanningSpatialAssetV1.requireObligationPurpose(.init(id: "appearance", kind: kind,
                    subject: location.name, requirement: "The final colour and lighting", required: true), asset: actual)
            } catch { rejected = true }
            guard rejected else { throw GateBlocked("Neutral geometry was incorrectly admitted as final appearance.") }
        }
        let geometric = ReferenceDemandV1(id: "geometry", assetID: actual.id, modality: .image,
            semanticJobID: CoreReferenceSemanticJobIDV1.referenceAnchor, isRequired: true, priority: 0,
            preservationScopeIDs: [PlanningSpatialAssetV1.geometryScopeID], inputSlotID: CoreReferenceInputSlotIDV1.referenceImage,
            modeID: "keyframe")
        try PlanningSpatialAssetV1.requireDemandPurpose(geometric, asset: actual)
        let style = ReferenceDemandV1(id: "style", assetID: actual.id, modality: .image,
            semanticJobID: CoreReferenceSemanticJobIDV1.styleReference, isRequired: true, priority: 0,
            preservationScopeIDs: [PlanningSpatialAssetV1.geometryScopeID], inputSlotID: CoreReferenceInputSlotIDV1.referenceImage,
            modeID: "keyframe")
        var styleRejected = false
        do { try PlanningSpatialAssetV1.requireDemandPurpose(style, asset: actual) }
        catch { styleRejected = true }
        guard styleRejected else { throw GateBlocked("Neutral geometry was incorrectly admitted as a style reference.") }
        return ["nativeSpatialProofGraphAdmitted": true, "neutralSpatialRejectedAsAppearance": true,
                "neutralSpatialReferenceGeometryOnly": true]
    }
}
