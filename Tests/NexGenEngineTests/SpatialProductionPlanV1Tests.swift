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
        let setupData = Data("setups".utf8)
        let cutData = Data("cuts".utf8)
        let stateData = Data("states".utf8)
        let layoutData = Data("layouts".utf8)
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
    }

    private func draft(
        shots: [PlannedGenerationShotV1]? = nil,
        states: [ProductionStateV1]? = nil,
        blockout: BlockoutRequestV1? = nil
    ) -> SpatialProductionPlanDraftV1 {
        SpatialProductionPlanDraftV1(
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
            states: states ?? [
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
            ],
            layouts: [SpatialLayoutV1(
                locationID: "rehearsal-room",
                widthMeters: 8,
                depthMeters: 6,
                heightMeters: 5,
                setupIDs: ["wide-a", "wide-b"]
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
        endStateID: String
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
                roleID: "identity",
                demandID: "demand-\(id)",
                timeSeconds: start
            )]
        )
    }

    private func hash(_ value: String) -> String {
        String(repeating: value, count: 64)
    }
}
