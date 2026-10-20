import AppKit
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
        let videoRange: CMTimeRange
    }

    static func inspect(_ url: URL) async throws -> ImportedSource {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw changed() }
        let hash = try FileDigest.sha256(of: url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let video = tracks.first else {
            throw GateBlocked("Choose a blockout with one continuous video track.")
        }
        let range = try await video.load(.timeRange)
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              CMTimeCompare(range.start, .zero) >= 0, CMTimeCompare(range.duration, .zero) > 0 else { throw changed() }
        _ = try await AVAssetImageGenerator(asset: asset).image(at: range.start)
        guard try FileDigest.sha256(of: url) == hash else { throw changed() }
        return .init(url: url, sha256: hash, videoRange: range)
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
        if receipt.kind == .planElevation {
            try SpatialEvaluatedGeometryRenderer.requireEvidence(references: receipt.stateReferences, stateReference: state,
                cameraID: camera, sceneReference: scene, shotID: shot.shotID,
                directory: (receipt.output.path as NSString).deletingLastPathComponent, dataRoot: dataRoot)
        }
        var refs = [reference, receipt.draft, receipt.timing, receipt.output, state, scene] + receipt.stateReferences
        if let original = receipt.original { refs.append(original) }
        for ref in refs { _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot) }
        let prior = try PlanningWriterIO.read(ShotPlanningDraftV1.self, at: receipt.draft.path, dataRoot: dataRoot)
        guard receipt.draft.path == ShotPlanningDraftV1.versionPath(prior.header.revision),
              prior.header.projectID == project.project,
              prior.shots.first(where: { $0.shotID == shot.shotID }).map({ physicalIntent($0.camera) }) == receipt.camera else { throw changed() }
        let current = try PlanningWriterIO.storyboard(dataRoot: dataRoot)
        let originalTiming = try PlanningWriterIO.read(StoryboardTimingV1.self, at: receipt.timing.path, dataRoot: dataRoot)
        guard receipt.timing.path == StoryboardTimingV1.versionPath(originalTiming.header.revision) else { throw changed() }
        try requireTiming(originalTiming, current: current.timing, shotID: shot.shotID)
        return refs
    }

    static func video(for shot: ShotPlanningDraftV1.ShotIntent, dataRoot: URL) throws -> CanonicalArtifactReferenceV1? {
        guard let reference = shot.camera.blockingReference else { return nil }
        _ = try references(reference, shot: shot, dataRoot: dataRoot)
        let receipt = try read(reference, dataRoot: dataRoot)
        return receipt.kind == .importedGeometry ? receipt.output : nil
    }

    static func requireTiming(_ original: StoryboardTimingV1, current: StoryboardTimingV1, shotID: String) throws {
        guard original.header.projectID == current.header.projectID, original.timebase == current.timebase,
              let prior = original.shots.first(where: { $0.id == shotID }),
              let present = current.shots.first(where: { $0.id == shotID }),
              prior.durationTicks == present.durationTicks else { throw changed() }
    }

    static func matchingVideoReferences(_ reference: CanonicalArtifactReferenceV1, shot: ShotPlanningDraftV1.ShotIntent,
                                       path: String, sha256: String, dataRoot: URL) throws -> [CanonicalArtifactReferenceV1]? {
        let receipt = try read(reference, dataRoot: dataRoot)
        guard receipt.kind == .importedGeometry, receipt.output.path == path, receipt.output.sha256 == sha256 else { return nil }
        return try references(reference, shot: shot, dataRoot: dataRoot)
    }

    static func requirePurpose(sha256: String, geometry: Bool, dataRoot: URL) throws {
        let directory = "shot-planning/native-blockouts"
        let url = dataRoot.appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
        let resolved = try metadataDirectory(directory, dataRoot: dataRoot)
        var matchesOriginal = false, matchesOutput = false
        for name in try FileManager.default.contentsOfDirectory(atPath: resolved.path).sorted() where name.hasSuffix(".v1.json") {
            let path = directory + "/" + name
            let ref = try PlanningWriterIO.reference(path, id: name, role: "host.native-blockout", dataRoot: dataRoot)
            let value = try read(ref, dataRoot: dataRoot)
            guard value.output.sha256 == sha256 || value.original?.sha256 == sha256 else { continue }
            guard geometry, value.kind == .importedGeometry else {
                throw GateBlocked("A blockout carries geometry only. Plan/elevation diagrams are planning evidence, not appearance or generation inputs.")
            }
            matchesOriginal = matchesOriginal || value.original?.sha256 == sha256
            matchesOutput = matchesOutput || value.output.sha256 == sha256
        }
        if matchesOriginal && !matchesOutput {
            throw GateBlocked("The original blockout is archival evidence. Use its reviewed, trimmed geometry clip as conditioning.")
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
        let operation: BpyRuntimeOperation?
        if imported == nil {
            guard let key = editor.openWorkingCopyKey,
                  let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject })
                    .first(where: { $0.editorViewModel === editor }) else { throw changed() }
            operation = try BpyRuntimeHost.shared.acquireOperation(document: document, documentID: key)
        } else { operation = nil }
        defer { if let operation { BpyRuntimeHost.shared.releaseOperation(operation) } }
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
            var stateRefs = try PipelineSpatialDerivationWriter.planningStateReferences(reference: stateRef,
                cameraID: cameraID, sceneReference: sceneRef, shotID: shotID, dataRoot: access.root)
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
            var mediaFiles: [(path: String, url: URL, sha256: String)] = []
            var original: CanonicalArtifactReferenceV1?
            var sourceRange: CMTimeRange?
            if let imported {
                guard !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      try FileDigest.sha256(of: imported.url) == imported.sha256 else { throw changed() }
                let range = CMTimeRange(start: start, duration: duration)
                let originalURL = scratch.appendingPathComponent("original.mov")
                try PipelineGeometryVideoExport.copyVerified(source: imported.url, to: originalURL, expectedSHA256: imported.sha256)
                _ = try await PipelineGeometryVideoExport.export(source: originalURL, range: range, to: outputURL)
                original = .init(id: "blockout-original-" + id, role: "host.blockout-original",
                    path: directory + "/original.mov", sha256: imported.sha256)
                if let original { mediaFiles.append((original.path, originalURL, original.sha256)) }; sourceRange = range
            } else {
                guard let operation else { throw changed() }
                let evaluated = try await SpatialEvaluatedGeometryRenderer.prepare(state: state, revision: context.scene,
                    runtime: operation.session, runtimeRoot: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BpyRuntime"))
                let projection = try NativeBlockoutPlanProjection(snapshot: context.scene.snapshot, snapshotData: context.scene.snapshotData, state: state,
                    geometry: evaluated.geometry, locationID: head.id.uuidString)
                for (name, bytes) in evaluated.files.sorted(by: { $0.key < $1.key }) {
                    let reference = PlanningWriterIO.reference(directory + "/" + name, id: "evaluated-geometry-" + id + "-" + name,
                        role: "host.evaluated-geometry", bytes: bytes)
                    stateRefs.append(reference)
                    files.append((reference.path, bytes))
                }
                let clock = try SpatialClayRenderer.sequenceClock(.init(numerator: timing.durationTicks,
                    denominator: Int32(board.timing.timebase.ticksPerSecond)), numerator: context.scene.snapshot.timebaseNumerator,
                    denominator: context.scene.snapshot.timebaseDenominator, count: state.frames.count)
                try NativeBlockoutExporter.export(width: defaultPovSize.width, height: defaultPovSize.height,
                    frameCount: state.frames.count, presentation: { clock.presentation($0) }, duration: clock.duration,
                    to: outputURL, frame: projection.frame)
            }
            try Task.checkCancellation()
            let output = CanonicalArtifactReferenceV1(id: "native-blockout-video-" + id,
                role: imported == nil ? "host.plan-elevation-video" : "core.shot-blockout-video",
                path: directory + "/blockout.mov", sha256: try FileDigest.sha256(of: outputURL))
            mediaFiles.append((output.path, outputURL, output.sha256))
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
            let preparedMedia = mediaFiles
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "shot_planning")
                let current = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: staging, storyboard: PlanningWriterIO.storyboard(dataRoot: staging))
                guard current == before else { throw changed() }
                for file in preparedMedia {
                    try ProductionWorkflowRecoveryMigration.requireNewOutput(file.path, dataRoot: staging)
                    _ = try ProjectLocalFile.ensureDirectory((file.path as NSString).deletingLastPathComponent, dataRoot: staging)
                    try PipelineGeometryVideoExport.copyVerified(source: file.url, to: staging.appendingPathComponent(file.path),
                        expectedSHA256: file.sha256)
                }
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
            guard editor.openWorkingCopyGeneration == generation,
                  operation.map({ BpyRuntimeHost.shared.isOperationActive($0) }) ?? true else { throw changed() }
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
