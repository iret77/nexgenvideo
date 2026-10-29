import Foundation
import NexGenEngine

struct FilmFlowAdoption: Codable, Equatable, Sendable {
    let snapshotID: UUID
    let snapshotSHA256: String
    let sourceObjectID: String
    let targetID: String
    let fields: [String]

    struct Receipt: Codable, Sendable {
        let schema: String
        let id: UUID
        let projectID: String
        let phase: String
        let mapping: FilmFlowAdoption
        let outputs: [CanonicalArtifactReferenceV1]
        let adoptedAt: Date
    }

    static func storyboardOutputs(_ snapshot: StoryboardBundleSnapshot) throws -> [CanonicalArtifactReferenceV1] {
        let revision = snapshot.storyboard.header.revision
        let paths = [StoryboardV2.versionPath(revision), StoryboardCausalityV2.versionPath(revision),
            StoryboardTimingV1.versionPath(revision), StoryboardIdentityV1.versionPath(revision)]
        return try paths.map { path in
            guard let reference = snapshot.references.first(where: { $0.path == path }) else {
                throw FilmFlowFailure.message("The accepted Storyboard revision has no immutable archive.")
            }
            return reference
        }
    }

    struct PreparedScript: Sendable {
        fileprivate let mapping: FilmFlowAdoption
        fileprivate let projectID: String
        fileprivate let root: URL
        fileprivate let fence: PipelineSpatialSceneAuthority.SourceFence

        func file(outputs: [CanonicalArtifactReferenceV1], dataRoot: URL) throws -> (path: String, bytes: Data) {
            guard dataRoot.standardizedFileURL == root.standardizedFileURL else {
                throw FilmFlowFailure.message("The target project changed while the imported action was being checked.")
            }
            try fence.requireCanonicalRootsUnchanged()
            return try mapping.receiptFile(phase: "script", outputs: outputs, projectID: projectID)
        }
    }

    func prepareScript(dataRoot: URL) throws -> (PreparedScript, FilmFlowMaterial.Item) {
        let directory = dataRoot.appendingPathComponent(FilmFlowSnapshotStore.path(snapshotID))
        let snapshot = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: snapshotSHA256)
        let paths = ["snapshot.v1.json"] + snapshot.responses.flatMap { [$0.portablePath, "schemas/" + $0.tool + ".json"] }
            + snapshot.images.map(\.path)
        let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: dataRoot,
            additionalCanonicalPaths: paths.map { FilmFlowSnapshotStore.path(snapshotID) + "/" + $0 })
        _ = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: snapshotSHA256)
        let material = try FilmFlowMaterial.load(directory: directory, snapshot: snapshot)
        guard let item = material.items.first(where: { $0.id == sourceObjectID }), !targetID.isEmpty,
              fields == ["action"] else { throw FilmFlowFailure.message("Choose the retained source object and current Script event.") }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        try fence.requireUnchanged()
        return (PreparedScript(mapping: self, projectID: project.project, root: dataRoot, fence: fence), item)
    }

    func file(phase: String, outputs: [CanonicalArtifactReferenceV1], dataRoot: URL) throws -> (path: String, bytes: Data) {
        let directory = dataRoot.appendingPathComponent(FilmFlowSnapshotStore.path(snapshotID))
        let snapshot = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: snapshotSHA256)
        let material = try FilmFlowMaterial.load(directory: directory, snapshot: snapshot)
        guard sourceObjectID == "planning-notes" || material.items.contains(where: { $0.id == sourceObjectID }),
              !targetID.isEmpty, !fields.isEmpty, Set(fields).count == fields.count else {
            throw FilmFlowFailure.message("Choose a source object and current target before adopting FilmFlow material.")
        }
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        return try receiptFile(phase: phase, outputs: outputs, projectID: project.project)
    }

    private func receiptFile(phase: String, outputs: [CanonicalArtifactReferenceV1], projectID: String) throws -> (path: String, bytes: Data) {
        let id = UUID()
        let receipt = Receipt(schema: "ngv.filmflow-adoption.v1", id: id, projectID: projectID,
                              phase: phase, mapping: self, outputs: outputs, adoptedAt: Date())
        return ("import/filmflow-adoptions/\(snapshotID.uuidString.lowercased())/\(id.uuidString.lowercased()).json",
                try FilmFlowSnapshot.encode(receipt))
    }

    func record(phase: String, outputs: [CanonicalArtifactReferenceV1], dataRoot: URL) throws {
        for output in outputs { _ = try ProjectLocalFile.requireHash(output.sha256, at: output.path, dataRoot: dataRoot) }
        let value = try file(phase: phase, outputs: outputs, dataRoot: dataRoot)
        _ = try ProjectLocalFile.ensureDirectory((value.path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
        try value.bytes.write(to: dataRoot.appendingPathComponent(value.path), options: .atomic)
    }
}

enum FilmFlowSnapshotStore {
    struct Retained: Sendable, Identifiable {
        let snapshot: FilmFlowSnapshot
        let sha256: String
        let directory: URL
        var id: UUID { snapshot.id }
    }
    struct Acceptance: Codable, Sendable {
        let snapshotSHA256: String
        let omittedImagePointers: [String]
        let acceptedAt: Date
    }
    static func path(_ id: UUID) -> String { "import/filmflow/" + id.uuidString.lowercased() }

    @MainActor
    static func accept(_ prepared: FilmFlowSnapshot.Prepared, omittedImages: Set<String>,
                       editor: EditorViewModel) async throws -> Retained {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Import FilmFlow snapshot")
        defer { access.end(editor: editor) }
        let task = Task.detached(priority: .userInitiated) {
            try requireWorkflow(access: access)
            let snapshot = try FilmFlowSnapshot.verify(directory: prepared.directory, expectedSHA256: prepared.manifestSHA256)
            guard omittedImages == Set(snapshot.missingImages.map(\.pointer)) else {
                throw FilmFlowFailure.message("Explicitly omit each unavailable image before accepting this snapshot.")
            }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root)
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let destination = staging.appendingPathComponent(path(snapshot.id))
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw FilmFlowFailure.message("This snapshot is already retained. Open its existing copy.")
                }
                _ = try ProjectLocalFile.ensureDirectory("import/filmflow", dataRoot: staging)
                try FileManager.default.copyItem(at: prepared.directory, to: destination)
                _ = try FilmFlowSnapshot.verify(directory: destination, expectedSHA256: prepared.manifestSHA256)
                let accepted = Acceptance(snapshotSHA256: prepared.manifestSHA256,
                    omittedImagePointers: omittedImages.sorted(), acceptedAt: Date())
                let receiptPath = "import/filmflow-adoptions/\(snapshot.id.uuidString.lowercased())/accepted.json"
                _ = try ProjectLocalFile.ensureDirectory((receiptPath as NSString).deletingLastPathComponent, dataRoot: staging)
                try FilmFlowSnapshot.encode(accepted).write(to: staging.appendingPathComponent(receiptPath), options: .atomic)
                return snapshot
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let snapshot = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            try result.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        editor.onPipelineChanged?()
        return Retained(snapshot: snapshot, sha256: prepared.manifestSHA256, directory: access.root.appendingPathComponent(path(snapshot.id)))
    }

    static func list(dataRoot: URL) throws -> [Retained] {
        let base = dataRoot.appendingPathComponent("import/filmflow")
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let root = try ProjectLocalFile.resolve("import/filmflow", dataRoot: dataRoot)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent), directory.lastPathComponent == id.uuidString.lowercased() else {
                    throw FilmFlowFailure.message("The FilmFlow snapshot directory contains an invalid entry.")
                }
                let receipt = try FilmFlowSnapshot.decode(Acceptance.self, from: Data(contentsOf: ProjectLocalFile.resolve(
                    "import/filmflow-adoptions/\(id.uuidString.lowercased())/accepted.json", dataRoot: dataRoot)))
                let value = try FilmFlowSnapshot.verify(directory: directory, expectedSHA256: receipt.snapshotSHA256)
                guard value.id == id, receipt.omittedImagePointers == value.missingImages.map(\.pointer).sorted() else {
                    throw FilmFlowFailure.message("The FilmFlow snapshot acceptance changed.")
                }
                return Retained(snapshot: value, sha256: receipt.snapshotSHA256, directory: directory)
            }
    }

    private static func requireWorkflow(access: PipelineNativeEditAccess) throws {
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: access.root,
            expectedPack: access.declaration.binding, expectedProductionContract: access.declaration.productionContract), workflow.isProductionV2 else {
            throw GateBlocked("Choose a production workflow before importing FilmFlow material.")
        }
        let state = try ProjectStateBuilder.buildSnapshot(dataRoot: access.root, order: PhaseContractRuntime.order(workflow: workflow))
        if workflow.packID == "musicvideo" {
            guard state.nextPhase.map({ !["project_init", "analysis"].contains($0) }) ?? state.phases.allSatisfy(\.approved) else {
                throw GateBlocked("Approve Audio Analysis before importing story material.")
            }
        }
    }
}

struct FilmFlowMaterial: Sendable {
    struct Item: Sendable, Identifiable {
        enum Kind: String, Sendable { case project, scene, shot, entity }
        let id: String
        let kind: Kind
        let title: String
        let notes: String
        let image: FilmFlowSnapshot.Image?
        let shot: FilmFlowShotlist.Shot?
        let entity: FilmFlowEntity?
    }
    let project: FilmFlowProject
    let items: [Item]

    static func load(directory: URL, snapshot: FilmFlowSnapshot) throws -> Self {
        let project: FilmFlowProject = try FilmFlowSnapshot.read("get_project", in: directory)
        var items: [Item] = [.init(id: "get_project#", kind: .project, title: "Project style · " + project.title,
            notes: [project.styleBible, "Aspect ratio: " + project.aspectRatio, "Sketch style: " + project.sketchStyle].compactMap { $0 }.joined(separator: "\n"),
            image: nil, shot: nil, entity: nil)]
        func image(_ pointer: String) -> FilmFlowSnapshot.Image? { snapshot.images.first { $0.pointers.contains(pointer) } }
        if !snapshot.noActiveScript {
            let scenes: [FilmFlowScene] = try FilmFlowSnapshot.read("list_scenes", in: directory)
            for (index, scene) in scenes.enumerated() {
                items.append(.init(id: "list_scenes#/\(index)", kind: .scene, title: scene.heading,
                    notes: [scene.shortTitle, scene.intExt, scene.timeOfDay].compactMap { $0 }.joined(separator: "\n"),
                    image: nil, shot: nil, entity: nil))
            }
            let shots: FilmFlowShotlist = try FilmFlowSnapshot.read("get_shotlist", in: directory)
            for (sceneIndex, scene) in shots.scenes.enumerated() {
                for (shotIndex, shot) in scene.shots.enumerated() {
                    let id = "get_shotlist#/scenes/\(sceneIndex)/shots/\(shotIndex)"
                    let notes = [shot.description, shot.staging.intent, shot.staging.notes, shot.camera.move,
                        shot.camera.moveNotes, shot.camera.framingNotes, shot.camera.moveIntensity,
                        shot.camera.lensMm.map { "Lens: \($0) mm" }, shot.camera.height, shot.camera.angle, shot.camera.support,
                        shot.lighting.mood, shot.lighting.complexity, shot.lighting.notes,
                        "Characters: " + shot.charactersInFrame.joined(separator: ", "),
                        shot.targetEntity.map { "Target: " + $0.type + " · " + $0.name },
                        shot.variant, "Shot type: " + shot.shotType, shot.durationSeconds.map { "Duration: \($0) seconds" }].compactMap { $0 }
                    items.append(.init(id: id, kind: .shot, title: scene.heading + " · " + shot.shotLabel,
                        notes: notes.joined(separator: "\n"), image: image(id + "/storyboardImageUrl"), shot: shot, entity: nil))
                }
            }
        }
        let entities: [FilmFlowEntity] = try FilmFlowSnapshot.read("list_entities", in: directory)
        for (index, entity) in entities.enumerated() {
            let id = "list_entities#/\(index)"
            items.append(.init(id: id, kind: .entity, title: entity.type + " · " + entity.name,
                notes: [entity.visualDescription, entity.notes].compactMap { $0 }.joined(separator: "\n"),
                image: image(id + "/referenceImageUrl"), shot: nil, entity: entity))
        }
        return .init(project: project, items: items)
    }

    func planningNotes(selected: Set<String>) throws -> String {
        guard !selected.isEmpty, selected.isSubset(of: Set(items.map(\.id))) else {
            throw FilmFlowFailure.message("Select the source objects to include in planning notes.")
        }
        return (["# FilmFlow planning notes", "Project: " + project.title,
                 "Imported descriptions and planning references; this is not the original screenplay."]
            + items.filter { selected.contains($0.id) }.map { "## " + $0.title + "\n" + $0.notes }).joined(separator: "\n\n")
    }
}
