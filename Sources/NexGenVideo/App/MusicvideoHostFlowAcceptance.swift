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
        let nativeGateApprovals: [MusicvideoNativeAcceptance.GateEvidence]
        let nativeIntakeEvidence: [String]
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
    private var nativeIntakeEvidence: [String] = []
    private(set) var gateApprovals: [MusicvideoNativeAcceptance.GateEvidence] = []
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
        NSDocumentController.shared.addDocument(document)
        MusicvideoNativeAcceptance.register(editor: document.editorViewModel, runtime: runtime)
        let flow = MusicvideoHostFlowAcceptance(document: document, projectURL: home, runtime: runtime, evidenceURL: evidenceURL)
        do {
            document.makeWindowControllers()
            document.showWindows()
            flow.window.setContentSize(AppTheme.Window.projectMin)
            flow.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await flow.editor.refreshEngineState()
            try await flow.waitForDialog("Track", attachAs: "song")
            try flow.require(flow.editor.projectState?.nextPhaseName == "project_init", "Track did not precede Project Init")
            try flow.require(WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: flow.window) == false,
                "Empty Track intake was actionable")
            let intakeDriver = ProductionVisualSourcesDriver(window: flow.window, output: evidenceURL, name: "hostflow-track-lyrics")
            try await intakeDriver.chooseFile(track, in: flow.window, trigger: "agent.dialog.choose-file")
            try await intakeDriver.click("agent.dialog.confirm", in: flow.window)
            try await flow.waitForDialog("Lyrics", attachAs: "lyrics")
            let song = AudioProjectLayout.songFiles(dataRoot: flow.dataRoot)
            try flow.require(song.count == 1 && song[0].lastPathComponent == track.lastPathComponent
                && (try FileDigest.sha256(of: song[0])) == (try FileDigest.sha256(of: track)),
                "Track intake changed the source identity or its readable filename")
            if let lyrics { try await intakeDriver.chooseFile(lyrics, in: flow.window, trigger: "agent.dialog.choose-file") }
            try await intakeDriver.click("agent.dialog.confirm", in: flow.window)
            try await flow.waitForHandoff("project_init")
            try flow.require(flow.service.pendingDialog == nil, "A creative intake appeared before analysis")
            try FileManager.default.copyItem(at: track, to: evidenceURL.appendingPathComponent("intake-track-source.bin"))
            try FileManager.default.copyItem(at: song[0], to: evidenceURL.appendingPathComponent("intake-track-assigned.bin"))
            try intakeDriver.record("native Track and optional Lyrics intake", fields: ["trackName": track.lastPathComponent,
                "trackSHA256": try FileDigest.sha256(of: track), "lyricsSupplied": lyrics != nil,
                "nextPhase": "project_init", "creativeIntakeAbsent": true])
            try flow.recordIntake(intakeDriver)
            try await flow.approve("project_init")
            try await flow.waitForHandoff("analysis")
            try flow.require(flow.editor.productionSelectedPhase == "analysis", "Init approval left the old phase selected")
            return flow
        } catch {
            flow.close()
            throw error
        }
    }

    func runAnalysis(configureAudioAnalysis: @escaping ToolExecutor.AudioAnalysisConfiguration = { AudioAnalysisRuntime.configure($0) }) async throws {
        try await tool("run_phase", ["phase": "analysis"],
            executor: ToolExecutor(editor: editor, configureAudioAnalysis: configureAudioAnalysis))
        try require(editor.pipelinePhaseExecution.snapshot?.status == .completed,
            "Analysis did not complete through the host phase coordinator")
        try require(service.pendingDialog == nil && editor.projectState?.nextPhaseName == "analysis",
            "Creative intake advanced before analysis approval")
        guard let requirement = PackCatalog.registry(activePack: editor.declaredPluginName).artifactWriteRequirements["analysis"] else {
            throw Failure("The loaded pack has no measured-analysis write requirement")
        }
        try requirement(dataRoot)
        let readiness = await NativeGateWriter.controlReadiness(projectDir: editor.workingRoot!, phase: "analysis",
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator)
        try require(!readiness.approval.isReady, "Measured analysis was approved without interpretation")
        transitions.append("analysis.measured; approval blocked before interpretation")
        try capture("analysis-measured")
    }

    func finishPlanningIntake(sectionLabels: [String], finalResolution: VideoResolution = .res1080p,
                              conceptType: ConceptType = .narrative,
                              beforeBriefApproval: (@MainActor (EditorViewModel) async throws -> Void)? = nil) async throws {
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
        let reference = FileManager.default.temporaryDirectory.appendingPathComponent("Stage-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: reference) }
        try FullflowAcceptanceFixture.writeReference(to: reference)
        try require(WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: window) == false,
            "An empty prepared location was actionable")
        let intakeDriver = ProductionVisualSourcesDriver(window: window, output: evidenceURL, name: "hostflow-repeatable-intake")
        try await intakeDriver.chooseFile(nil, in: window, trigger: "agent.dialog.choose-file")
        try require(service.dialogDraft.fileURLs.isEmpty && service.dialogDraft.direction.isEmpty,
            "Canceling the picker changed the prepared location")
        try await intakeDriver.chooseFile(reference, in: window, trigger: "agent.dialog.choose-file")
        try require(WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: window) == false
            && WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.complete", in: window) == false,
            "A reference without an identity name can bypass the repeatable intake")
        try intakeDriver.capture("location-without-name", target: window)
        try await intakeDriver.fill("agent.dialog.direction", value: "Stage", in: window)
        try require(service.dialogDraft.direction == "Stage", "Native identity input did not reach the actual draft")
        try await intakeDriver.click("agent.dialog.confirm", in: window)
        try await waitForDialog("Prepared location 2", attachAs: "location")
        try require(service.pendingDialog?.fileIntake?.completionLabel == "Done", "The completed location has no Done action")
        let confirmed = try ConfirmedIdentityAssetStoreV1.load(dataRoot: dataRoot).entries.values.filter {
            $0.role == .location && $0.identitySlug == "stage"
        }
        try require(confirmed.count == 1 && confirmed[0].sha256 == (try FileDigest.sha256(of: reference)),
            "Native location intake did not confirm the exact supplied image")
        let completeManifest = try ConfirmedIdentityAssetStoreV1.load(dataRoot: dataRoot)
        try JSONEncoder().encode(completeManifest).write(to: evidenceURL.appendingPathComponent("intake-before-partial.json"))
        try await intakeDriver.fill("agent.dialog.direction", value: "Unfinished location", in: window)
        try require(WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: window) == false
            && WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.complete", in: window) == false,
            "An unfinished repeated location can be attached or discarded with Done")
        try intakeDriver.visible(["agent.dialog.confirm", "agent.dialog.complete", "agent.dialog.clear-item"], in: window)
        try intakeDriver.capture("second-location-incomplete", target: window)
        try await intakeDriver.click("agent.dialog.clear-item", in: window)
        try await intakeDriver.wait("clear incomplete repeated location") {
            self.service.dialogDraft.direction.isEmpty && self.service.dialogDraft.fileURLs.isEmpty
                && WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.complete", in: self.window) == true
                && WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: self.window) == false
        }
        try await intakeDriver.click("agent.dialog.complete", in: window)
        try await waitForDialog("Style references", attachAs: "style")
        let afterManifest = try ConfirmedIdentityAssetStoreV1.load(dataRoot: dataRoot)
        try require(afterManifest == completeManifest, "Clearing the second item lost or invented a confirmed identity")
        try JSONEncoder().encode(afterManifest).write(to: evidenceURL.appendingPathComponent("intake-after-partial.json"))
        try Data(contentsOf: reference).write(to: evidenceURL.appendingPathComponent("intake-location.png"))
        try Data(contentsOf: ProjectLocalFile.requireHash(confirmed[0].sha256, at: confirmed[0].path, dataRoot: dataRoot))
            .write(to: evidenceURL.appendingPathComponent("intake-confirmed-location.png"))
        try intakeDriver.record("native incomplete repeated location", fields: ["firstName": "Stage", "nextTitle": "Prepared location 2",
            "partialName": "Unfinished location", "sourceSHA256": confirmed[0].sha256, "confirmedID": confirmed[0].id,
            "fileWithoutNameBlocked": true, "partialAttachBlocked": true, "partialDoneBlocked": true,
            "clearPreservedConfirmedIdentity": true, "doneAdvancedToStyle": true])
        try recordIntake(intakeDriver)
        try await click("agent.dialog.confirm")
        try await waitForHandoff("brief")
        if let index = gateApprovals.firstIndex(where: { $0.phase == "analysis" }), let handoff = runtime.handoffs.last {
            gateApprovals[index].handoffPhase = handoff.phase
            gateApprovals[index].handoffHidden = service.messages.last(where: { $0.role == .user })?.hidden == true
            gateApprovals[index].packagedInstructions = handoff.phase == "brief" && handoff.instructionsSHA256 != nil
            gateApprovals[index].handoffTurnID = handoff.turnID
            gateApprovals[index].handoffInstructionsSHA256 = handoff.instructionsSHA256
        }
        try require(!FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("import/script.md").path),
            "Skipping Existing story invented supplied material")
        try await tool("record_affect", ["detected": [["tag": "meditative", "weight": 1.0]],
            "basis": "inferred", "rationale": "Supplied acceptance interpretation; no live LLM inference."])
        try await tool("write_brief", ["mission": "single_release", "target_platform": "YouTube",
            "aspect_ratio": "16:9", "project_mode": "section", "concept_type": conceptType.rawValue,
            "visual_medium": "live_action_realistic", "figures": "none", "lyrics_integration": "metaphorical",
            "final_resolution": finalResolution.rawValue])
        try await beforeBriefApproval?(editor)
        try await approve("brief")
        try await waitForHandoff("production_design")
        try require(editor.productionSelectedPhase == "production_design", "Brief approval left the old phase selected")
        try await saveAndReopen(backend: .claudeCode, expectedPhase: "production_design")
    }

    func saveAndReopen(backend: AgentBackend, expectedPhase: String) async throws {
        try await waitUntil("agent idle before saving \(expectedPhase)") { !self.service.isStreaming }
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
        NSDocumentController.shared.addDocument(document)
        MusicvideoNativeAcceptance.register(editor: document.editorViewModel, runtime: runtime)
        document.makeWindowControllers()
        document.showWindows()
        window.setContentSize(AppTheme.Window.projectMin)
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
            screenshots: screenshots, nativeGateApprovals: gateApprovals, nativeIntakeEvidence: nativeIntakeEvidence)
    }

    func close() {
        service.cancel()
        document.close()
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func approve(_ phase: String) async throws {
        gateApprovals.append(try await MusicvideoNativeAcceptance.approve(phase, editor: editor,
            evidenceURL: evidenceURL, awaitHandoff: phase != "analysis"))
        transitions.append("approved \(phase)")
    }

    private func tool(_ name: String, _ args: [String: Any], executor: ToolExecutor? = nil) async throws {
        try await waitUntil("agent idle before \(name)") { !self.service.isStreaming }
        guard let session = service.currentSessionId else { throw Failure("No host session owns this phase") }
        var arguments = args
        arguments["project_dir"] = dataRoot.path
        let result = await (executor ?? ToolExecutor(editor: editor)).execute(name: name, args: arguments,
            origin: .inAppChat(sessionID: session), toolUseID: "acceptance-\(UUID().uuidString)")
        if result.isError { throw Failure("\(name) failed: \(result.content)") }
    }

    private func waitForDialog(_ title: String, attachAs: String) async throws {
        try await waitUntil("dialog \(title)") {
            self.service.pendingDialog?.title == title && self.service.pendingDialog?.fileIntake?.attachAs == attachAs
                && WorkspaceUIAcceptance.probeText(identifier: "agent.dialog.title", in: self.window) == title
        }
        transitions.append(title)
        try capture(attachAs)
    }

    private func waitForHandoff(_ phase: String, hidden: Bool = true) async throws {
        try await waitUntil("handoff to \(phase)") {
            if let error = self.service.streamError {
                throw Failure("Hostflow handoff to \(phase) failed: \(error.localizedDescription)")
            }
            return self.runtime.phases.contains(phase) && !self.service.isStreaming
        }
        try require(editor.projectState?.nextPhaseName == phase && service.pendingDialog == nil,
            "The runtime received the wrong workflow phase")
        guard let message = service.messages.last(where: { $0.role == .user }) else {
            throw Failure("No actual message carried the phase handoff")
        }
        if hidden { try require(message.hidden && message.userPresentation == nil, "An automatic handoff became a user turn") }
        transitions.append("handoff \(phase)")
        try capture(phase)
    }

    private func recordIntake(_ driver: ProductionVisualSourcesDriver) throws {
        let name = driver.name + "-result.json"
        try JSONSerialization.data(withJSONObject: driver.result(), options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceURL.appendingPathComponent(name), options: .atomic)
        nativeIntakeEvidence.append(name)
        screenshots.append(contentsOf: driver.screenshots)
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
        try await waitUntil("control \(identifier)") {
            self.window.contentView?.layoutSubtreeIfNeeded()
            return WorkspaceUIAcceptance.probeState(identifier: identifier, in: self.window) == true
        }
        if let failure = WorkspaceUIAcceptance.click(identifier: identifier, in: window) {
            throw Failure("\(identifier) is unreachable: \(failure)")
        }
    }

    private func waitUntil(_ step: String = "native host control", _ ready: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if try ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure("Hostflow did not settle (\(step)): phase=\(editor.projectState?.nextPhaseName ?? "none"), dialog=\(service.pendingDialog?.title ?? "none"), recorded=\(runtime.phases.joined(separator: ",")), error=\(service.dialogSubmissionError ?? service.streamError?.localizedDescription ?? "none")")
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

    final class RecordingRuntime: AgentRuntimeAdapter {
        struct Handoff {
            let turnID: String
            let phase: String
            let instructionsSHA256: String?
        }
        let backend: AgentBackend
        let descriptor: AgentRuntimeDescriptor
        private(set) var state: AgentRuntimeState = .idle
        private(set) var handoffs: [Handoff] = []
        var phases: [String] { handoffs.map(\.phase) }
        private var phase: String?
        private var instructionsSHA256: String?

        init(backend: AgentBackend) {
            self.backend = backend
            descriptor = backend.runtimeDescriptor(toolNames: [], providerExtensions: [])
        }

        func start(_ request: AgentRuntimeSessionRequest) throws {
            guard let pack = request.hostContext.pack, pack.id == "musicvideo",
                  let working = request.workingDirectory, let root = DataRootResolver.dataRoot(of: working) else {
                throw Failure("The actual backend request omitted the current pack phase instructions")
            }
            guard let binding = ProjectPackBinding(id: pack.id, version: pack.version, projectSchema: pack.projectSchema),
                  let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: binding, expectedProductionContract: nil) else {
                throw Failure("The recording runtime has no exact loaded workflow identity")
            }
            let projectState = try JSONDecoder().decode(ProjectStateData.self,
                from: NativeCockpitReader.stateJSON(dataRoot: root, activePack: pack.id, workflow: workflow))
            if projectState.isComplete {
                guard request.hostContext.pack?.currentPhase == nil, request.hostContext.phaseInstructions == nil else {
                    throw Failure("The completed workflow invented another phase or phase instructions")
                }
                phase = "complete"
                instructionsSHA256 = nil
                state = .ready(sessionID: request.sessionID)
                return
            }
            if workflow.isProductionV2 {
                guard let phase = pack.currentPhase, projectState.nextPhaseName == phase,
                      let instructions = request.hostContext.phaseInstructions else {
                    throw Failure("The V2 runtime request omitted its actual current phase")
                }
                let exact = try PhaseContractRuntime.contract(workflow: workflow).instructions(for: phase)
                guard !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instructions.contains(exact) else {
                    throw Failure("The V2 runtime request omitted the exact packaged phase document")
                }
                if ["treatment", "script", "storyboard", "shot_planning", "shotlist", "render_review", "render"].contains(phase) {
                    let requiredKnowledge = [
                        "Keep the original song once at timeline zero; mute provider song audio so generated clips cannot double or replace it.",
                        "A voice has one visible mouth owner within the phrase",
                        "Dance roles requiring the full body also preserve floor contact",
                    ]
                    guard requiredKnowledge.allSatisfy(instructions.contains) else {
                        throw Failure("The V2 runtime request omitted the actual selected music-performance guidance for " + phase)
                    }
                }
                self.phase = phase
                instructionsSHA256 = FileDigest.sha256(of: Data(instructions.utf8))
                state = .ready(sessionID: request.sessionID)
                return
            }
            let headings = ["project_init": "# Phase K0 — Project Init", "analysis": "# Phase A2 — Analysis",
                "brief": "# Phase K1 — Brief", "production_design": "# Phase K2 — Production Design",
                "treatment": "# Phase K3 — Treatment", "storyboard": "# Phase K4 — Storyboard",
                "bible": "# Phase K5 — Bible", "shotlist": "# Phase K7 — Shotlist",
                "sanity": "# Phase S — Sanity Audit", "frames": "# Phase F — Frames", "render": "# Phase R1/R2 — Render"]
            guard let phase = pack.currentPhase, projectState.nextPhaseName == phase else {
                throw Failure("Backend phase mismatch: host=\(pack.currentPhase ?? "none"), project=\(projectState.nextPhaseName ?? "none"), pack=\(pack.id)")
            }
            guard let heading = headings[phase], let instructions = request.hostContext.phaseInstructions,
                  instructions.contains(heading) else {
                throw Failure("Backend request omitted the packaged instructions for \(phase)")
            }
            self.phase = phase
            instructionsSHA256 = FileDigest.sha256(of: Data(instructions.utf8))
            state = .ready(sessionID: request.sessionID)
        }

        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }

        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            guard let phase else { throw Failure("A backend turn started without phase context") }
            handoffs.append(Handoff(turnID: request.turnID.uuidString, phase: phase, instructionsSHA256: instructionsSHA256))
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
