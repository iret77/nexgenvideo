import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelineShotPlanningEditor {
    @MainActor private final class Session {
        weak var editor: EditorViewModel?
        let home: URL?
        let key: String?
        let manager: UndoManager
        lazy var history = PipelineNativeRevisionHistory<ShotPlanningDraftV1>(manager: manager,
            equivalent: { $0.header.projectID == $1.header.projectID && $0.storyboardRevision == $1.storyboardRevision && $0.shots == $1.shots }, restore: { [weak self] desired, expected in
                guard let self, let editor = self.editor, editor.workingRoot == self.home,
                      editor.openWorkingCopyKey == self.key else { throw GateBlocked("Open the original project to restore Shot Planning.") }
                return try await write(desired.shots, expected: expected, editor: editor, recordUndo: false)
            }, failure: { [weak self] error in
                self?.editor?.mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            })
        init(editor: EditorViewModel, manager: UndoManager) { self.editor = editor; self.manager = manager; home = editor.workingRoot; key = editor.openWorkingCopyKey }
    }
    private static var sessions: [ObjectIdentifier: Session] = [:]

    @discardableResult
    static func replace(_ shot: ShotPlanningDraftV1.ShotIntent, in expected: ShotPlanningDraftV1,
                        editor: EditorViewModel, filmFlow: FilmFlowAdoption? = nil) async throws -> ShotPlanningDraftV1 {
        try requireAvailable(editor: editor)
        guard expected.shots.contains(where: { $0.shotID == shot.shotID }) else {
            throw GateBlocked("The selected shot no longer exists. Reload Shot Planning.")
        }
        return try await write(expected.shots.map { $0.shotID == shot.shotID ? shot : $0 }, expected: expected, editor: editor, filmFlow: filmFlow)
    }

    static func attachSource(from sourceURL: URL, to shot: ShotPlanningDraftV1.ShotIntent,
                             in expected: ShotPlanningDraftV1, editor: EditorViewModel) async throws -> ShotPlanningDraftV1 {
        try requireAvailable(editor: editor)
        guard shot.sourceMode != .generated, expected.shots.contains(where: { $0.shotID == shot.shotID }) else {
            throw GateBlocked("Choose Imported footage or AI-enhanced footage before assigning a source.")
        }
        return try await write(expected.shots, expected: expected, editor: editor, sourceImport: (sourceURL, shot.shotID, shot.sourceMode))
    }

    static func removeBlockouts(shotIDs: Set<String>, in expected: ShotPlanningDraftV1,
                               editor: EditorViewModel, expectedSHA256: String? = nil) async throws -> ShotPlanningDraftV1 {
        try requireAvailable(editor: editor)
        let shots = try removingBlockouts(shotIDs: shotIDs, from: expected)
        return try await write(shots, expected: expected, editor: editor,
            blockoutRemoval: (shotIDs, expectedSHA256))
    }

    nonisolated static func removingBlockouts(shotIDs: Set<String>, from draft: ShotPlanningDraftV1) throws -> [ShotPlanningDraftV1.ShotIntent] {
        let assigned = Set(draft.shots.filter { $0.camera.blockingReference != nil }.map(\.shotID))
        guard !shotIDs.isEmpty, shotIDs.isSubset(of: assigned) else { throw GateBlocked("The blockout assignments changed. Reload Shot Planning.") }
        return draft.shots.map { shot in
            guard shotIDs.contains(shot.shotID) else { return shot }
            let camera = shot.camera
            return PipelineNativeBlockoutStore.replacing(shot, camera: .init(framing: camera.framing,
                movement: camera.movement, movementDetail: camera.movementDetail, blocking: camera.blocking,
                sceneReference: camera.sceneReference, spatialState: camera.spatialState,
                spatialCameraID: camera.spatialCameraID, spatialDerivation: camera.spatialDerivation))
        }
    }

    nonisolated static func requireReadableRange(_ range: SourceFootageRangeV1, dataRoot: URL) async throws {
        try range.validate()
        let url = try ProjectLocalFile.requireHash(range.source.sha256, at: range.source.path, dataRoot: dataRoot)
        let asset = AVURLAsset(url: url)
        let start = CMTime(value: range.startTicks, timescale: Int32(range.timebase.ticksPerSecond))
        let end = CMTime(value: range.startTicks + range.durationTicks, timescale: Int32(range.timebase.ticksPerSecond))
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, CMTimeCompare(end, duration) <= 0,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw ToolError("The selected range must fit inside a readable source video.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 64, height: 64)
        _ = try await generator.image(at: start)
        _ = try ProjectLocalFile.requireHash(range.source.sha256, at: range.source.path, dataRoot: dataRoot)
    }

    private static func write(_ desired: [ShotPlanningDraftV1.ShotIntent], expected: ShotPlanningDraftV1,
        editor: EditorViewModel, recordUndo: Bool = true,
        sourceImport: (url: URL, shotID: String, mode: SourceMode)? = nil,
        blockoutRemoval: (shotIDs: Set<String>, sha256: String?)? = nil, filmFlow: FilmFlowAdoption? = nil) async throws -> ShotPlanningDraftV1 {
        let access = try PipelineNativeEditAccess(editor: editor, label: "Edit Shot Planning")
        var holdsLease = true
        defer { if holdsLease { access.end(editor: editor) } }
        let preparation = Task.detached(priority: .userInitiated) {
            let live = try PipelinePlanningWriteAccess(dataRoot: access.root, declaration: access.declaration, phase: "shot_planning")
            let before = try requireCurrent(expected, access: live, blockoutRemoval: blockoutRemoval)
            let board = try PlanningWriterIO.storyboard(dataRoot: access.root)
            var shots = desired
            var copied: (url: URL, path: String, hash: String)?
            if let sourceImport {
                let values = try sourceImport.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ToolError("Choose a regular video file.") }
                let hash = try FileDigest.sha256(of: sourceImport.url)
                let media = AVURLAsset(url: sourceImport.url)
                let duration = try await media.load(.duration)
                guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
                      !(try await media.loadTracks(withMediaType: .video)).isEmpty else { throw ToolError("The selected file has no readable video track.") }
                _ = try await AVAssetImageGenerator(asset: media).image(at: .zero)
                let ticks = CMTimeConvertScale(duration, timescale: Int32(board.timing.timebase.ticksPerSecond), method: .roundTowardZero)
                guard ticks.isNumeric, ticks.value > 0,
                      let original = before.shots.first(where: { $0.shotID == sourceImport.shotID }) else { throw ToolError("The source video is too short or its target shot changed.") }
                let id = UUID().uuidString.lowercased()
                let path = "shot-planning/sources/" + id + "/" + sourceImport.url.lastPathComponent
                let reference = CanonicalArtifactReferenceV1(id: "source-" + id, role: "core.source-footage", path: path, sha256: hash)
                let replacement = ShotPlanningDraftV1.ShotIntent(shotID: original.shotID, sourceMode: sourceImport.mode,
                    source: reference, camera: original.camera,
                    obligations: original.obligations.filter { $0.id != original.sourceObligationID }, narrativeBeat: original.narrativeBeat,
                    sourceInputRange: .init(source: reference, timebase: board.timing.timebase, startTicks: 0, durationTicks: ticks.value))
                shots = shots.map { $0.shotID == original.shotID ? replacement : $0 }
                copied = (sourceImport.url, path, hash)
            }
            for shot in shots where shot.source != nil && shot.shotID != sourceImport?.shotID {
                guard let range = shot.sourceInputRange, range.source == shot.source else { throw ToolError("Choose the source video's start and end before applying this shot.") }
                try await requireReadableRange(range, dataRoot: access.root)
            }
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: access.root,
                additionalCanonicalPaths: board.references.map(\.path) + before.header.inputs.map(\.path) + [ShotPlanningDraftV1.currentPath])
            let finalShots = shots
            let transaction = try ProjectWorkingCopy.preparePipelineTransaction(at: access.root) { staging in
                let writer = try PipelinePlanningWriteAccess(dataRoot: staging, declaration: access.declaration, phase: "shot_planning")
                _ = try requireCurrent(expected, access: writer, blockoutRemoval: blockoutRemoval)
                if let copied {
                    _ = try ProjectLocalFile.ensureDirectory((copied.path as NSString).deletingLastPathComponent, dataRoot: staging)
                    let target = staging.appendingPathComponent(copied.path)
                    try FileManager.default.copyItem(at: copied.url, to: target)
                    guard try FileDigest.sha256(of: copied.url) == copied.hash,
                          try FileDigest.sha256(of: target) == copied.hash else { throw ToolError("The video changed while it was being attached. Choose it again.") }
                }
                let written = try PipelineShotPlanningWriter.write(shots: finalShots, origin: .userRevision, access: writer)
                try filmFlow?.record(phase: "shot_planning", outputs: [PlanningWriterIO.reference(
                    ShotPlanningDraftV1.versionPath(written.header.revision), id: "shot-planning", role: "core.shot-planning", dataRoot: staging)], dataRoot: staging)
                return written
            }
            do { try fence.requireUnchanged(); return (transaction, before, fence) }
            catch { transaction.discard(); throw error }
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        defer { Task.detached { result.0.discard() } }
        try Task.checkCancellation()
        let after = try result.0.commit { _ in
            try access.requireCurrent(editor: editor)
            try result.2.requireCanonicalRootsUnchanged()
            try ProjectWorkingCopy.markDirty(key: access.key)
        }
        access.end(editor: editor)
        holdsLease = false
        if recordUndo { recordNativeAssignment(before: result.1, after: after, editor: editor, name: "Edit Shot Planning") }
        editor.onPipelineChanged?()
        await editor.refreshEngineState()
        return after
    }

    static func recordNativeAssignment(before: ShotPlanningDraftV1, after: ShotPlanningDraftV1,
                                       editor: EditorViewModel, name: String) {
        guard before.shots != after.shots else { return }
        guard let manager = editor.undoManager else {
            editor.mediaPanelToast = MediaPanelToast(message: "Shot Planning was saved. Its editor window has no Undo manager.")
            return
        }
        sessions = sessions.filter { $0.value.editor != nil }
        let key = ObjectIdentifier(editor)
        let session: Session
        if let existing = sessions[key], existing.home == editor.workingRoot, existing.key == editor.openWorkingCopyKey { session = existing }
        else { sessions[key]?.history.clear(); session = Session(editor: editor, manager: manager); sessions[key] = session }
        session.history.record(before: before, after: after, name: name)
    }

    static func resetHistory(editor: EditorViewModel) {
        sessions.removeValue(forKey: ObjectIdentifier(editor))?.history.clear()
    }

    static func requireAvailable(editor: EditorViewModel) throws {
        guard editor.undoManager != nil else { throw GateBlocked("Open this project's editor window before changing Shot Planning.") }
        if let value = sessions[ObjectIdentifier(editor)], value.history.isBusy {
            throw GateBlocked("Wait for the native revision to finish restoring.")
        }
    }

    nonisolated private static func requireCurrent(_ expected: ShotPlanningDraftV1, access: PipelinePlanningWriteAccess,
        blockoutRemoval: (shotIDs: Set<String>, sha256: String?)? = nil) throws -> ShotPlanningDraftV1 {
        try access.revalidate()
        if let removal = blockoutRemoval {
            let snapshot = try PipelineBlockoutRemovalSnapshot.load(dataRoot: access.dataRoot, shotIDs: removal.shotIDs)
            guard snapshot.draft == expected, removal.sha256 == nil || removal.sha256 == snapshot.sha256 else {
                throw GateBlocked("The blockout assignments changed. Reload Shot Planning before removing them.")
            }
            return snapshot.draft
        }
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: access.dataRoot)
        let current = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: access.dataRoot, storyboard: storyboard)
        guard current == expected else { throw GateBlocked("Shot Planning changed while this edit was open. Reload it before applying changes.") }
        return current
    }
}
