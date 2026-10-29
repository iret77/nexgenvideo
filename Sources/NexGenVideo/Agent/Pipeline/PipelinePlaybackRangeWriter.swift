import AVFoundation
import Foundation
import NexGenEngine

@MainActor
enum PipelinePlaybackRangeWriter {
    struct Snapshot: Sendable, Equatable {
        let projectID: String
        let workflowID: String
        let analysis: CanonicalArtifactReferenceV1
        let audio: CanonicalArtifactReferenceV1
        let timebase: RationalTimebaseV1
        let audioDurationTicks: Int64
        let kind: PlaybackRangeV1.Kind
        let startTicks: Int64
        let durationTicks: Int64
        let fingerprint: String
        let selectionReceipt: CanonicalArtifactReferenceV1?
    }

    private struct Selection: Codable {
        let schema: String
        let id: String
        let projectID: String
        let workflowID: String
        let analysis: CanonicalArtifactReferenceV1
        let audio: CanonicalArtifactReferenceV1
        let timebase: RationalTimebaseV1
        let audioDurationTicks: Int64
        let kind: PlaybackRangeV1.Kind
        let startTicks: Int64
        let durationTicks: Int64
    }

    nonisolated private static let currentSelection = "brief/playback-range-selection.current.v1.json"

    static func capture(editor: EditorViewModel) async throws -> Snapshot {
        guard let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else {
            throw GateBlocked("Open a Music Video project first.")
        }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        guard let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: declaration.binding,
            expectedProductionContract: declaration.productionContract), workflow.isProductionV2, workflow.packID == "musicvideo" else {
            throw GateBlocked("Playback range selection requires the current Music Video workflow.")
        }
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "brief")
        let tracks = AudioProjectLayout.songFiles(dataRoot: root)
        guard tracks.count == 1, let track = tracks.first,
              let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root) else {
            throw GateBlocked("Attach and analyze exactly one track before selecting its playback range.")
        }
        let registry = PackCatalog.registry(activePack: workflow.packID)
        try GateGuard.checkApprovable(phase: "analysis", dataRoot: root,
            requirement: PhaseContractRuntime.gateRequirement(workflow: workflow, phase: "analysis", registry: registry))
        let analysis = try PlanningWriterIO.reference(FrameInventory.relativePath(of: analysisURL, to: root),
            id: "analysis", role: "musicvideo.analysis", dataRoot: root)
        let audio = try PlanningWriterIO.reference(FrameInventory.relativePath(of: track, to: root),
            id: "audio", role: "musicvideo.track", dataRoot: root)
        let fps = Int64(editor.timeline.fps)
        let duration = try await AVURLAsset(url: track).load(.duration)
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0, fps > 0 else {
            throw GateBlocked("The selected track has no exact readable duration.")
        }
        let scale = Int64(duration.timescale)
        var a = scale
        var b = fps
        while b != 0 { (a, b) = (b, a % b) }
        let common = (scale / a).multipliedReportingOverflow(by: fps)
        guard !common.overflow, common.partialValue <= Int64(Int32.max) else {
            throw GateBlocked("The track and frame rate have no supported exact common timebase.")
        }
        let ticks = duration.value.multipliedReportingOverflow(by: common.partialValue / scale)
        guard !ticks.overflow, ticks.partialValue > 0 else { throw GateBlocked("The track duration exceeds the supported timebase.") }
        let timebase = RationalTimebaseV1(ticksPerSecond: common.partialValue, fpsNumerator: fps)
        try timebase.validate()
        try access.revalidate()
        guard editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) == root,
              Int64(editor.timeline.fps) == fps else { throw GateBlocked("The active project changed while reading the track.") }
        let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        var selected: Selection?
        var receipt: CanonicalArtifactReferenceV1?
        let selectionCandidate = root.appendingPathComponent(currentSelection)
        if FileManager.default.fileExists(atPath: selectionCandidate.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: selectionCandidate.path)) != nil {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(currentSelection, dataRoot: root))
            let value = try JSONDecoder().decode(Selection.self, from: bytes)
            let archive = "brief/playback-range-selections/\(value.id).v1.json"
            guard let uuid = UUID(uuidString: value.id), uuid.uuidString.lowercased() == value.id,
                  value.schema == "playback-range-selection/v1", value.projectID == project.project,
                  value.workflowID == workflow.contractID, value.analysis == analysis, value.audio == audio,
                  value.timebase == timebase, value.audioDurationTicks == ticks.partialValue,
                  bytes == (try Data(contentsOf: ProjectLocalFile.resolve(archive, dataRoot: root))) else {
                throw GateBlocked("The native playback range is stale. Select the range again after restoring its source.")
            }
            selected = value
            receipt = PlanningWriterIO.reference(archive, id: value.id, role: "host.playback-range-selection", bytes: bytes)
        }
        let kind = selected?.kind ?? .fullSong
        let start = selected?.startTicks ?? 0
        let length = selected?.durationTicks ?? ticks.partialValue
        let identity = [project.project, workflow.contractID, analysis.sha256, audio.sha256,
            String(timebase.ticksPerSecond), String(timebase.fpsNumerator), String(timebase.fpsDenominator),
            String(ticks.partialValue), kind.rawValue, String(start), String(length), receipt?.sha256 ?? "none"]
        let fingerprint = FileDigest.sha256(of: try PlanningWriterIO.json(identity))
        let result = Snapshot(projectID: project.project, workflowID: workflow.contractID, analysis: analysis, audio: audio,
            timebase: timebase, audioDurationTicks: ticks.partialValue, kind: kind, startTicks: start,
            durationTicks: length, fingerprint: fingerprint, selectionReceipt: receipt)
        try requireCurrent(result, dataRoot: root)
        return result
    }

    static func selectExcerpt(startTicks: Int64, durationTicks: Int64, expectedFingerprint: String,
                              editor: EditorViewModel) async throws -> Snapshot {
        try await select(kind: .excerpt, startTicks: startTicks, durationTicks: durationTicks,
            expectedFingerprint: expectedFingerprint, editor: editor)
    }

    static func selectFullSong(expectedFingerprint: String, editor: EditorViewModel) async throws -> Snapshot {
        let snapshot = try await capture(editor: editor)
        return try await select(kind: .fullSong, startTicks: 0, durationTicks: snapshot.audioDurationTicks,
            expectedFingerprint: expectedFingerprint, editor: editor)
    }

    nonisolated static func materialize(_ snapshot: Snapshot, brief: CanonicalArtifactReferenceV1) throws -> PlaybackRangeV1 {
        let inputs = [brief, snapshot.analysis, snapshot.audio] + [snapshot.selectionReceipt].compactMap { $0 }
        let range = PlaybackRangeV1(header: .init(projectID: snapshot.projectID, revision: 1, origin: .userRevision, inputs: inputs),
            kind: snapshot.kind, analysis: snapshot.analysis, timebase: snapshot.timebase,
            audioDurationTicks: snapshot.audioDurationTicks, startTicks: snapshot.startTicks,
            durationTicks: snapshot.durationTicks, selectionReceipt: snapshot.kind == .excerpt ? snapshot.selectionReceipt : nil)
        try range.validate()
        return range
    }

    nonisolated static func requireCurrent(_ snapshot: Snapshot, dataRoot: URL) throws {
        let currentURL = dataRoot.appendingPathComponent(currentSelection)
        if let selection = snapshot.selectionReceipt {
            let archived = try Data(contentsOf: ProjectLocalFile.requireHash(selection.sha256, at: selection.path, dataRoot: dataRoot))
            guard archived == (try Data(contentsOf: ProjectLocalFile.resolve(currentSelection, dataRoot: dataRoot))) else {
                throw GateBlocked("The native playback range changed. Review the current selection again.")
            }
        } else if FileManager.default.fileExists(atPath: currentURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)) != nil {
            throw GateBlocked("A native playback range was selected after this snapshot. Review it again.")
        }
        for ref in [snapshot.analysis, snapshot.audio] + [snapshot.selectionReceipt].compactMap({ $0 }) {
            _ = try ProjectLocalFile.requireHash(ref.sha256, at: ref.path, dataRoot: dataRoot)
        }
        let end = snapshot.startTicks.addingReportingOverflow(snapshot.durationTicks)
        guard snapshot.startTicks >= 0, snapshot.durationTicks > 0, !end.overflow,
              end.partialValue <= snapshot.audioDurationTicks,
              snapshot.kind != .fullSong || (snapshot.startTicks == 0 && snapshot.durationTicks == snapshot.audioDurationTicks),
              snapshot.kind != .excerpt || snapshot.selectionReceipt != nil else {
            throw GateBlocked("Choose a non-empty range inside the actual track.")
        }
    }

    nonisolated static func requireCanonicalCurrent(_ range: PlaybackRangeV1, dataRoot: URL, workflowID: String) throws {
        try range.validate()
        try range.header.requireCurrentInputs(dataRoot: dataRoot)
        let project = try YAMLArtifactStore(dataRoot: dataRoot).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        guard range.header.projectID == project.project,
              range.header.inputs.contains(where: { $0.path == PipelineLayout.briefFile }),
              let audio = range.header.inputs.first(where: { $0.role == "musicvideo.track" }),
              let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              try FrameInventory.relativePath(of: analysisURL, to: dataRoot) == range.analysis.path,
              AudioProjectLayout.songFiles(dataRoot: dataRoot).count == 1,
              AudioProjectLayout.songFiles(dataRoot: dataRoot).first == (try ProjectLocalFile.resolve(audio.path, dataRoot: dataRoot)) else {
            throw GateBlocked("The playback range does not bind this project's current track and analysis.")
        }
        let selectionURL = dataRoot.appendingPathComponent(currentSelection)
        if FileManager.default.fileExists(atPath: selectionURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: selectionURL.path)) != nil {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(currentSelection, dataRoot: dataRoot))
            let value = try JSONDecoder().decode(Selection.self, from: bytes)
            guard let uuid = UUID(uuidString: value.id), uuid.uuidString.lowercased() == value.id,
                  value.schema == "playback-range-selection/v1", value.projectID == project.project,
                  value.workflowID == workflowID, value.analysis == range.analysis, value.audio == audio,
                  value.timebase == range.timebase, value.audioDurationTicks == range.audioDurationTicks,
                  value.kind == range.kind, value.startTicks == range.startTicks, value.durationTicks == range.durationTicks else {
                throw GateBlocked("The playback range differs from the current native selection.")
            }
            let path = "brief/playback-range-selections/\(value.id).v1.json"
            let reference = PlanningWriterIO.reference(path, id: value.id, role: "host.playback-range-selection", bytes: bytes)
            guard bytes == (try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))),
                  range.header.inputs.contains(reference), range.kind != .excerpt || range.selectionReceipt == reference else {
                throw GateBlocked("The playback range has no current native selection receipt.")
            }
        } else if range.kind != .fullSong || range.selectionReceipt != nil {
            throw GateBlocked("Choose the excerpt in the native playback range controls.")
        }
    }

    private static func select(kind: PlaybackRangeV1.Kind, startTicks: Int64, durationTicks: Int64,
                               expectedFingerprint: String, editor: EditorViewModel) async throws -> Snapshot {
        let snapshot = try await capture(editor: editor)
        guard snapshot.fingerprint == expectedFingerprint,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
              let key = editor.openWorkingCopyKey else { throw GateBlocked("The playback range changed. Review it again.") }
        guard let lease = editor.pipelinePhaseRunCoordinator.beginMutation(projectRoot: root, label: "brief") else {
            throw GateBlocked("Wait for the current production job before changing its playback range.")
        }
        defer { editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: root, id: lease) }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let access = try PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "brief")
        let id = UUID().uuidString.lowercased()
        let selection = Selection(schema: "playback-range-selection/v1", id: id, projectID: snapshot.projectID,
            workflowID: snapshot.workflowID, analysis: snapshot.analysis, audio: snapshot.audio, timebase: snapshot.timebase,
            audioDurationTicks: snapshot.audioDurationTicks, kind: kind, startTicks: startTicks, durationTicks: durationTicks)
        let archive = "brief/playback-range-selections/\(id).v1.json"
        let bytes = try PlanningWriterIO.json(selection)
        let receipt = PlanningWriterIO.reference(archive, id: id, role: "host.playback-range-selection", bytes: bytes)
        let proposed = Snapshot(projectID: snapshot.projectID, workflowID: snapshot.workflowID, analysis: snapshot.analysis,
            audio: snapshot.audio, timebase: snapshot.timebase, audioDurationTicks: snapshot.audioDurationTicks,
            kind: kind, startTicks: startTicks, durationTicks: durationTicks, fingerprint: "", selectionReceipt: receipt)
        let end = startTicks.addingReportingOverflow(durationTicks)
        guard startTicks >= 0, durationTicks > 0, !end.overflow, end.partialValue <= snapshot.audioDurationTicks,
              kind != .fullSong || (startTicks == 0 && durationTicks == snapshot.audioDurationTicks) else {
            throw GateBlocked("Choose a non-empty range inside the actual track.")
        }
        let hasBrief = FileManager.default.fileExists(atPath: root.appendingPathComponent(PipelineLayout.briefFile).path)
        var files: [(path: String, bytes: Data)] = [(archive, bytes), (currentSelection, bytes)]
        if hasBrief {
            let brief = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: root)
            files.append((PlaybackRangeV1.currentPath, try PlanningWriterIO.json(materialize(proposed, brief: brief))))
        }
        try ProjectWorkingCopy.markDirty(key: key)
        let paths = files.map { root.appendingPathComponent($0.path) }
            + [PipelineLayout.gatesFile, PipelineLayout.lineageFile].map { root.appendingPathComponent($0) }
        try ArtifactTransaction.perform(paths: paths, dataRoot: root) {
            try access.revalidate()
            try requireCurrent(snapshot, dataRoot: root)
            for file in files {
                _ = try ProjectLocalFile.ensureDirectory((file.path as NSString).deletingLastPathComponent, dataRoot: root)
                try file.bytes.write(to: root.appendingPathComponent(file.path), options: .atomic)
            }
            try requireCurrent(proposed, dataRoot: root)
            try PipelinePhaseMutationRecorder.record(phase: "brief", dataRoot: root, captureLineage: false,
                declaredPack: declaration.packName, declaredBinding: declaration.binding,
                declaredProductionContract: declaration.productionContract)
        }
        editor.onPipelineChanged?()
        return try await capture(editor: editor)
    }
}
