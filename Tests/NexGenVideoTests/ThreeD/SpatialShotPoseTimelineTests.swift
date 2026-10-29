import Foundation
import Testing
import simd
@testable import NexGenVideo

@Suite("Shot camera and object keyframes")
struct SpatialShotPoseTimelineTests {
    @Test func everyFrameKeepsFullObjectPoseAndExactEndpoints() throws {
        let first = try pose(frame: 0, position: [0, 2, 4], rotation: [0, 0, 0], scale: [1, 1, 1], fov: 0.6)
        let last = try pose(frame: 4, position: [8, 6, 12], rotation: [0, 0, 90], scale: [3, 3, 3], fov: 1.0)
        let timeline = SpatialShotPoseTimeline(frameCount: 5, keyframes: [0: first, 4: last])
        let state = try timeline.resolve(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera")
        #expect(state.frames.map(\.frame) == [0, 1, 2, 3, 4])
        #expect(state.frames.first == first)
        #expect(state.frames.last == last)
        let middle = state.frames[2]
        let matrix = try SpatialShotPoseTimeline.matrix(middle.objects[0].matrixWorld)
        #expect(abs(matrix[3].x - 4) < 0.000001)
        #expect(abs(matrix[3].y - 4) < 0.000001)
        #expect(abs(matrix[3].z - 8) < 0.000001)
        #expect(abs(matrix[0].x - sqrt(2)) < 0.000001)
        #expect(abs(matrix[0].y - sqrt(2)) < 0.000001)
        #expect(abs(middle.cameraVerticalFieldOfView - 0.8) < 0.000001)
        #expect(middle.objects.map(\.objectID) == ["camera", "actor"])
        #expect(middle.objects[1] == first.objects[1])
    }

    @Test func rotationCrossesTheShortArcAt180Degrees() throws {
        let first = try pose(frame: 0, position: .zero, rotation: [0, 0, 170])
        let last = try pose(frame: 2, position: .zero, rotation: [0, 0, -170])
        let middle = try SpatialShotPoseTimeline(frameCount: 3, keyframes: [0: first, 2: last]).resolved(at: 1)
        let matrix = try SpatialShotPoseTimeline.matrix(middle.objects[0].matrixWorld)
        #expect(abs(matrix[0].x + 1) < 0.000001)
        #expect(abs(matrix[0].y) < 0.000001)
    }

    @Test(arguments: [90.0, -90.0]) func inspectorPreservesVerticalCameraOrientation(pitch: Double) throws {
        let matrix = try SpatialShotPoseTimeline.transform(position: [1, 2, 3], rotationDegrees: [23, pitch, 47], scale: [1, 2, 3])
        let parts = try SpatialShotPoseTimeline.components(matrix)
        let restored = try SpatialShotPoseTimeline.transform(position: parts.position, rotationDegrees: parts.rotation, scale: parts.scale)
        #expect(zip(matrix, restored).allSatisfy { abs($0 - $1) < 0.000001 })
    }

    @Test func incompleteObjectSetsAndDuplicateIDsThrowInsteadOfLosingGeometry() throws {
        let first = try pose(frame: 0, position: .zero, rotation: .zero)
        let missing = SpatialClayStateFrame(frame: 2, objects: [first.objects[0]], cameraVerticalFieldOfView: 0.6)
        #expect(throws: SpatialSceneError.self) { _ = try SpatialShotPoseTimeline(frameCount: 3, keyframes: [0: first, 2: missing]).resolved(at: 1) }
        let duplicate = SpatialClayStateFrame(frame: 2, objects: [first.objects[0], first.objects[0]], cameraVerticalFieldOfView: 0.6)
        #expect(throws: SpatialSceneError.self) { _ = try SpatialShotPoseTimeline(frameCount: 3, keyframes: [0: first, 2: duplicate]).resolved(at: 1) }
        #expect(throws: SpatialSceneError.self) { _ = try SpatialShotPoseTimeline(frameCount: 3, keyframes: [0: first]).resolved(at: 2) }
    }

    @Test func changingShearedPoseRequiresGeometryCorrection() throws {
        var matrix = try SpatialShotPoseTimeline.transform(position: .zero, rotationDegrees: .zero, scale: [1, 1, 1])
        matrix[1] = 0.5
        let first = SpatialClayStateFrame(frame: 0, objects: [.init(objectID: "camera", matrixWorld: matrix)], cameraVerticalFieldOfView: 0.6)
        var moved = matrix; moved[3] = 2
        let last = SpatialClayStateFrame(frame: 2, objects: [.init(objectID: "camera", matrixWorld: moved)], cameraVerticalFieldOfView: 0.6)
        #expect(throws: SpatialSceneError.self) { _ = try SpatialShotPoseTimeline(frameCount: 3, keyframes: [0: first, 2: last]).resolved(at: 1) }
    }

    @Test func unsupportedObjectKeepsItsMatrixAndDoesNotTrapNavigation() throws {
        var original = try pose(frame: 0, position: [8, 9, 10], rotation: .zero)
        var sheared = original.objects[1].matrixWorld
        sheared[1] = 0.5
        original = .init(frame: 0, objects: [original.objects[0], .init(objectID: "actor", matrixWorld: sheared)], cameraVerticalFieldOfView: 0.6)
        var edit = SpatialShotPoseEdit(pose: original, objectID: "actor")
        #expect(!edit.transformEditable && !edit.hasChanges && !edit.canSetKeyframe)
        #expect(edit.failure != nil)
        #expect(try edit.applying() == original)
        edit.fieldOfView = 75
        #expect(edit.hasChanges && edit.canSetKeyframe)
        let changed = try edit.applying()
        #expect(changed.objects == original.objects)
        #expect(abs(changed.cameraVerticalFieldOfView - 75 * .pi / 180) < 0.000001)
        let camera = SpatialShotPoseEdit(pose: changed, objectID: "camera")
        #expect(camera.transformEditable && !camera.hasChanges)
    }

    @Test func inspectingNearSingularRotationDoesNotInventEdits() throws {
        let original = try pose(frame: 1, position: [1, 2, 3], rotation: [23, 89.99995, 47])
        let edit = SpatialShotPoseEdit(pose: original, objectID: "camera")
        #expect(edit.transformEditable && !edit.hasChanges)
        #expect(try edit.applying() == original)
    }

    @Test func authoringKeyframesSurviveReloadWithoutMakingEveryFrameEditable() throws {
        let first = try pose(frame: 0, position: .zero, rotation: .zero)
        let middle = try pose(frame: 3, position: [9, 0, 0], rotation: [0, 0, 40])
        let last = try pose(frame: 7, position: [1, 2, 3], rotation: [0, 0, 90])
        let source = SpatialShotPoseTimeline(frameCount: 8, keyframes: [0: first, 3: middle, 7: last])
        let state = try source.resolve(sceneManifestSHA256: String(repeating: "a", count: 64), cameraID: "camera")
        let restored = try SpatialShotPoseTimeline(state: state, authoringFrames: [0, 3, 7])
        #expect(restored.keyframes.keys.sorted() == [0, 3, 7])
        #expect(try restored.resolve(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: state.cameraID) == state)
        #expect(throws: SpatialSceneError.self) { _ = try SpatialShotPoseTimeline(state: state, authoringFrames: [0, 7]) }
    }

    private func pose(frame: Int, position: SIMD3<Double>, rotation: SIMD3<Double>, scale: SIMD3<Double> = [1, 1, 1], fov: Double = 0.6) throws -> SpatialClayStateFrame {
        .init(frame: frame, objects: [
            .init(objectID: "camera", matrixWorld: try SpatialShotPoseTimeline.transform(position: position, rotationDegrees: rotation, scale: scale)),
            .init(objectID: "actor", matrixWorld: [1, 0, 0, 9, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        ], cameraVerticalFieldOfView: fov)
    }
}
