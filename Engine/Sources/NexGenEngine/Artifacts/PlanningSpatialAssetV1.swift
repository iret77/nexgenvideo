import Foundation

public enum PlanningSpatialAssetV1 {
    public static let provenanceKindID = "core.planning-spatial-geometry"
    public static let sourceRoleID = "core.spatial-geometry"
    public static let geometryScopeID = "core.preserve.geometry"
    public static let permittedScopeIDs: Set<String> = [geometryScopeID, "core.preserve.camera", "core.preserve.blocking", "core.preserve.composition"]

    public static func requireDemandPurpose(_ demand: ReferenceDemandV1, asset: AssetGraphNodeV1, targetShotID: String? = nil) throws {
        guard asset.provenance.kindID == provenanceKindID else { return }
        let image = asset.modality == .image && demand.modality == .image
            && ProductionIdentifierNormalizerV1.matches(demand.semanticJobID, CoreReferenceSemanticJobIDV1.referenceAnchor)
        let video = asset.modality == .video && demand.modality == .video && targetShotID != nil
            && targetShotID == asset.provenance.sourceShotID
            && ProductionIdentifierNormalizerV1.matches(demand.semanticJobID, CoreReferenceSemanticJobIDV1.motionReference)
        guard (image || video), Set(demand.preservationScopeIDs).contains(geometryScopeID),
              Set(demand.preservationScopeIDs).isSubset(of: permittedScopeIDs) else {
            throw ProductionPlanningError.invalid("spatialAsset.geometryOnlyPurpose")
        }
    }

    public static func requireProductionPurpose(_ requirement: GenerationRequirementV1, graph: AssetGraphV1) throws {
        let geometryIDs = Set(graph.assets.filter { $0.provenance.kindID == provenanceKindID }.map(\.id))
        guard Set(requirement.identityLockAssetIDs).isDisjoint(with: geometryIDs),
              requirement.sourceVideoAssetID.map({ !geometryIDs.contains($0) }) ?? true else {
            throw ProductionPlanningError.invalid("spatialAsset.notIdentityLock")
        }
    }

    public static func requireObligationPurpose(_ obligation: ShotPlanningDraftV1.Obligation, asset: AssetGraphNodeV1) throws {
        guard asset.provenance.kindID == provenanceKindID else { return }
        guard obligation.kind == .geometry, asset.modality == .geometry else {
            throw ProductionPlanningError.invalid("spatialAsset.notAppearanceOrLook")
        }
    }
}
