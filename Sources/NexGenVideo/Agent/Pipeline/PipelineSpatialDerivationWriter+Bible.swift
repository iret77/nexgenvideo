import AppKit
import Foundation
import NexGenEngine

extension PipelineSpatialDerivationWriter {
    struct PreparedBibleView: Sendable {
        let locationID: String
        let viewID: String
        let purpose: String
        let imageData: Data
        fileprivate let candidate: SpatialClayCandidate
        fileprivate let originalBible: Bible
        fileprivate let originalBytes: Data
        fileprivate let contextFingerprint: String
        fileprivate let scene: SpatialSceneRevision
        fileprivate let home: URL
        fileprivate let documentKey: String
        fileprivate let generation: UUID

        fileprivate init(locationID: String, viewID: String, purpose: String, imageData: Data,
                         candidate: SpatialClayCandidate, originalBible: Bible, originalBytes: Data,
                         contextFingerprint: String, scene: SpatialSceneRevision, home: URL, documentKey: String, generation: UUID) {
            self.locationID = locationID; self.viewID = viewID; self.purpose = purpose; self.imageData = imageData
            self.candidate = candidate; self.originalBible = originalBible; self.originalBytes = originalBytes
            self.contextFingerprint = contextFingerprint; self.scene = scene; self.home = home; self.documentKey = documentKey
            self.generation = generation
        }
    }

    private struct BibleBinding: Codable, Sendable, Equatable {
        let locationID: String
        let locationIdentitySHA256: String
        let viewID: String
        let purpose: String
    }

    private struct BibleAdoption: Codable, Sendable {
        var schema = "spatial-bible-view-adoption/v1"
        let id: UUID
        let projectID: String
        let binding: BibleBinding
        let sourceBible: CanonicalArtifactReferenceV1
        let image: CanonicalArtifactReferenceV1
        let proof: CanonicalArtifactReferenceV1
        let scene: CanonicalArtifactReferenceV1
        let sceneManifest: CanonicalArtifactReferenceV1
    }

    @MainActor
    static func prepareBibleView(locationID: String, viewID: String, purpose: String, scene: SpatialSceneHead,
                                 cameraID: String, expectedBibleSHA256: String, editor: EditorViewModel) async throws -> PreparedBibleView {
        guard let home = editor.workingRoot, let key = editor.openWorkingCopyKey, let generation = editor.openWorkingCopyGeneration,
              let root = DataRootResolver.dataRoot(of: home), !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                .first(where: { $0.editorViewModel === editor }),
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Render Bible location view") else {
            throw GateBlocked("Finish the current production action before rendering this location view.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let operation = try BpyRuntimeHost.shared.acquireOperation(document: document, documentID: key)
        defer { BpyRuntimeHost.shared.releaseOperation(operation) }
        let runtime = operation.session
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let input = try await background {
            _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "bible")
            guard viewID.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GateBlocked("Enter a view identifier and describe what the location view must show.")
            }
            let before = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
            let bible = try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile)
            let revision = try currentScene(scene, dataRoot: root)
            guard FileDigest.sha256(of: before) == expectedBibleSHA256,
                  let location = bible.locations.first(where: { $0.id == locationID }),
                  let camera = revision.snapshot.cameras.first(where: { $0.id == cameraID }) else { throw bibleViewChanged() }
            let binding = BibleBinding(locationID: locationID, locationIdentitySHA256: try locationIdentityFingerprint(location),
                viewID: viewID, purpose: purpose.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            let dimensions = try SpatialClayRenderer.renderDimensions(width: camera.width, height: camera.height)
            let request = SpatialClayRequest(owner: .bible, ownerArtifactSHA256: expectedBibleSHA256,
                ownerBindingSHA256: FileDigest.sha256(of: try PlanningWriterIO.json(binding)), cameraID: cameraID,
                startFrame: revision.snapshot.restFrame, endFrame: revision.snapshot.restFrame,
                width: dimensions.width, height: dimensions.height, samples: 32, stateSHA256: nil)
            return (before, bible, revision, request, binding, try bibleContextFingerprint(dataRoot: root))
        }
        try Task.checkCancellation()
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation,
              BpyRuntimeHost.shared.isOperationActive(operation) else { throw bibleViewChanged() }
        let candidate = try await SpatialClayRenderer.prepare(request: input.3, revision: input.2, runtime: runtime,
            runtimeRoot: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BpyRuntime"))
        let prepared = try await background {
            try runtime.authenticateSpatialDerivation(candidate, source: input.2)
            try SpatialClayRenderer.validate(candidate, against: input.2)
            guard input.5 == (try bibleContextFingerprint(dataRoot: root)),
                  candidate.proof.outputs.count == 1, let output = candidate.proof.outputs.first,
                  output.mediaKind == "image/png", let image = candidate.files[output.filename] else { throw bibleViewChanged() }
            return PreparedBibleView(locationID: locationID, viewID: viewID, purpose: input.4.purpose, imageData: image,
                candidate: candidate, originalBible: input.1, originalBytes: input.0, contextFingerprint: input.5,
                scene: input.2, home: home, documentKey: key, generation: generation)
        }
        try Task.checkCancellation()
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation,
              BpyRuntimeHost.shared.isOperationActive(operation) else { throw bibleViewChanged() }
        return prepared
    }

    @MainActor
    static func confirmBibleView(_ prepared: PreparedBibleView, editor: EditorViewModel) async throws {
        guard let home = editor.workingRoot, home == prepared.home, let key = editor.openWorkingCopyKey,
              key == prepared.documentKey, editor.openWorkingCopyGeneration == prepared.generation,
              let root = DataRootResolver.dataRoot(of: home),
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "Assign Bible location view") else { throw bibleViewChanged() }
        var holdsLease = true
        defer { if holdsLease { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) } }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let publication = try await background {
            _ = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "bible")
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root,
                additionalCanonicalPaths: [PipelineLayout.bibleFile, PipelineLayout.bibleIdentityVariantsFile]
                    + (try sceneReferences(dataRoot: root)).map(\.path))
            guard try bibleContextFingerprint(dataRoot: root) == prepared.contextFingerprint else { throw bibleViewChanged() }
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                let access = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: declaration, phase: "bible")
                try publishBibleView(prepared, access: access)
                let after = try YAMLArtifactStore(dataRoot: staging).load(Bible.self, at: PipelineLayout.bibleFile)
                let hash = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: staging))
                return (after, hash)
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let after: (Bible, String)
        do {
            try Task.checkCancellation()
            after = try publication.0.commit { _ in
                guard editor.workingRoot == home, editor.openWorkingCopyKey == key,
                      editor.openWorkingCopyGeneration == prepared.generation,
                      editor.declaredPluginName == declaration.packName, editor.declaredPluginBinding == declaration.binding,
                      editor.declaredProductionContract == declaration.productionContract,
                      !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
                      editor.pipelinePhaseRunCoordinator.holdsMutation(projectRoot: root, id: lease) else { throw bibleViewChanged() }
                try publication.1.requireCanonicalRootsUnchanged()
                try ProjectWorkingCopy.markDirty(key: key)
            }
        } catch {
            await Task.detached(priority: .utility) { publication.0.discard() }.value
            throw error
        }
        await Task.detached(priority: .utility) { publication.0.discard() }.value
        editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease)
        holdsLease = false
        var undoFailure: String?
        do {
            try await PipelineBibleEditor.recordNativeAssignment(before: prepared.originalBible,
                beforeSHA256: FileDigest.sha256(of: prepared.originalBytes), after: after.0, afterSHA256: after.1,
                editor: editor, name: "Assign Bible View")
        } catch { undoFailure = error.localizedDescription }
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        if let undoFailure {
            editor.mediaPanelToast = MediaPanelToast(message: "Bible view assigned. Undo is unavailable: \(undoFailure)")
        }
    }

    private static func publishBibleView(_ prepared: PreparedBibleView, access: PipelinePlanningWriteAccess) throws {
        let root = access.dataRoot, candidate = prepared.candidate
        guard try bibleContextFingerprint(dataRoot: root) == prepared.contextFingerprint,
              let index = prepared.originalBible.locations.firstIndex(where: { $0.id == prepared.locationID }),
              let output = candidate.proof.outputs.first, candidate.proof.outputs.count == 1 else { throw bibleViewChanged() }
        let scene = try currentScene(candidate.proof.scene, dataRoot: root)
        try SpatialClayRenderer.validate(candidate, against: scene)
        let path = try ProductionWorkflowRecoveryMigration.outputPath(area: "bible",
            leaf: "spatial-\(candidate.proof.id.uuidString.lowercased())/derivation.v1.json", dataRoot: root)
        let directory = (path as NSString).deletingLastPathComponent
        let proof = PlanningWriterIO.reference(path, id: "bible-spatial-proof.\(candidate.proof.id)", role: "core.spatial-derivation", bytes: candidate.proofData)
        let image = CanonicalArtifactReferenceV1(id: "bible-spatial-view.\(candidate.proof.id)", role: "core.bible-spatial-view",
            path: directory + "/" + output.filename, sha256: output.sha256)
        let source = PlanningWriterIO.reference(directory + "/source-bible.yaml", id: "bible-spatial-source.\(candidate.proof.id)",
            role: "core.bible", bytes: prepared.originalBytes)
        let binding = BibleBinding(locationID: prepared.locationID,
            locationIdentitySHA256: try locationIdentityFingerprint(prepared.originalBible.locations[index]), viewID: prepared.viewID, purpose: prepared.purpose)
        let record = BibleAdoption(id: candidate.proof.id, projectID: prepared.originalBible.project, binding: binding,
            sourceBible: source, image: image, proof: proof,
            scene: .init(id: "bible-spatial-scene.\(scene.manifest.sceneID)", role: "core.production-spatial",
                path: scenePath(scene), sha256: scene.manifest.sceneSHA256), sceneManifest: manifestReference(scene))
        var bible = prepared.originalBible
        bible.locations[index].sheets[prepared.viewID] = image.path
        bible.locations[index].viewPurpose[prepared.viewID] = prepared.purpose
        let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: root)
            ?? BibleIdentityVariantsV1(project: bible.project, revision: 1, variants: [])
        let files: [(path: String, bytes: Data)] = [(image.path, prepared.imageData), (proof.path, candidate.proofData),
            (source.path, prepared.originalBytes), (adoptionPath(candidate.proof.id), try PlanningWriterIO.json(record))]
        for file in files {
            if file.path.hasPrefix("bible/") { try ProductionWorkflowRecoveryMigration.requireNewOutput(file.path, dataRoot: root) }
            else { try requireNewMetadata(file.path, dataRoot: root) }
        }
        try access.publish(files) {
            try PipelineBibleWriter.write(bible, variants: variants, dataRoot: root)
        }
    }

    static func bibleViewReferences(location: Location, viewID: String, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1]? {
        guard let path = location.sheets[viewID] else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "bible", parts[2].hasPrefix("spatial-") else { return nil }
        guard parts.count == 4, UUID(uuidString: String(parts[1])) != nil,
              let id = UUID(uuidString: String(parts[2].dropFirst("spatial-".count))) else { throw bibleViewChanged() }
        let directory = (path as NSString).deletingLastPathComponent
        let recordPath = adoptionPath(id)
        let record = try PlanningWriterIO.read(BibleAdoption.self, at: recordPath, dataRoot: dataRoot)
        let proofData = try bytes(record.proof, dataRoot: dataRoot)
        let proof = try JSONDecoder().decode(SpatialDerivationProof.self, from: proofData)
        let source = try YAMLArtifactStore(dataRoot: dataRoot).load(Bible.self, at: record.sourceBible.path)
        _ = try bytes(record.sourceBible, dataRoot: dataRoot)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        let scene = try currentScene(proof.scene, dataRoot: dataRoot)
        guard record.schema == "spatial-bible-view-adoption/v1", record.id == id, proof.id == id,
              record.projectID == project.project, source.project == project.project,
              let original = source.locations.first(where: { $0.id == location.id }),
              try locationIdentityFingerprint(original) == locationIdentityFingerprint(location),
              record.binding == BibleBinding(locationID: location.id, locationIdentitySHA256: try locationIdentityFingerprint(location),
                viewID: viewID, purpose: location.viewPurpose[viewID] ?? ""),
              record.image.path == path, record.image.role == "core.bible-spatial-view",
              record.proof.path == directory + "/derivation.v1.json", record.proof.role == "core.spatial-derivation",
              record.sourceBible.path == directory + "/source-bible.yaml",
              record.scene.path == scenePath(scene), record.scene.sha256 == scene.manifest.sceneSHA256,
              record.sceneManifest == manifestReference(scene), proof.request.owner == .bible,
              proof.request.ownerArtifactSHA256 == record.sourceBible.sha256,
              proof.request.ownerBindingSHA256 == FileDigest.sha256(of: try PlanningWriterIO.json(record.binding)),
              proof.outputs.count == 1, let output = proof.outputs.first,
              path == directory + "/" + output.filename, record.image.sha256 == output.sha256 else { throw bibleViewChanged() }
        let imageData = try bytes(record.image, dataRoot: dataRoot)
        try SpatialClayRenderer.validate(.init(proof: proof, proofData: proofData, files: [output.filename: imageData]), against: scene)
        return [record.image, record.proof, record.sourceBible, record.scene, record.sceneManifest,
            try PlanningWriterIO.reference(recordPath, id: "bible-spatial-adoption.\(id)", role: "core.spatial-adoption", dataRoot: dataRoot)]
            + (try sceneReferences(dataRoot: dataRoot))
    }

    static func bibleGeometryReferences(location: Location, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        try location.sheets.keys.sorted().flatMap { key in
            try (bibleViewReferences(location: location, viewID: key, dataRoot: dataRoot) ?? [])
                .filter { $0.path.hasSuffix("/scene.blend") && $0.id.hasPrefix("bible-spatial-scene.") }
        }
    }

    private static func locationIdentityFingerprint(_ location: Location) throws -> String {
        var identity = location
        identity.sheets = [:]; identity.viewPurpose = [:]
        return FileDigest.sha256(of: try PlanningWriterIO.json(identity))
    }

    private static func bibleContextFingerprint(dataRoot: URL) throws -> String {
        var paths = [PipelineLayout.bibleFile, PipelineLayout.projectFile, PipelineLayout.gatesFile]
        paths += [PipelineLayout.bibleIdentityVariantsFile, PipelineLayout.lineageFile, PipelineLayout.assetProofFile(scope: "bible")]
            .filter { FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path) }
        let references = try paths.map { try PlanningWriterIO.reference($0, id: $0, role: "core.bible-context", dataRoot: dataRoot) }
            + sceneReferences(dataRoot: dataRoot)
        return FileDigest.sha256(of: try PlanningWriterIO.json(references))
    }

    private static func bibleViewChanged() -> GateBlocked {
        GateBlocked("The Bible, location or camera changed. Reload Bible and locations, then render this view again.")
    }
}
