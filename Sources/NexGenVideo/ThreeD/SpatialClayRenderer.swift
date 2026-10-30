import AVFoundation
import BpyRuntimeProtocol
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

struct SpatialClayRequest: Codable, Sendable, Equatable {
    enum Owner: String, Codable, Sendable { case storyboard, bible, shotPlanning = "shot_planning" }
    let owner: Owner
    let ownerArtifactSHA256: String
    let ownerBindingSHA256: String
    let cameraID: String
    let startFrame: Int
    let endFrame: Int
    let width: Int
    let height: Int
    let samples: Int
    let stateSHA256: String?
}

struct SpatialClayObjectPose: Codable, Sendable, Equatable {
    let objectID: String
    let matrixWorld: [Double]
}

struct SpatialClayStateFrame: Codable, Sendable, Equatable {
    let frame: Int
    let objects: [SpatialClayObjectPose]
    let cameraVerticalFieldOfView: Double
}

struct SpatialClayState: Codable, Sendable, Equatable {
    var schema = "spatial-clay-state/v1"
    let sceneManifestSHA256: String
    let cameraID: String
    let frames: [SpatialClayStateFrame]
}

struct SpatialClayFramePose: Codable, Sendable, Equatable {
    let frame: Int
    let matrixWorld: [Double]
    let projection: [Double]
    let objects: [SpatialClayObjectPose]
    let cameraVerticalFieldOfView: Double
}

struct SpatialClayOutput: Codable, Sendable, Equatable {
    let filename: String
    let sha256: String
    let byteCount: Int
    let width: Int
    let height: Int
    let frameCount: Int
    let mediaKind: String
}

struct SpatialDerivationProof: Codable, Sendable, Equatable {
    var schema = "spatial-derivation-proof/v1"
    let id: UUID
    let request: SpatialClayRequest
    let state: SpatialClayState?
    let purpose: String
    let cameraOwner: String
    let stateKind: String
    let scene: SpatialSceneHead
    let sceneSHA256: String
    let resourceClosureSHA256: String
    let sourceSnapshotSHA256: String
    let cameraSnapshotSHA256: String
    let framePoses: [SpatialClayFramePose]
    let timebaseNumerator: Int
    let timebaseDenominator: Int
    let runtimeLockSHA256: String
    let workerSHA256: String
    let rendererScriptSHA256: String
    let rendererBinarySHA256: String
    let renderer: String
    let blenderBuildHash: String
    let settingsSHA256: String
    let jobID: UUID
    let jobFingerprint: String
    let verifiedRenderSnapshotSHA256: String
    let outputs: [SpatialClayOutput]
}

nonisolated final class SpatialClayCandidate: @unchecked Sendable {
    let proof: SpatialDerivationProof
    let proofData: Data
    let files: [String: BpyRuntimeFile]
    let lease: BpyRuntimeResultLease
    private let lock = NSLock()
    private var released = false
    private var registration: BpyRuntimeResultLease.Registration?

    init(proof: SpatialDerivationProof, proofData: Data, files: [String: BpyRuntimeFile], lease: BpyRuntimeResultLease) {
        self.proof = proof; self.proofData = proofData; self.files = files; self.lease = lease
        registration = lease.observeInvalidation { [weak self] in self?.release() }
    }

    func release() {
        let release = lock.withLock { if released { return false }; released = true; return true }
        guard release else { return }
        for file in files.values { file.release() }
        lease.release()
    }
    deinit { release() }
}

enum SpatialClayRenderer {
    static func renderDimensions(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard (64...8192).contains(width), (64...8192).contains(height) else {
            throw SpatialSceneError.invalid("Enter camera dimensions between 64 and 8192 pixels.")
        }
        guard let result = fitDimensions(width: width, height: height, maximumWidth: 4096, maximumHeight: 4096) else {
            throw SpatialSceneError.invalid("Choose a camera aspect ratio that fits even dimensions between 64 and 4096 pixels without upscaling.")
        }
        return result
    }

    private static func fitDimensions(width: Int, height: Int, maximumWidth: Int, maximumHeight: Int) -> (width: Int, height: Int)? {
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        let unitWidth = width / a, unitHeight = height / a
        let multiple = min(a, maximumWidth / unitWidth, maximumHeight / unitHeight) / 2 * 2
        let result = (width: unitWidth * multiple, height: unitHeight * multiple)
        guard result.width >= 64, result.height >= 64 else { return nil }
        return result
    }

    static func prepare(
        request: SpatialClayRequest,
        revision: SpatialSceneRevision,
        state: SpatialClayState? = nil,
        runtime: BpyRuntimeSession,
        runtimeRoot: URL,
        cancellation: BpyOperationCancellation,
        jobID: UUID = UUID(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SpatialClayCandidate {
        let task = Task.detached(priority: .userInitiated) {
            try await prepareOffMain(request: request, revision: revision, state: state, runtime: runtime,
                                     runtimeRoot: runtimeRoot, jobID: jobID, cancellation: cancellation,
                                     isCancelled: { Task.isCancelled || isCancelled() })
        }
        let registration = cancellation.observe { task.cancel() }
        defer { withExtendedLifetime(registration) {} }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            cancellation.cancel(); task.cancel()
        }
    }

    private static func prepareOffMain(request: SpatialClayRequest, revision: SpatialSceneRevision,
                                       state: SpatialClayState?, runtime: BpyRuntimeSession, runtimeRoot: URL,
                                       jobID: UUID, cancellation: BpyOperationCancellation,
                                       isCancelled: @escaping @Sendable () -> Bool) async throws -> SpatialClayCandidate {
        guard request.startFrame >= 0, request.endFrame >= request.startFrame, request.endFrame <= 1_000_000,
              (64...4096).contains(request.width), (64...4096).contains(request.height),
              request.width.isMultiple(of: 2), request.height.isMultiple(of: 2),
              (1...128).contains(request.samples),
              request.ownerArtifactSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              request.ownerBindingSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let camera = revision.snapshot.cameras.first(where: { $0.id == request.cameraID }),
              camera.width * request.height == camera.height * request.width else {
            throw SpatialSceneError.invalid("The Clay camera, time interval, or owner binding is invalid.")
        }
        let count = request.endFrame - request.startFrame + 1
        guard count <= 240, request.width * request.height * count <= 33_554_432 else {
            throw SpatialSceneError.invalid("Reduce the Clay frame count or resolution for this render.")
        }
        try validateState(state, request: request, revision: revision)
        let script = try Data(contentsOf: runtimeRoot.appendingPathComponent("scene_operations.py"))
        let lock = try Data(contentsOf: runtimeRoot.appendingPathComponent("runtime-lock.json"))
        let worker = try Data(contentsOf: runtimeRoot.appendingPathComponent("worker.py"))
        let settings = try renderSettings(request, state: state)
        let literal = try JSONEncoder().encode(String(decoding: settings, as: UTF8.self))
        let source = "import json\nngv_command = json.loads(\(String(decoding: literal, as: UTF8.self)))\n"
            + String(decoding: script, as: UTF8.self)
        let runtimeLockSHA256 = SpatialSceneStore.digest(lock)
        let workerSHA256 = SpatialSceneStore.digest(worker)
        let rendererBinarySHA256 = try runtime.digestRuntimeFile(at: runtimeRoot.appendingPathComponent("site-packages/bpy/__init__.so"), cancellation: cancellation)
        let result = try await Task.detached {
            if isCancelled() { throw CancellationError() }
            try runtime.loadProjectCheckpoint(sceneRevision: revision, cancellation: cancellation)
            if isCancelled() { throw CancellationError() }
            return try runtime.runJob(id: jobID, expectedRevision: revision.manifest.revision.uuidString, source: source,
                                      cancellation: cancellation)
        }.value
        var transferred = false
        defer { if !transferred { result.release() } }
        guard let lease = result.lease else { throw SpatialSceneError.changed }
        let work = try runtime.consumerWork(cancellation: cancellation)
        defer { work.release() }
        guard !isCancelled() else { throw CancellationError() }
        let verified = try SpatialSceneStore.prepare(
            result: result, sceneID: revision.manifest.sceneID, name: revision.manifest.name,
            expectedHead: nil, runtimeLock: lock, worker: worker, resources: [], cancellation: cancellation
        )
        defer { verified.revision.scenePayload.releaseRuntimeSource() }
        try runtime.transferResult(result, source: revision, cancellation: cancellation)
        guard let fingerprint = result.response.jobFingerprint else {
            throw SpatialSceneError.invalid("The Clay render has no execution receipt.")
        }
        func bytes(_ name: String) throws -> Data {
            guard let descriptor = result.response.outputs.first(where: { $0.name == name }) else {
                throw SpatialSceneError.invalid("The Clay render is incomplete: \(name)")
            }
            let data = try lease.data(name, maximum: runtime.limits.outputBytes, checking: { try work.check() })
            guard data.count == descriptor.byteCount, SpatialSceneStore.digest(data) == descriptor.sha256 else {
                throw SpatialSceneError.changed
            }
            return data
        }
        let poses = try JSONDecoder().decode([SpatialClayFramePose].self, from: bytes("clay-frames.json"))
        guard poses.map(\.frame) == Array(request.startFrame...request.endFrame),
              poses.allSatisfy({ $0.matrixWorld.count == 16 && $0.projection.count == 16
                  && $0.matrixWorld.allSatisfy(\.isFinite) && $0.projection.allSatisfy(\.isFinite) }) else {
            throw SpatialSceneError.invalid("The Clay camera samples do not match the requested interval.")
        }
        var files: [String: BpyRuntimeFile] = [:]
        defer { if !transferred { for file in files.values { file.release() } } }
        var outputs: [SpatialClayOutput] = []
        for frame in request.startFrame...request.endFrame {
            guard !isCancelled() else { throw CancellationError() }
            let name = String(format: "clay-%08d.png", frame)
            let file = try lease.file(name)
            files[name] = file
            try lease.withDecode(width: request.width, height: request.height, cancellation: cancellation) {
                _ = try decodePNG(file.verifiedData(maximum: runtime.limits.outputBytes,
                    checking: { try work.check(); try cancellation.check() }), width: request.width, height: request.height)
            }
            outputs.append(.init(filename: name, sha256: file.sha256, byteCount: Int(file.byteCount),
                width: request.width, height: request.height, frameCount: 1, mediaKind: "image/png"))
        }
        if count > 1 {
            let movie = try await encodeMovie(request: request, files: files, lease: lease,
                numerator: revision.snapshot.timebaseNumerator, denominator: revision.snapshot.timebaseDenominator,
                cancellation: cancellation, work: work,
                isCancelled: { isCancelled() || work.isStopped })
            try lease.installGenerated("clay.mov", file: movie)
            files["clay.mov"] = movie
            outputs.append(.init(filename: "clay.mov", sha256: movie.sha256, byteCount: Int(movie.byteCount),
                width: request.width, height: request.height, frameCount: count, mediaKind: "video/quicktime"))
        }
        guard !isCancelled() else { throw CancellationError() }
        let head = SpatialSceneHead(id: revision.manifest.sceneID, name: revision.manifest.name,
                                    revision: revision.manifest.revision, manifestSHA256: SpatialSceneStore.digest(revision.manifestData))
        let proof = SpatialDerivationProof(
            id: UUID(), request: request, state: state, purpose: "geometry", cameraOwner: cameraOwner(request.owner),
            stateKind: request.owner == .shotPlanning ? "shot_state" : "scene_rest",
            scene: head, sceneSHA256: revision.manifest.sceneSHA256,
            resourceClosureSHA256: revision.manifest.resourceClosureSHA256,
            sourceSnapshotSHA256: revision.manifest.snapshotSHA256,
            cameraSnapshotSHA256: SpatialSceneStore.digest(try SpatialSceneStore.encode(camera)),
            framePoses: poses, timebaseNumerator: revision.snapshot.timebaseNumerator,
            timebaseDenominator: revision.snapshot.timebaseDenominator,
            runtimeLockSHA256: runtimeLockSHA256, workerSHA256: workerSHA256,
            rendererScriptSHA256: SpatialSceneStore.digest(script), rendererBinarySHA256: rendererBinarySHA256,
            renderer: "Blender Cycles / CPU / neutral material override",
            blenderBuildHash: verified.revision.manifest.receipt.blenderBuildHash,
            settingsSHA256: SpatialSceneStore.digest(settings),
            jobID: jobID, jobFingerprint: fingerprint,
            verifiedRenderSnapshotSHA256: verified.revision.manifest.snapshotSHA256, outputs: outputs
        )
        let candidate = SpatialClayCandidate(proof: proof, proofData: try SpatialSceneStore.encode(proof), files: files, lease: lease)
        try validate(candidate, against: revision, cancellation: cancellation)
        try runtime.retainSpatialDerivation(candidate, source: revision, cancellation: cancellation)
        transferred = true
        return candidate
    }

    static func preview(revision: SpatialSceneRevision, cameraID: String, frame: Int,
                        runtime: BpyRuntimeSession, runtimeRoot: URL, jobID: UUID,
                        cancellation: BpyOperationCancellation,
                        isCancelled: @escaping @Sendable () -> Bool) async throws -> Data {
        guard (0...1_000_000).contains(frame),
              let camera = revision.snapshot.cameras.first(where: { $0.id == cameraID }) else {
            throw SpatialSceneError.invalid("Select a saved camera and a valid frame.")
        }
        let dimensions = try renderDimensions(width: camera.width, height: camera.height)
        let preview = fitDimensions(width: dimensions.width, height: dimensions.height, maximumWidth: 960, maximumHeight: 540) ?? dimensions
        let width = preview.width, height = preview.height
        let command: [String: Any] = ["kind": "render_clay", "cameraID": cameraID,
                                    "width": width, "height": height, "samples": 8,
                                    "startFrame": frame, "endFrame": frame]
        let data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        let literal = try JSONEncoder().encode(String(decoding: data, as: UTF8.self))
        let source = "import json\nngv_command = json.loads(\(String(decoding: literal, as: UTF8.self)))\n"
            + (try String(contentsOf: runtimeRoot.appendingPathComponent("scene_operations.py"), encoding: .utf8))
        let task = Task.detached {
            if isCancelled() { throw CancellationError() }
            try runtime.loadProjectCheckpoint(sceneRevision: revision, cancellation: cancellation)
            if isCancelled() { throw CancellationError() }
            let result = try runtime.runJob(id: jobID, expectedRevision: revision.manifest.revision.uuidString, source: source, cancellation: cancellation)
            defer { result.release() }
            guard result.response.ok, result.response.state == .awaitingConfirmation, !isCancelled() else {
                throw SpatialSceneError.invalid(result.response.message ?? "The camera preview did not complete.")
            }
            let name = String(format: "clay-%08d.png", frame)
            guard let descriptor = result.response.outputs.first(where: { $0.name == name }),
                  let lease = result.lease else {
                throw SpatialSceneError.invalid("The camera preview image is missing.")
            }
            return try lease.withDecode(width: width, height: height, cancellation: cancellation,
                checking: { if isCancelled() { throw CancellationError() } }) {
                    let bytes = try lease.data(name, maximum: runtime.limits.outputBytes, checking: { try cancellation.check() })
                    guard bytes.count == descriptor.byteCount, SpatialSceneStore.digest(bytes) == descriptor.sha256 else {
                        throw SpatialSceneError.changed
                    }
                    _ = try decodePNG(bytes, width: width, height: height)
                    return bytes
                }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            cancellation.cancel(); task.cancel()
        }
    }

    static func validate(_ candidate: SpatialClayCandidate, against revision: SpatialSceneRevision,
                         cancellation: BpyOperationCancellation) throws {
        try candidate.lease.withConsumer(cancellation: cancellation) { work, cancellation in
            func check() throws {
                try work.check(); try cancellation.check()
                guard candidate.lease.isAvailable else { throw SpatialSceneError.changed }
            }
            try validate(proof: candidate.proof, proofData: candidate.proofData, names: Set(candidate.files.keys), against: revision) { output in
                try check()
                guard let file = candidate.files[output.filename], file.byteCount == output.byteCount,
                      file.sha256 == output.sha256 else { throw SpatialSceneError.changed }
                try file.verify(checking: check)
                if output.mediaKind == "image/png" {
                    try candidate.lease.withDecode(width: output.width, height: output.height, cancellation: cancellation, checking: check) {
                        _ = try decodePNG(file.verifiedData(maximum: candidate.lease.limits.outputBytes, checking: check), width: output.width, height: output.height)
                    }
                }
            }
        }
    }

    static func validate(proof: SpatialDerivationProof, proofData: Data, files: [String: Data],
                         against revision: SpatialSceneRevision, scope: BpyMediaReadScope) throws {
        try scope.withConsumer { _ in
            try validate(proof: proof, proofData: proofData, names: Set(files.keys), against: revision) { output in
                try scope.check()
                guard let data = files[output.filename], data.count == output.byteCount,
                      data.count <= BpyRuntimeLimits().outputBytes,
                      SpatialSceneStore.digest(data) == output.sha256 else { throw SpatialSceneError.changed }
                if output.mediaKind == "image/png" {
                    try BpyMediaDecode.withPixels(width: output.width, height: output.height, encodedBytes: UInt64(data.count),
                        owner: scope.owner, cancellation: scope.cancellation, checking: scope.check) {
                        _ = try decodePNG(data, width: output.width, height: output.height)
                    }
                }
            }
        }
    }

    static func validate(proof: SpatialDerivationProof, proofData: Data, files: [String: URL],
                         against revision: SpatialSceneRevision, scope: BpyMediaReadScope) throws {
        try scope.withConsumer { _ in
            try validate(proof: proof, proofData: proofData, names: Set(files.keys), against: revision) { output in
                try autoreleasepool {
                    guard let url = files[output.filename] else { throw SpatialSceneError.changed }
                    let file = try BpyRuntimeFile.borrow(url.lastPathComponent, in: url.deletingLastPathComponent(),
                        maximum: BpyRuntimeLimits().outputBytes, expectedSHA256: output.sha256, checking: scope.check)
                    defer { file.release() }
                    guard file.byteCount == output.byteCount else { throw SpatialSceneError.changed }
                    if output.mediaKind == "image/png" {
                        try BpyMediaDecode.withPixels(width: output.width, height: output.height, encodedBytes: file.byteCount,
                            owner: scope.owner, cancellation: scope.cancellation, checking: scope.check) {
                            _ = try decodePNG(file.verifiedData(maximum: BpyRuntimeLimits.maximumOutputBytes, checking: scope.check), width: output.width, height: output.height)
                        }
                    }
                }
            }
        }
    }

    private static func validate(proof: SpatialDerivationProof, proofData: Data, names fileNames: Set<String>,
                                 against revision: SpatialSceneRevision,
                                 inspect: (SpatialClayOutput) throws -> Void) throws {
        guard try SpatialSceneStore.encode(proof) == proofData,
              proof.schema == "spatial-derivation-proof/v1",
              proof.purpose == "geometry", proof.cameraOwner == cameraOwner(proof.request.owner),
              proof.stateKind == (proof.request.owner == .shotPlanning ? "shot_state" : "scene_rest"),
              proof.scene.id == revision.manifest.sceneID, proof.scene.revision == revision.manifest.revision,
              proof.scene.name == revision.manifest.name,
              proof.scene.manifestSHA256 == SpatialSceneStore.digest(revision.manifestData),
              proof.sceneSHA256 == revision.manifest.sceneSHA256,
              proof.resourceClosureSHA256 == revision.manifest.resourceClosureSHA256,
              proof.sourceSnapshotSHA256 == revision.manifest.snapshotSHA256,
              let camera = revision.snapshot.cameras.first(where: { $0.id == proof.request.cameraID }),
              camera.width * proof.request.height == camera.height * proof.request.width,
              proof.cameraSnapshotSHA256 == SpatialSceneStore.digest(try SpatialSceneStore.encode(camera)),
              proof.settingsSHA256 == SpatialSceneStore.digest(try renderSettings(proof.request, state: proof.state)),
              proof.timebaseNumerator == revision.snapshot.timebaseNumerator,
              proof.timebaseDenominator == revision.snapshot.timebaseDenominator,
              Set(proof.outputs.map(\.filename)) == fileNames,
              proof.outputs.count == fileNames.count,
              proof.request.startFrame >= 0, proof.request.endFrame >= proof.request.startFrame,
              proof.request.endFrame <= 1_000_000 else {
            throw SpatialSceneError.changed
        }
        let count = proof.request.endFrame - proof.request.startFrame + 1
        guard (1...240).contains(count), (64...4096).contains(proof.request.width),
              (64...4096).contains(proof.request.height),
              proof.request.width.isMultiple(of: 2), proof.request.height.isMultiple(of: 2),
              (1...128).contains(proof.request.samples),
              proof.request.width * proof.request.height * count <= 33_554_432,
              proof.framePoses.allSatisfy({ pose in
                  pose.matrixWorld.count == 16 && pose.projection.count == 16
                    && pose.matrixWorld.allSatisfy(\.isFinite) && pose.projection.allSatisfy(\.isFinite)
                    && pose.cameraVerticalFieldOfView.isFinite && pose.cameraVerticalFieldOfView > 0
                    && pose.cameraVerticalFieldOfView < .pi
                    && pose.objects.count == revision.snapshot.objects.count
                    && Set(pose.objects.map(\.objectID)) == Set(revision.snapshot.objects.map(\.id))
                    && pose.objects.allSatisfy { $0.matrixWorld.count == 16 && $0.matrixWorld.allSatisfy(\.isFinite) }
              }) else {
            throw SpatialSceneError.invalid("The Clay receipt contains invalid geometry or media bounds.")
        }
        let names = (proof.request.startFrame...proof.request.endFrame).map { String(format: "clay-%08d.png", $0) }
        guard (1...240).contains(count),
              fileNames == Set(names + (count > 1 ? ["clay.mov"] : [])),
              proof.framePoses.map(\.frame) == Array(proof.request.startFrame...proof.request.endFrame),
              [proof.runtimeLockSHA256, proof.workerSHA256, proof.rendererScriptSHA256, proof.rendererBinarySHA256,
               proof.jobFingerprint, proof.verifiedRenderSnapshotSHA256, proof.request.ownerArtifactSHA256,
               proof.request.ownerBindingSHA256].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else {
            throw SpatialSceneError.invalid("The Clay receipt is incomplete.")
        }
        try validateState(proof.state, request: proof.request, revision: revision)
        if let state = proof.state {
            for (requested, rendered) in zip(state.frames, proof.framePoses) {
                let measured = Dictionary(uniqueKeysWithValues: rendered.objects.map { ($0.objectID, $0.matrixWorld) })
                guard rendered.objects.count == requested.objects.count,
                      abs(rendered.cameraVerticalFieldOfView - requested.cameraVerticalFieldOfView) <= 0.00001,
                      requested.objects.allSatisfy({ item in
                          guard let actual = measured[item.objectID] else { return false }
                          return actual.count == 16 && zip(actual, item.matrixWorld).allSatisfy { abs($0 - $1) <= 0.00001 }
                      }) else { throw SpatialSceneError.invalid("The Clay render did not apply its resolved shot state.") }
            }
        }

        for output in proof.outputs {
            guard output.width == proof.request.width, output.height == proof.request.height,
                  output.frameCount == (output.filename == "clay.mov" ? count : 1),
                  output.mediaKind == (output.filename == "clay.mov" ? "video/quicktime" : "image/png") else {
                throw SpatialSceneError.changed
            }
            try inspect(output)
        }
    }

    private static func cameraOwner(_ owner: SpatialClayRequest.Owner) -> String {
        switch owner {
        case .storyboard: "storyboard_layout"
        case .bible: "bible_inspection"
        case .shotPlanning: "shot_plan"
        }
    }

    static func renderSettings(_ request: SpatialClayRequest, state: SpatialClayState?) throws -> Data {
        var command: [String: Any] = [
            "kind": "render_clay", "cameraID": request.cameraID, "width": request.width,
            "height": request.height, "samples": request.samples,
            "startFrame": request.startFrame, "endFrame": request.endFrame,
        ]
        if let state { command["state"] = try JSONSerialization.jsonObject(with: SpatialSceneStore.encode(state)) }
        return try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
    }

    static func validateState(_ state: SpatialClayState?, request: SpatialClayRequest, revision: SpatialSceneRevision) throws {
        guard request.startFrame >= 0, request.endFrame >= request.startFrame, request.endFrame <= 1_000_000,
              request.endFrame - request.startFrame < 240 else { throw SpatialSceneError.changed }
        guard request.owner == .shotPlanning else {
            guard state == nil, request.stateSHA256 == nil, request.startFrame == revision.snapshot.restFrame,
                  request.endFrame == request.startFrame else {
                throw SpatialSceneError.invalid("Early location views require the scene rest frame without a shot-state claim.")
            }
            return
        }
        try validateShotState(state, request: request, revision: revision)
    }

    static func validateSequenceState(_ state: SpatialClayState, request: SpatialClayRequest,
                                      revision: SpatialSceneRevision) throws {
        guard request.owner == .shotPlanning, request.startFrame == 0,
              request.endFrame >= request.startFrame, request.endFrame <= 1_000_000 else {
            throw SpatialSceneError.invalid("The Clay sequence requires a complete shot interval starting at frame zero.")
        }
        try validateShotState(state, request: request, revision: revision)
    }

    private static func validateShotState(_ state: SpatialClayState?, request: SpatialClayRequest,
                                          revision: SpatialSceneRevision) throws {
        let identities = Set(revision.snapshot.objects.map(\.id))
        guard let state, state.schema == "spatial-clay-state/v1",
              state.sceneManifestSHA256 == SpatialSceneStore.digest(revision.manifestData),
              state.cameraID == request.cameraID,
              state.frames.map(\.frame) == Array(request.startFrame...request.endFrame),
              SpatialSceneStore.digest(try SpatialSceneStore.encode(state)) == request.stateSHA256,
              state.frames.allSatisfy({ frame in
                  frame.cameraVerticalFieldOfView.isFinite && frame.cameraVerticalFieldOfView > 0
                    && frame.cameraVerticalFieldOfView < .pi
                    && frame.objects.count == identities.count
                    && Set(frame.objects.map(\.objectID)) == identities
                    && frame.objects.allSatisfy { $0.matrixWorld.count == 16 && $0.matrixWorld.allSatisfy(\.isFinite) }
              }) else { throw SpatialSceneError.invalid("The Clay shot state is missing, stale, or incomplete.") }
    }

    static func decodePNG(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard data.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else {
            throw SpatialSceneError.invalid("The Clay render returned an invalid image.")
        }
        return image
    }

    private static func encodeMovie(request: SpatialClayRequest, files: [String: BpyRuntimeFile],
                                    lease: BpyRuntimeResultLease, numerator: Int, denominator: Int,
                                    cancellation: BpyOperationCancellation, work: BpyConsumerWork,
                                    isCancelled: @escaping @Sendable () -> Bool) async throws -> BpyRuntimeFile {
        let countFrames = request.endFrame - request.startFrame + 1
        guard numerator > 0, numerator <= Int32.max, denominator > 0,
              denominator <= Int.max / max(1, countFrames) else {
            throw SpatialSceneError.invalid("The Clay video timebase is invalid.")
        }
        let media = try BpyGeneratedMedia(lease: lease, filename: "clay.mov", width: request.width, height: request.height)
        defer { media.abandon() }
        let url = media.url
        func image(_ index: Int) throws -> CGImage {
            guard let file = files[String(format: "clay-%08d.png", request.startFrame + index)] else { throw SpatialSceneError.changed }
            return try decodePNG(file.verifiedData(maximum: lease.limits.outputBytes,
                checking: { try work.check(); try cancellation.check() }), width: request.width, height: request.height)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = Int32(numerator)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: request.width, AVVideoHeightKey: request.height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoAverageBitRateKey: max(2_000_000, request.width * request.height * 8)],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.mediaTimeScale = Int32(numerator)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: request.width, kCVPixelBufferHeightKey as String: request.height,
        ])
        guard writer.canAdd(input) else { throw SpatialSceneError.invalid("The Clay video encoder is unavailable.") }
        writer.add(input)
        let lifetime = try BpyMediaWriter(writer: writer, pin: media.retainForIO(), cancellation: cancellation, work: work)
        defer { lifetime.requestCancel() }
        do {
        guard try lifetime.perform({ writer.startWriting() }) else { throw writer.error ?? SpatialSceneError.invalid("The Clay video could not start.") }
        try lifetime.perform { writer.startSession(atSourceTime: .zero) }
        guard let pool = adaptor.pixelBufferPool else { throw SpatialSceneError.invalid("The Clay video frame pool is unavailable.") }
        let deadline = try BpyRuntimeClock.awakeSeconds() + 120
        for index in 0..<countFrames {
            while !input.isReadyForMoreMediaData {
                try work.check()
                guard !isCancelled() else { throw CancellationError() }
                guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw SpatialSceneError.invalid("The Clay video encoder stopped responding.") }
                guard writer.status == .writing else { throw writer.error ?? SpatialSceneError.invalid("The Clay video encoder stopped.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard !isCancelled() else { throw CancellationError() }
            try lease.withDecode(width: request.width, height: request.height, cancellation: cancellation,
                checking: { if isCancelled() { throw CancellationError() } }) {
            let frame = try image(index)
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                throw SpatialSceneError.invalid("The Clay video frame could not be allocated.")
            }
            CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVPixelBufferLockBaseAddress(pixel, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: request.width, height: request.height,
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                          space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                            | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(pixel, [])
                throw SpatialSceneError.invalid("The Clay video drawing surface is unavailable.")
            }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: request.width, height: request.height))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let time = CMTime(value: Int64(index) * Int64(denominator), timescale: Int32(numerator))
            try media.checkSize()
            guard try lifetime.perform({ adaptor.append(pixel, withPresentationTime: time) }) else {
                throw writer.error ?? SpatialSceneError.invalid("The Clay video frame could not be written.")
            }
            }
        }
        try lifetime.perform {
            writer.endSession(atSourceTime: CMTime(value: Int64(countFrames) * Int64(denominator), timescale: Int32(numerator)))
            input.markAsFinished()
        }
        try await lifetime.finish(deadline: deadline, checking: { if isCancelled() { throw CancellationError() } })
        guard writer.status == .completed, !isCancelled() else {
            throw writer.error ?? CancellationError()
        }
        let asset = AVURLAsset(url: url)
        let reading = try BpyMediaReader.begin(asset: asset, pin: media.retainForIO(), cancellation: cancellation, work: work)
        var readComplete = false
        defer { reading.endBody(success: readComplete) }
        do {
        try reading.check()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SpatialSceneError.invalid("The Clay video contains no video track.")
        }
        try reading.progress()
        let dimensions = try await track.load(.naturalSize)
        try reading.progress()
        let duration = try await asset.load(.duration)
        try reading.progress()
        let expectedDuration = CMTime(value: Int64(countFrames) * Int64(denominator), timescale: Int32(numerator))
        guard dimensions.width == CGFloat(request.width), dimensions.height == CGFloat(request.height),
              CMTimeCompare(duration, expectedDuration) == 0 else {
            throw SpatialSceneError.invalid("The Clay video dimensions or duration changed during encoding.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpatialSceneError.invalid("The Clay video cannot be verified.") }
        reader.add(output)
        try reading.start(reader)
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            try reading.check()
            guard !isCancelled() else { throw CancellationError() }
            let expected = CMTime(value: Int64(count) * Int64(denominator), timescale: Int32(numerator))
            guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), expected) == 0 else {
                throw SpatialSceneError.invalid("The Clay video frame timing changed during encoding.")
            }
            guard count < countFrames, let decoded = CMSampleBufferGetImageBuffer(sample) else {
                throw SpatialSceneError.invalid("The Clay video has unexpected decoded frames.")
            }
            try lease.withDecode(width: request.width, height: request.height, cancellation: cancellation,
                checking: { if isCancelled() { throw CancellationError() } }) {
                try verifyMovieFrame(decoded, expected: image(count))
            }
            count += 1
            try reading.progress()
        }
        guard reader.status == .completed, count == countFrames else {
            throw SpatialSceneError.invalid("The Clay video is incomplete.")
        }
        try reading.check()
        readComplete = true
        reading.endBody(success: true)
        return try media.finish()
        } catch {
            try reading.check()
            throw error
        }
        } catch {
            try await lifetime.cancelAndWait()
            try work.rethrowAfterCleanup(error)
        }
    }
    static func verifyMovieFrame(_ actual: CVPixelBuffer, expected: CGImage) throws {
        guard CVPixelBufferGetWidth(actual) == expected.width, CVPixelBufferGetHeight(actual) == expected.height,
              CVPixelBufferGetPixelFormatType(actual) == kCVPixelFormatType_32BGRA else { throw SpatialSceneError.changed }
        let stride = expected.width * 4
        var reference = [UInt8](repeating: 0, count: stride * expected.height)
        try reference.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: expected.width, height: expected.height,
                                          bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpace(name: CGColorSpace.itur_709)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw SpatialSceneError.invalid("The Clay comparison surface is unavailable.")
            }
            context.draw(expected, in: CGRect(x: 0, y: 0, width: expected.width, height: expected.height))
        }
        CVPixelBufferLockBaseAddress(actual, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(actual, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(actual)?.assumingMemoryBound(to: UInt8.self) else {
            throw SpatialSceneError.invalid("The Clay decoded frame cannot be read.")
        }
        var total: UInt64 = 0, differing = 0
        let channels = expected.width * expected.height * 3
        for y in 0..<expected.height {
            for x in 0..<expected.width {
                for channel in 0..<3 {
                    let delta = abs(Int(pixels[y * CVPixelBufferGetBytesPerRow(actual) + x * 4 + channel])
                                    - Int(reference[y * stride + x * 4 + channel]))
                    total += UInt64(delta)
                    if delta > 24 { differing += 1 }
                }
            }
        }
        guard Double(total) / Double(channels) <= 4, Double(differing) / Double(channels) <= 0.01 else {
            throw SpatialSceneError.invalid("The Clay movie frame differs from its verified PNG source.")
        }
    }

}
