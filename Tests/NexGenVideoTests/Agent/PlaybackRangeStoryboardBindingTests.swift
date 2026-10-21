import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Storyboard playback input closure; no analysis or native selection acceptance claim")
struct PlaybackRangeStoryboardBindingTests {
    private struct Fixture {
        let home: URL
        let root: URL
        let range: PlaybackRangeV1
        let inputs: [CanonicalArtifactReferenceV1]

        func timing(mode: Mode = .beat, start: Int64? = nil, duration: Int64? = nil,
                    inputs: [CanonicalArtifactReferenceV1]? = nil) -> StoryboardTimingV1 {
            .init(header: .init(projectID: range.header.projectID, revision: 1, origin: .userRevision,
                inputs: inputs ?? self.inputs), timebase: range.timebase, mode: mode,
                rangeStartTicks: start ?? (mode == .multicam ? 0 : range.startTicks),
                rangeDurationTicks: duration ?? (mode == .multicam ? range.audioDurationTicks : range.durationTicks),
                audio: .init(source: range.header.inputs.first { $0.role == "musicvideo.track" }!,
                    durationTicks: range.audioDurationTicks), shots: [])
        }
    }

    private func fixture() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("StoryboardRange-\(UUID().uuidString).ngv")
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: home) } }
        let root = try ProjectScaffold.initProject(home: home, name: "Range byte binding", mode: .beat)
        let project = try YAMLArtifactStore(dataRoot: root).load(ProjectMeta.self, at: PipelineLayout.projectFile)
        _ = try ProjectLocalFile.ensureDirectory("audio", dataRoot: root)
        _ = try ProjectLocalFile.ensureDirectory("analysis", dataRoot: root)
        _ = try ProjectLocalFile.ensureDirectory("brief/playback-range-selections", dataRoot: root)
        try FullflowAcceptanceFixture.writeTone(to: root.appendingPathComponent("audio/song.wav"), duration: 8)
        try Data("{\"unitScope\":\"exact bytes only, not interpreted song analysis\"}".utf8)
            .write(to: root.appendingPathComponent("analysis/song.json"))
        try Data("unit brief bytes".utf8).write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        let audio = try PlanningWriterIO.reference("audio/song.wav", id: "audio", role: "musicvideo.track", dataRoot: root)
        let analysis = try PlanningWriterIO.reference("analysis/song.json", id: "analysis", role: "musicvideo.analysis", dataRoot: root)
        let timebase = RationalTimebaseV1(ticksPerSecond: 600, fpsNumerator: 30)
        let selection = PipelinePlaybackRangeWriter.Selection(schema: "playback-range-selection/v1",
            id: UUID().uuidString.lowercased(), projectID: project.project, workflowID: HostWorkflowKey.musicvideoV2Contract,
            analysis: analysis, audio: audio, timebase: timebase, audioDurationTicks: 4800,
            kind: .excerpt, startTicks: 1200, durationTicks: 2400)
        let selectionBytes = try PlanningWriterIO.json(selection)
        let selectionPath = "brief/playback-range-selections/\(selection.id).v1.json"
        try selectionBytes.write(to: root.appendingPathComponent(selectionPath))
        try selectionBytes.write(to: root.appendingPathComponent("brief/playback-range-selection.current.v1.json"))
        let receipt = PlanningWriterIO.reference(selectionPath, id: selection.id, role: "host.playback-range-selection", bytes: selectionBytes)
        let snapshot = PipelinePlaybackRangeWriter.Snapshot(projectID: project.project, workflowID: selection.workflowID,
            analysis: analysis, audio: audio, timebase: timebase, audioDurationTicks: 4800,
            kind: .excerpt, startTicks: 1200, durationTicks: 2400, fingerprint: String(repeating: "a", count: 64),
            selectionReceipt: receipt)
        let range = try PipelinePlaybackRangeWriter.materialize(snapshot,
            brief: PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: root))
        try PlanningWriterIO.json(range).write(to: root.appendingPathComponent(PlaybackRangeV1.currentPath))
        let references: [CanonicalArtifactReferenceV1]
        do {
            references = try PipelinePlaybackRangeWriter.bindingReferences(range, dataRoot: root, workflowID: selection.workflowID)
        } catch {
            func describe(_ url: URL?) -> [String: String] {
                guard let url else { return ["status": "unavailable"] }
                return ["absolute": url.absoluteString, "path": url.path,
                    "base": url.baseURL?.absoluteString ?? "none", "standardized": url.standardizedFileURL.absoluteString]
            }
            var track: [String: String]
            do { track = describe(try ProjectLocalFile.resolve(audio.path, dataRoot: root)) }
            catch { track = ["error": String(describing: error)] }
            var projectObservation: [String: String]
            do {
                projectObservation = ["project": try YAMLArtifactStore(dataRoot: root)
                    .load(ProjectMeta.self, at: PipelineLayout.projectFile).project]
            } catch { projectObservation = ["error": String(describing: error)] }
            let expectedAnalysis = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root)
            let observation: [String: Any] = [
                "scope": "fixture observation after original binding failure", "error": String(describing: error),
                "rangeProject": range.header.projectID, "project": projectObservation, "root": describe(root),
                "inputs": range.header.inputs.map { ["path": $0.path, "role": $0.role, "sha256": $0.sha256] },
                "analysisPath": range.analysis.path, "expectedAnalysis": describe(expectedAnalysis),
                "expectedAnalysisRelativePath": expectedAnalysis.map { FrameInventory.relativePath(of: $0, to: root) } ?? "unavailable",
                "songs": AudioProjectLayout.songFiles(dataRoot: root).map { describe($0) }, "resolvedTrack": track,
            ]
            if var bytes = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]) {
                bytes.append(0x0A)
                FileHandle.standardError.write(bytes)
            }
            throw error
        }
        let unique = Dictionary(grouping: references, by: \.path).values.compactMap(\.first).sorted { $0.path < $1.path }
        retained = true
        return Fixture(home: home, root: root, range: range, inputs: unique)
    }

    @Test func reanalysisPreservesTheOldReceiptButRequiresAnExplicitNewRange() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.home) }
        let audio = try #require(value.range.header.inputs.first { $0.role == "musicvideo.track" })
        func read(_ analysis: CanonicalArtifactReferenceV1) throws -> PipelinePlaybackRangeWriter.SelectionState {
            try PipelinePlaybackRangeWriter.readSelection(projectID: value.range.header.projectID,
                workflowID: HostWorkflowKey.musicvideoV2Contract, analysis: analysis, audio: audio,
                timebase: value.range.timebase, audioDurationTicks: value.range.audioDurationTicks, dataRoot: value.root)
        }
        let original = try read(value.range.analysis)
        #expect(original.selected?.kind == .excerpt)
        #expect(!original.requiresConfirmation)
        try Data("new analysis".utf8).write(to: value.root.appendingPathComponent(value.range.analysis.path))
        let analysis = try PlanningWriterIO.reference(value.range.analysis.path, id: "analysis",
            role: "musicvideo.analysis", dataRoot: value.root)
        let stale = try read(analysis)
        #expect(stale.selected == nil)
        #expect(stale.receipt == original.receipt)
        #expect(stale.requiresConfirmation)
        let pending = PipelinePlaybackRangeWriter.Snapshot(projectID: value.range.header.projectID,
            workflowID: HostWorkflowKey.musicvideoV2Contract, analysis: analysis, audio: audio,
            timebase: value.range.timebase, audioDurationTicks: value.range.audioDurationTicks,
            kind: .fullSong, startTicks: 0, durationTicks: value.range.audioDurationTicks,
            fingerprint: "pending", selectionReceipt: stale.receipt, requiresSelectionConfirmation: true)
        try PipelinePlaybackRangeWriter.requireCurrent(pending, dataRoot: value.root)
        let brief = try #require(value.range.header.inputs.first { $0.path == PipelineLayout.briefFile })
        #expect(throws: GateBlocked.self) { try PipelinePlaybackRangeWriter.materialize(pending, brief: brief) }
        try Data("damaged receipt".utf8).write(to: value.root.appendingPathComponent(try #require(stale.receipt).path))
        #expect(throws: (any Error).self) { try read(analysis) }
        #expect(throws: (any Error).self) { try PipelinePlaybackRangeWriter.requireCurrent(pending, dataRoot: value.root) }
    }

    @Test func excerptAndMulticamHaveDifferentPlanningIntervalsAndMandatoryNativeClosure() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.home) }
        for mode in [Mode.beat, .multicam] {
            let timing = value.timing(mode: mode)
            try PipelinePlaybackRangeWriter.requireStoryboardBinding(timing, dataRoot: value.root,
                workflowID: HostWorkflowKey.musicvideoV2Contract)
            for omitted in [PlaybackRangeV1.currentPath, "brief/playback-range-selection.current.v1.json",
                            value.range.selectionReceipt!.path] {
                #expect(throws: (any Error).self) {
                    try PipelinePlaybackRangeWriter.requireStoryboardBinding(value.timing(mode: mode,
                        inputs: value.inputs.filter { $0.path != omitted }), dataRoot: value.root,
                        workflowID: HostWorkflowKey.musicvideoV2Contract)
                }
            }
        }
        for timing in [value.timing(start: 0, duration: 4800), value.timing(mode: .multicam, start: 1200, duration: 2400)] {
            #expect(throws: (any Error).self) {
                try PipelinePlaybackRangeWriter.requireStoryboardBinding(timing, dataRoot: value.root,
                    workflowID: HostWorkflowKey.musicvideoV2Contract)
            }
        }
    }

    @Test func changedRangeCurrentSelectionTrackOrAnalysisRefusesUntilExactRestoration() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.home) }
        let timing = value.timing()
        for path in [PlaybackRangeV1.currentPath, "brief/playback-range-selection.current.v1.json", "audio/song.wav", "analysis/song.json"] {
            let url = value.root.appendingPathComponent(path)
            let original = try Data(contentsOf: url)
            var changed = original
            changed.append(contentsOf: [0x20, 0x20])
            try changed.write(to: url)
            #expect(throws: (any Error).self) {
                try PipelinePlaybackRangeWriter.requireStoryboardBinding(timing, dataRoot: value.root,
                    workflowID: HostWorkflowKey.musicvideoV2Contract)
            }
            try original.write(to: url)
            try PipelinePlaybackRangeWriter.requireStoryboardBinding(timing, dataRoot: value.root,
                workflowID: HostWorkflowKey.musicvideoV2Contract)
        }
    }

    @Test func canonicalRangeRejectsAnAdditionalSongUntilItIsRemoved() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.home) }
        let original = try Data(contentsOf: value.root.appendingPathComponent("audio/song.wav"))
        let additional = value.root.appendingPathComponent("audio/additional.wav")
        try original.write(to: additional)
        #expect(throws: GateBlocked.self) {
            try PipelinePlaybackRangeWriter.requireCanonicalCurrent(value.range, dataRoot: value.root,
                workflowID: HostWorkflowKey.musicvideoV2Contract)
        }
        try FileManager.default.removeItem(at: additional)
        try PipelinePlaybackRangeWriter.requireCanonicalCurrent(value.range, dataRoot: value.root,
            workflowID: HostWorkflowKey.musicvideoV2Contract)
    }

    @Test(arguments: [false, true])
    func canonicalRangeRejectsLinkedTracks(outsideProject: Bool) throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.home) }
        let song = value.root.appendingPathComponent("audio/song.wav")
        let target = outsideProject
            ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            : value.home.appendingPathComponent("retained-song.wav")
        defer { if outsideProject { try? FileManager.default.removeItem(at: target) } }
        try FileManager.default.moveItem(at: song, to: target)
        try FileManager.default.createSymbolicLink(at: song, withDestinationURL: target)
        #expect(throws: ProjectLocalFileError.symbolicLink("audio/song.wav")) {
            try PipelinePlaybackRangeWriter.requireCanonicalCurrent(value.range, dataRoot: value.root,
                workflowID: HostWorkflowKey.musicvideoV2Contract)
        }
    }

    @Test func canonicalRangeRehashesAnalysisEvenWhenItsHeaderOmitsTheAnalysisInput() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.home) }
        let range = value.range
        let omitted = PlaybackRangeV1(header: .init(projectID: range.header.projectID, revision: range.header.revision,
            origin: range.header.origin, inputs: range.header.inputs.filter { $0.path != range.analysis.path }),
            kind: range.kind, analysis: range.analysis, timebase: range.timebase, audioDurationTicks: range.audioDurationTicks,
            startTicks: range.startTicks, durationTicks: range.durationTicks, selectionReceipt: range.selectionReceipt)
        try PipelinePlaybackRangeWriter.requireCanonicalCurrent(omitted, dataRoot: value.root,
            workflowID: HostWorkflowKey.musicvideoV2Contract)
        let url = value.root.appendingPathComponent(range.analysis.path), original = try Data(contentsOf: url)
        var changed = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        changed["unitScope"] = "changed exact bytes; still valid JSON"
        let changedBytes = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
        #expect(changedBytes != original)
        _ = try JSONSerialization.jsonObject(with: changedBytes)
        try changedBytes.write(to: url)
        #expect(throws: (any Error).self) {
            try PipelinePlaybackRangeWriter.requireCanonicalCurrent(omitted, dataRoot: value.root,
                workflowID: HostWorkflowKey.musicvideoV2Contract)
        }
        try original.write(to: url)
        try PipelinePlaybackRangeWriter.requireCanonicalCurrent(omitted, dataRoot: value.root,
            workflowID: HostWorkflowKey.musicvideoV2Contract)
    }
}
