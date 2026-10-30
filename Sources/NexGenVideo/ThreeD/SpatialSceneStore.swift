import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

enum SpatialSceneError: LocalizedError {
    case invalid(String)
    case changed

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .changed: "The location changed. Reload it before applying this edit."
        }
    }
}

struct SpatialSceneIndex: Codable, Sendable, Equatable {
    var schema = "spatial-scene-index/v1"
    var scenes: [SpatialSceneHead] = []
}

struct SpatialSceneHead: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var revision: UUID
    var manifestSHA256: String
}

struct SpatialSceneResource: Codable, Sendable, Equatable {
    let id: UUID
    let filename: String
    let sha256: String
    let byteCount: Int
}

struct SpatialSceneManifest: Codable, Sendable, Equatable {
    var schema = "spatial-scene-manifest/v1"
    let sceneID: UUID
    let revision: UUID
    let parentRevision: UUID?
    let restoredFromRevision: UUID?
    let name: String
    let sceneSHA256: String
    let snapshotSHA256: String
    let resourceClosureSHA256: String
    let resources: [SpatialSceneResource]
    let receipt: SpatialSceneReceipt
}

struct SpatialSceneReceipt: Codable, Sendable, Equatable {
    let jobID: UUID
    let jobFingerprint: String
    let runtimeLockSHA256: String
    let workerSHA256: String
    let blenderBuildHash: String
    let sceneSHA256: String
    let snapshotSHA256: String
    let resourceClosureSHA256: String
}

struct SpatialSceneRevision: Sendable {
    let manifest: SpatialSceneManifest
    let snapshot: BpySpatialSnapshot
    let manifestData: Data
    let scenePayload: SpatialScenePayload
    var sceneData: Data { get throws { try scenePayload.data() } }
    let snapshotData: Data
    let resources: [UUID: Data]
    init(manifest: SpatialSceneManifest, snapshot: BpySpatialSnapshot, manifestData: Data,
         scenePayload: SpatialScenePayload, snapshotData: Data, resources: [UUID: Data]) {
        self.manifest = manifest; self.snapshot = snapshot; self.manifestData = manifestData
        self.scenePayload = scenePayload; self.snapshotData = snapshotData; self.resources = resources
    }

    init(manifest: SpatialSceneManifest, snapshot: BpySpatialSnapshot, manifestData: Data,
         sceneData: Data, snapshotData: Data, resources: [UUID: Data]) {
        self.init(manifest: manifest, snapshot: snapshot, manifestData: manifestData,
            scenePayload: .init(data: sceneData), snapshotData: snapshotData, resources: resources)
    }

}

struct SpatialSceneCandidate: Sendable {
    let revision: SpatialSceneRevision
    let expectedHead: SpatialSceneHead?
}

struct SpatialSceneCommit: Sendable {
    let head: SpatialSceneHead
    let revision: SpatialSceneRevision
    let index: SpatialSceneIndex
}

enum SpatialSceneStore {
    static let basePath = "production_design/spatial"

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func index(in pipelineRoot: URL) throws -> SpatialSceneIndex {
        let path = "\(basePath)/index.v1.json"
        guard FileManager.default.fileExists(atPath: pipelineRoot.appendingPathComponent(path).path) else {
            guard !FileManager.default.fileExists(atPath: pipelineRoot.appendingPathComponent(basePath).path) else {
                throw SpatialSceneError.invalid("The location index is missing from its project.")
            }
            return SpatialSceneIndex()
        }
        let result = try JSONDecoder().decode(SpatialSceneIndex.self, from: read(path, in: pipelineRoot))
        guard result.schema == "spatial-scene-index/v1",
              Set(result.scenes.map(\.id)).count == result.scenes.count,
              result.scenes.allSatisfy({ !$0.name.isEmpty && validDigest($0.manifestSHA256) }) else {
            throw SpatialSceneError.invalid("The location index is invalid.")
        }
        return result
    }

    static func load(_ head: SpatialSceneHead, in pipelineRoot: URL) throws -> SpatialSceneRevision {
        try BpyMediaReadScope.withScope(dataRoot: pipelineRoot) { scope in
            try scope.withConsumer { work in
                try load(head, in: pipelineRoot, checking: { try scope.check(); try work.check() })
            }
        }
    }

    private static func load(_ head: SpatialSceneHead, in pipelineRoot: URL,
                             checking: () throws -> Void) throws -> SpatialSceneRevision {
        let path = revisionPath(scene: head.id, revision: head.revision)
        let manifestData = try read("\(path)/manifest.v1.json", in: pipelineRoot, checking: checking)
        guard digest(manifestData) == head.manifestSHA256 else { throw SpatialSceneError.changed }
        let manifest = try JSONDecoder().decode(SpatialSceneManifest.self, from: manifestData)
        guard manifest.schema == "spatial-scene-manifest/v1", manifest.sceneID == head.id,
              manifest.revision == head.revision, manifest.name == head.name else {
            throw SpatialSceneError.invalid("The location revision does not match its index.")
        }
        let sceneFile = try BpyRuntimeFile.borrow("\(path)/scene.blend", in: pipelineRoot,
            maximum: 512 * 1_024 * 1_024, expectedSHA256: manifest.sceneSHA256, checking: checking)
        defer { sceneFile.release() }
        let scene = SpatialScenePayload(path: "\(path)/scene.blend", root: pipelineRoot,
            sha256: sceneFile.sha256, byteCount: sceneFile.byteCount)
        let snapshotData = try read("\(path)/snapshot.v1.json", in: pipelineRoot, checking: checking)
        guard scene.sha256 == manifest.sceneSHA256,
              digest(snapshotData) == manifest.snapshotSHA256,
              manifest.receipt.sceneSHA256 == manifest.sceneSHA256,
              manifest.receipt.snapshotSHA256 == manifest.snapshotSHA256,
              manifest.receipt.resourceClosureSHA256 == manifest.resourceClosureSHA256,
              validDigest(manifest.receipt.runtimeLockSHA256),
              validDigest(manifest.receipt.workerSHA256),
              validDigest(manifest.receipt.jobFingerprint),
              digest(try encode(manifest.resources)) == manifest.resourceClosureSHA256,
              Set(manifest.resources.map(\.id)).count == manifest.resources.count else {
            throw SpatialSceneError.invalid("The location's source or resource evidence changed.")
        }
        let snapshot = try JSONDecoder().decode(BpySpatialSnapshot.self, from: snapshotData)
        try validate(snapshot)
        var resources: [UUID: Data] = [:]
        for item in manifest.resources {
            try validateFilename(item.filename)
            let data = try read("\(path)/resources/\(item.id.uuidString)/\(item.filename)", in: pipelineRoot, checking: checking)
            guard data.count == item.byteCount, try digest(data, checking: checking) == item.sha256 else {
                throw SpatialSceneError.invalid("A location resource changed: \(item.filename)")
            }
            resources[item.id] = data
        }
        try checking()
        return .init(manifest: manifest, snapshot: snapshot, manifestData: manifestData,
                     scenePayload: scene, snapshotData: snapshotData, resources: resources)
    }

    static func prepare(
        result: BpyRuntimeJobResult,
        sceneID: UUID,
        name: String,
        expectedHead: SpatialSceneHead?,
        runtimeLock: Data,
        worker: Data,
        resources: [(SpatialSceneResource, Data)],
        cancellation: BpyOperationCancellation
    ) throws -> SpatialSceneCandidate {
        guard let lease = result.lease else { throw SpatialSceneError.changed }
        return try lease.withConsumer(cancellation: cancellation) { work, cancellation in
            func checking() throws { try cancellation.check(); try work.check() }
            struct Verification: Decodable {
                let schema: String
                let jobID: UUID
                let fingerprint: String
                let blenderBuildHash: String
                let spatial: BpySpatialSnapshot?
            }
            guard result.response.ok, result.response.state == .awaitingConfirmation,
                  let jobID = result.response.jobID, let fingerprint = result.response.jobFingerprint,
                  result.stagedOutputs["scene.blend"] != nil,
                  let verificationURL = result.stagedOutputs["verification.json"],
                  expectedHead == nil || expectedHead?.id == sceneID,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpatialSceneError.invalid("The runtime did not return a complete location candidate.")
            }
            guard let sceneDescriptor = result.response.outputs.first(where: { $0.name == "scene.blend" }),
                  sceneDescriptor.byteCount <= (result.lease?.limits.inputBytes ?? 512 * 1_024 * 1_024) else { throw SpatialSceneError.changed }
            let file = try lease.file("scene.blend")
            guard file.byteCount == sceneDescriptor.byteCount, file.sha256 == sceneDescriptor.sha256 else {
                file.release(); throw SpatialSceneError.changed
            }
            let scene = SpatialScenePayload(file: file)
            var accepted = false
            defer { if !accepted { scene.releaseRuntimeSource() } }
            try scene.verify(checking: checking)
            let verificationData = try output(verificationURL, named: "verification.json", result: result, checking: checking)
            let verification = try JSONDecoder().decode(Verification.self, from: verificationData)
            guard verification.schema == "nexgenvideo/bpy-verification/1",
                  verification.jobID == jobID, verification.fingerprint == fingerprint,
                  let snapshot = verification.spatial else {
                throw SpatialSceneError.invalid("The independent location verification is missing.")
            }
            try validate(snapshot)
            let snapshotData = try encode(snapshot)
            let resourceList = resources.map(\.0).sorted { $0.id.uuidString < $1.id.uuidString }
            guard Set(resourceList.map(\.id)).count == resources.count else {
                throw SpatialSceneError.invalid("A location resource ID is duplicated.")
            }
            for (item, data) in resources {
                try validateFilename(item.filename)
                guard item.byteCount == data.count, item.sha256 == (try digest(data, checking: checking)) else {
                    throw SpatialSceneError.invalid("A location import changed before publication.")
                }
            }
            let receipt = SpatialSceneReceipt(
                jobID: jobID, jobFingerprint: fingerprint, runtimeLockSHA256: digest(runtimeLock),
                workerSHA256: digest(worker), blenderBuildHash: verification.blenderBuildHash,
                sceneSHA256: scene.sha256, snapshotSHA256: digest(snapshotData),
                resourceClosureSHA256: digest(try encode(resourceList))
            )
            let manifest = SpatialSceneManifest(
                sceneID: sceneID, revision: UUID(), parentRevision: expectedHead?.revision,
                restoredFromRevision: nil, name: name, sceneSHA256: scene.sha256,
                snapshotSHA256: digest(snapshotData), resourceClosureSHA256: digest(try encode(resourceList)),
                resources: resourceList, receipt: receipt
            )
            let manifestData = try encode(manifest)
            let candidate = SpatialSceneCandidate(revision: .init(
                manifest: manifest, snapshot: snapshot, manifestData: manifestData,
                scenePayload: scene, snapshotData: snapshotData,
                resources: Dictionary(uniqueKeysWithValues: resources.map { ($0.0.id, $0.1) })
            ), expectedHead: expectedHead)
            accepted = true
            return candidate
        }
    }

    static func restoration(_ original: SpatialSceneRevision, replacing head: SpatialSceneHead) throws -> SpatialSceneCandidate {
        guard original.manifest.sceneID == head.id else { throw SpatialSceneError.changed }
        let prior = original.manifest
        let manifest = SpatialSceneManifest(
            sceneID: prior.sceneID, revision: UUID(), parentRevision: head.revision,
            restoredFromRevision: prior.revision, name: prior.name, sceneSHA256: prior.sceneSHA256,
            snapshotSHA256: prior.snapshotSHA256, resourceClosureSHA256: prior.resourceClosureSHA256,
            resources: prior.resources, receipt: prior.receipt
        )
        return .init(revision: .init(
            manifest: manifest, snapshot: original.snapshot, manifestData: try encode(manifest),
            scenePayload: original.scenePayload, snapshotData: original.snapshotData, resources: original.resources
        ), expectedHead: head)
    }

    // The owning canonical writer calls this inside its existing project transaction.
    static func publish(_ candidate: SpatialSceneCandidate, in stagingPipelineRoot: URL) throws -> SpatialSceneHead {
        var index = try index(in: stagingPipelineRoot)
        let revision = candidate.revision
        let manifest = revision.manifest
        guard index.scenes.first(where: { $0.id == manifest.sceneID }) == candidate.expectedHead else {
            throw SpatialSceneError.changed
        }
        let path = revisionPath(scene: manifest.sceneID, revision: manifest.revision)
        guard !FileManager.default.fileExists(atPath: stagingPipelineRoot.appendingPathComponent(path).path) else {
            throw SpatialSceneError.invalid("An immutable location revision already exists.")
        }
        try BpyMediaReadScope.withScope(dataRoot: stagingPipelineRoot) { scope in
            try scope.withConsumer { work in
                try revision.scenePayload.export(to: destination("\(path)/scene.blend", in: stagingPipelineRoot),
                    checking: { try scope.check(); try work.check() })
            }
        }
        try write(revision.snapshotData, to: "\(path)/snapshot.v1.json", in: stagingPipelineRoot)
        for item in manifest.resources {
            guard let data = revision.resources[item.id] else {
                throw SpatialSceneError.invalid("A location resource is missing.")
            }
            try write(data, to: "\(path)/resources/\(item.id.uuidString)/\(item.filename)", in: stagingPipelineRoot)
        }
        try write(revision.manifestData, to: "\(path)/manifest.v1.json", in: stagingPipelineRoot)
        let head = SpatialSceneHead(id: manifest.sceneID, name: manifest.name, revision: manifest.revision,
                                    manifestSHA256: digest(revision.manifestData))
        _ = try load(head, in: stagingPipelineRoot)
        index.scenes.removeAll { $0.id == head.id }
        index.scenes.append(head)
        try write(try encode(index), to: "\(basePath)/index.v1.json", in: stagingPipelineRoot)
        return head
    }

    static func validate(_ snapshot: BpySpatialSnapshot) throws {
        let objects = Set(snapshot.objects.map(\.id))
        guard snapshot.schema == "nexgenvideo/bpy-spatial-snapshot/1", snapshot.units == "meters",
              snapshot.metersPerUnit.isFinite, snapshot.metersPerUnit > 0,
              snapshot.framesPerSecond.isFinite, snapshot.framesPerSecond > 0,
              (0...1_000_000).contains(snapshot.frame), (0...1_000_000).contains(snapshot.restFrame),
              snapshot.timebaseNumerator > 0, snapshot.timebaseDenominator > 0,
              abs(Double(snapshot.timebaseNumerator) / Double(snapshot.timebaseDenominator) - snapshot.framesPerSecond) < 0.000001,
              snapshot.externalPaths.isEmpty, objects.count == snapshot.objects.count,
              snapshot.objects.allSatisfy({ UUID(uuidString: $0.id) != nil && validMatrix($0.matrixWorld) }),
              Set(snapshot.meshes.map(\.id)).count == snapshot.meshes.count,
              Set(snapshot.cameras.map(\.id)).count == snapshot.cameras.count else {
            throw SpatialSceneError.invalid("The evaluated location snapshot is invalid.")
        }
        for mesh in snapshot.meshes {
            guard objects.contains(mesh.objectID), validMatrix(mesh.matrixWorld),
                  mesh.positions.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
                  mesh.triangles.count.isMultiple(of: 3),
                  mesh.triangles.allSatisfy({ UInt64($0) < UInt64(mesh.positions.count) }) else {
                throw SpatialSceneError.invalid("The evaluated location mesh is invalid.")
            }
        }
        for camera in snapshot.cameras {
            guard objects.contains(camera.id), validMatrix(camera.matrixWorld), validMatrix(camera.projection),
                  camera.near.isFinite, camera.far.isFinite, camera.near > 0, camera.far > camera.near,
                  camera.verticalFieldOfView.isFinite, camera.verticalFieldOfView > 0,
                  camera.verticalFieldOfView < .pi, camera.width > 0, camera.height > 0 else {
                throw SpatialSceneError.invalid("The evaluated location camera is invalid.")
            }
        }
    }

    static func revisionPath(scene: UUID, revision: UUID) -> String {
        "\(basePath)/scenes/\(scene.uuidString)/revisions/\(revision.uuidString)"
    }

    static func read(_ path: String, in root: URL, checking: () throws -> Void = {}) throws -> Data {
        try checking()
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { throw SpatialSceneError.invalid("A location path is empty.") }
        for component in components { try validateFilename(component) }
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { Darwin.close(descriptor) }
        for (offset, component) in components.enumerated() {
            let directory = offset < components.count - 1
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard next >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
            Darwin.close(descriptor)
            descriptor = next
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0, status.st_size <= 512 * 1_024 * 1_024 else {
            throw SpatialSceneError.invalid("The location resource is not a bounded regular file.")
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try checking()
                let count = pread(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset), off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SpatialSceneError.changed }
                offset += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == status.st_size,
              after.st_dev == status.st_dev, after.st_ino == status.st_ino,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec else { throw SpatialSceneError.changed }
        try checking()
        return data
    }

    private static func write(_ data: Data, to path: String, in root: URL) throws {
        try data.write(to: destination(path, in: root), options: .atomic)
    }

    private static func destination(_ path: String, in root: URL) throws -> URL {
        var directory = URL(fileURLWithPath: try BpyRuntimePath.canonical(root))
        let components = path.split(separator: "/").map(String.init)
        for component in components { try validateFilename(component) }
        for component in components.dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SpatialSceneError.invalid("A location path escapes its project.")
            }
        }
        return directory.appendingPathComponent(components.last!)
    }

    private static func output(_ url: URL, named name: String, result: BpyRuntimeJobResult,
                               checking: () throws -> Void) throws -> Data {
        guard let descriptor = result.response.outputs.first(where: { $0.name == name }) else {
            throw SpatialSceneError.invalid("A verified location output is missing.")
        }
        let data = try read(url.lastPathComponent, in: url.deletingLastPathComponent(), checking: checking)
        guard data.count == descriptor.byteCount, try digest(data, checking: checking) == descriptor.sha256 else {
            throw SpatialSceneError.changed
        }
        return data
    }

    static func digest(_ data: Data, checking: () throws -> Void) throws -> String {
        var digest = SHA256()
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            try checking()
            digest.update(data: data[offset..<min(offset + 65_536, data.count)])
        }
        try checking()
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validMatrix(_ values: [Double]) -> Bool {
        values.count == 16 && values.allSatisfy(\.isFinite)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validateFilename(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SpatialSceneError.invalid("A location resource path is invalid.")
        }
    }
}
