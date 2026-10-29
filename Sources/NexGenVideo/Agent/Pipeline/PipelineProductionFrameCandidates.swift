import Foundation
import NexGenEngine

enum PipelineProductionFrameCandidates {
    struct Candidate: Codable, Equatable, Sendable {
        let receipt: PipelineProductionFramesWriter.Receipt
        let usage: FrameReferenceUsageV1
        var id: String { get throws { FileDigest.sha256(of: try PlanningWriterIO.json(self)) } }
    }

    struct Decision: Codable, Equatable, Sendable {
        let candidateID: String
        let recordedAt: String
    }

    struct Index: Codable, Equatable, Sendable {
        let schema: String
        let project: String
        let shotID: String
        let role: String
        var candidates: [CanonicalArtifactReferenceV1]
        var active: String?
        var decisions: [Decision]
    }

    struct Item: Sendable, Identifiable {
        let id: String
        let candidate: Candidate
        let unavailable: String?
    }

    struct Snapshot: Sendable {
        let home: URL
        let index: Index
        let projectionSHA256: String
        let items: [Item]
        var shotID: String { index.shotID }
        var role: String { index.role }
    }

    enum Aspect: String, Codable, Sendable, CaseIterable, Identifiable {
        case composition = "Composition", continuity = "Continuity", performance = "Performance"
        case style = "Style", lighting = "Lighting", technical = "Technical quality"
        var id: String { rawValue }
    }

    enum IterationKind: String, Codable, Sendable { case redo, remix }

    struct Iteration: Codable, Equatable, Sendable {
        struct Source: Codable, Equatable, Sendable {
            let candidate: CanonicalArtifactReferenceV1
            let image: CanonicalArtifactReferenceV1
            let aspects: [Aspect]
        }
        let schema: String
        let kind: IterationKind
        let project: String
        let shotID: String
        let role: String
        let projectionSHA256: String
        let sources: [Source]
        let reason: Aspect
        let note: String
        let recordedAt: String

        var directives: [String] {
            let sources = sources.enumerated().map { index, source in
                "Candidate source \(index + 1): preserve \(source.aspects.map(\.rawValue).joined(separator: ", "))."
            }
            return ["Frame \(kind.rawValue): correct \(reason.rawValue.lowercased()) while preserving the approved boundary state."]
                + sources + (note.isEmpty ? [] : ["Frame revision direction: " + note])
        }
    }

    static func iterationPath(shotID: String, role: String) throws -> String {
        _ = try directory(shotID: shotID, role: role)
        return "frames/iterations/\(shotID)-\(role).current.v1.json"
    }

    static func iterationReference(_ value: Iteration) throws -> CanonicalArtifactReferenceV1 {
        let hash = FileDigest.sha256(of: try PlanningWriterIO.json(value))
        return .init(id: hash, role: "host.frame-iteration", path: "frames/iterations/\(hash).v1.json", sha256: hash)
    }

    static func currentIteration(shotID: String, role: String, dataRoot: URL) throws -> Iteration? {
        let path = try iterationPath(shotID: shotID, role: role)
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else { return nil }
        let value = try PlanningWriterIO.read(Iteration.self, at: path, dataRoot: dataRoot)
        let ref = try iterationReference(value)
        _ = try PipelineGenerationEvidenceSnapshot.requireExact(ref.sha256, path: path, root: dataRoot)
        _ = try PipelineGenerationEvidenceSnapshot.requireExact(ref.sha256, path: ref.path, root: dataRoot)
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        guard value.schema == "production-frame-iteration/v1", value.project == projection.header.projectID,
              value.shotID == shotID, value.role == role,
              value.kind == .redo ? value.sources.count == 1 : value.sources.count >= 2,
              Set(value.sources.map { $0.candidate.id }).count == value.sources.count else { throw changed() }
        guard value.projectionSHA256 == FileDigest.sha256(of: try PlanningWriterIO.json(projection)) else { return nil }
        let index = try load(shotID: shotID, role: role, project: value.project, dataRoot: dataRoot)
        for source in value.sources {
            guard index.candidates.contains(source.candidate), !source.aspects.isEmpty,
                  Set(source.aspects).count == source.aspects.count else { throw changed() }
            let original = try candidate(source.candidate, index: index, dataRoot: dataRoot)
            let frame = try PipelineProductionFramesWriter.requireEvidence(receipt: original.receipt, usage: original.usage,
                projection: projection, dataRoot: dataRoot)
            guard source.image == CanonicalArtifactReferenceV1(id: source.candidate.id, role: "host.frame-candidate-image",
                path: frame.path, sha256: original.usage.outputSHA256) else { throw changed() }
        }
        return value
    }

    @MainActor
    static func requestIteration(kind: IterationKind, sources: [String: [Aspect]], reason: Aspect, note: String,
        snapshot: Snapshot, editor: EditorViewModel) async throws -> CanonicalArtifactReferenceV1 {
        guard kind == .redo ? sources.count == 1 : sources.count >= 2 else { throw changed() }
        let selected = try sources.keys.sorted().map { id -> Iteration.Source in
            guard let item = snapshot.items.first(where: { $0.id == id }), item.unavailable == nil,
                  let aspects = sources[id], !aspects.isEmpty else { throw changed() }
            return .init(candidate: try reference(item.candidate), image: .init(id: id, role: "host.frame-candidate-image",
                path: item.candidate.receipt.frame.path, sha256: item.candidate.usage.outputSHA256),
                aspects: Array(Set(aspects)).sorted { $0.rawValue < $1.rawValue })
        }
        let value = Iteration(schema: "production-frame-iteration/v1", kind: kind, project: snapshot.index.project,
            shotID: snapshot.shotID, role: snapshot.role, projectionSHA256: snapshot.projectionSHA256,
            sources: selected, reason: reason, note: note.trimmingCharacters(in: .whitespacesAndNewlines), recordedAt: currentTimestamp())
        let ref = try iterationReference(value)
        try await mutate(snapshot: snapshot, editor: editor, label: kind == .redo ? "Prepare frame redo" : "Prepare frame remix") { access, index in
            var updated = index
            var files: [(path: String, bytes: Data)] = []
            for source in value.sources {
                let original = try candidate(source.candidate, index: index, dataRoot: access.dataRoot)
                files += try archive(original, index: &updated, dataRoot: access.dataRoot)
            }
            let bytes = try PlanningWriterIO.json(value)
            files += [(ref.path, bytes), (try iterationPath(shotID: value.shotID, role: value.role), bytes)]
            let unique = Dictionary(files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { _, last in last })
            try access.publish(unique.map { (path: $0.key, bytes: $0.value) }, captureLineage: false) {
                guard try currentIteration(shotID: value.shotID, role: value.role, dataRoot: access.dataRoot) == value else { throw changed() }
            }
        }
        return ref
    }

    static func iterationBindings(_ value: Iteration) -> [FrameReferenceBindingV1] {
        value.sources.enumerated().map { index, source in
            .init(path: source.image.path, sha256: source.image.sha256, role: "frameRevision",
                entityID: source.candidate.id, viewID: value.role,
                purpose: value.directives.joined(separator: " ") + " This source preserves " + source.aspects.map(\.rawValue).joined(separator: ", ") + ".",
                requirementIDs: ["frame-revision-" + source.candidate.id], isRequired: true, priority: index)
        }
    }

    static func requireIterationEvidence(inputs: [CanonicalArtifactReferenceV1], usage: FrameReferenceUsageV1,
        projection: ProductionPlanProjectionV1, dataRoot: URL) throws {
        let references = inputs.filter { $0.role == "host.frame-iteration" }
        let bindings = usage.plan.bindings.filter { $0.role == "frameRevision" }
        guard references.count <= 1 else { throw changed() }
        guard let reference = references.first else {
            guard bindings.isEmpty else { throw changed() }
            return
        }
        _ = try PipelineGenerationEvidenceSnapshot.requireExact(reference.sha256, path: reference.path, root: dataRoot)
        let value = try PlanningWriterIO.read(Iteration.self, at: reference.path, dataRoot: dataRoot)
        guard try iterationReference(value) == reference, value.schema == "production-frame-iteration/v1",
              value.project == projection.header.projectID, value.shotID == usage.shotID, value.role == usage.role,
              value.projectionSHA256 == FileDigest.sha256(of: try PlanningWriterIO.json(projection)),
              iterationBindings(value) == bindings else { throw changed() }
        for source in value.sources {
            guard inputs.contains(source.candidate), !source.aspects.isEmpty else { throw changed() }
            _ = try PipelineGenerationEvidenceSnapshot.requireExact(source.candidate.sha256, path: source.candidate.path, root: dataRoot)
            let original = try PlanningWriterIO.read(Candidate.self, at: source.candidate.path, dataRoot: dataRoot)
            guard try self.reference(original) == source.candidate,
                  original.receipt.shotID == usage.shotID, original.receipt.role == usage.role,
                  source.image.path == original.receipt.frame.path, source.image.sha256 == original.usage.outputSHA256,
                  try GenerationOutputReceipt.load(assetID: original.receipt.generation.assetID,
                    home: FrameInventory.projectHome(of: dataRoot)) == original.receipt.generation,
                  source.image.sha256 == original.receipt.generation.output.sha256 else { throw changed() }
            _ = try ProjectLocalFile.requireHash(source.image.sha256, at: source.image.path, dataRoot: dataRoot)
        }
    }

    static func directory(shotID: String, role: String) throws -> String {
        guard UUID(uuidString: shotID) != nil, ["start", "end"].contains(role) else { throw changed() }
        return "frames/candidates/\(shotID)/\(role)"
    }

    static func indexPath(shotID: String, role: String) throws -> String {
        try directory(shotID: shotID, role: role) + "/index.v1.json"
    }

    static func reference(_ candidate: Candidate) throws -> CanonicalArtifactReferenceV1 {
        let id = try candidate.id
        return .init(id: id, role: "host.frame-candidate", path: try directory(shotID: candidate.receipt.shotID,
            role: candidate.receipt.role) + "/\(id).v1.json", sha256: id)
    }

    static func load(shotID: String, role: String, project: String, dataRoot: URL) throws -> Index {
        let path = try indexPath(shotID: shotID, role: role)
        let directory = try self.directory(shotID: shotID, role: role)
        guard FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) else {
            guard !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(directory).path) else { throw changed() }
            let legacyPath = PipelineProductionFramesWriter.receiptPath(shotID: shotID, role: role)
            let legacy: [CanonicalArtifactReferenceV1]
            if FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(legacyPath).path) {
                let candidate = Candidate(receipt: try PlanningWriterIO.read(PipelineProductionFramesWriter.Receipt.self,
                    at: legacyPath, dataRoot: dataRoot), usage: try FrameReferenceUsageStoreV1.load(shotID: shotID, role: role, dataRoot: dataRoot))
                legacy = [try reference(candidate)]
            } else { legacy = [] }
            return Index(schema: "production-frame-candidates/v1", project: project, shotID: shotID, role: role,
                candidates: legacy, active: legacy.first?.id, decisions: [])
        }
        let indexURL = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        guard indexURL.standardizedFileURL == dataRoot.appendingPathComponent(path).standardizedFileURL else { throw changed() }
        let index = try PlanningWriterIO.read(Index.self, at: path, dataRoot: dataRoot)
        guard index.schema == "production-frame-candidates/v1", index.project == project,
              index.shotID == shotID, index.role == role,
              Set(index.candidates.map(\.id)).count == index.candidates.count,
              index.active.map({ id in index.candidates.contains { $0.id == id } }) ?? index.candidates.isEmpty,
              index.decisions.last.map({ $0.candidateID == index.active }) ?? true,
              index.decisions.allSatisfy({ decision in index.candidates.contains { $0.id == decision.candidateID } }) else { throw changed() }
        let actual = try Set(FileManager.default.contentsOfDirectory(atPath: indexURL.deletingLastPathComponent().path))
        guard actual == Set(index.candidates.map { ($0.path as NSString).lastPathComponent } + ["index.v1.json"]) else { throw changed() }
        for ref in index.candidates { _ = try candidate(ref, index: index, dataRoot: dataRoot) }
        return index
    }

    static func candidate(_ ref: CanonicalArtifactReferenceV1, index: Index, dataRoot: URL) throws -> Candidate {
        let value: Candidate
        if !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(try indexPath(shotID: index.shotID, role: index.role)).path) {
            value = Candidate(receipt: try PlanningWriterIO.read(PipelineProductionFramesWriter.Receipt.self,
                at: PipelineProductionFramesWriter.receiptPath(shotID: index.shotID, role: index.role), dataRoot: dataRoot),
                usage: try FrameReferenceUsageStoreV1.load(shotID: index.shotID, role: index.role, dataRoot: dataRoot))
        } else {
            _ = try PipelineGenerationEvidenceSnapshot.requireExact(ref.sha256, path: ref.path, root: dataRoot)
            value = try PlanningWriterIO.read(Candidate.self, at: ref.path, dataRoot: dataRoot)
        }
        guard try reference(value) == ref, value.receipt.shotID == index.shotID,
              value.receipt.role == index.role, value.usage.shotID == index.shotID,
              value.usage.role == index.role else { throw changed() }
        return value
    }

    static func requireActive(receipt: PipelineProductionFramesWriter.Receipt,
        usage: FrameReferenceUsageV1, dataRoot: URL) throws {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let index = try load(shotID: receipt.shotID, role: receipt.role, project: projection.header.projectID, dataRoot: dataRoot)
        guard let ref = index.candidates.first(where: { $0.id == index.active }),
              try candidate(ref, index: index, dataRoot: dataRoot) == Candidate(receipt: receipt, usage: usage) else { throw changed() }
    }

    static func archive(_ value: Candidate, index: inout Index, dataRoot: URL) throws -> [(path: String, bytes: Data)] {
        var files: [(path: String, bytes: Data)] = []
        for ref in index.candidates where !FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(ref.path).path) {
            files.append((ref.path, try PlanningWriterIO.json(candidate(ref, index: index, dataRoot: dataRoot))))
        }
        let ref = try reference(value)
        if !index.candidates.contains(ref) {
            index.candidates.append(ref)
            files.append((ref.path, try PlanningWriterIO.json(value)))
        }
        if index.active == nil { index.active = ref.id }
        files.append((try indexPath(shotID: index.shotID, role: index.role), try PlanningWriterIO.json(index)))
        return files
    }

    static func capture(home: URL) async throws -> [Snapshot] {
        try await Task.detached(priority: .userInitiated) {
            guard let root = DataRootResolver.dataRoot(of: home) else { throw changed() }
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: root)
            let hash = FileDigest.sha256(of: try PlanningWriterIO.json(projection))
            return try projection.shots.flatMap { shot in
                try projection.requiredFrameRoles(for: shot.id).map { role in
                    let index = try load(shotID: shot.id, role: role, project: projection.header.projectID, dataRoot: root)
                    let items = try index.candidates.map { ref in
                        let value = try candidate(ref, index: index, dataRoot: root)
                        let failure: String?
                        do {
                            _ = try PipelineProductionFramesWriter.requireEvidence(receipt: value.receipt, usage: value.usage,
                                projection: projection, dataRoot: root)
                            failure = nil
                        } catch { failure = error.localizedDescription }
                        return Item(id: ref.id, candidate: value, unavailable: failure)
                    }
                    return Snapshot(home: home, index: index, projectionSHA256: hash, items: items)
                }
            }
        }.value
    }

    @MainActor
    static func select(candidateID: String, snapshot: Snapshot, editor: EditorViewModel) async throws {
        try await mutate(snapshot: snapshot, editor: editor, label: "Select frame") { access, index in
            guard let ref = index.candidates.first(where: { $0.id == candidateID }) else { throw changed() }
            let value = try candidate(ref, index: index, dataRoot: access.dataRoot)
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: access.dataRoot)
            _ = try PipelineProductionFramesWriter.requireEvidence(receipt: value.receipt, usage: value.usage,
                projection: projection, dataRoot: access.dataRoot)
            var updated = index
            updated.active = candidateID
            updated.decisions.append(Decision(candidateID: candidateID, recordedAt: currentTimestamp()))
            let files = try archive(value, index: &updated, dataRoot: access.dataRoot)
            try PipelineProductionFramesWriter.publish(candidate: value, files: files, access: access)
        }
    }

    @MainActor
    static func mutate(snapshot: Snapshot, editor: EditorViewModel, label: String,
        operation: @escaping @Sendable (PipelinePlanningWriteAccess, Index) throws -> Void) async throws {
        guard editor.workingRoot == snapshot.home else { throw changed() }
        let access = try PipelineNativeEditAccess(editor: editor, label: label)
        defer { access.end(editor: editor) }
        let preparation = Task.detached(priority: .userInitiated) {
            let writer = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "frames")
            let initialFence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root)
            let sourceFence = PipelineSpatialSceneAuthority.SourceFence(paths: initialFence.paths,
                canonicalPaths: Array(initialFence.paths.keys))
            let index = try load(shotID: snapshot.shotID, role: snapshot.role, project: snapshot.index.project, dataRoot: access.root)
            let projection = try ProductionPlanningLineageV2.projection(dataRoot: access.root)
            guard index == snapshot.index, FileDigest.sha256(of: try PlanningWriterIO.json(projection)) == snapshot.projectionSHA256 else { throw changed() }
            let sources = try index.candidates.flatMap { ref -> [URL] in
                let value = try candidate(ref, index: index, dataRoot: access.root)
                let completed = value.receipt.generation
                return try [GenerationOutputReceipt.path(assetID: completed.assetID), completed.output.path, completed.package.path]
                    .map { try ProjectLocalFile.resolve($0, dataRoot: access.home) }
            }
            let generationFence = try PipelineNativeTakeSourceFence.capture(sources)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let staged = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: writer.declaration, phase: "frames")
                try operation(staged, index)
            }
            do { try sourceFence.requireUnchanged(); try generationFence.requireUnchanged() }
            catch { transaction.discard(); throw error }
            return (transaction, sourceFence, generationFence)
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            try result.1.requireCanonicalRootsUnchanged()
            try result.2.requireUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor)
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
    }

    static func changed() -> GateBlocked {
        GateBlocked("The frame candidates or their source evidence changed. Reload Frames before selecting or regenerating a candidate.")
    }
}
