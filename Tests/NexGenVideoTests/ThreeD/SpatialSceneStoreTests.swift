import BpyRuntimeProtocol
import CoreMedia
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Portable spatial scene revisions")
struct SpatialSceneStoreTests {
    @Test func projectResourceReadStopsOnCallerCancellationBetweenBlocks() throws {
        try withDirectory { root in
            let bytes = Data(repeating: 0x69, count: 3 * 65_536)
            try bytes.write(to: root.appendingPathComponent("resource.glb"))
            let token = BpyOperationCancellation()
            var checks = 0
            #expect(!Task.isCancelled)
            #expect(throws: BpyAdmissionFailure.cancelled) {
                _ = try SpatialSceneStore.read("resource.glb", in: root, checking: {
                    checks += 1
                    if checks == 3 { token.cancel() }
                    try token.check()
                })
            }
            #expect(checks == 3)
            #expect(!Task.isCancelled)
            #expect(try SpatialSceneStore.read("resource.glb", in: root) == bytes)
        }
    }

    @Test func resourceDigestStopsOnTheCallerTokenAndKeepsTheExactControlDigest() throws {
        let bytes = Data(repeating: 0x64, count: 3 * 65_536), token = BpyOperationCancellation()
        var checks = 0
        #expect(throws: BpyAdmissionFailure.cancelled) {
            _ = try SpatialSceneStore.digest(bytes, checking: {
                checks += 1
                if checks == 2 { token.cancel() }
                try token.check()
            })
        }
        #expect(checks == 2)
        #expect(!Task.isCancelled)
        #expect(try SpatialSceneStore.digest(bytes, checking: {}) == SpatialSceneStore.digest(bytes))
    }

    @Test func validClayDimensionsStayUnchanged() throws {
        for (width, height) in [(64, 64), (128, 128), (1280, 720), (1920, 1080), (3840, 2160), (4096, 2160), (64, 4096), (4096, 64)] {
            let result = try SpatialClayRenderer.renderDimensions(width: width, height: height)
            #expect(result.width == width)
            #expect(result.height == height)
        }
    }

    @Test func clayDownscalePreservesExactAspectRatioWithoutUpscaling() throws {
        for (width, height, expectedWidth, expectedHeight) in [(7680, 4320, 4096, 2304), (4320, 7680, 2304, 4096),
                                                              (8192, 4320, 4096, 2160), (8192, 8192, 4096, 4096),
                                                              (639, 360, 568, 320)] {
            let result = try SpatialClayRenderer.renderDimensions(width: width, height: height)
            #expect(result.width == expectedWidth)
            #expect(result.height == expectedHeight)
            #expect(result.width * height == result.height * width)
            #expect(result.width <= width && result.height <= height)
        }
    }

    @Test func unrenderableCameraRatiosAreRejectedBeforeSaving() {
        for (width, height) in [(641, 360), (360, 641), (64, 8192), (8192, 64), (63, 128), (128, 8193), (0, 0), (Int.max, 128)] {
            #expect(throws: SpatialSceneError.self) { _ = try SpatialClayRenderer.renderDimensions(width: width, height: height) }
        }
    }

    @Test func staleEditPreservesCurrentRevision() throws {
        try withDirectory { root in
            let first = try fixture()
            let head = try SpatialSceneStore.publish(first, in: root)
            let second = try SpatialSceneStore.restoration(first.revision, replacing: head)
            let current = try SpatialSceneStore.publish(second, in: root)
            let stale = try SpatialSceneStore.restoration(first.revision, replacing: head)
            #expect(throws: SpatialSceneError.self) { _ = try SpatialSceneStore.publish(stale, in: root) }
            #expect(try SpatialSceneStore.index(in: root).scenes == [current])
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
                SpatialSceneStore.revisionPath(scene: head.id, revision: stale.revision.manifest.revision)
            ).path))
        }
    }

    @Test func restorationCreatesNewHistoryAndRetainsOriginalBytes() throws {
        try withDirectory { root in
            let first = try fixture()
            let original = try SpatialSceneStore.publish(first, in: root)
            let restored = try SpatialSceneStore.restoration(first.revision, replacing: original)
            let head = try SpatialSceneStore.publish(restored, in: root)
            #expect(head.revision != original.revision)
            #expect(restored.revision.manifest.parentRevision == original.revision)
            #expect(restored.revision.manifest.restoredFromRevision == original.revision)
            #expect(try SpatialSceneStore.load(original, in: root).sceneData == first.revision.sceneData)
            #expect(try SpatialSceneStore.load(head, in: root).sceneData == first.revision.sceneData)
        }
    }

    @Test func copiedProjectReopensWithoutOriginalLocation() throws {
        try withDirectory { root in
            let original = root.appendingPathComponent("original")
            let copy = root.appendingPathComponent("copy")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            let candidate = try fixture()
            let head = try SpatialSceneStore.publish(candidate, in: original)
            try FileManager.default.copyItem(at: original, to: copy)
            try FileManager.default.removeItem(at: original)
            let reopened = try SpatialSceneStore.load(head, in: copy)
            #expect(reopened.resources == candidate.revision.resources)
            #expect(reopened.snapshot == candidate.revision.snapshot)
            #expect(try reopened.sceneData == candidate.revision.sceneData)
        }
    }

    @Test func changedResourceCannotReopenAsVerifiedScene() throws {
        try withDirectory { root in
            let candidate = try fixture()
            let head = try SpatialSceneStore.publish(candidate, in: root)
            let resource = try #require(candidate.revision.manifest.resources.first)
            let path = SpatialSceneStore.revisionPath(scene: head.id, revision: head.revision)
                + "/resources/\(resource.id.uuidString)/\(resource.filename)"
            try Data("different".utf8).write(to: root.appendingPathComponent(path))
            #expect(throws: SpatialSceneError.self) { _ = try SpatialSceneStore.load(head, in: root) }
        }
    }

    @Test func symlinkedSceneSourceIsRejectedEvenWithMatchingBytes() throws {
        try withDirectory { root in
            let candidate = try fixture()
            let head = try SpatialSceneStore.publish(candidate, in: root)
            let outside = root.appendingPathComponent("external.blend")
            try candidate.revision.sceneData.write(to: outside)
            let path = root.appendingPathComponent(SpatialSceneStore.revisionPath(scene: head.id, revision: head.revision))
                .appendingPathComponent("scene.blend")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
            #expect(throws: (any Error).self) { _ = try SpatialSceneStore.load(head, in: root) }
        }
    }

    @Test func externalResourcesAndInconsistentTimebaseAreRejected() throws {
        var data = snapshotJSON()
        data["externalPaths"] = ["/external/texture.png"]
        let external = try JSONDecoder().decode(BpySpatialSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(throws: SpatialSceneError.self) { try SpatialSceneStore.validate(external) }
        data = snapshotJSON()
        data["timebaseNumerator"] = 25
        let wrongRate = try JSONDecoder().decode(BpySpatialSnapshot.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(throws: SpatialSceneError.self) { try SpatialSceneStore.validate(wrongRate) }
    }

    @Test func shotStateRequiresExactSceneFramesAndDigest() throws {
        let revision = try fixture()
        let state = SpatialClayState(sceneManifestSHA256: SpatialSceneStore.digest(revision.revision.manifestData),
                                     cameraID: "camera", frames: [.init(frame: 1, objects: [], cameraVerticalFieldOfView: 1)])
        func request(hash: String?) -> SpatialClayRequest {
            .init(owner: .shotPlanning, ownerArtifactSHA256: String(repeating: "a", count: 64),
                  ownerBindingSHA256: String(repeating: "b", count: 64), cameraID: "camera",
                  startFrame: 1, endFrame: 1, width: 128, height: 128, samples: 1, stateSHA256: hash)
        }
        let digest = SpatialSceneStore.digest(try SpatialSceneStore.encode(state))
        try SpatialClayRenderer.validateState(state, request: request(hash: digest), revision: revision.revision)
        #expect(throws: SpatialSceneError.self) {
            try SpatialClayRenderer.validateState(nil, request: request(hash: digest), revision: revision.revision)
        }
        #expect(throws: SpatialSceneError.self) {
            try SpatialClayRenderer.validateState(state, request: request(hash: String(repeating: "0", count: 64)), revision: revision.revision)
        }
        let stale = SpatialClayState(sceneManifestSHA256: String(repeating: "c", count: 64), cameraID: state.cameraID, frames: state.frames)
        #expect(throws: SpatialSceneError.self) {
            try SpatialClayRenderer.validateState(stale, request: request(hash: SpatialSceneStore.digest(try SpatialSceneStore.encode(stale))), revision: revision.revision)
        }
    }

    @Test func rewrittenResourceManifestCannotReplaceRuntimeReceipt() throws {
        try withDirectory { root in
            let candidate = try fixture()
            let head = try SpatialSceneStore.publish(candidate, in: root)
            let path = SpatialSceneStore.revisionPath(scene: head.id, revision: head.revision) + "/manifest.v1.json"
            var manifest = try #require(JSONSerialization.jsonObject(with: candidate.revision.manifestData) as? [String: Any])
            manifest["resources"] = []
            manifest["resourceClosureSHA256"] = SpatialSceneStore.digest(try SpatialSceneStore.encode([SpatialSceneResource]()))
            let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try bytes.write(to: root.appendingPathComponent(path))
            var forged = head
            forged.manifestSHA256 = SpatialSceneStore.digest(bytes)
            #expect(throws: SpatialSceneError.self) { _ = try SpatialSceneStore.load(forged, in: root) }
        }
    }

    @Test func completeShotStateHasNoSingleJobFrameOrPixelLimit() throws {
        let revision = try fixture().revision
        let frames = (0...300).map { SpatialClayStateFrame(frame: $0, objects: [], cameraVerticalFieldOfView: 1) }
        let state = SpatialClayState(sceneManifestSHA256: SpatialSceneStore.digest(revision.manifestData),
                                     cameraID: "camera", frames: frames)
        func request(_ state: SpatialClayState) throws -> SpatialClayRequest {
            .init(owner: .shotPlanning, ownerArtifactSHA256: String(repeating: "a", count: 64),
                ownerBindingSHA256: String(repeating: "b", count: 64), cameraID: "camera", startFrame: 0, endFrame: 300,
                width: 1280, height: 720, samples: 8, stateSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(state)))
        }
        try SpatialClayRenderer.validateSequenceState(state, request: request(state), revision: revision)
        #expect(throws: SpatialSceneError.self) {
            try SpatialClayRenderer.validateState(state, request: request(state), revision: revision)
        }
        let truncated = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: state.cameraID,
                                         frames: Array(frames.dropLast()))
        #expect(throws: SpatialSceneError.self) {
            try SpatialClayRenderer.validateSequenceState(truncated, request: request(truncated), revision: revision)
        }
        var reversedFrames = frames
        reversedFrames.swapAt(31, 32)
        let reordered = SpatialClayState(sceneManifestSHA256: state.sceneManifestSHA256, cameraID: state.cameraID, frames: reversedFrames)
        #expect(throws: SpatialSceneError.self) {
            try SpatialClayRenderer.validateSequenceState(reordered, request: request(reordered), revision: revision)
        }
    }

    @Test func completeShotClockRetainsPartialFinalFrameWithoutResampling() throws {
        let timing = SpatialClaySequenceTiming(numerator: 240_741, denominator: 24_000)
        let clock = try SpatialClayRenderer.sequenceClock(timing, numerator: 24_000, denominator: 1_001, count: 241)
        #expect(CMTimeCompare(clock.presentation(240), CMTime(value: 240_240, timescale: 24_000)) == 0)
        #expect(CMTimeCompare(clock.sampleDuration(240), CMTime(value: 501, timescale: 24_000)) == 0)
        #expect(CMTimeCompare(clock.sampleDuration(239), CMTime(value: 1_001, timescale: 24_000)) == 0)
        #expect(throws: SpatialSceneError.self) {
            _ = try SpatialClayRenderer.sequenceClock(timing, numerator: 24_000, denominator: 1_001, count: 240)
        }
        #expect(throws: SpatialSceneError.self) {
            _ = try SpatialClayRenderer.sequenceClock(timing, numerator: 24_000, denominator: 1_001, count: 242)
        }
        #expect(throws: SpatialSceneError.self) {
            _ = try SpatialClayRenderer.sequenceClock(.init(numerator: Int64.max, denominator: 1),
                                                       numerator: 24_000, denominator: 1_001, count: 241)
        }
        #expect(throws: SpatialSceneError.self) {
            _ = try SpatialClayRenderer.sequenceClock(.init(numerator: 1, denominator: 0),
                                                       numerator: 24_000, denominator: 1_001, count: 1)
        }
    }

    private func snapshotJSON() -> [String: Any] {
        ["schema": "nexgenvideo/bpy-spatial-snapshot/1", "units": "meters", "metersPerUnit": 1,
         "frame": 1, "restFrame": 1, "framesPerSecond": 24, "timebaseNumerator": 24, "timebaseDenominator": 1,
         "objects": [], "cameras": [], "meshes": [], "externalPaths": []]
    }

    @Test func projectPayloadVerificationAndHeaderUseOneHashPassAndRejectReplacement() throws {
        try withDirectory { root in
            let bytes = Data(repeating: 0x42, count: 1_048_576), path = root.appendingPathComponent("scene.blend")
            try bytes.write(to: path)
            let expected = SpatialSceneStore.digest(bytes)
            let payload = SpatialScenePayload(path: "scene.blend", root: root, sha256: expected, byteCount: UInt64(bytes.count))
            var checks = 0
            #expect(try payload.verify(checking: { checks += 1 }) == expected)
            #expect(checks >= 16 && checks < 32)
            checks = 0
            let verified = try payload.verifiedHeader(checking: { checks += 1 })
            #expect(verified.sha256 == expected && verified.header == Data(bytes.prefix(64)))
            #expect(checks >= 16 && checks < 32)
            try Data(repeating: 0x43, count: bytes.count).write(to: path, options: .atomic)
            #expect(throws: CocoaError(.fileReadCorruptFile)) { try payload.verify(checking: {}) }
            #expect(throws: CocoaError(.fileReadCorruptFile)) { try payload.verifiedHeader(checking: {}) }
        }
    }

    private func fixture() throws -> SpatialSceneCandidate {
        let snapshot = try JSONDecoder().decode(BpySpatialSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshotJSON()))
        let snapshotData = try SpatialSceneStore.encode(snapshot)
        let scene = Data("BLENDER-unit-fixture".utf8)
        let resourceData = Data("glTF-unit-fixture".utf8)
        let resource = SpatialSceneResource(id: UUID(), filename: "room.glb",
                                            sha256: SpatialSceneStore.digest(resourceData), byteCount: resourceData.count)
        let receipt = SpatialSceneReceipt(jobID: UUID(), jobFingerprint: String(repeating: "a", count: 64),
                                          runtimeLockSHA256: String(repeating: "b", count: 64),
                                          workerSHA256: String(repeating: "c", count: 64), blenderBuildHash: "unit-fixture",
                                          sceneSHA256: SpatialSceneStore.digest(scene), snapshotSHA256: SpatialSceneStore.digest(snapshotData),
                                          resourceClosureSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode([resource])))
        let manifest = SpatialSceneManifest(sceneID: UUID(), revision: UUID(), parentRevision: nil,
                                            restoredFromRevision: nil, name: "Room", sceneSHA256: receipt.sceneSHA256,
                                            snapshotSHA256: receipt.snapshotSHA256,
                                            resourceClosureSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode([resource])),
                                            resources: [resource], receipt: receipt)
        return .init(revision: .init(manifest: manifest, snapshot: snapshot, manifestData: try SpatialSceneStore.encode(manifest),
                                     sceneData: scene, snapshotData: snapshotData, resources: [resource.id: resourceData]), expectedHead: nil)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: try BpyRuntimePath.canonical(FileManager.default.temporaryDirectory)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
