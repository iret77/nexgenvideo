import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Explicit static placement at the production end boundary")
struct ProductionStaticEndCameraTests {
    @Test func staticEndPreservesApprovedPlacementWithoutInventingAnEndpoint() throws {
        let shot = shot(movement: .static)
        let intent = intent(movement: .static)
        let end = ProductionFrameBoundaryV1(characterCount: 0, characterPositions: "", gaze: "", visibleZones: [])
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture")
        let projected = PromptComposer.ShotProjection(execution: shot, intent: intent, bible: bible,
            boundaryRole: "end", endBoundary: end)
        let audit = try FrameAuditExpectations.makeProduction(shot: shot, intent: intent, role: "end",
            allowTextOverlays: false, endBoundary: end)
        #expect(shot.camera.endpoint == nil)
        #expect(projected.camera.contains("tripod beside the left doorway"))
        #expect(audit["camera_height"] == "Keep the approved static camera placement: tripod beside the left doorway")
        #expect(audit["character_count"] == "0")
        #expect(audit["visible_zones"] == "")
    }

    @Test func movingEndDoesNotBorrowTheStartPlacement() throws {
        let shot = shot(movement: .pan)
        let intent = intent(movement: .pan)
        let end = ProductionFrameBoundaryV1(characterCount: 0, characterPositions: "", gaze: "", visibleZones: [],
            framing: "wide", cameraAngle: "toward the right wall", cameraHeight: "eye level")
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture")
        let projected = PromptComposer.ShotProjection(execution: shot, intent: intent, bible: bible,
            boundaryRole: "end", endBoundary: end)
        let audit = try FrameAuditExpectations.makeProduction(shot: shot, intent: intent, role: "end",
            allowTextOverlays: false, endBoundary: end)
        #expect(!projected.camera.contains("tripod beside the left doorway"))
        #expect(projected.camera.contains("toward the right wall"))
        #expect(audit["camera_height"] == "eye level")
    }

    private func shot(movement: CameraMovement) -> ExecutionShotV1 {
        .init(id: "shot-00000000-0000-0000-0000-000000000001", sourceMode: .generated,
            startState: .init(summary: "Empty doorway"), endState: .init(summary: "Empty room"), primaryAction: "Hold the empty room",
            camera: .init(movementID: movement.rawValue, placement: "tripod beside the left doorway"), renderability: .green)
    }

    private func intent(movement: CameraMovement) -> ShotPlanningDraftV1.ShotIntent {
        .init(shotID: "shot-00000000-0000-0000-0000-000000000001", sourceMode: .generated,
            camera: .init(framing: .init(scale: "wide", composition: "left doorway", cameraView: "front"), movement: movement), obligations: [])
    }
}
