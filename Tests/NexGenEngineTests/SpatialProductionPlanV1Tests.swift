import Foundation
import Testing
@testable import NexGenEngine

@Suite("Spatial production plan V1")
struct SpatialProductionPlanV1Tests {
    @Test("multi-axis vertical geography requires and accepts a concrete blockout")
    func acceptsConcreteSpatialPlan() throws {
        try SpatialProductionValidatorV1.validate(draft())
    }

    @Test("unknown setups and overlapping internal shots fail before generation")
    func rejectsUnknownAndOverlappingShots() {
        let unknown = shot(
            id: "s001",
            setupID: "missing-setup",
            start: 0,
            end: 3,
            startStateID: "room-v1",
            endStateID: "room-v2"
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(draft(shots: [unknown]))
        }

        let first = shot(
            id: "s001",
            setupID: "wide-a",
            start: 0,
            end: 4,
            startStateID: "room-v1",
            endStateID: "room-v2"
        )
        let overlapping = shot(
            id: "s002",
            setupID: "wide-b",
            start: 3,
            end: 6,
            startStateID: "room-v2",
            endStateID: "room-v2"
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(draft(shots: [first, overlapping]))
        }
    }

    @Test("multi-shot generations require real cuts and shot-owned timed anchors")
    func rejectsAmbiguousInternalTakePlan() {
        let noInternalCut = shot(
            id: "s010",
            setupID: "wide-a",
            start: 0,
            end: 3,
            startStateID: "room-v1",
            endStateID: "room-v2"
        )
        let final = shot(
            id: "s002",
            setupID: "wide-b",
            start: 3,
            end: 6,
            startStateID: "room-v2",
            endStateID: "room-v2"
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(
                draft(shots: [noInternalCut, final])
            )
        }

        let first = shot(
            id: "s001",
            setupID: "wide-a",
            start: 0,
            end: 3,
            startStateID: "room-v1",
            endStateID: "room-v2",
            timedRoleID: "shared-role",
            timedDemandID: "shared-demand"
        )
        let reusedAnchor = shot(
            id: "s002",
            setupID: "wide-b",
            start: 3,
            end: 6,
            startStateID: "room-v2",
            endStateID: "room-v2",
            timedRoleID: "shared-role",
            timedDemandID: "shared-demand"
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(
                draft(shots: [first, reusedAnchor])
            )
        }
    }

    @Test("state versions require an explicit causal beat")
    func rejectsUncausedState() {
        let invalidState = ProductionStateV1(
            id: "room-v1",
            entityID: "room",
            version: 1,
            description: "The intact rehearsal room.",
            causeBeatID: "   "
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(draft(states: [invalidState]))
        }
    }

    @Test("complex geography cannot omit its blockout")
    func rejectsMissingBlockout() {
        let none = BlockoutRequestV1(
            mode: .none,
            width: 1920,
            height: 1080,
            fps: 24,
            durationSeconds: 6
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(draft(blockout: none))
        }
    }

    @Test("blockout proof binds exact plan and clip bytes")
    func blockoutProofBindsBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spatial-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clip = root.appendingPathComponent("pipeline/spatial/blockout.mov")
        try FileManager.default.createDirectory(
            at: clip.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("blockout".utf8).write(to: clip)
        let draft = draft()
        let shotlistSHA256 = hash("f")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let setupData = try encoder.encode(CameraSetupPlanV1(
            projectID: "demo",
            shotlistSHA256: shotlistSHA256,
            activation: draft.activation,
            setups: draft.setups
        ))
        let cutData = try encoder.encode(ShotGenerationCutPlanV1(
            projectID: "demo",
            shotlistSHA256: shotlistSHA256,
            shots: draft.shots
        ))
        let stateData = try encoder.encode(StateLadderV1(
            projectID: "demo",
            shotlistSHA256: shotlistSHA256,
            states: draft.states
        ))
        let layoutData = try encoder.encode(LayoutPanelsV1(
            projectID: "demo",
            shotlistSHA256: shotlistSHA256,
            layouts: draft.layouts,
            shapes: draft.shapes,
            panels: draft.panels
        ))
        let proof = BlockoutProofV1(
            projectID: "demo",
            sourceMode: .native,
            cameraSetupPlanSHA256: FileDigest.sha256(of: setupData),
            shotGenerationCutPlanSHA256: FileDigest.sha256(of: cutData),
            stateLadderSHA256: FileDigest.sha256(of: stateData),
            layoutPanelsSHA256: FileDigest.sha256(of: layoutData),
            clipPath: "pipeline/spatial/blockout.mov",
            clipSHA256: try FileDigest.sha256(of: clip),
            container: "quicktime",
            width: 1920,
            height: 1080,
            fps: 24,
            durationSeconds: 6,
            setupIDs: ["wide-a", "wide-b"],
            shapeIDs: ["room-shell"],
            entityStateIDs: ["room-v1", "room-v2"]
        )

        try SpatialProductionValidatorV1.validate(
            proof: proof,
            cameraSetupPlanData: setupData,
            shotGenerationCutPlanData: cutData,
            stateLadderData: stateData,
            layoutPanelsData: layoutData,
            dataRoot: root
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(
                proof: proof,
                cameraSetupPlanData: Data("changed".utf8),
                shotGenerationCutPlanData: cutData,
                stateLadderData: stateData,
                layoutPanelsData: layoutData,
                dataRoot: root
            )
        }
        let wrongAssignment = BlockoutProofV1(
            projectID: proof.projectID,
            sourceMode: proof.sourceMode,
            cameraSetupPlanSHA256: proof.cameraSetupPlanSHA256,
            shotGenerationCutPlanSHA256: proof.shotGenerationCutPlanSHA256,
            stateLadderSHA256: proof.stateLadderSHA256,
            layoutPanelsSHA256: proof.layoutPanelsSHA256,
            clipPath: proof.clipPath,
            clipSHA256: proof.clipSHA256,
            container: proof.container,
            width: proof.width,
            height: proof.height,
            fps: proof.fps,
            durationSeconds: proof.durationSeconds,
            setupIDs: proof.setupIDs,
            shapeIDs: ["substituted-shape"],
            entityStateIDs: proof.entityStateIDs
        )
        #expect(throws: SpatialProductionValidationErrorV1.self) {
            try SpatialProductionValidatorV1.validate(
                proof: wrongAssignment,
                cameraSetupPlanData: setupData,
                shotGenerationCutPlanData: cutData,
                stateLadderData: stateData,
                layoutPanelsData: layoutData,
                dataRoot: root
            )
        }
    }

    private func draft(
        shots: [PlannedGenerationShotV1]? = nil,
        states: [ProductionStateV1]? = nil,
        blockout: BlockoutRequestV1? = nil
    ) -> SpatialProductionPlanDraftV1 {
        let resolvedStates = states ?? [
            ProductionStateV1(
                id: "room-v1",
                entityID: "room",
                version: 1,
                description: "The intact rehearsal room.",
                causeBeatID: "arrival"
            ),
            ProductionStateV1(
                id: "room-v2",
                entityID: "room",
                version: 2,
                description: "The landing light is now on.",
                causeBeatID: "switch-light"
            ),
        ]
        return SpatialProductionPlanDraftV1(
            activation: SpatialPlanActivationV1(
                verticalGeography: true,
                axisIDs: ["room-axis", "stair-axis"],
                documentedSpatialDrift: false,
                rationale: "The action crosses two axes and a raised landing."
            ),
            setups: [setup(id: "wide-a", axisID: "room-axis", x: -3),
                     setup(id: "wide-b", axisID: "stair-axis", x: 3)],
            shots: shots ?? [
                shot(
                    id: "s001",
                    setupID: "wide-a",
                    start: 0,
                    end: 3,
                    startStateID: "room-v1",
                    endStateID: "room-v2"
                ),
                shot(
                    id: "s002",
                    setupID: "wide-b",
                    start: 3,
                    end: 6,
                    startStateID: "room-v2",
                    endStateID: "room-v2"
                ),
            ],
            states: resolvedStates,
            layouts: [SpatialLayoutV1(
                locationID: "rehearsal-room",
                widthMeters: 8,
                depthMeters: 6,
                heightMeters: 5,
                setupIDs: ["wide-a", "wide-b"]
            )],
            shapes: [BlockoutShapeV1(
                id: "room-shell",
                entityID: "room",
                entityStateIDs: resolvedStates.map(\.id),
                locationID: "rehearsal-room",
                primitive: .box,
                center: SpatialVector3V1(x: 0, y: 0.05, z: 0),
                size: SpatialVector3V1(x: 8, y: 0.1, z: 6),
                headingDegrees: 0
            )],
            panels: [
                LookFreePanelV1(
                    id: "panel-a",
                    setupID: "wide-a",
                    path: "pipeline/spatial/panel-a.png",
                    sha256: hash("a"),
                    lookFree: true
                ),
                LookFreePanelV1(
                    id: "panel-b",
                    setupID: "wide-b",
                    path: "pipeline/spatial/panel-b.png",
                    sha256: hash("b"),
                    lookFree: true
                ),
            ],
            blockout: blockout ?? BlockoutRequestV1(
                mode: .native,
                width: 1920,
                height: 1080,
                fps: 24,
                durationSeconds: 6
            )
        )
    }

    private func setup(id: String, axisID: String, x: Double) -> CameraSetupV1 {
        CameraSetupV1(
            id: id,
            locationID: "rehearsal-room",
            position: SpatialVector3V1(x: x, y: 1.6, z: -4),
            orientationDegrees: SpatialVector3V1(x: 0, y: 0, z: 0),
            axisID: axisID,
            axisSide: .positive,
            heightMeters: 1.6,
            focalLengthMM: 35,
            horizontalFOVDegrees: 54,
            lookTarget: "raised landing",
            path: [CameraPathKeyframeV1(
                timeSeconds: 0,
                position: SpatialVector3V1(x: x, y: 1.6, z: -4),
                lookAt: SpatialVector3V1(x: 0, y: 1.5, z: 0)
            )]
        )
    }

    private func shot(
        id: String,
        setupID: String,
        start: Double,
        end: Double,
        startStateID: String,
        endStateID: String,
        timedRoleID: String? = nil,
        timedDemandID: String? = nil
    ) -> PlannedGenerationShotV1 {
        PlannedGenerationShotV1(
            shotID: id,
            generationID: "generation-1",
            setupID: setupID,
            internalStartSeconds: start,
            internalEndSeconds: end,
            cutAfter: id == "s001" ? .modelInternal : .none,
            startStateID: startStateID,
            endStateID: endStateID,
            continuityIn: ["screen-direction-left-to-right"],
            continuityOut: ["screen-direction-left-to-right"],
            timedReferences: [TimedReferenceAnchorV1(
                roleID: timedRoleID ?? "identity-\(id)",
                demandID: timedDemandID ?? "demand-\(id)",
                timeSeconds: start
            )]
        )
    }

    private func hash(_ value: String) -> String {
        String(repeating: value, count: 64)
    }
}
