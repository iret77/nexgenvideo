import Darwin
import Foundation
import NexGenEngine

@MainActor
final class PipelineSpatialSceneAuthority: SpatialSceneAuthority {
    private weak var editor: EditorViewModel?
    private let home: URL
    private let key: String
    private let declaration: ProjectPackGate.MutationDeclaration
    private let runtime: BpyRuntimeSession

    init(editor: EditorViewModel, runtime: BpyRuntimeSession) throws {
        guard let home = editor.workingRoot, let key = editor.openWorkingCopyKey else {
            throw GateBlocked("Open a production project before editing locations.")
        }
        self.editor = editor
        self.home = home
        self.key = key
        self.runtime = runtime
        declaration = .init(packName: editor.declaredPluginName, binding: editor.declaredPluginBinding,
                            productionContract: editor.declaredProductionContract)
        _ = try requireContext()
    }

    private func requireContext() throws -> URL {
        guard let editor, editor.workingRoot == home, editor.openWorkingCopyKey == key,
              editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
              editor.declaredProductionContract == declaration.productionContract,
              let root = DataRootResolver.dataRoot(of: home) else {
            throw GateBlocked("The production project changed. Reopen its location editor.")
        }
        return root
    }

    func requireReadableScene() async throws {
        try await readScene { _ in () }
    }

    func readScene<Value: Sendable>(_ operation: @escaping @Sendable (URL) throws -> Value) async throws -> Value {
        let root = try requireContext()
        let declaration = declaration
        let (value, fence) = try await Self.background {
            let fence = try SourceFence.capture(dataRoot: root)
            try Self.requireReadable(dataRoot: root, declaration: declaration)
            let value = try operation(root)
            try fence.requireUnchanged()
            return (value, fence)
        }
        try Task.checkCancellation()
        guard try requireContext() == root else { throw SpatialSceneError.changed }
        try fence.requireCanonicalRootsUnchanged()
        return value
    }

    nonisolated private static func requireReadable(dataRoot: URL, declaration: ProjectPackGate.MutationDeclaration) throws {
        guard try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract)?.isProductionV2 == true else {
            throw GateBlocked("The production workflow changed. Reopen its location editor.")
        }
        try requireCurrent(dataRoot: dataRoot)
    }

    func commitSceneEdit(_ prepare: @escaping @Sendable () async throws -> SpatialSceneCandidate) async throws -> SpatialSceneCommit {
        let root = try requireContext()
        guard let editor, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Edit location") else {
            throw GateBlocked("Finish the current production action before editing this location.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let declaration = declaration
        let runtime = runtime
        let before = try await Self.background {
            try Self.requireReadable(dataRoot: root, declaration: declaration)
            _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "production_design")
            return try Self.editFingerprint(dataRoot: root)
        }
        try Task.checkCancellation()
        guard try requireContext() == root,
              editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else { throw SpatialSceneError.changed }
        let candidate = try await prepare()
        try Task.checkCancellation()
        let publication = try await Self.background {
            let source = try SourceFence.capture(dataRoot: root)
            try Self.requireReadable(dataRoot: root, declaration: declaration)
            _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "production_design")
            guard try Self.editFingerprint(dataRoot: root) == before else { throw SpatialSceneError.changed }
            let restored = try Self.restoredSource(candidate.revision, dataRoot: root)
            if restored == nil { try runtime.authenticateSpatialReceipt(candidate.revision) }
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                _ = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: declaration, phase: "production_design")
                let head = try SpatialSceneStore.publish(candidate, in: staging)
                try Self.recordAdoption(candidate.revision, restoredFrom: restored, dataRoot: staging)
                let inventory = try Self.inventory(dataRoot: staging)
                try PlanningWriterIO.json(inventory).write(to: staging.appendingPathComponent(ProductionSpatialInventoryV1.currentPath), options: .atomic)
                try Self.requireCurrent(dataRoot: staging)
                try PipelinePhaseMutationRecorder.record(phase: "production_design", dataRoot: staging,
                    captureLineage: FileManager.default.fileExists(atPath: staging.appendingPathComponent(PipelineLayout.productionDesignFile).path),
                    declaredPack: declaration.packName, declaredBinding: declaration.binding,
                    declaredProductionContract: declaration.productionContract)
                return SpatialSceneCommit(head: head, revision: candidate.revision, index: try SpatialSceneStore.index(in: staging))
            }
            do {
                try source.requireUnchanged()
                return PreparedPublication(transaction: transaction, source: source)
            } catch {
                transaction.discard()
                throw error
            }
        }
        defer { Task.detached { publication.transaction.discard() } }
        try Task.checkCancellation()
        let result = try publication.transaction.commit { _ in
            guard try self.requireContext() == root,
                  editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease),
                  runtime.isAvailable else { throw SpatialSceneError.changed }
            try publication.source.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: key)
        }
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return result
    }

    nonisolated private static func background<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private struct PreparedPublication: Sendable {
        let transaction: ProjectWorkingCopy.PreparedPipelineTransaction<SpatialSceneCommit>
        let source: SourceFence
    }

    private struct SourceFence: Sendable {
        let paths: [URL: [Int64]]
        let canonicalPaths: [URL]

        static func capture(dataRoot: URL) throws -> Self {
            let root = dataRoot.standardizedFileURL
            let home = root.deletingLastPathComponent()
            var stamps: [URL: [Int64]] = [home: try stamp(home)]
            func visit(_ path: URL) throws {
                try Task.checkCancellation()
                let state = try stamp(path)
                guard !state.isEmpty else { throw SpatialSceneError.changed }
                stamps[path] = state
                if UInt32(state[3]) & S_IFMT == S_IFDIR {
                    for child in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                        try visit(child)
                    }
                }
            }
            try visit(root)
            let canonical = [root, home] + ["ngv.json", ".ngv-open-generation"].map { home.appendingPathComponent($0) }
                + [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.gatesFile,
                   PipelineLayout.lineageFile, PipelineLayout.productionDesignFile, StorySourceV1.currentPath,
                   ProductionSpatialInventoryV1.currentPath, "\(SpatialSceneStore.basePath)/index.v1.json"]
                    .map { root.appendingPathComponent($0) }
            for path in canonical { stamps[path] = try stamp(path) }
            let result = Self(paths: stamps, canonicalPaths: canonical)
            try result.requireUnchanged()
            return result
        }

        func requireUnchanged() throws {
            for (path, expected) in paths {
                try Task.checkCancellation()
                guard try Self.stamp(path) == expected else { throw SpatialSceneError.changed }
            }
        }

        func requireCanonicalRootsUnchanged() throws {
            for path in canonicalPaths {
                guard try Self.stamp(path) == paths[path] else { throw SpatialSceneError.changed }
            }
        }

        private static func stamp(_ path: URL) throws -> [Int64] {
            var value = stat()
            guard lstat(path.path, &value) == 0 else {
                if errno == ENOENT { return [] }
                throw SpatialSceneError.changed
            }
            guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else {
                throw SpatialSceneError.changed
            }
            return [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size,
                    Int64(value.st_mode), Int64(value.st_nlink), Int64(value.st_uid),
                    Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
                    Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
    }

    private struct Adoption: Codable {
        let schema: String
        let projectID: String
        let manifest: CanonicalArtifactReferenceV1
        let receipt: SpatialSceneReceipt
        let restoredFrom: CanonicalArtifactReferenceV1?
    }

    nonisolated static func requireCurrent(dataRoot: URL) throws {
        guard let stored = try ProductionSpatialInventoryV1.loadIfPresent(dataRoot: dataRoot) else { return }
        guard try inventory(dataRoot: dataRoot) == stored else { throw GateBlocked("A location or its verified source changed. Restore or revise Production Design.") }
    }

    nonisolated private static func inventory(dataRoot: URL) throws -> ProductionSpatialInventoryV1 {
        let index = try SpatialSceneStore.index(in: dataRoot)
        var references = [try reference("\(SpatialSceneStore.basePath)/index.v1.json", dataRoot: dataRoot)]
        for head in index.scenes {
            let revision = try SpatialSceneStore.load(head, in: dataRoot)
            references += try verifiedReferences(revision, dataRoot: dataRoot, visited: [])
        }
        var unique: [String: CanonicalArtifactReferenceV1] = [:]
        for reference in references {
            if let previous = unique[reference.path], previous != reference { throw SpatialSceneError.changed }
            unique[reference.path] = reference
        }
        let meta = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        return ProductionSpatialInventoryV1(projectID: meta.project, references: unique.values.sorted { $0.path < $1.path })
    }

    nonisolated private static func verifiedReferences(_ revision: SpatialSceneRevision, dataRoot: URL,
                                                       visited: Set<UUID>) throws -> [CanonicalArtifactReferenceV1] {
        let manifest = revision.manifest
        guard !visited.contains(manifest.revision) else { throw SpatialSceneError.changed }
        let path = SpatialSceneStore.revisionPath(scene: manifest.sceneID, revision: manifest.revision)
        let record = try PlanningWriterIO.read(Adoption.self, at: adoptionPath(manifest.revision), dataRoot: dataRoot)
        let meta = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard record.schema == "spatial-scene-adoption/v1", record.projectID == meta.project,
              record.receipt == manifest.receipt,
              record.manifest.path == "\(path)/manifest.v1.json",
              record.manifest.sha256 == FileDigest.sha256(of: revision.manifestData) else {
            throw GateBlocked("The location has no matching host verification. Import or create it again in Production Design.")
        }
        var references = try (["\(path)/manifest.v1.json", "\(path)/scene.blend", "\(path)/snapshot.v1.json",
            adoptionPath(manifest.revision)] + manifest.resources.map { "\(path)/resources/\($0.id.uuidString)/\($0.filename)" })
            .map { try reference($0, dataRoot: dataRoot) }
        if let originalID = manifest.restoredFromRevision {
            guard let original = record.restoredFrom,
                  original.path == "\(SpatialSceneStore.revisionPath(scene: manifest.sceneID, revision: originalID))/manifest.v1.json" else {
                throw SpatialSceneError.changed
            }
            let source = try restoredRevision(original, sceneID: manifest.sceneID, revisionID: originalID, dataRoot: dataRoot)
            guard source.manifest.sceneSHA256 == manifest.sceneSHA256,
                  source.manifest.snapshotSHA256 == manifest.snapshotSHA256,
                  source.manifest.resourceClosureSHA256 == manifest.resourceClosureSHA256,
                  source.manifest.receipt == manifest.receipt else { throw SpatialSceneError.changed }
            references += try verifiedReferences(source, dataRoot: dataRoot, visited: visited.union([manifest.revision]))
        } else if record.restoredFrom != nil { throw SpatialSceneError.changed }
        return references
    }

    nonisolated private static func restoredSource(_ revision: SpatialSceneRevision, dataRoot: URL) throws -> CanonicalArtifactReferenceV1? {
        guard let originalID = revision.manifest.restoredFromRevision else { return nil }
        let path = "\(SpatialSceneStore.revisionPath(scene: revision.manifest.sceneID, revision: originalID))/manifest.v1.json"
        let original = try reference(path, dataRoot: dataRoot)
        let source = try restoredRevision(original, sceneID: revision.manifest.sceneID, revisionID: originalID, dataRoot: dataRoot)
        _ = try verifiedReferences(source, dataRoot: dataRoot, visited: [])
        guard source.sceneData == revision.sceneData, source.snapshotData == revision.snapshotData,
              source.resources == revision.resources, source.manifest.receipt == revision.manifest.receipt else { throw SpatialSceneError.changed }
        return original
    }

    nonisolated private static func restoredRevision(_ reference: CanonicalArtifactReferenceV1, sceneID: UUID,
                                                      revisionID: UUID, dataRoot: URL) throws -> SpatialSceneRevision {
        let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)
        let manifest = try JSONDecoder().decode(SpatialSceneManifest.self, from: Data(contentsOf: url))
        return try SpatialSceneStore.load(.init(id: sceneID, name: manifest.name, revision: revisionID,
            manifestSHA256: reference.sha256), in: dataRoot)
    }

    nonisolated private static func recordAdoption(_ revision: SpatialSceneRevision, restoredFrom: CanonicalArtifactReferenceV1?, dataRoot: URL) throws {
        let manifest = revision.manifest
        let path = adoptionPath(manifest.revision)
        guard !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else { throw SpatialSceneError.changed }
        let meta = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let manifestPath = "\(SpatialSceneStore.revisionPath(scene: manifest.sceneID, revision: manifest.revision))/manifest.v1.json"
        let record = Adoption(schema: "spatial-scene-adoption/v1", projectID: meta.project,
            manifest: try reference(manifestPath, dataRoot: dataRoot), receipt: manifest.receipt, restoredFrom: restoredFrom)
        _ = try ProjectLocalFile.ensureDirectory((path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
        try PlanningWriterIO.json(record).write(to: dataRoot.appendingPathComponent(path), options: .atomic)
    }

    nonisolated private static func adoptionPath(_ revision: UUID) -> String { "\(SpatialSceneStore.basePath)/adoptions/\(revision.uuidString).json" }

    nonisolated private static func reference(_ path: String, dataRoot: URL) throws -> CanonicalArtifactReferenceV1 {
        .init(id: "spatial." + FileDigest.sha256(of: Data(path.utf8)), role: "core.production-spatial", path: path,
              sha256: try FileDigest.sha256(of: ProjectLocalFile.resolve(path, dataRoot: dataRoot)))
    }

    nonisolated private static func editFingerprint(dataRoot: URL) throws -> String {
        let required = [PipelineLayout.projectFile, PipelineLayout.briefFile, PipelineLayout.gatesFile]
        let optional = [PipelineLayout.lineageFile, PipelineLayout.productionDesignFile, StorySourceV1.currentPath,
            ProductionSpatialInventoryV1.currentPath]
        var paths = required + optional.filter { FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path) }
        if let inventory = try ProductionSpatialInventoryV1.loadIfPresent(dataRoot: dataRoot) { paths += inventory.references.map(\.path) }
        return FileDigest.sha256(of: try PlanningWriterIO.json(try paths.sorted().map { try reference($0, dataRoot: dataRoot) }))
    }
}
