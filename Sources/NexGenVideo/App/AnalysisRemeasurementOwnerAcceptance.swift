import AppKit
import Foundation
import NexGenEngine

@MainActor
enum AnalysisRemeasurementOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested, let binding = PluginLoader.liveBinding(id: "musicvideo"),
              binding.version == HostWorkflowKey.musicvideoV2Version, binding.projectSchema == HostWorkflowKey.musicvideoV2Schema else {
            throw GateBlocked("Analysis owner acceptance requires the exact loaded Music Video V2 pack.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let track = output.appendingPathComponent("Analysis owner song.wav")
        try FullflowAcceptanceFixture.writeTone(to: track, duration: 8)
        let sourceSHA = try FileDigest.sha256(of: track)
        let controlled = DecoderControl(expectedSHA256: sourceSHA)
        let flow = try await MusicvideoHostFlowAcceptance.start(track: track, lyrics: nil, binding: binding,
            evidenceURL: output.appendingPathComponent("startup"), toolExecutorFactory: { editor in
                ToolExecutor(editor: editor, configureAudioAnalysis: { registry in controlled.configure(registry) })
            })
        defer { controlled.release(); flow.close() }
        let editor = flow.editor, root = flow.dataRoot
        let window = try MusicvideoNativeAcceptance.window(for: editor)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "analysis-remeasure-owner")
        func artifact(_ name: String) throws -> Data {
            guard let file = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root) else { throw GateBlocked("The real measured analysis is missing.") }
            let data = try Data(contentsOf: file)
            try data.write(to: output.appendingPathComponent(name + ".json"))
            let proof = file.deletingPathExtension().appendingPathExtension("measurement-proof.json")
            try Data(contentsOf: proof).write(to: output.appendingPathComponent(name + "-proof.json"))
            return data
        }
        func execution(_ snapshot: PipelinePhaseExecutionSnapshot) -> [String: Any] {
            let status: String
            switch snapshot.status { case .running: status = "running"; case .completed: status = "completed"; case .failed: status = "failed" }
            return ["runID": snapshot.runID.uuidString, "phase": snapshot.phase, "status": status,
                "root": snapshot.projectRootPath, "sourceFilename": snapshot.sourceFilename as Any? ?? NSNull(),
                "stageID": snapshot.stageID as Any? ?? NSNull(), "completed": snapshot.completedUnitCount,
                "total": snapshot.totalUnitCount, "stages": snapshot.stageEvents.compactMap(\.stageID)]
        }
        do {
            try await flow.runAnalysis {
                $0.registerAudioDecoder(AVFoundationAudioDecoder())
                $0.registerBeatDetector(UnresolvedBarGrid(expectedSHA256: sourceSHA))
            }
            let before = try artifact("initial-analysis")
            let initial = try JSONDecoder().decode(AnalysisSurfaceData.self, from: before)
            guard initial.songSHA256 == sourceSHA, !initial.hasCanonicalStructure,
                  initial.structureResolution?.status == "needs_review", initial.structureResolution?.method == "unresolved",
                  initial.nonSuccessStageDiagnostics.contains(where: { $0.stage == "music_understanding" }) else {
                throw GateBlocked("The initial real DSP run did not expose the actual unavailable structural adapter.")
            }
            try await driver.wait("actual reduced analysis evidence") { driver.text("analysis.diagnostics", in: window)?.contains("No system music-structure analyzer is registered.") == true }
            try await driver.reveal("analysis.structure.unresolved", in: window)
            guard driver.text("analysis.structure.unresolved", in: window)?.isEmpty == false else { throw GateBlocked("The actual unresolved structure warning is missing.") }
            try driver.visible(["analysis.structure.unresolved"], in: window)
            try driver.capture("unresolved-structure-warning", target: window)
            try await driver.reveal("analysis.diagnostics", in: window)
            try driver.visible(["analysis.diagnostics"], in: window)
            try driver.capture("reduced-measurement-evidence", target: window)
            try await driver.reveal("pipeline.overview.approve.analysis", in: window)
            guard let approvalEnabled = driver.state("pipeline.overview.approve.analysis", in: window), !approvalEnabled else {
                throw GateBlocked("The unresolved analysis has no actual disabled approval control.")
            }
            try driver.visible(["pipeline.overview.approve.analysis"], in: window)
            try driver.record("actual reduced measurement evidence", fields: ["visible": driver.text("analysis.diagnostics", in: window) ?? "",
                "analysisSHA256": FileDigest.sha256(of: before), "songSHA256": sourceSHA,
                "unresolvedWarning": driver.text("analysis.structure.unresolved", in: window) ?? "",
                "approveEnabled": approvalEnabled])
            let initialJob = try execution(requiredSnapshot(editor))
            let gatesURL = root.appendingPathComponent(PipelineLayout.gatesFile)
            let gateBytes = try Data(contentsOf: gatesURL)
            var refusal: String?
            do {
                try await NativeGateWriter.approve(projectDir: editor.workingRoot!, phase: "analysis",
                    declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
                    declaredProductionContract: editor.declaredProductionContract, editor: editor,
                    executionCoordinator: editor.pipelinePhaseRunCoordinator)
            } catch { refusal = error.localizedDescription }
            guard let refusal, refusal.contains("unresolved"), try Data(contentsOf: gatesURL) == gateBytes,
                  editor.projectState?.nextPhaseName == "analysis" else { throw GateBlocked("Uninterpreted analysis unexpectedly approved.") }
            try gateBytes.write(to: output.appendingPathComponent("gates-before-refusal.yaml"))
            try Data(contentsOf: gatesURL).write(to: output.appendingPathComponent("gates-after-refusal.yaml"))
            flow.runAnalysisOnNextNativeTurn()
            try await driver.click("dock.continue", in: window)
            try await driver.wait("real native remeasurement failure", seconds: 30) {
                !editor.agentService.isStreaming && flow.nativeAnalysisResults.count == 1
            }
            let failedSnapshot = try requiredSnapshot(editor)
            guard flow.nativeAnalysisResults[0].isError, case .failed(let message) = failedSnapshot.status,
                  message.contains(DecoderControl.failure), try artifact("failed-analysis") == before else {
                throw GateBlocked("The failed remeasurement replaced the last known canonical grid or failed for another reason.")
            }
            try await driver.click("production.ai", in: window)
            try await driver.wait("actual visible analysis failure") { driver.text("agent.failure.message", in: window)?.contains(DecoderControl.failure) == true }
            let visibleError = driver.text("agent.failure.message", in: window) ?? ""
            try driver.capture("actual-decoder-failure", target: window)
            try driver.record("actual analysis failure", fields: ["job": execution(failedSnapshot), "visibleError": visibleError,
                "analysisSHA256": FileDigest.sha256(of: before)])
            try await driver.click("production.activity.close", in: window)
            flow.runAnalysisOnNextNativeTurn()
            try await driver.click("dock.continue", in: window)
            try await driver.wait("actual runner decoder stage", seconds: 15) {
                controlled.isWaiting && editor.pipelinePhaseExecution.snapshot?.isRunning == true
                    && driver.text("analysis.remeasure", in: window) == track.lastPathComponent
            }
            try await driver.reveal("analysis.grid", in: window)
            let duringSnapshot = try requiredSnapshot(editor)
            let priorGrid = "beats=\(initial.beats.count);downbeats=\(initial.downbeats.count);sections=\(initial.sections.count)"
            guard duringSnapshot.stageID == "decode_audio", duringSnapshot.sourceFilename == track.lastPathComponent,
                  driver.text("analysis.grid", in: window) == priorGrid,
                  try artifact("during-analysis") == before else { throw GateBlocked("The remeasurement overlay did not retain its current source and last measured grid.") }
            try driver.visible(["analysis.remeasure", "analysis.grid"], in: window)
            try driver.capture("remeasuring-current-track-last-grid", target: window)
            try driver.record("actual remeasurement retains last grid", fields: ["job": execution(duringSnapshot),
                "trackName": driver.text("analysis.remeasure", in: window) ?? "", "grid": driver.text("analysis.grid", in: window) ?? "",
                "analysisSHA256": FileDigest.sha256(of: before)])
            controlled.release()
            try await driver.wait("actual retried analysis complete", seconds: 60) {
                !editor.agentService.isStreaming && flow.nativeAnalysisResults.count == 2
                    && editor.pipelinePhaseExecution.snapshot?.status == .completed
            }
            let finalJob = try requiredSnapshot(editor), after = try artifact("retried-analysis")
            let final = try JSONDecoder().decode(AnalysisSurfaceData.self, from: after)
            guard !flow.nativeAnalysisResults[1].isError, after != before, final.songSHA256 == sourceSHA,
                  final.hasCanonicalStructure, final.downbeatSource == "music-understanding",
                  final.structureResolution?.method == "music_understanding_hierarchy",
                  editor.projectState?.nextPhaseName == "analysis",
                  try FileDigest.sha256(of: AudioProjectLayout.songFiles(dataRoot: root)[0]) == sourceSHA,
                  window.contentView?.bounds.size == AppTheme.Window.projectMin,
                  AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else {
                throw GateBlocked("Retry did not publish a new exact-source measured grid while preserving the approval boundary.")
            }
            try await driver.wait("actual new analysis grid") {
                driver.text("analysis.grid", in: window) == "beats=\(final.beats.count);downbeats=\(final.downbeats.count);sections=\(final.sections.count)"
            }
            try driver.capture("retried-grid-awaits-interpretation", target: window)
            try driver.record("actual retry completed", fields: ["job": execution(finalJob), "analysisSHA256": FileDigest.sha256(of: after),
                "grid": driver.text("analysis.grid", in: window) ?? "", "nextPhase": editor.projectState?.nextPhaseName ?? ""])
            let calls = flow.nativeAnalysisResults.map { value in ["isError": value.isError,
                "result": value.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["requests": flow.nativeAnalysisRequests, "results": calls,
                "decoder": controlled.calls], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("actual-tools.json"))
            var result = driver.result()
            result.merge(["scale": scale, "viewport": [AppTheme.Window.projectMin.width, AppTheme.Window.projectMin.height],
                "songName": track.lastPathComponent, "songSHA256": sourceSHA, "gateRefusal": refusal,
                "visibleFailure": visibleError, "initialJob": initialJob, "failedJob": execution(failedSnapshot),
                "duringJob": execution(duringSnapshot), "retriedJob": execution(finalJob), "liveAnalyzer": false, "liveAgent": false,
                "measurementFixture": "Actual AVFoundation/DSP with deterministic one-downbeat adapter produces unresolved structure through the real Consolidator; first native rerun decoder fails; retry decodes actual bytes and uses explicitly supplied deterministic hierarchy, not Apple/provider quality evidence."] as [String: Any]) { _, new in new }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("analysis-owner-result.json"))
            return result
        } catch { controlled.release(); driver.failure(error); throw error }
    }

    private static func requiredSnapshot(_ editor: EditorViewModel) throws -> PipelinePhaseExecutionSnapshot {
        guard let value = editor.pipelinePhaseExecution.snapshot, value.phase == "analysis" else { throw GateBlocked("The actual analysis job is missing.") }
        return value
    }

    private final class DecoderControl: @unchecked Sendable {
        static let failure = "The isolated analysis decoder is temporarily unavailable. Retry the current track."
        let expectedSHA256: String
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var attempt = 0
        private var waiting = false
        private var decoded: [[String: Any]] = []
        init(expectedSHA256: String) { self.expectedSHA256 = expectedSHA256 }
        var isWaiting: Bool { lock.withLock { waiting } }
        var calls: [[String: Any]] { lock.withLock { decoded } }
        @MainActor func configure(_ registry: EngineRegistry) {
            attempt += 1
            registry.registerAudioDecoder(Decoder(control: self, attempt: attempt))
            if attempt > 1 { registry.registerMusicUnderstandingAnalyzer(Hierarchy(expectedSHA256: expectedSHA256)) }
        }
        func release() { semaphore.signal() }
        func decode(_ url: URL, attempt: Int) throws -> PCMBuffer {
            let actual = try FileDigest.sha256(of: url)
            guard actual == expectedSHA256 else { throw GateBlocked("The analysis runner substituted its source bytes.") }
            lock.withLock { decoded.append(["attempt": attempt, "sha256": actual, "filename": url.lastPathComponent]) }
            if attempt == 1 { throw GateBlocked(Self.failure) }
            lock.withLock { waiting = true }
            defer { lock.withLock { waiting = false } }
            guard semaphore.wait(timeout: .now() + 30) == .success else { throw GateBlocked("Native remeasurement observation did not release its actual decoder.") }
            return try AVFoundationAudioDecoder().decode(url)
        }
    }
    private struct Decoder: AudioPCMDecoding {
        let control: DecoderControl
        let attempt: Int
        func decode(_ url: URL) throws -> PCMBuffer { try control.decode(url, attempt: attempt) }
    }
    private struct UnresolvedBarGrid: AudioBeatDetecting {
        let expectedSHA256: String
        func detectBeats(_ audio: URL, stems: SeparatedStems?) throws -> DetectedBeatGrid? {
            guard try FileDigest.sha256(of: audio) == expectedSHA256 else { throw GateBlocked("The unresolved-grid adapter received another song.") }
            return .init(beats: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }, downbeats: [0], bpm: 120)
        }
    }
    private struct Hierarchy: MusicUnderstandingAnalyzing {
        let expectedSHA256: String
        func analyze(_ url: URL) throws -> MusicUnderstandingMeasurement {
            guard try FileDigest.sha256(of: url) == expectedSHA256 else { throw GateBlocked("The hierarchy fixture received another song.") }
            return .init(beats: stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }, bars: [0, 2, 4, 6, 8], bpm: 120,
                sections: [.init(start: 0, end: 4), .init(start: 4, end: 8)],
                segments: [.init(start: 0, end: 4), .init(start: 4, end: 8)],
                phrases: [.init(start: 0, end: 2), .init(start: 2, end: 4), .init(start: 4, end: 6), .init(start: 6, end: 8)])
        }
    }
}
