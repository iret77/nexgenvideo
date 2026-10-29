import Foundation
import NexGenEngine

enum PipelinePanoramaStore {
    static let receiptPathKey = "core.native-panorama-receipt"
    static let receiptHashKey = "core.native-panorama-receipt-sha256"
    struct View: Codable, Sendable, Equatable {
        let geometry: Scene3D.PovRecord
        let image: CanonicalArtifactReferenceV1
    }
    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let id: String
        let projectID: String
        let workflowID: String
        let locationID: String
        let originalName: String
        let panorama: CanonicalArtifactReferenceV1
        let views: [View]
        let recordedAt: String
    }
    struct Prepared: Sendable {
        let home: URL
        let key: String
        let generation: UUID
        let declaration: ProjectPackGate.MutationDeclaration
        let before: Bible
        let beforeSHA256: String
        let sourceURL: URL
        let id: String
        let workflowID: String
        let locationID: String
        let panorama: CanonicalArtifactReferenceV1
        let views: [View]
        let files: [(path: String, bytes: Data)]
    }

    static func hasNativeSelection(_ location: Location) -> Bool {
        ((location.scene3d.panorama as NSString).deletingLastPathComponent as NSString).lastPathComponent.hasPrefix("native-panorama-")
            || location.attributes[receiptPathKey] != nil || location.attributes[receiptHashKey] != nil
    }

    static func references(location: Location, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        do { return try validatedReferences(location: location, dataRoot: dataRoot) }
        catch {
            if error is CancellationError { throw error }
            guard hasNativeSelection(location) else { throw error }
            throw GateBlocked("The panorama assignment for “\(location.name)” is missing or changed (\(location.attributes[receiptPathKey] ?? location.scene3d.panorama)). Open Panorama to remove the invalid assignment, or restore its original files.")
        }
    }

    private static func validatedReferences(location: Location, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        let directory = (location.scene3d.panorama as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        guard name.hasPrefix("native-panorama-") else {
            guard location.attributes[receiptPathKey] == nil, location.attributes[receiptHashKey] == nil else { throw changed() }
            return []
        }
        let id = String(name.dropFirst("native-panorama-".count))
        guard UUID(uuidString: id) != nil else { throw changed() }
        let path = "bible/native-panorama-selections/" + id + ".v1.json"
        let reference = try PlanningWriterIO.reference(path, id: id, role: "host.panorama-selection", dataRoot: dataRoot)
        guard location.attributes[receiptPathKey] == path, location.attributes[receiptHashKey] == reference.sha256 else { throw changed() }
        let receipt = try PlanningWriterIO.read(Receipt.self, at: path, dataRoot: dataRoot)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard receipt.schema == "native-panorama-selection/v1", receipt.id == id,
              receipt.projectID == project.project, receipt.locationID == location.id,
              receipt.workflowID == (try PipelineNativeBlockoutStore.workflowID(dataRoot: dataRoot)),
              !receipt.originalName.isEmpty, !receipt.recordedAt.isEmpty,
              receipt.panorama.path == location.scene3d.panorama,
              receipt.views.map(\.geometry) == location.scene3d.povs,
              location.scene3d.provider == "native-import", !receipt.views.isEmpty,
              Set(receipt.views.map { $0.geometry.name }).count == receipt.views.count,
              receipt.views.allSatisfy({ $0.image.path == directory + "/" + $0.geometry.name + ".png" }) else { throw changed() }
        try validate(specs: receipt.views.map { $0.geometry.spec })
        let references = [reference, receipt.panorama] + receipt.views.map(\.image)
        for ref in references { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        return references
    }

    static func current(location: Location, dataRoot: URL) throws -> Receipt? {
        guard let reference = try references(location: location, dataRoot: dataRoot).first else { return nil }
        return try PlanningWriterIO.read(Receipt.self, at: reference.path, dataRoot: dataRoot)
    }

    static func requireAgentPreservesNativeSelection(_ candidate: Bible, dataRoot: URL) throws {
        let beforeLocations = try loadBible(dataRoot: dataRoot)?.locations ?? []
        for location in beforeLocations {
            guard !(try references(location: location, dataRoot: dataRoot)).isEmpty else { continue }
            guard let selected = candidate.locations.first(where: { $0.id == location.id }),
                  selected.scene3d == location.scene3d,
                  selected.attributes[receiptPathKey] == location.attributes[receiptPathKey],
                  selected.attributes[receiptHashKey] == location.attributes[receiptHashKey] else {
                throw GateBlocked("Preserve this location's native panorama selection. Only the native panorama controls may replace or remove it.")
            }
        }
        for location in candidate.locations {
            if hasNativeSelection(location) {
                guard let original = beforeLocations.first(where: { $0.id == location.id }),
                      original.scene3d == location.scene3d,
                      original.attributes[receiptPathKey] == location.attributes[receiptPathKey],
                      original.attributes[receiptHashKey] == location.attributes[receiptHashKey] else { throw fabrication() }
            }
            if !(try references(location: location, dataRoot: dataRoot)).isEmpty {
                guard beforeLocations.first(where: { $0.id == location.id })?.scene3d == location.scene3d,
                      beforeLocations.first(where: { $0.id == location.id })?.attributes[receiptHashKey] == location.attributes[receiptHashKey] else { throw fabrication() }
            } else if location.attributes[receiptPathKey] != nil || location.attributes[receiptHashKey] != nil { throw fabrication() }
        }
    }

    static func requirePurpose(sha256: String, geometry: Bool, dataRoot: URL) throws {
        guard !geometry else { return }
        let receipts = dataRoot.appendingPathComponent("bible/native-panorama-selections")
        if FileManager.default.fileExists(atPath: receipts.path) {
            let directory = try PipelineNativeBlockoutStore.metadataDirectory("bible/native-panorama-selections", dataRoot: dataRoot)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".v1.json") {
                try Task.checkCancellation()
                let receipt: Receipt?
                do { receipt = try PlanningWriterIO.read(Receipt.self, at: "bible/native-panorama-selections/" + name, dataRoot: dataRoot) }
                catch is CancellationError { throw CancellationError() }
                catch { receipt = nil }
                if let receipt, receipt.panorama.sha256 == sha256 || receipt.views.contains(where: { $0.image.sha256 == sha256 }) {
                    throw GateBlocked("A panorama geometry anchor cannot supply appearance, style or identity. Create a separate approved appearance sheet from this view.")
                }
            }
        }
        // Damaged removable receipts must not erase the geometry-only restriction on their retained output bytes.
        let bible = dataRoot.appendingPathComponent("bible")
        guard FileManager.default.fileExists(atPath: bible.path) else { return }
        let root = try PipelineNativeBlockoutStore.metadataDirectory("bible", dataRoot: dataRoot)
        for namespace in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            try Task.checkCancellation()
            let values = try namespace.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for directory in try FileManager.default.contentsOfDirectory(at: namespace, includingPropertiesForKeys: [.isDirectoryKey]) {
                let name = directory.lastPathComponent
                guard name.hasPrefix("native-panorama-"), UUID(uuidString: String(name.dropFirst("native-panorama-".count))) != nil else { continue }
                let path = "bible/" + namespace.lastPathComponent + "/" + name
                let protected = try PipelineNativeBlockoutStore.metadataDirectory(path, dataRoot: dataRoot)
                for file in try FileManager.default.contentsOfDirectory(atPath: protected.path) {
                    try Task.checkCancellation()
                    let url = try ProjectLocalFile.resolve(path + "/" + file, dataRoot: dataRoot)
                    if try FileDigest.sha256(of: url) == sha256 {
                        throw GateBlocked("A panorama geometry anchor cannot supply appearance, style or identity. Create a separate approved appearance sheet from this view.")
                    }
                }
            }
        }
    }

    @MainActor
    static func prepare(source: URL, locationID: String, specs: [PovSpec], editor: EditorViewModel) async throws -> Prepared {
        guard let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let key = editor.openWorkingCopyKey, let generation = editor.openWorkingCopyGeneration else { throw changed() }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let preparation = Task.detached(priority: .userInitiated) {
            try validate(specs: specs)
            let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "bible")
            guard let before = try loadBible(dataRoot: root), before.locations.contains(where: { $0.id == locationID }) else { throw changed() }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw changed() }
            let beforeSHA = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
            let bytes = try Data(contentsOf: source)
            let hash = FileDigest.sha256(of: bytes)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-panorama-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let original = scratch.appendingPathComponent("panorama")
            try bytes.write(to: original)
            let images = try PovExtractor.extractSet(panorama: original, to: scratch.appendingPathComponent("povs"), povs: specs)
            let id = UUID().uuidString.lowercased()
            let directory = (try ProductionWorkflowRecoveryMigration.outputPath(area: "bible", leaf: "native-panorama-" + id + "/source.panorama", dataRoot: root) as NSString).deletingLastPathComponent
            let panorama = PlanningWriterIO.reference(directory + "/source.panorama", id: "panorama-" + id,
                role: "core.panorama-geometry", bytes: bytes)
            var files = [(path: panorama.path, bytes: bytes)]
            var views: [View] = []
            for spec in specs {
                try Task.checkCancellation()
                guard let image = images[spec.name] else { throw changed() }
                let bytes = try Data(contentsOf: image)
                let ref = PlanningWriterIO.reference(directory + "/" + spec.name + ".png", id: "panorama-" + id + "-" + spec.name,
                    role: "core.panorama-pov-geometry", bytes: bytes)
                views.append(.init(geometry: .init(spec), image: ref)); files.append((ref.path, bytes))
            }
            guard try FileDigest.sha256(of: source) == hash,
                  try loadBible(dataRoot: root) == before,
                  try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root)) == beforeSHA else { throw changed() }
            return Prepared(home: home, key: key, generation: generation, declaration: declaration, before: before,
                beforeSHA256: beforeSHA, sourceURL: source, id: id, workflowID: access.workflow.contractID,
                locationID: locationID, panorama: panorama, views: views, files: files)
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        guard editor.workingRoot == home, editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation else { throw changed() }
        return result
    }

    @MainActor
    static func confirm(_ prepared: Prepared, editor: EditorViewModel) async throws {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Assign panorama views")
        var holdsLease = true
        defer { if holdsLease { access.end(editor: editor) } }
        guard access.home == prepared.home, access.key == prepared.key, access.declaration == prepared.declaration,
              editor.openWorkingCopyGeneration == prepared.generation else { throw changed() }
        let operation = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "bible")
            guard try loadBible(dataRoot: access.root) == prepared.before,
                  try FileDigest.sha256(of: prepared.sourceURL) == prepared.panorama.sha256,
                  try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: access.root)) == prepared.beforeSHA256 else { throw changed() }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: PipelineBibleWriter.referencePaths(prepared.before) + [PipelineLayout.bibleFile, PipelineLayout.bibleIdentityVariantsFile])
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "bible")
                guard let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: staging),
                      try loadBible(dataRoot: staging) == prepared.before else { throw changed() }
                var after = prepared.before
                guard let index = after.locations.firstIndex(where: { $0.id == prepared.locationID }) else { throw changed() }
                after.locations[index].scene3d = .init(panorama: prepared.panorama.path,
                    povs: prepared.views.map(\.geometry), provider: "native-import")
                let receipt = Receipt(schema: "native-panorama-selection/v1", id: prepared.id,
                    projectID: after.project, workflowID: prepared.workflowID, locationID: prepared.locationID,
                    originalName: prepared.sourceURL.lastPathComponent, panorama: prepared.panorama,
                    views: prepared.views, recordedAt: ISO8601DateFormatter().string(from: Date()))
                let receiptPath = "bible/native-panorama-selections/" + prepared.id + ".v1.json"
                let receiptBytes = try PlanningWriterIO.json(receipt)
                after.locations[index].attributes[receiptPathKey] = receiptPath
                after.locations[index].attributes[receiptHashKey] = FileDigest.sha256(of: receiptBytes)
                let files = prepared.files + [(path: receiptPath, bytes: receiptBytes)]
                for file in files {
                    guard !FileManager.default.fileExists(atPath: staging.appendingPathComponent(file.path).path) else { throw changed() }
                    if !file.path.hasPrefix("bible/native-panorama-selections/") { try ProductionWorkflowRecoveryMigration.requireNewOutput(file.path, dataRoot: staging) }
                    _ = try ProjectLocalFile.ensureDirectory((file.path as NSString).deletingLastPathComponent, dataRoot: staging)
                    try file.bytes.write(to: staging.appendingPathComponent(file.path), options: .atomic)
                }
                try PipelineBibleWriter.write(after, variants: variants, dataRoot: staging)
                _ = try references(location: after.locations[index], dataRoot: staging)
                try PipelinePhaseMutationRecorder.record(phase: "bible", dataRoot: staging, captureLineage: true,
                    declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                    declaredProductionContract: access.declaration.productionContract)
                try writer.revalidate()
                return (after, try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: staging)))
            }
            do { try fence.requireUnchanged(); return (transaction, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let after = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            guard editor.openWorkingCopyGeneration == prepared.generation else { throw changed() }
            try result.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor); holdsLease = false
        await finishAssignment(before: prepared.before, beforeSHA256: prepared.beforeSHA256,
            after: after.0, afterSHA256: after.1, editor: editor, name: "Assign Panorama Views")
    }

    static func invalidSelections(in bible: Bible, dataRoot: URL) throws -> [Location] {
        var invalid: [Location] = []
        for location in bible.locations where hasNativeSelection(location) {
            try Task.checkCancellation()
            do { _ = try references(location: location, dataRoot: dataRoot) }
            catch is CancellationError { throw CancellationError() }
            catch { invalid.append(location) }
        }
        return invalid
    }

    @MainActor
    static func clear(locationID: String, expected: Receipt, editor: EditorViewModel) async throws {
        try await clear(locationID: locationID, expected: expected, invalidLocations: nil, expectedBibleSHA256: nil, editor: editor)
    }

    @MainActor
    static func clearInvalid(location: Location, bibleSHA256: String, editor: EditorViewModel) async throws {
        try await clearInvalid(locations: [location], bibleSHA256: bibleSHA256, editor: editor)
    }

    @MainActor
    static func clearInvalid(locations: [Location], bibleSHA256: String, editor: EditorViewModel) async throws {
        guard !locations.isEmpty else { throw changed() }
        try await clear(locationID: locations[0].id, expected: nil, invalidLocations: locations,
            expectedBibleSHA256: bibleSHA256, editor: editor)
    }

    @MainActor
    private static func clear(locationID: String, expected: Receipt?, invalidLocations: [Location]?,
                              expectedBibleSHA256: String?, editor: EditorViewModel) async throws {
        guard let generation = editor.openWorkingCopyGeneration else { throw changed() }
        let access = try PipelineNativeEditAccess(editor: editor, label: "Remove panorama assignment")
        var holdsLease = true
        defer { if holdsLease { access.end(editor: editor) } }
        let task = Task.detached(priority: .userInitiated) {
            _ = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "bible")
            guard let before = try loadBible(dataRoot: access.root),
                  let index = before.locations.firstIndex(where: { $0.id == locationID }) else { throw changed() }
            let beforeSHA = try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: access.root))
            let indices: [Int]
            if let expected {
                guard try current(location: before.locations[index], dataRoot: access.root) == expected else { throw changed() }
                indices = [index]
            } else {
                guard let invalidLocations, !invalidLocations.isEmpty, beforeSHA == expectedBibleSHA256,
                      try invalidSelections(in: before, dataRoot: access.root) == invalidLocations else { throw changed() }
                indices = before.locations.indices.filter { index in invalidLocations.contains(before.locations[index]) }
                guard indices.count == invalidLocations.count else { throw changed() }
            }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: PipelineBibleWriter.referencePaths(before) + [PipelineLayout.bibleFile, PipelineLayout.bibleIdentityVariantsFile]
                    + before.locations.compactMap { location in
                        guard let path = location.attributes[receiptPathKey],
                              path.range(of: "^bible/native-panorama-selections/[A-Za-z0-9-]+\\.v1\\.json$", options: .regularExpression) != nil else { return nil }
                        return path
                    })
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "bible")
                guard try loadBible(dataRoot: staging) == before,
                      let variants = try BibleIdentityVariantStoreV1.loadIfPresent(dataRoot: staging) else { throw changed() }
                var after = before
                if let invalidLocations {
                    guard try invalidSelections(in: before, dataRoot: staging) == invalidLocations else { throw changed() }
                }
                for index in indices {
                    after.locations[index].scene3d = .init()
                    after.locations[index].attributes.removeValue(forKey: receiptPathKey)
                    after.locations[index].attributes.removeValue(forKey: receiptHashKey)
                }
                try PipelineBibleWriter.write(after, variants: variants, dataRoot: staging)
                try PipelinePhaseMutationRecorder.record(phase: "bible", dataRoot: staging, captureLineage: true,
                    declaredPack: access.declaration.packName, declaredBinding: access.declaration.binding,
                    declaredProductionContract: access.declaration.productionContract)
                try writer.revalidate()
                return (after, try FileDigest.sha256(of: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: staging)))
            }
            do { try fence.requireUnchanged(); return (transaction, fence, before, beforeSHA) }
            catch { transaction.discard(); throw error }
        }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { Task.detached { prepared.0.discard() } }
        try Task.checkCancellation()
        let after = try prepared.0.commit { _ in
            try access.requireCurrent(editor: editor)
            guard editor.openWorkingCopyGeneration == generation else { throw changed() }
            try prepared.1.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor); holdsLease = false
        await finishAssignment(before: prepared.2, beforeSHA256: prepared.3,
            after: after.0, afterSHA256: after.1, editor: editor, name: invalidLocations == nil ? "Remove Panorama Assignment" : "Remove Invalid Panorama Assignments")
    }

    @MainActor
    private static func finishAssignment(before: Bible, beforeSHA256: String, after: Bible, afterSHA256: String,
                                         editor: EditorViewModel, name: String) async {
        let key = editor.openWorkingCopyKey, generation = editor.openWorkingCopyGeneration
        var warning: String?
        do {
            try await PipelineBibleEditor.recordNativeAssignment(before: before, beforeSHA256: beforeSHA256,
                after: after, afterSHA256: afterSHA256, editor: editor, name: name)
        } catch { warning = "Panorama assignment saved; Undo is unavailable. " + error.localizedDescription }
        guard editor.openWorkingCopyKey == key, editor.openWorkingCopyGeneration == generation else { return }
        if let warning { editor.mediaPanelToast = MediaPanelToast(message: warning) }
        editor.onPipelineChanged?(); await editor.refreshEngineState()
    }

    static func validate(specs: [PovSpec]) throws {
        guard !specs.isEmpty, Set(specs.map(\.name)).count == specs.count,
              specs.allSatisfy({ $0.name.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
                && $0.yawDegrees.isFinite && $0.pitchDegrees.isFinite && $0.fovHorizontalDegrees.isFinite
                && (-180...180).contains($0.yawDegrees) && (-90...90).contains($0.pitchDegrees)
                && $0.fovHorizontalDegrees > 0 && $0.fovHorizontalDegrees < 180 }) else { throw GateBlocked("Choose unique view names, yaw between −180° and 180°, pitch between −90° and 90°, and a field of view between 0° and 180°.") }
    }
    private static func fabrication() -> GateBlocked { GateBlocked("Do not create native panorama receipts or assignments. Preserve the existing selection; only the native Panorama controls may assign it.") }
    private static func changed() -> GateBlocked { GateBlocked("The panorama, Bible or project changed. Create and inspect the current views before confirming them.") }
}
