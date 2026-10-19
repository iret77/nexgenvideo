import Foundation
import NexGenEngine
import XCTest
@testable import NexGenVideo

final class NativeBlockoutBindingTests: XCTestCase {
    private let shotID = "00000000-0000-4000-8000-000000000001"
    private let framing = StoryboardTimingV1.FramingIntent(scale: "wide", composition: "center", cameraView: "front")

    func testTimingBindingIgnoresOtherShotsAndRevisionButRejectsOwnDurationAndClock() throws {
        let original = timing(revision: 1, duration: 48)
        XCTAssertNoThrow(try PipelineNativeBlockoutStore.requireTiming(original,
            current: timing(revision: 2, duration: 48, otherDuration: 96), shotID: shotID))
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.requireTiming(original,
            current: timing(revision: 2, duration: 49), shotID: shotID))
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.requireTiming(original,
            current: timing(revision: 2, duration: 48, ticksPerSecond: 48), shotID: shotID))
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.requireTiming(original,
            current: timing(revision: 2, duration: 48, project: "other"), shotID: shotID))
    }

    func testOriginalIsNeverAnUntrimmedGeometrySubstituteAndMatchingPrecedesStateValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased(), namespace = UUID().uuidString.lowercased()
        let directory = "execution/blockout/" + namespace + "/native-" + id
        let output = ref(directory + "/blockout.mov", role: "core.shot-blockout-video", byte: "b")
        let original = ref(directory + "/original.mov", role: "host.blockout-original", byte: "a")
        let camera = ShotPlanningDraftV1.CameraIntent(framing: framing, movement: .static)
        let receipt = PipelineNativeBlockoutStore.Receipt(schema: "native-blockout-selection/v1", id: id,
            projectID: "fixture", workflowID: "fixture", shotID: shotID, kind: .importedGeometry, camera: camera,
            draft: ref("shot-planning/v1.v1.json"), timing: ref("storyboard/timing-v1.v1.json"), stateReferences: [],
            output: output, original: original, originalName: "Source.mov", sourceStartValue: 24,
            sourceDurationValue: 48, sourceTimescale: 24, sourceDurationTimescale: 24, observation: "fixture", recordedAt: "fixture")
        let path = "shot-planning/native-blockouts/" + id + ".v1.json", bytes = try PlanningWriterIO.json(receipt)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shot-planning/native-blockouts"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(path))
        let reference = PlanningWriterIO.reference(path, id: id, role: "host.native-blockout", bytes: bytes)
        XCTAssertNoThrow(try PipelineNativeBlockoutStore.requirePurpose(sha256: output.sha256, geometry: true, dataRoot: root))
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.requirePurpose(sha256: original.sha256, geometry: true, dataRoot: root))
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.requirePurpose(sha256: output.sha256, geometry: false, dataRoot: root))
        let shot = ShotPlanningDraftV1.ShotIntent(shotID: shotID, sourceMode: .generated, camera: camera, obligations: [])
        XCTAssertNil(try PipelineNativeBlockoutStore.matchingVideoReferences(reference, shot: shot,
            path: "unrelated.mov", sha256: output.sha256, dataRoot: root))
        XCTAssertNil(try PipelineNativeBlockoutStore.matchingVideoReferences(reference, shot: shot,
            path: output.path, sha256: original.sha256, dataRoot: root))
        XCTAssertThrowsError(try PipelineNativeBlockoutStore.matchingVideoReferences(reference, shot: shot,
            path: output.path, sha256: output.sha256, dataRoot: root))
    }

    func testRemovalRetainsStatesSourcesAndUnselectedShotsWithoutReadingStaleReceipts() throws {
        let first = shot(shotID), second = shot("00000000-0000-4000-8000-000000000002")
        let draft = ShotPlanningDraftV1(header: .init(projectID: "fixture", revision: 1, origin: .userRevision, inputs: []),
            storyboardRevision: 1, shots: [first, second])
        let one = try PipelineShotPlanningEditor.removingBlockouts(shotIDs: [shotID], from: draft)
        XCTAssertNil(one[0].camera.blockingReference)
        XCTAssertEqual(one[0].camera.spatialState, first.camera.spatialState)
        XCTAssertEqual(one[0].camera.spatialDerivation, first.camera.spatialDerivation)
        XCTAssertEqual(one[0].sourceInputRange, first.sourceInputRange)
        XCTAssertEqual(one[1], second)
        XCTAssertTrue(try PipelineShotPlanningEditor.removingBlockouts(shotIDs: [first.shotID, second.shotID], from: draft)
            .allSatisfy { $0.camera.blockingReference == nil })
        XCTAssertThrowsError(try PipelineShotPlanningEditor.removingBlockouts(shotIDs: [], from: draft))
        XCTAssertThrowsError(try PipelineShotPlanningEditor.removingBlockouts(shotIDs: ["unknown"], from: draft))
    }

    func testRecoveryExceptionsAreOnlyTheExplicitlyRemovedNativeClosure() throws {
        let id = UUID().uuidString.lowercased(), namespace = UUID().uuidString.lowercased()
        let receipt = ref("shot-planning/native-blockouts/" + id + ".v1.json", role: "host.native-blockout")
        let directory = "execution/blockout/" + namespace + "/native-" + id + "/"
        for (path, role) in [(receipt.path, receipt.role), (directory + "blockout.mov", "core.shot-blockout-video"),
                             (directory + "original.mov", "host.blockout-original"),
                             (directory + "evaluated-bounds-120.v1.json", "host.evaluated-geometry")] {
            XCTAssertTrue(try PipelineBlockoutRemovalSnapshot.removable(ref(path, role: role), receipts: [receipt]))
        }
        for reference in [ref(directory + "state.v1.json"), ref(directory + "blockout.mov", role: "core.source-footage"),
                          ref("shot-planning/spatial-states/" + id + "/state.v1.json"),
                          ref("execution/blockout/" + namespace + "/native-" + UUID().uuidString.lowercased() + "/blockout.mov", role: "core.shot-blockout-video")] {
            XCTAssertFalse(try PipelineBlockoutRemovalSnapshot.removable(reference, receipts: [receipt]))
        }
    }

    func testRecoveryAllowsOwnedEvaluatedSourceSidecarsOnly() throws {
        let id = UUID().uuidString.lowercased(), namespace = UUID().uuidString.lowercased()
        let receipt = ref("shot-planning/native-blockouts/" + id + ".v1.json", role: "host.native-blockout")
        let directory = "execution/blockout/" + namespace + "/native-" + id + "/"
        let names = ["evaluated-scene-operations.py", "evaluated-worker.py", "evaluated-runtime-lock.json",
            "evaluated-runtime-record.csv", "evaluated-command-0.py", "evaluated-command-120.py",
            "evaluated-geometry.v1.json", "evaluated-bounds-0.v1.json", "evaluated-verification-120.v1.json"]
        for name in names {
            XCTAssertTrue(try PipelineBlockoutRemovalSnapshot.removable(ref(directory + name, role: "host.evaluated-geometry"), receipts: [receipt]))
            XCTAssertFalse(try PipelineBlockoutRemovalSnapshot.removable(ref(directory + name, role: "core.source-footage"), receipts: [receipt]))
            XCTAssertFalse(try PipelineBlockoutRemovalSnapshot.removable(ref(directory + name, role: "host.evaluated-geometry"), receipts: []))
        }
        for name in ["evaluated-runtime-lock.json.old", "evaluated-worker.py/state.json", "evaluated-command--1.py", "evaluated-command-01.py", "worker.py",
                     "evaluated-command-0.py\n", "evaluated-bounds-0.v1.json\n", "evaluated-verification-120.v1.json\r\n",
                     "evaluated-command-0.py\u{2028}"] {
            XCTAssertFalse(try PipelineBlockoutRemovalSnapshot.removable(ref(directory + name, role: "host.evaluated-geometry"), receipts: [receipt]))
        }
    }

    private func ref(_ path: String, role: String = "fixture", byte: String = "a") -> CanonicalArtifactReferenceV1 {
        .init(id: path, role: role, path: path, sha256: String(repeating: byte, count: 64))
    }

    private func shot(_ id: String) -> ShotPlanningDraftV1.ShotIntent {
        let source = ref("shot-planning/sources/" + id + "/source.mov")
        return .init(shotID: id, sourceMode: .imported, source: source,
            camera: .init(framing: framing, movement: .static, sceneReference: ref("scene.blend"),
                spatialState: ref("state.json"), spatialCameraID: "camera", spatialDerivation: ref("clay.json"),
                blockingReference: ref("shot-planning/native-blockouts/" + id + ".v1.json", role: "host.native-blockout")),
            obligations: [], sourceInputRange: .init(source: source,
                timebase: .init(ticksPerSecond: 24, fpsNumerator: 24), startTicks: 0, durationTicks: 48))
    }

    private func timing(revision: Int, duration: Int64, otherDuration: Int64 = 48,
                        ticksPerSecond: Int64 = 24, project: String = "fixture") -> StoryboardTimingV1 {
        .init(header: .init(projectID: project, revision: revision, origin: .userRevision, inputs: []),
            timebase: .init(ticksPerSecond: ticksPerSecond, fpsNumerator: 24), mode: .generic,
            rangeDurationTicks: duration + otherDuration, shots: [
                .init(id: shotID, primaryStepID: "step1", startTicks: 0, durationTicks: duration, framing: framing, moments: []),
                .init(id: "00000000-0000-4000-8000-000000000002", primaryStepID: "step2", startTicks: duration,
                    durationTicks: otherDuration, framing: framing, moments: [])])
    }
}
