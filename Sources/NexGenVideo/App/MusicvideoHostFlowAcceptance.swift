import AppKit
import NexGenEngine

@MainActor
final class MusicvideoHostFlowAcceptance {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["NGV_EXAMPLE_ANALYSIS_PACK"] != nil
    }

    struct Report: Encodable {
        let transitions: [String]
        let backendPhases: [String: [String]]
        let savedAndReopened: Bool
        let screenshots: [String]
        let interpretationSource = "supplied deterministic acceptance labels; no live LLM"
    }

    private(set) var document: VideoProject
    let projectURL: URL
    private let evidenceURL: URL
    private var runtime: RecordingRuntime
    private var transitions: [String] = []
    private var backendPhases: [String: [String]] = [:]
    private var savedAndReopened = false
    private var screenshots: [String] = []
    var editor: EditorViewModel { document.editorViewModel }
    var dataRoot: URL { DataRootResolver.dataRoot(of: editor.workingRoot!)! }
    private var service: AgentService { editor.agentService }
    private var window: NSWindow { document.windowControllers[0].window! }

    private init(document: VideoProject, projectURL: URL, runtime: RecordingRuntime, evidenceURL: URL) {
        self.document = document
        self.projectURL = projectURL
        self.runtime = runtime
        self.evidenceURL = evidenceURL
    }

    static func start(track: URL, lyrics: URL?, binding: ProjectPackBinding, evidenceURL: URL) async throws -> MusicvideoHostFlowAcceptance {
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        UserDefaults.standard.set(AppTheme.Typography.standardScale, forKey: AppTheme.Typography.scaleKey)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MusicvideoHostFlow-\(UUID().uuidString).ngv")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: home.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: home.appendingPathComponent(Project.generationLogFilename))
        _ = try ProjectIdentity.uuid(for: home)
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
        _ = try ProjectScaffold.initProject(home: home, name: "Musicvideo host flow", mode: .beat,
            extraDirs: PackCatalog.projectDirs(activePack: "musicvideo"))
        let runtime = RecordingRuntime(backend: .claudeCode)
        let document = try await VideoProject.load(from: home, agentService: makeService(runtime))
        let flow = MusicvideoHostFlowAcceptance(document: document, projectURL: home, runtime: runtime, evidenceURL: evidenceURL)
        do {
            document.makeWindowControllers()
            document.showWindows()
            flow.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await flow.editor.refreshEngineState()
            try await flow.waitForDialog("Track", attachAs: "song")
            try flow.require(flow.editor.projectState?.nextPhaseName == "project_init", "Track did not precede Project Init")
            try flow.require(WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: flow.window) == false,
                "Empty Track intake was actionable")
            flow.service.dialogDraft.fileURLs = [track]
            try await flow.click("agent.dialog.confirm")
            try await flow.waitForDialog("Lyrics", attachAs: "lyrics")
            let song = AudioProjectLayout.songFiles(dataRoot: flow.dataRoot)
            try flow.require(song.count == 1 && song[0].lastPathComponent == track.lastPathComponent
                && (try FileDigest.sha256(of: song[0])) == (try FileDigest.sha256(of: track)),
                "Track intake changed the source identity or its readable filename")
            if let lyrics { flow.service.dialogDraft.fileURLs = [lyrics] }
            try await flow.click("agent.dialog.confirm")
            try await flow.waitForHandoff("project_init")
            try flow.require(flow.service.pendingDialog == nil, "A creative intake appeared before analysis")
            try await flow.approve("project_init")
            try await flow.waitForHandoff("analysis")
            try flow.require(flow.editor.productionSelectedPhase == "analysis", "Init approval left the old phase selected")
            return flow
        } catch {
            flow.close()
            throw error
        }
    }

    func runAnalysis() async throws {
        try await tool("run_phase", ["phase": "analysis"])
        try require(editor.pipelinePhaseExecution.snapshot?.status == .completed,
            "Analysis did not complete through the host phase coordinator")
        try require(service.pendingDialog == nil && editor.projectState?.nextPhaseName == "analysis",
            "Creative intake advanced before analysis approval")
        let readiness = await NativeGateWriter.controlReadiness(projectDir: editor.workingRoot!, phase: "analysis",
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator)
        try require(!readiness.approval.isReady, "Measured analysis was approved without interpretation")
        transitions.append("analysis.measured; approval blocked before interpretation")
        try capture("analysis-measured")
    }

    func finishPlanningIntake(sectionLabels: [String]) async throws {
        guard let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: dataRoot),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let sections = object["sections"] as? [[String: Any]], sections.count == sectionLabels.count else {
            throw Failure("The supplied labels do not cover the actual measured sections")
        }
        let labels: [[String: Any]] = try zip(sections, sectionLabels).map { section, label in
            guard let index = section["index"] as? NSNumber else { throw Failure("A measured section has no index") }
            return ["index": index.intValue, "label": label, "confidence": 1.0,
                "note": "Supplied acceptance label; no live LLM inference."]
        }
        try await tool("write_analysis_interpretation", ["tempo_multiplier": 1.0,
            "section_labels": labels, "overall_character": "Supplied acceptance interpretation of the measured track.",
            "anomalies": []])
        try await saveAndReopen(backend: .anthropicAPI, expectedPhase: "analysis")
        try await approve("analysis")
        try await waitForDialog("Existing story", attachAs: "script")
        try require(editor.productionSelectedPhase == "brief", "Analysis approval left the old phase selected")
        try await click("agent.dialog.confirm")
        try await waitForDialog("Prepared character 1", attachAs: "character")
        try require(service.pendingDialog?.fileIntake?.completionLabel == "Skip", "First empty character has no Skip action")
        try await click("agent.dialog.complete")
        try await waitForDialog("Prepared location 1", attachAs: "location")
        try await click("agent.dialog.complete")
        try await waitForDialog("Style references", attachAs: "style")
        try await click("agent.dialog.confirm")
        try await waitForHandoff("brief")
        try require(!FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("import/script.md").path),
            "Skipping Existing story invented supplied material")
        try await tool("write_brief", ["mission": "single_release", "target_platform": "YouTube",
            "aspect_ratio": "16:9", "project_mode": "section", "concept_type": "narrative",
            "visual_medium": "live_action_realistic", "figures": "none", "lyrics_integration": "metaphorical"])
        try await approve("brief")
        try await waitForHandoff("production_design")
        try require(editor.productionSelectedPhase == "production_design", "Brief approval left the old phase selected")
        try await saveAndReopen(backend: .claudeCode, expectedPhase: "production_design")
    }

    func saveAndReopen(backend: AgentBackend, expectedPhase: String) async throws {
        try await waitUntil { !self.service.isStreaming }
        let previousMessages = service.messages.map(\.id)
        let beforeGates = try Data(contentsOf: dataRoot.appendingPathComponent(PipelineLayout.gatesFile))
        let beforeIntake = IntakeLedger.load(dataRoot: dataRoot)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: projectURL, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        recordBackendPhases()
        document.close()
        runtime = RecordingRuntime(backend: backend)
        document = try await VideoProject.load(from: projectURL, agentService: Self.makeService(runtime))
        document.makeWindowControllers()
        document.showWindows()
        window.makeKeyAndOrderFront(nil)
        await editor.refreshEngineState()
        try require(editor.projectState?.nextPhaseName == expectedPhase && service.pendingDialog == nil,
            "Save/reopen restarted completed intake or changed the current phase")
        try require(service.messages.map(\.id) == previousMessages, "Save/reopen lost the actual agent transcript")
        try require(try Data(contentsOf: dataRoot.appendingPathComponent(PipelineLayout.gatesFile)) == beforeGates,
            "Save/reopen changed approval bytes")
        try require(IntakeLedger.load(dataRoot: dataRoot) == beforeIntake, "Save/reopen lost intake decisions")
        try require(editor.continueProductionPhase(expectedPhase), "The reopened phase could not continue")
        try await waitForHandoff(expectedPhase, hidden: false)
        savedAndReopened = true
        transitions.append("saved and reopened \(expectedPhase) with \(backend.runtimeID.rawValue)")
    }

    func report() -> Report {
        recordBackendPhases()
        return Report(transitions: transitions, backendPhases: backendPhases, savedAndReopened: savedAndReopened,
            screenshots: screenshots)
    }

    func close() {
        service.cancel()
        document.close()
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func approve(_ phase: String) async throws {
        try await tool("approve_gate", ["phase": phase])
        try require(service.pendingGateApproval?.phase == phase, "The phase writer bypassed host approval")
        try await click("agent.gate.approve")
        try await waitUntil { self.service.pendingGateApproval == nil || self.service.gateApprovalError != nil }
        try require(service.gateApprovalError == nil, "Host approval failed: \(service.gateApprovalError ?? "unknown")")
        await editor.refreshEngineState()
        let gates = try YAMLArtifactStore(dataRoot: dataRoot).load(Gates.self, at: PipelineLayout.gatesFile)
        try require(gates.get(phase).approved, "The clicked host approval did not persist")
        transitions.append("approved \(phase)")
    }

    private func tool(_ name: String, _ args: [String: Any]) async throws {
        try await waitUntil { !self.service.isStreaming }
        guard let session = service.currentSessionId else { throw Failure("No host session owns this phase") }
        var arguments = args
        arguments["project_dir"] = dataRoot.path
        let result = await ToolExecutor(editor: editor).execute(name: name, args: arguments,
            origin: .inAppChat(sessionID: session), toolUseID: "acceptance-\(UUID().uuidString)")
        if result.isError { throw Failure("\(name) failed: \(result.content)") }
    }

    private func waitForDialog(_ title: String, attachAs: String) async throws {
        try await waitUntil {
            self.service.pendingDialog?.title == title && self.service.pendingDialog?.fileIntake?.attachAs == attachAs
                && WorkspaceUIAcceptance.probeText(identifier: "agent.dialog.title", in: self.window) == title
        }
        transitions.append(title)
        try capture(attachAs)
    }

    private func waitForHandoff(_ phase: String, hidden: Bool = true) async throws {
        try await waitUntil { self.runtime.phases.contains(phase) && !self.service.isStreaming }
        try require(editor.projectState?.nextPhaseName == phase && service.pendingDialog == nil,
            "The runtime received the wrong workflow phase")
        guard let message = service.messages.last(where: { $0.role == .user }) else {
            throw Failure("No actual message carried the phase handoff")
        }
        if hidden { try require(message.hidden && message.userPresentation == nil, "An automatic handoff became a user turn") }
        transitions.append("handoff \(phase)")
        try capture(phase)
    }

    private func capture(_ name: String) throws {
        guard let view = window.contentView else { throw Failure("The host window has no content") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("The host window could not be captured") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Host capture could not be encoded") }
        let filename = "hostflow-\(screenshots.count)-\(name).png"
        try data.write(to: evidenceURL.appendingPathComponent(filename), options: .atomic)
        screenshots.append(filename)
    }

    private func click(_ identifier: String) async throws {
        try await waitUntil {
            self.window.contentView?.layoutSubtreeIfNeeded()
            return WorkspaceUIAcceptance.probeState(identifier: identifier, in: self.window) == true
        }
        if let failure = WorkspaceUIAcceptance.click(identifier: identifier, in: window) {
            throw Failure("\(identifier) is unreachable: \(failure)")
        }
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Hostflow did not settle: phase=\(editor.projectState?.nextPhaseName ?? "none"), dialog=\(service.pendingDialog?.title ?? "none"), error=\(service.dialogSubmissionError ?? service.streamError?.localizedDescription ?? "none")")
    }

    private func recordBackendPhases() {
        let key = runtime.descriptor.identity.backendID.rawValue
        backendPhases[key] = (backendPhases[key] ?? []) + runtime.phases
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private static func makeService(_ runtime: RecordingRuntime) -> AgentService {
        AgentService(backend: runtime.backend, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil })
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class RecordingRuntime: AgentRuntimeAdapter {
        let backend: AgentBackend
        let descriptor: AgentRuntimeDescriptor
        private(set) var state: AgentRuntimeState = .idle
        private(set) var phases: [String] = []
        private var phase: String?

        init(backend: AgentBackend) {
            self.backend = backend
            descriptor = backend.runtimeDescriptor(toolNames: [], providerExtensions: [])
        }

        func start(_ request: AgentRuntimeSessionRequest) throws {
            guard request.hostContext.pack?.id == "musicvideo", let phase = request.hostContext.pack?.currentPhase,
                  let instructions = request.hostContext.phaseInstructions, !instructions.isEmpty,
                  let working = request.workingDirectory, let root = DataRootResolver.dataRoot(of: working) else {
                throw Failure("The actual backend request omitted the current pack phase instructions")
            }
            let projectState = try JSONDecoder().decode(ProjectStateData.self, from: NativeCockpitReader.stateJSON(dataRoot: root))
            let headings = ["project_init": "# Phase K0 — Project Init", "analysis": "# Phase A2 — Analysis",
                "brief": "# Phase K1 — Brief", "production_design": "# Phase K2 — Production Design"]
            guard projectState.nextPhaseName == phase,
                  headings[phase].map({ instructions.contains($0) }) ?? true else {
                throw Failure("Backend request used another phase's packaged instructions")
            }
            self.phase = phase
            state = .ready(sessionID: request.sessionID)
        }

        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }

        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            guard let phase else { throw Failure("A backend turn started without phase context") }
            phases.append(phase)
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            return AsyncStream { continuation in
                continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                    event: .text(messageID: nil, value: "Acceptance transport received \(phase).", isDelta: false)))
                continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                    event: .terminal(.completed(.endTurn))))
                continuation.finish()
            }
        }

        func cancel(sessionID: UUID) { state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { state = .ended(sessionID: sessionID) }
    }
}
