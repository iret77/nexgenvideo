import Foundation
import Testing
@testable import NexGenEngine

@Suite("Neutral spatial references retain their geometric purpose")
struct PlanningSpatialAssetV1Tests {
    @Test func geometryObligationsAcceptSceneGeometryAndRejectItsPreviewImage() throws {
        let preview = try spatialImage()
        let geometry = AssetGraphNodeV1(id: "scene", version: 1, path: "locations/room/scene.blend",
            sha256: String(repeating: "2", count: 64), modality: .geometry, entityID: "room", approval: .approved,
            provenance: preview.provenance, allowedUseIDs: [CoreReferenceSemanticJobIDV1.referenceAnchor])
        let obligation = ShotPlanningDraftV1.Obligation(id: "geometry", kind: .geometry,
            subject: "Room geometry", requirement: "The approved scene", required: true)
        try PlanningSpatialAssetV1.requireObligationPurpose(obligation, asset: geometry)
        #expect(throws: ProductionPlanningError.invalid("spatialAsset.notAppearanceOrLook")) {
            try PlanningSpatialAssetV1.requireObligationPurpose(obligation, asset: preview)
        }
    }

    @Test func nativeGeometryProofDoesNotClaimFrameOrTakeProvenance() throws {
        let asset = try spatialImage()
        let graph = try graph(asset)
        try AssetGraphValidatorV1.validate(graph)
        let data = try AssetGraphCanonicalCodecV1.encode(graph)
        let geometry = demand(asset, scope: [PlanningSpatialAssetV1.geometryScopeID])
        let set = ReferenceDemandSetV1(id: "geometry-demands", projectID: "fixture", shotID: "shot-00000000-0000-0000-0000-000000000001",
            assetGraph: .init(id: graph.id, role: AssetGraphV1.artifactRole, path: PipelineLayout.assetGraphFile, sha256: FileDigest.sha256(of: data)), demands: [geometry])
        try AssetGraphValidatorV1.validate(set, against: graph)
        #expect(asset.provenance.sourceShotID == nil)
    }

    @Test func neutralClayCannotFulfilAppearanceLookOrIdentityLocks() throws {
        let asset = try spatialImage()
        for kind in [ShotPlanningDraftV1.Obligation.Kind.look, .locationAppearance, .characterIdentity, .stateVariant] {
            #expect(throws: ProductionPlanningError.self) {
                try PlanningSpatialAssetV1.requireObligationPurpose(.init(id: "obligation", kind: kind,
                    subject: "The same room", requirement: "Approved appearance", required: true), asset: asset)
            }
        }
        let requirement = GenerationRequirementV1(modalityID: "video", modeIDs: ["keyframe"], visibleEntityCount: 0,
            identityLockAssetIDs: [asset.id])
        #expect(throws: ProductionPlanningError.self) {
            try PlanningSpatialAssetV1.requireProductionPurpose(requirement, graph: graph(asset))
        }
    }

    @Test func geometricReferenceCannotBeRelabelledAsLookLightingOrIdentity() throws {
        let asset = try spatialImage()
        for role in [CoreReferenceSemanticJobIDV1.styleReference, CoreReferenceSemanticJobIDV1.lightingReference,
                     CoreReferenceSemanticJobIDV1.firstFrame] {
            #expect(throws: ProductionPlanningError.self) {
                try PlanningSpatialAssetV1.requireDemandPurpose(demand(asset, role: role, scope: [PlanningSpatialAssetV1.geometryScopeID]), asset: asset)
            }
        }
        for scope in [[], ["identity"], [PlanningSpatialAssetV1.geometryScopeID, "core.preserve.look"]] {
            #expect(throws: ProductionPlanningError.self) {
                try PlanningSpatialAssetV1.requireDemandPurpose(demand(asset, scope: scope), asset: asset)
            }
        }
        try PlanningSpatialAssetV1.requireDemandPurpose(demand(asset,
            scope: [PlanningSpatialAssetV1.geometryScopeID, "core.preserve.camera"]), asset: asset)
    }

    @Test func fullShotClayVideoIsOnlyMotionGeometryForItsActualShot() throws {
        let shot = "shot-00000000-0000-0000-0000-000000000001"
        let namespace = "00000000-0000-4000-8000-000000000002"
        let receipt = "00000000-0000-4000-8000-000000000003"
        let asset = try AssetGraphContentAddressV1.reidentified(.init(id: "pending", version: 1,
            path: "execution/blockout/\(namespace)/native-\(receipt)/blockout.mov", sha256: String(repeating: "2", count: 64), modality: .video,
            approval: .approved, provenance: .init(kindID: PlanningSpatialAssetV1.provenanceKindID,
                sourceShotID: shot, sourceRoleID: PlanningSpatialAssetV1.sourceRoleID,
                sourceProofPath: "shot-planning/native-blockouts/\(receipt).v1.json", sourceProofSHA256: String(repeating: "3", count: 64), recordedAt: "fixture"),
            allowedUseIDs: [CoreReferenceSemanticJobIDV1.motionReference], durationSeconds: 2))
        try AssetGraphValidatorV1.validate(graph(asset))
        let motion = ReferenceDemandV1(id: "motion", assetID: asset.id, modality: .video,
            semanticJobID: CoreReferenceSemanticJobIDV1.motionReference, isRequired: true, priority: 0,
            preservationScopeIDs: [PlanningSpatialAssetV1.geometryScopeID], inputSlotID: "video-reference", modeID: "video-to-video")
        try PlanningSpatialAssetV1.requireDemandPurpose(motion, asset: asset, targetShotID: shot)
        for wrong in [nil, "shot-00000000-0000-0000-0000-000000000002"] {
            #expect(throws: ProductionPlanningError.self) {
                try PlanningSpatialAssetV1.requireDemandPurpose(motion, asset: asset, targetShotID: wrong)
            }
        }
        #expect(throws: ProductionPlanningError.self) {
            try PlanningSpatialAssetV1.requireProductionPurpose(.init(modalityID: "video", modeIDs: ["video-to-video"],
                visibleEntityCount: 0, sourceVideoAssetID: asset.id), graph: graph(asset))
        }
    }

    private func graph(_ asset: AssetGraphNodeV1) throws -> AssetGraphV1 {
        .init(id: try AssetGraphContentAddressV1.graphID(projectID: "fixture", assets: [asset]), projectID: "fixture", assets: [asset])
    }

    private func spatialImage() throws -> AssetGraphNodeV1 {
        try AssetGraphContentAddressV1.reidentified(.init(id: "pending", version: 1,
            path: "bible/location/clay.png", sha256: String(repeating: "0", count: 64), modality: .image,
            entityID: "room", viewID: "wide", approval: .approved,
            provenance: .init(kindID: PlanningSpatialAssetV1.provenanceKindID, sourceRoleID: PlanningSpatialAssetV1.sourceRoleID,
                sourceProofPath: "bible/location/derivation.v1.json", sourceProofSHA256: String(repeating: "1", count: 64), recordedAt: "fixture"),
            allowedUseIDs: [CoreReferenceSemanticJobIDV1.referenceAnchor]))
    }

    private func demand(_ asset: AssetGraphNodeV1, role: String = CoreReferenceSemanticJobIDV1.referenceAnchor,
                        scope: [String]) -> ReferenceDemandV1 {
        .init(id: "geometry", assetID: asset.id, modality: .image, semanticJobID: role, isRequired: true,
            priority: 0, preservationScopeIDs: scope, inputSlotID: CoreReferenceInputSlotIDV1.referenceImage, modeID: "keyframe")
    }
}
