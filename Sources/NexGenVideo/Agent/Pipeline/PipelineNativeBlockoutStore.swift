import AVFoundation
import Foundation
import NexGenEngine

enum PipelineNativeBlockoutStore {
    enum Kind: String, Codable, Sendable { case planElevation, importedGeometry }
    struct Receipt: Codable, Sendable, Equatable {
        let schema: String
        let id: String
        let projectID: String
        let workflowID: String
        let shotID: String
        let kind: Kind
        let camera: ShotPlanningDraftV1.CameraIntent
        let draft: CanonicalArtifactReferenceV1
        let timing: CanonicalArtifactReferenceV1
        let stateReferences: [CanonicalArtifactReferenceV1]
        let output: CanonicalArtifactReferenceV1
        let original: CanonicalArtifactReferenceV1?
        let originalName: String?
        let sourceStartValue: Int64?
        let sourceDurationValue: Int64?
        let sourceTimescale: Int32?
        let sourceDurationTimescale: Int32?
        let observation: String
        let recordedAt: String
    }
    struct ImportedSource: Sendable {
        let url: URL
        let sha256: String
        let duration: CMTime
    }

    static func inspect(_ url: URL) async throws -> ImportedSource {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw changed() }
        let hash = try FileDigest.sha256(of: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.value > 0,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw changed() }
        _ = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
        guard try FileDigest.sha256(of: url) == hash else { throw changed() }
        return .init(url: url, sha256: hash, duration: duration)
    }

    static func references(_ reference: CanonicalArtifactReferenceV1, shot: ShotPlanningDraftV1.ShotIntent,
                           dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        let receipt = try read(reference, dataRoot: dataRoot)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard receipt.workflowID == (try workflowID(dataRoot: dataRoot)),
              receipt.projectID == project.project,
              receipt.shotID == shot.shotID, receipt.camera == physicalIntent(shot.camera),
              let state = shot.camera.spatialState, let camera = shot.camera.spatialCameraID,
              let scene = shot.camera.sceneReference else { throw changed() }
        guard receipt.kind != .importedGeometry || shot.camera.spatialDerivation == nil else { throw changed() }
        let actual = try PipelineSpatialDerivationWriter.planningStateReferences(reference: state,
            cameraID: camera, sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
        guard actual.allSatisfy({ ref in receipt.stateReferences.contains { $0.path == ref.path && $0.sha256 == ref.sha256 } }) else { throw changed() }
        var refs = [reference, receipt.draft, receipt.timing, receipt.output, state, scene] + receipt.stateReferences
        if let original = receipt.original { refs.append(original) }
        for ref in refs { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        let prior = try PlanningWriterIO.read(ShotPlanningDraftV1.self, at: receipt.draft.path, dataRoot: dataRoot)
        guard receipt.draft.path == ShotPlanningDraftV1.versionPath(prior.header.revision),
              prior.header.projectID == project.project,
              prior.shots.first(where: { $0.shotID == shot.shotID }).map({ physicalIntent($0.camera) }) == receipt.camera else { throw changed() }
        let current = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let timing = try PlanningWriterIO.reference(StoryboardTimingV1.versionPath(current.timing.header.revision),
            id: "native-blockout-timing", role: "core.storyboard-timing", dataRoot: dataRoot)
        guard receipt.timing.path == timing.path, receipt.timing.sha256 == timing.sha256 else { throw changed() }
        return refs
    }

    static func video(for shot: ShotPlanningDraftV1.ShotIntent, dataRoot: URL) throws -> CanonicalArtifactReferenceV1? {
        guard let reference = shot.camera.blockingReference else { return nil }
        _ = try references(reference, shot: shot, dataRoot: dataRoot)
        let receipt = try read(reference, dataRoot: dataRoot)
        return receipt.kind == .importedGeometry ? receipt.output : nil
    }

    static func requirePurpose(sha256: String, geometry: Bool, dataRoot: URL) throws {
        let directory = "shot-planning/native-blockouts"
        let url = dataRoot.appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
        let resolved = try metadataDirectory(directory, dataRoot: dataRoot)
        for name in try FileManager.default.contentsOfDirectory(atPath: resolved.path).sorted() where name.hasSuffix(".v1.json") {
            let path = directory + "/" + name
            let ref = try PlanningWriterIO.reference(path, id: name, role: "host.native-blockout", dataRoot: dataRoot)
            let value = try read(ref, dataRoot: dataRoot)
            guard value.output.sha256 == sha256 || value.original?.sha256 == sha256 else { continue }
            guard geometry, value.kind == .importedGeometry else {
                throw GateBlocked("A blockout carries geometry only. Plan/elevation diagrams are planning evidence, not appearance or generation inputs.")
            }
        }
    }

    @MainActor
    static func attach(shotID: String, expected: ShotPlanningDraftV1, imported: ImportedSource? = nil,
                       start: CMTime = .zero, observation: String = "", editor: EditorViewModel) async throws -> ShotPlanningDraftV1 {
        try PipelineShotPlanningEditor.requireAvailable(editor: editor)
        guard let generation = editor.openWorkingCopyGeneration else { throw changed() }
        let access = try PipelineNativeEditAccess(editor: editor, label: imported == nil ? "Export plan and elevation" : "Attach blockout video")
        var holdsLease = true
        defer { if holdsLease { access.end(editor: editor) } }
        let preparation = Task.detached(priority: .userInitiated) {
            let live = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "shot_planning")
            let board = try PlanningWriterIO.storyboard(dataRoot: access.root)
            let before = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: access.root, storyboard: board)
            guard before == expected, let shot = before.shots.first(where: { $0.shotID == shotID }),
                  let stateRef = shot.camera.spatialState, let cameraID = shot.camera.spatialCameraID,
                  let sceneRef = shot.camera.sceneReference,
                  let head = try SpatialSceneStore.index(in: access.root).scenes.first(where: {
                      SpatialSceneStore.revisionPath(scene: $0.id, revision: $0.revision) + "/scene.blend" == sceneRef.path
                  }), let timing = board.timing.shots.first(where: { $0.id == shotID }) else { throw changed() }
            let context = try PipelineSpatialDerivationWriter.planningContext(shotID: shotID, scene: head, dataRoot: access.root)
            let state = try PipelineSpatialDerivationWriter.requirePlanningState(reference: stateRef,
                cameraID: cameraID, sceneReference: sceneRef, shotID: shotID, dataRoot: access.root)
            let stateRefs = before.header.inputs + [stateRef, sceneRef] + (try PipelineSpatialDerivationWriter.planningStateReferences(reference: stateRef,
                cameraID: cameraID, sceneReference: sceneRef, shotID: shotID, dataRoot: access.root))
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: before.header.inputs.map(\.path) + [ShotPlanningDraftV1.currentPath])
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ngv-native-blockout-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let outputURL = scratch.appendingPathComponent("blockout.mov")
            let duration = CMTime(value: timing.durationTicks, timescale: Int32(board.timing.timebase.ticksPerSecond))
            let id = UUID().uuidString.lowercased()
            let directory = (try ProductionWorkflowRecoveryMigration.outputPath(area: "execution/blockout",
                leaf: "native-" + id + "/blockout.mov", dataRoot: access.root) as NSString).deletingLastPathComponent
            var files: [(path: String, bytes: Data)] = []
            var original: CanonicalArtifactReferenceV1?
            var sourceRange: CMTimeRange?
            if let imported {
                guard !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      try FileDigest.sha256(of: imported.url) == imported.sha256 else { throw changed() }
                let range = CMTimeRange(start: start, duration: duration)
                _ = try await PipelineProductionInputMedia.exportRange(source: imported.url, range: range, modality: .video, to: outputURL)
                let bytes = try Data(contentsOf: imported.url)
                guard FileDigest.sha256(of: bytes) == imported.sha256 else { throw changed() }
                original = PlanningWriterIO.reference(directory + "/original.mov", id: "blockout-original-" + id,
                    role: "host.blockout-original", bytes: bytes)
                if let original { files.append((original.path, bytes)) }; sourceRange = range
            } else {
                let projection = try NativeBlockoutPlanProjection(snapshot: context.scene.snapshot, state: state, locationID: head.id.uuidString)
                let clock = try SpatialClaySequenceRenderer.sequenceClock(.init(numerator: timing.durationTicks,
                    denominator: Int32(board.timing.timebase.ticksPerSecond)), numerator: context.scene.snapshot.timebaseNumerator,
                    denominator: context.scene.snapshot.timebaseDenominator, count: state.frames.count)
                try NativeBlockoutExporter.export(width: defaultPovSize.width, height: defaultPovSize.height,
                    frameCount: state.frames.count, presentation: { clock.presentation($0) }, duration: clock.duration,
                    to: outputURL, frame: projection.frame)
            }
            try Task.checkCancellation()
            let outputBytes = try Data(contentsOf: outputURL)
            let output = PlanningWriterIO.reference(directory + "/blockout.mov", id: "native-blockout-video-" + id,
                role: imported == nil ? "host.plan-elevation-video" : "core.shot-blockout-video", bytes: outputBytes)
            files.append((output.path, outputBytes))
            let receipt = Receipt(schema: "native-blockout-selection/v1", id: id, projectID: before.header.projectID,
                workflowID: live.workflow.contractID, shotID: shotID, kind: imported == nil ? .planElevation : .importedGeometry,
                camera: physicalIntent(shot.camera), draft: try PlanningWriterIO.reference(ShotPlanningDraftV1.versionPath(before.header.revision),
                    id: "native-blockout-draft", role: "core.shot-planning", dataRoot: access.root),
                timing: try PlanningWriterIO.reference(StoryboardTimingV1.versionPath(board.timing.header.revision),
                    id: "native-blockout-timing", role: "core.storyboard-timing", dataRoot: access.root), stateReferences: stateRefs,
                output: output, original: original, originalName: imported?.url.lastPathComponent,
                sourceStartValue: sourceRange?.start.value, sourceDurationValue: sourceRange?.duration.value,
                sourceTimescale: sourceRange?.start.timescale, sourceDurationTimescale: sourceRange?.duration.timescale,
                observation: imported == nil ? "Plan/elevation schematic: evaluated world-axis mesh bounds, not a perspective render." : observation,
                recordedAt: ISO8601DateFormatter().string(from: Date()))
            let receiptBytes = try PlanningWriterIO.json(receipt)
            let reference = PlanningWriterIO.reference("shot-planning/native-blockouts/" + id + ".v1.json",
                id: "native-blockout-" + id, role: "host.native-blockout", bytes: receiptBytes)
            files.append((reference.path, receiptBytes))
            let camera = shot.camera
            let replacement = replacing(shot, camera: .init(framing: camera.framing, movement: camera.movement,
                movementDetail: camera.movementDetail, blocking: camera.blocking, sceneReference: camera.sceneReference,
                spatialState: camera.spatialState, spatialCameraID: camera.spatialCameraID,
                spatialDerivation: imported == nil ? camera.spatialDerivation : nil, blockingReference: reference))
            let preparedFiles = files
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "shot_planning")
                let current = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: staging, storyboard: PlanningWriterIO.storyboard(dataRoot: staging))
                guard current == before else { throw changed() }
                for file in preparedFiles {
                    guard !FileManager.default.fileExists(atPath: staging.appendingPathComponent(file.path).path) else { throw changed() }
                    if file.path.hasPrefix("execution/blockout/") { try ProductionWorkflowRecoveryMigration.requireNewOutput(file.path, dataRoot: staging) }
                    _ = try ProjectLocalFile.ensureDirectory((file.path as NSString).deletingLastPathComponent, dataRoot: staging)
                    try file.bytes.write(to: staging.appendingPathComponent(file.path), options: .atomic)
                }
                return try PipelineShotPlanningWriter.write(shots: before.shots.map { $0.shotID == shotID ? replacement : $0 }, origin: .userRevision, access: writer)
            }
            do { try fence.requireUnchanged(); return (transaction, before, fence) }
            catch { transaction.discard(); throw error }
        }
        let prepared = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { prepared.0.discard() } }
        try Task.checkCancellation()
        let result = try prepared.0.commit { _ in
            try access.requireCurrent(editor: editor)
            guard editor.openWorkingCopyGeneration == generation else { throw changed() }
            try prepared.2.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor); holdsLease = false
        PipelineShotPlanningEditor.recordNativeAssignment(before: prepared.1, after: result, editor: editor,
            name: imported == nil ? "Export Plan and Elevation" : "Attach Blockout Video")
        editor.onPipelineChanged?(); await editor.refreshEngineState()
        return result
    }

    static func diagramReference(_ camera: ShotPlanningDraftV1.CameraIntent, dataRoot: URL) throws -> CanonicalArtifactReferenceV1? {
        guard let reference = camera.blockingReference else { return nil }
        return try read(reference, dataRoot: dataRoot).kind == .planElevation ? reference : nil
    }

    static func replacing(_ shot: ShotPlanningDraftV1.ShotIntent, camera: ShotPlanningDraftV1.CameraIntent) -> ShotPlanningDraftV1.ShotIntent {
        .init(shotID: shot.shotID, sourceMode: shot.sourceMode, source: shot.source, sourceObligationID: shot.sourceObligationID,
            camera: camera, obligations: shot.obligations, chainKind: shot.chainKind, predecessorShotID: shot.predecessorShotID,
            narrativeBeat: shot.narrativeBeat, sourceInputRange: shot.sourceInputRange)
    }

    private static func physicalIntent(_ camera: ShotPlanningDraftV1.CameraIntent) -> ShotPlanningDraftV1.CameraIntent {
        .init(framing: camera.framing, movement: camera.movement, movementDetail: camera.movementDetail, blocking: camera.blocking,
            sceneReference: camera.sceneReference, spatialState: camera.spatialState, spatialCameraID: camera.spatialCameraID)
    }

    static func read(_ reference: CanonicalArtifactReferenceV1, dataRoot: URL) throws -> Receipt {
        let value = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf:
            ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: dataRoot)))
        guard value.schema == "native-blockout-selection/v1", UUID(uuidString: value.id) != nil,
              reference.path == "shot-planning/native-blockouts/" + value.id + ".v1.json",
              reference.role == "host.native-blockout", !value.observation.isEmpty, !value.recordedAt.isEmpty,
              (value.kind == .importedGeometry) == (value.original != nil),
              value.output.path.hasPrefix("execution/blockout/"),
              (value.output.path as NSString).deletingLastPathComponent.hasSuffix("/native-" + value.id),
              value.output.role == (value.kind == .planElevation ? "host.plan-elevation-video" : "core.shot-blockout-video") else { throw changed() }
        if value.kind == .importedGeometry {
            guard let start = value.sourceStartValue, let duration = value.sourceDurationValue,
                  let scale = value.sourceTimescale, let durationScale = value.sourceDurationTimescale,
                  start >= 0, duration > 0, scale > 0, durationScale > 0, value.originalName?.isEmpty == false,
                  value.original?.path == (value.output.path as NSString).deletingLastPathComponent + "/original.mov" else { throw changed() }
        } else {
            guard value.sourceStartValue == nil, value.sourceDurationValue == nil, value.sourceTimescale == nil,
                  value.sourceDurationTimescale == nil, value.originalName == nil else { throw changed() }
        }
        return value
    }
    static func requireExportDestination(_ destination: URL, protectedRoots: [URL]) throws {
        let resolved = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        for root in protectedRoots.map({ $0.resolvingSymlinksInPath().standardizedFileURL }) {
            guard resolved != root, !resolved.path.hasPrefix(root.path + "/") else {
                throw GateBlocked("Choose an export destination outside the project and its working copy. Import the exported MOV through the Media Library if needed.")
            }
        }
        if FileManager.default.fileExists(atPath: destination.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw changed() }
        }
    }

    static func metadataDirectory(_ path: String, dataRoot: URL) throws -> URL {
        let url = dataRoot.appendingPathComponent(path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath() == dataRoot.resolvingSymlinksInPath().appendingPathComponent(path).standardizedFileURL else { throw changed() }
        return url
    }

    static func workflowID(dataRoot: URL) throws -> String {
        let home = FrameInventory.projectHome(of: dataRoot)
        let pack: ProjectPackBinding?
        switch ProjectPluginSettings.bindingResolution(projectURL: home) {
        case .absent: pack = nil
        case .bound(let value): pack = value
        default: throw changed()
        }
        let core: HostProductionContractBinding?
        switch ProjectPluginSettings.productionContractResolution(projectURL: home) {
        case .absent: core = nil
        case .bound(let value): core = value
        default: throw changed()
        }
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: dataRoot, expectedPack: pack,
            expectedProductionContract: core), workflow.isProductionV2 else { throw changed() }
        return workflow.contractID
    }
    private static func changed() -> GateBlocked { GateBlocked("The blockout, source range, camera state or shot changed. Review the current shot and attach it again.") }
}
