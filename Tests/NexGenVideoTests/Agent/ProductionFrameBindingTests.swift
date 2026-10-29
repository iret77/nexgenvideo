import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Production frame boundary authority")
struct ProductionFrameBindingTests {
    @Test func endGeometryDrivesTheActualImageProjectionAndAuditTogether() throws {
        let shot = boundaryShot()
        let intent = ShotPlanningDraftV1.ShotIntent(shotID: shot.id, sourceMode: .generated,
            camera: .init(framing: .init(scale: "wide", composition: "left wall", cameraView: "low angle"), movement: .static), obligations: [])
        let end = ProductionFrameBoundaryV1(characterCount: 2, characterPositions: "Beside the right window", gaze: "Look outside",
            visibleZones: ["right window"], framing: "close-up", cameraAngle: "high angle", cameraHeight: "Above head height")
        let startAudit = try FrameAuditExpectations.makeProduction(shot: shot, intent: intent, role: "start", allowTextOverlays: false, endBoundary: end)
        let endAudit = try FrameAuditExpectations.makeProduction(shot: shot, intent: intent, role: "end", allowTextOverlays: false, endBoundary: end)
        #expect(startAudit["framing"] == "wide")
        #expect(endAudit["framing"] == "close-up")
        #expect(endAudit["camera_angle"] == "high angle")
        #expect(endAudit["camera_height"] == "Above head height")
        #expect(endAudit["character_count"] == "2")
        #expect(endAudit["visible_zones"] == "right window")
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture")
        let projected = PromptComposer.ShotProjection(execution: shot, intent: intent, bible: bible,
            boundaryRole: "end", endBoundary: end)
        #expect(projected.composition == "right window")
        #expect(projected.spec.framing == "close-up")
        #expect(projected.spec.cameraHeight == "Above head height")
        #expect(projected.camera.contains("high angle"))
        #expect(!projected.camera.contains("low angle"))
        let video = PromptComposer.ShotProjection(execution: shot, intent: intent, bible: bible, endBoundary: end)
        #expect(video.composition == "left wall")
        #expect(video.spec.framing == "wide")
        #expect(throws: (any Error).self) {
            try FrameAuditExpectations.makeProduction(shot: shot, intent: intent, role: "end", allowTextOverlays: false, endBoundary: nil)
        }
    }

    @Test func movingEndCameraRequiresDistinctDeclaredFields() throws {
        let incomplete = ProductionFrameBoundaryV1(characterCount: 0, characterPositions: "", gaze: "", visibleZones: [])
        try incomplete.validate(movingCamera: false)
        #expect(throws: ProductionPlanningError.invalid("frameBoundary.movingCamera")) {
            try incomplete.validate(movingCamera: true)
        }
        let complete = ProductionFrameBoundaryV1(characterCount: 0, characterPositions: "", gaze: "", visibleZones: [],
            framing: "wide", cameraAngle: "front", cameraHeight: "eye level")
        try complete.validate(movingCamera: true)
        let shot = boundaryShot()
        #expect(PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "start", endBoundary: complete)
            == PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "start"))
        #expect(PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "end", endBoundary: complete).contains("Camera height: eye level"))
    }

    @Test("Identical boundary descriptions require and preserve the explicit role")
    func identicalBoundaryRoles() throws {
        let shot = boundaryShot()
        let intent = PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "start")
        #expect(intent == PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "end"))
        for role in ["start", "end"] {
            #expect(try PipelineProductionFramesWriter.boundaryRole(intent: intent, requestedRole: role,
                shot: shot, requiredRoles: ["start", "end"]) == role)
        }
        #expect(throws: (any Error).self) {
            try PipelineProductionFramesWriter.boundaryRole(intent: intent, requestedRole: nil,
                shot: shot, requiredRoles: ["start", "end"])
        }
    }

    @Test("An explicit role cannot change intent or request a nonrequired boundary")
    func roleAndIntentMustMatch() throws {
        let shot = boundaryShot(end: "The figure has left the room")
        let start = PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "start")
        let end = PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: "end")
        #expect(try PipelineProductionFramesWriter.boundaryRole(intent: start, requestedRole: nil,
            shot: shot, requiredRoles: ["start", "end"]) == "start")
        #expect(try PipelineProductionFramesWriter.boundaryRole(intent: " \n" + end, requestedRole: nil,
            shot: shot, requiredRoles: ["start", "end"]) == "end")
        for (intent, role, required) in [(start, "end", ["start", "end"]), (end, "end", ["start"]),
                                        (start, "middle", ["start", "end"]), (start, "start", [])] {
            #expect(throws: (any Error).self) {
                try PipelineProductionFramesWriter.boundaryRole(intent: intent, requestedRole: role,
                    shot: shot, requiredRoles: required)
            }
        }
        let same = boundaryShot()
        #expect(try PipelineProductionFramesWriter.boundaryRole(intent: start, requestedRole: nil,
            shot: same, requiredRoles: ["start"]) == "start")
    }

    @Test("Multiline canonical boundaries match the actual composed image subject")
    func whitespaceNormalizationSurvivesCompilationAndRecordComparison() async throws {
        let shot = ExecutionShotV1(id: "00000000-0000-4000-8000-000000000001", sourceMode: .generated,
            startState: .init(summary: "  A   still\nfigure in a fixed room ", spatialState: " Beside  the\twindow "),
            endState: .init(summary: " The figure  stands\nbeside the window ", spatialState: "At\t the  window"),
            primaryAction: "Hold still", camera: .init(movementID: "static", placement: " fixed \n camera ", endpoint: " fixed\ncamera "),
            renderability: .green)
        let boundary = ProductionFrameBoundaryV1(characterCount: 1, characterPositions: "Beside   window", gaze: "Look\tnorth",
            visibleZones: [" right\nwindow"], framing: " close  up ", cameraAngle: "high\nangle", cameraHeight: "eye\tlevel")
        for (role, expected) in [
            ("start", "A still figure in a fixed room; Beside the window; fixed camera"),
            ("end", "The figure stands beside the window; At the window; fixed camera; Visible characters: 1; Character positions: Beside window; Gaze: Look north; Visible zones: right window; Framing: close up; Camera angle: high angle; Camera height: eye level")
        ] {
            let canonical = PipelineProductionFramesWriter.boundaryIntent(shot: shot, role: role, endBoundary: boundary)
            #expect(canonical == expected)
            let multilineInput = " \n" + canonical.replacingOccurrences(of: " ", with: " \t\n ") + "\n "
            #expect(try PipelineProductionFramesWriter.boundaryRole(intent: multilineInput, requestedRole: role,
                shot: shot, requiredRoles: ["start", "end"], endBoundary: boundary) == role)
            let actual = try await PromptComposer.compose(intent: multilineInput, modality: .image,
                modelId: "openai/gpt-image-2", projectDir: nil, capturesImageIR: true)
            let bytes = try #require(actual.sourceIRData)
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["subject"] as? String == canonical)
        }
        #expect(throws: (any Error).self) {
            try PipelineProductionFramesWriter.boundaryRole(intent: "A different pose", requestedRole: "start",
                shot: shot, requiredRoles: ["start", "end"], endBoundary: boundary)
        }
    }

    @Test("Frame roles cannot be attached to free generation")
    func freeGenerationRejectsBoundaryRole() async {
        for modality in [PromptComposer.Modality.image, .video] {
            do {
                _ = try await PromptCompiler.compile(intent: "A still figure", modelId: "fixture",
                    modality: modality, editor: nil, frameRole: "end")
                Issue.record("Free generation accepted a production frame role")
            } catch {
                #expect(error.localizedDescription == "frameRole is only available for a planned production boundary image.")
            }
        }
    }

    @Test("The real compile tool exposes the additive constrained role")
    func roleSchema() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .compilePrompt })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let role = try #require(properties["frameRole"] as? [String: Any])
        #expect(role["enum"] as? [String] == ["start", "end"])
        #expect((tool.inputSchema["required"] as? [String])?.contains("frameRole") == false)
    }

    @Test("An identical prompt cannot reuse a start-frame token for the end frame")
    func boundaryRemainsPartOfAuthority() throws {
        let start = PromptBinding(projectKey: "project", shotId: "shot", shotFingerprint: "plan", frameRole: "start")
        let end = PromptBinding(projectKey: "project", shotId: "shot", shotFingerprint: "plan", frameRole: "end")
        let text = "A still figure in a fixed room."
        let token = PromptCompiler.token(for: text, modelId: "image-model", binding: start)
        #expect(PromptCompiler.validate(token: token, text: text, modelId: "image-model", binding: start))
        #expect(!PromptCompiler.validate(token: token, text: text, modelId: "image-model", binding: end))
        #expect(!start.matchesCurrentState(of: end))
        #expect(!start.withPromptIRSHA256("image-ir").matchesCurrentState(of: end.withPromptIRSHA256("image-ir")))
        let restored = try JSONDecoder().decode(PromptBinding.self, from: JSONEncoder().encode(end))
        #expect(restored == end)
    }

    private func boundaryShot(end: String = "A still figure in a fixed room") -> ExecutionShotV1 {
        .init(id: "00000000-0000-4000-8000-000000000001", sourceMode: .generated,
            startState: .init(summary: "A still figure in a fixed room"), endState: .init(summary: end),
            primaryAction: "Hold still", camera: .init(movementID: "static", placement: "fixed", endpoint: "fixed"),
            renderability: .green)
    }
}
