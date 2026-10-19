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
        let nativeProjectCreation: String?
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
    private var nativeProjectCreation: String?
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

    static func start(track: URL, lyrics: URL?, binding: ProjectPackBinding, evidenceURL: URL,
                      toolExecutorFactory: (@MainActor (EditorViewModel) -> ToolExecutor)? = nil,
                      nativeCreation: Bool = false) async throws -> MusicvideoHostFlowAcceptance {
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        let runtime = RecordingRuntime(backend: .claudeCode)
        let home: URL
        let document: VideoProject
        if nativeCreation {
            let created = try await NativeNewMusicvideoAcceptance.create(
                service: makeService(runtime, toolExecutorFactory: toolExecutorFactory), binding: binding, output: evidenceURL)
            document = created.0
            home = created.1
        } else {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("MusicvideoHostFlow-\(UUID().uuidString).ngv")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try JSONEncoder().encode(Timeline()).write(to: home.appendingPathComponent(Project.timelineFilename))
            try JSONEncoder().encode(MediaManifest()).write(to: home.appendingPathComponent(Project.manifestFilename))
            try JSONEncoder().encode(GenerationLog()).write(to: home.appendingPathComponent(Project.generationLogFilename))
            _ = try ProjectIdentity.uuid(for: home)
            try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
            let root = try ProjectScaffold.initProject(home: home, name: "Musicvideo host flow", mode: .beat,
                extraDirs: PackCatalog.projectDirs(activePack: "musicvideo"))
            if let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: binding, expectedProductionContract: nil),
               workflow.isProductionV2 {
                try PhaseContractRuntime.initializeWorkflowState(dataRoot: root, workflow: workflow)
            }
            document = try await VideoProject.load(from: home, agentService: makeService(runtime, toolExecutorFactory: toolExecutorFactory))
        }
        if !NSDocumentController.shared.documents.contains(where: { $0 === document }) {
            NSDocumentController.shared.addDocument(document)
        }
        MusicvideoNativeAcceptance.register(editor: document.editorViewModel, runtime: runtime)
        let flow = MusicvideoHostFlowAcceptance(document: document, projectURL: home, runtime: runtime, evidenceURL: evidenceURL)
        flow.nativeProjectCreation = nativeCreation ? "hostflow-new-project-result.json" : nil
        do {
            if document.windowControllers.isEmpty { document.makeWindowControllers() }
            document.showWindows()
            flow.window.setContentSize(AppTheme.Window.projectMin)
            flow.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await flow.editor.refreshEngineState()
            try await flow.beginTrackIntake(track: track, lyrics: lyrics)
            return flow
        } catch {
            flow.close()
            throw error
        }
    }

    static func openExisting(projectURL: URL, evidenceURL: URL) async throws -> MusicvideoHostFlowAcceptance {
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        let runtime = RecordingRuntime(backend: .claudeCode)
        let document = try await VideoProject.load(from: projectURL, agentService: makeService(runtime))
        NSDocumentController.shared.addDocument(document)
        MusicvideoNativeAcceptance.register(editor: document.editorViewModel, runtime: runtime)
        document.makeWindowControllers()
        document.showWindows()
        let flow = MusicvideoHostFlowAcceptance(document: document, projectURL: projectURL, runtime: runtime, evidenceURL: evidenceURL)
        flow.window.setContentSize(AppTheme.Window.projectMin)
        flow.window.makeKeyAndOrderFront(nil)
        await flow.editor.refreshEngineState()
        return flow
    }

    func beginTrackIntake(track: URL, lyrics: URL?) async throws {
        try await waitForDialog("Track", attachAs: "song")
        try require(editor.projectState?.nextPhaseName == "project_init", "Track did not precede Project Init")
        try require(WorkspaceUIAcceptance.probeState(identifier: "agent.dialog.confirm", in: window) == false,
            "Empty Track intake was actionable")
        let intakeDriver = ProductionVisualSourcesDriver(window: window, output: evidenceURL, name: "hostflow-track-lyrics")
        try await intakeDriver.chooseFile(track, in: window, trigger: "agent.dialog.choose-file")
        try await intakeDriver.click("agent.dialog.confirm", in: window)
        try await waitForDialog("Lyrics", attachAs: "lyrics")
        let song = AudioProjectLayout.songFiles(dataRoot: dataRoot)
        try require(song.count == 1 && song[0].lastPathComponent == track.lastPathComponent
            && (try FileDigest.sha256(of: song[0])) == (try FileDigest.sha256(of: track)),
            "Track intake changed the source identity or its readable filename")
        if let lyrics { try await intakeDriver.chooseFile(lyrics, in: window, trigger: "agent.dialog.choose-file") }
        try await intakeDriver.click("agent.dialog.confirm", in: window)
        try await waitForHandoff("project_init")
        try require(service.pendingDialog == nil, "A creative intake appeared before analysis")
        try Data(contentsOf: track, options: .mappedIfSafe).write(to: evidenceURL.appendingPathComponent("intake-track-source.bin"), options: .atomic)
        try Data(contentsOf: song[0], options: .mappedIfSafe).write(to: evidenceURL.appendingPathComponent("intake-track-assigned.bin"), options: .atomic)
        try intakeDriver.record("native Track and optional Lyrics intake", fields: ["projectKey": editor.projectId ?? "", "settingsSHA256": try Self.retainIntakeProject(editor: editor, output: evidenceURL), "trackName": track.lastPathComponent,
            "trackSHA256": try FileDigest.sha256(of: track), "lyricsSupplied": lyrics != nil,
            "lyricsName": lyrics?.lastPathComponent as Any? ?? NSNull(),
            "nextPhase": "project_init", "creativeIntakeAbsent": true])
        try recordIntake(intakeDriver)
        try await approve("project_init")
        try await waitForHandoff("analysis")
        try require(editor.productionSelectedPhase == "analysis", "Init approval left the old phase selected")
    }

    func runAnalysisOnNextNativeTurn() { runtime.runAnalysisOnNextTurn = true }
    var nativeAnalysisResults: [ToolResult] { runtime.analysisResults }
    var nativeAnalysisRequests: [[String]] { runtime.analysisRequests }

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
                              conceptType: ConceptType = .narrative, reconfirmRangeAfterReanalysis: Bool = false,
                              beforeBriefApproval: (@MainActor (EditorViewModel) async throws -> Void)? = nil) async throws {
        try await finishAnalysis(sectionLabels: sectionLabels)
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
        try await finishBrief(finalResolution: finalResolution, conceptType: conceptType,
            sectionLabels: sectionLabels, reconfirmRangeAfterReanalysis: reconfirmRangeAfterReanalysis,
            beforeBriefApproval: beforeBriefApproval)
        try await saveAndReopen(backend: .claudeCode, expectedPhase: "production_design")
    }

    private func finishBrief(finalResolution: VideoResolution, conceptType: ConceptType,
                             sectionLabels: [String], reconfirmRangeAfterReanalysis: Bool = false,
                             beforeBriefApproval: (@MainActor (EditorViewModel) async throws -> Void)? = nil) async throws {
        try await tool("record_affect", ["detected": [["tag": "meditative", "weight": 1.0]],
            "basis": "inferred", "rationale": "Supplied acceptance interpretation; no live LLM inference."])
        try await tool("write_brief", ["mission": "single_release", "target_platform": "YouTube",
            "aspect_ratio": "16:9", "project_mode": "section", "concept_type": conceptType.rawValue,
            "visual_medium": "live_action_realistic", "figures": "none", "lyrics_integration": "metaphorical",
            "final_resolution": finalResolution.rawValue])
        try await finishBriefObservation(beforeBriefApproval, reanalyze: reconfirmRangeAfterReanalysis, sectionLabels: sectionLabels, finalResolution: finalResolution, conceptType: conceptType)
        try await approve("brief")
        try await waitForHandoff("production_design")
        try require(editor.productionSelectedPhase == "production_design", "Brief approval left the old phase selected")
    }

    func finishPreviousWorkflowIntake(historyFingerprint: String, storySHA256: String,
                                      identitySHA256: String) async throws -> [[String: String]] {
        let driver = ProductionVisualSourcesDriver(window: window, output: evidenceURL, name: "resume172-previous-material")
        var selected: [[String: String]] = []
        @MainActor func choose(_ role: PreviousWorkflowMaterialRole, hash: String) async throws {
            guard let dialog = service.pendingDialog, let scope = service.previousWorkflowMaterialScope(for: dialog),
                  scope.role == role else { throw Failure("The actual intake has no matching previous-material scope") }
            let catalog = try await service.previousWorkflowMaterials(scope: scope)
            let matches = catalog.items.filter { $0.selection.historyFingerprint == historyFingerprint
                && $0.role == role && $0.selection.expectedFiles.contains(where: { $0.sha256 == hash }) }
            guard matches.count == 1, let item = matches.first else {
                throw Failure("The original approved material is not offered exactly once in the actual scoped picker")
            }
            let messages = service.messages.map(\.id)
            try await driver.click("agent.dialog.previous-workflow.open", in: window)
            try await driver.click("agent.dialog.previous-workflow.choice." + item.id, in: window)
            try await driver.wait("actual previous material selected") {
                driver.text("agent.dialog.previous-workflow.selected", in: self.window) == item.id
                    && self.service.dialogDraft.previousWorkflowSelection == item.selection
            }
            try require(service.messages.map(\.id) == messages && service.dialogDraft.fileURLs.isEmpty,
                "Selecting previous material invented a user turn or a file-picker selection")
            try require(driver.text("agent.dialog.previous-workflow.open", in: window) == "collapsed",
                "Choosing previous material did not collapse its disclosure")
            try await driver.click("agent.dialog.previous-workflow.open", in: window)
            try await driver.click("agent.dialog.previous-workflow.open", in: window)
            try require(driver.text("agent.dialog.previous-workflow.selected", in: window) == item.id,
                "Collapsing the previous-material list lost its selection")
            if role == .script {
                try await driver.fill("agent.dialog.direction", value: "Temporary native story edit", in: window)
                try await driver.wait("typed story replaces the previous selection") {
                    self.service.dialogDraft.previousWorkflowSelection == nil
                        && driver.text("agent.dialog.previous-workflow.selected", in: self.window) == nil
                }
                try await driver.click("agent.dialog.previous-workflow.open", in: window)
                try await driver.click("agent.dialog.previous-workflow.choice." + item.id, in: window)
                try await driver.wait("original previous story selected again") {
                    self.service.dialogDraft.previousWorkflowSelection == item.selection && self.service.dialogDraft.direction.isEmpty
                }
            } else {
                let originalName = driver.text("agent.dialog.direction", in: window) ?? ""
                try require(!originalName.isEmpty, "The selected identity has no visible name")
                try await driver.fill("agent.dialog.direction", value: originalName + " revised", in: window)
                try require(service.dialogDraft.previousWorkflowSelection == item.selection,
                    "Editing the identity name discarded its previous-material selection")
                try await driver.fill("agent.dialog.direction", value: originalName, in: window)
            }
            try driver.capture("selected-previous-" + role.rawValue, target: window)
            selected.append(["role": role.rawValue, "materialID": item.id, "historyFingerprint": historyFingerprint,
                "sourceSHA256": hash])
            try await driver.click("agent.dialog.confirm", in: window)
        }
        try await waitForDialog("Existing story", attachAs: "script")
        try await choose(.script, hash: storySHA256)
        try await waitForDialog("Prepared character 1", attachAs: "character")
        try await driver.click("agent.dialog.complete", in: window)
        try await waitForDialog("Prepared location 1", attachAs: "location")
        try await choose(.location, hash: identitySHA256)
        try await waitForDialog("Prepared location 2", attachAs: "location")
        guard let dialog = service.pendingDialog, let scope = service.previousWorkflowMaterialScope(for: dialog) else {
            throw Failure("The repeated intake lost its scope after actual confirmation")
        }
        let remaining = try await service.previousWorkflowMaterials(scope: scope)
        try require(!remaining.items.contains(where: { $0.selection.historyFingerprint == historyFingerprint && $0.identityName == "Stage" }),
            "A currently confirmed Stage identity was offered again")
        let manifest = try ConfirmedIdentityAssetStoreV1.load(dataRoot: dataRoot)
        let identities = manifest.entries.values.filter { $0.role == .location && $0.identitySlug == "stage" && $0.sha256 == identitySHA256 }
        try require(identities.count == 1, "The actual historical location confirmation did not retain the original image bytes")
        try require(try FileDigest.sha256(of: dataRoot.appendingPathComponent("import/script.md")) == storySHA256,
            "The actual historical story confirmation did not retain the original text bytes")
        try JSONEncoder().encode(manifest).write(to: evidenceURL.appendingPathComponent("resume172-confirmed-identities.json"))
        try await driver.click("agent.dialog.complete", in: window)
        try await waitForDialog("Style references", attachAs: "style")
        try await driver.click("agent.dialog.confirm", in: window)
        try await waitForHandoff("brief", hidden: false)
        try driver.record("explicit previous-workflow material intake", fields: ["selected": selected,
            "confirmedIdentityID": identities[0].id, "storySHA256": storySHA256, "identitySHA256": identitySHA256,
            "projectID": editor.projectId ?? ""])
        try recordIntake(driver)
        try await finishBrief(finalResolution: .res720p, conceptType: .abstract, sectionLabels: ["opening"])
        return selected
    }

    private func finishAnalysis(sectionLabels: [String]) async throws {
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
            screenshots: screenshots, nativeGateApprovals: gateApprovals, nativeIntakeEvidence: nativeIntakeEvidence,
            nativeProjectCreation: nativeProjectCreation)
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

    private static func makeService(_ runtime: RecordingRuntime,
                                    toolExecutorFactory: (@MainActor (EditorViewModel) -> ToolExecutor)? = nil) -> AgentService {
        AgentService(backend: runtime.backend, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil }, toolExecutorFactory: toolExecutorFactory)
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
            execute = request.executeTool
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
            if runAnalysisOnNextTurn {
                guard phase == "analysis", let execute else { throw Failure("Native analysis did not retain its real current host executor.") }
                runAnalysisOnNextTurn = false
                analysisRequests.append(request.currentMessage.content.compactMap { if case .text(let value) = $0 { value } else { nil } })
                return AsyncStream { continuation in
                    analysisTask = Task { @MainActor in
                        let id = UUID().uuidString, arguments = "{\"phase\":\"analysis\"}"
                        continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                            event: .toolCall(messageID: nil, id: id, name: "run_phase", inputJSON: arguments)))
                        let result = await execute(id, "run_phase", arguments)
                        analysisResults.append(result)
                        continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                            event: .toolResult(id: id, content: result.content, isError: result.isError)))
                        continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
                        continuation.finish(); state = .ready(sessionID: request.sessionID)
                    }
                }
            }
            return AsyncStream { continuation in
                continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                    event: .text(messageID: nil, value: "Acceptance transport received \(phase).", isDelta: false)))
                continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                    event: .terminal(.completed(.endTurn))))
                continuation.finish()
            }
        }

        func cancel(sessionID: UUID) { analysisTask?.cancel(); state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { analysisTask?.cancel(); state = .ended(sessionID: sessionID) }
        var runAnalysisOnNextTurn = false
        private(set) var analysisResults: [ToolResult] = []
        private(set) var analysisRequests: [[String]] = []
        private var execute: AgentRuntimeToolExecutor?
        private var analysisTask: Task<Void, Never>?
    }
}

extension MusicvideoHostFlowAcceptance {
    private static func retainIntakeProject(editor: EditorViewModel, output: URL) throws -> String {
        guard let home = editor.workingRoot, let key = editor.projectId, !key.isEmpty,
              ProjectIdentity.existingUUID(for: home) == key else { throw Failure("The actual Track intake lost its project identity") }
        let bytes = try Data(contentsOf: home.appendingPathComponent("ngv.json"))
        try bytes.write(to: output.appendingPathComponent("intake-project-ngv.json"), options: .atomic)
        return FileDigest.sha256(of: bytes)
    }
}

extension MusicvideoHostFlowAcceptance {
    private func finishBriefObservation(_ observe: (@MainActor (EditorViewModel) async throws -> Void)?, reanalyze: Bool,
                                        sectionLabels: [String], finalResolution: VideoResolution, conceptType: ConceptType) async throws {
        if reanalyze { try await reconfirmRangeAfterNativeReanalysis(sectionLabels: sectionLabels, finalResolution: finalResolution, conceptType: conceptType) }
        try await observe?(editor)
    }

    private func reconfirmRangeAfterNativeReanalysis(sectionLabels: [String], finalResolution: VideoResolution, conceptType: ConceptType) async throws {
        let driver = ProductionVisualSourcesDriver(window: window, output: evidenceURL, name: "playback-reanalysis")
        guard nativeProjectCreation != nil, editor.projectState?.nextPhaseName == "brief",
              let index = gateApprovals.firstIndex(where: { $0.phase == "analysis" }),
              let home = editor.workingRoot else { throw Failure("Playback reanalysis requires the existing native Music Video Brief") }
        let firstApproval = gateApprovals[index]
        let root = dataRoot
        func capture(_ label: String) throws -> String {
            try driver.capture(label, target: window)
            guard let name = driver.screenshots.last else { throw Failure("The actual playback observation image is missing") }
            return name
        }
        func retain(_ path: String, as name: String) throws -> [String: String] {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
            try bytes.write(to: evidenceURL.appendingPathComponent(name), options: .atomic)
            return ["path": path, "retained": name, "sha256": FileDigest.sha256(of: bytes)]
        }
        do {
            let initial = try await PipelinePlaybackRangeWriter.capture(editor: editor)
            guard !initial.requiresSelectionConfirmation, initial.audioDurationTicks > 1 else { throw Failure("The initial song range is not current") }
            try await driver.wait("actual editable song range") { driver.state("playback-range.kind", in: self.window) == true }
            try await driver.segment("playback-range.kind", title: "Excerpt", titles: ["Full song", "Excerpt"], in: window)
            try await driver.fill("playback-range.start", value: "0", in: window)
            try await driver.fill("playback-range.end", value: ProductionTimeEntry.seconds(initial.audioDurationTicks / 2, timebase: initial.timebase), in: window)
            try await driver.click("playback-range.apply", in: window)
            try await driver.wait("actual initial excerpt saved") { driver.text("playback-range.saved", in: self.window)?.hasPrefix("Saved: excerpt") == true }
            let selected = try await PipelinePlaybackRangeWriter.capture(editor: editor)
            guard selected.kind == .excerpt, let oldReceipt = selected.selectionReceipt,
                  selected.durationTicks == initial.audioDurationTicks / 2 else { throw Failure("The initial native excerpt did not persist its exact selection") }
            let oldSelection = try retain(oldReceipt.path, as: "playback-reanalysis-old-selection.json")
            let oldAnalysis = try retain(selected.analysis.path, as: "playback-reanalysis-old-analysis.json")
            _ = try capture("initial-native-excerpt")
            let beforeRewind = try retain(PipelineLayout.gatesFile, as: "playback-reanalysis-before-rewind.yaml")
            try await driver.menu("pipeline.overview.actions.analysis", title: "Rewind to here…", in: window)
            try await SettingsOwnerAcceptance.dialog("Rewind to " + PhaseDisplay.label("analysis"), driver: driver)
            try await driver.wait("actual analysis rewind") { self.editor.projectState?.nextPhaseName == "analysis" && !self.service.isStreaming }
            try await driver.click("pipeline.overview.select.analysis", in: window, enabled: false)
            let afterRewind = try retain(PipelineLayout.gatesFile, as: "playback-reanalysis-after-rewind.yaml")
            let previousResults = nativeAnalysisResults.count
            try await driver.wait("native reanalysis command enabled") { driver.state("pipeline.overview.dock.continue", in: self.window) == true && !self.service.isComposerBlocked }
            runAnalysisOnNextNativeTurn()
            try await driver.click("pipeline.overview.dock.continue", in: window)
            try await driver.wait("actual native audio reanalysis", seconds: 60) {
                !self.service.isStreaming && self.nativeAnalysisResults.count == previousResults + 1
                    && self.editor.pipelinePhaseExecution.snapshot?.status == .completed
            }
            guard nativeAnalysisResults.last?.isError == false,
                  let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root),
                  let measured = try JSONSerialization.jsonObject(with: Data(contentsOf: analysisURL)) as? [String: Any],
                  let sections = measured["sections"] as? [[String: Any]], sections.count == sectionLabels.count else { throw Failure("The actual source reanalysis failed or changed its measured section coverage") }
            let blocked = await NativeGateWriter.controlReadiness(projectDir: home, phase: "analysis",
                declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
                executionCoordinator: editor.pipelinePhaseRunCoordinator)
            guard !blocked.approval.isReady, let reason = blocked.approval.blocker else { throw Failure("Fresh measurement was incorrectly approvable before interpretation") }
            try await driver.reveal("pipeline.overview.approve.analysis", in: window)
            guard driver.state("pipeline.overview.approve.analysis", in: window) == false else { throw Failure("The actual uninterpreted analysis approval is not disabled") }
            try driver.visible(["pipeline.overview.approve.analysis"], in: window)
            let blockedImage = try capture("remeasured-analysis-blocked")
            let labels: [[String: Any]] = try zip(sections, sectionLabels).map { section, label in
                guard let number = section["index"] as? NSNumber else { throw Failure("Remeasured section lacks its actual index") }
                return ["index": number.intValue, "label": label, "confidence": 1.0, "note": "Supplied acceptance interpretation; no live inference."]
            }
            try await tool("write_analysis_interpretation", ["tempo_multiplier": 1.0, "section_labels": labels,
                "overall_character": "Supplied acceptance interpretation of the actual remeasured source.", "anomalies": []])
            let interpreted = try retain(FrameInventory.relativePath(of: analysisURL, to: root), as: "playback-reanalysis-current-analysis.json")
            let gatesBefore = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
            try await tool("approve_gate", ["phase": "analysis"])
            try await driver.click("pipeline.overview.select.project_init", in: window, enabled: false)
            try await driver.wait("actual reanalysis approval artifact available") { driver.state("agent.gate.open", in: self.window) == true }
            try await driver.click("agent.gate.open", in: window)
            try await driver.wait("actual current reanalysis opened") { self.editor.productionSelectedPhase == "analysis" && driver.text("production.artifact", in: self.window) == "Analysis" && driver.state("agent.gate.approve", in: self.window) == true }
            let ready = await NativeGateWriter.controlReadiness(projectDir: home, phase: "analysis",
                declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
                executionCoordinator: editor.pipelinePhaseRunCoordinator)
            guard ready.approval.isReady else { throw Failure("The interpreted reanalysis is not actually approvable") }
            let readyImage = try capture("remeasured-analysis-ready")
            let priorTurns = runtime.handoffs.count
            try await driver.click("agent.gate.approve", in: window)
            try await driver.wait("actual reanalysis approval returns to Brief", seconds: 30) {
                self.editor.projectState?.nextPhaseName == "brief" && self.editor.productionSelectedPhase == "brief"
                    && !self.service.isStreaming && self.service.pendingDialog == nil && self.service.pendingGateApproval == nil
                    && self.runtime.handoffs.count > priorTurns
            }
            let handoffs = Array(runtime.handoffs.dropFirst(priorTurns))
            guard handoffs.count == 1, let handoff = handoffs.first, handoff.phase == "brief", handoff.instructionsSHA256 != nil,
                  service.messages.last(where: { $0.role == .user }).map({ $0.hidden && $0.userPresentation == nil }) == true else { throw Failure("The reanalysis approval did not deliver its actual hidden Brief handoff") }
            let gatesAfter = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
            let persisted = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
            let approvedImage = try capture("remeasured-analysis-approved")
            guard persisted.get("analysis").approved, gatesAfter != gatesBefore else { throw Failure("The second actual analysis approval did not persist") }
            let secondApproval = MusicvideoNativeAcceptance.GateEvidence(phase: "analysis", nextPhase: "brief", controlID: "agent.gate.approve",
                openControlID: "agent.gate.open", surface: editor.workspaceFocus.rawValue, artifactTitle: "Analysis", openedFromPhase: "project_init",
                artifactSHA256: interpreted["sha256"]!, gatesBeforeSHA256: FileDigest.sha256(of: gatesBefore), gatesAfterSHA256: FileDigest.sha256(of: gatesAfter),
                blockedReason: reason, blockedBeforeApproval: !blocked.approval.isReady, readyBeforeClick: ready.approval.isReady, approvedPersisted: persisted.get("analysis").approved,
                selectedPhaseAfter: editor.productionSelectedPhase ?? "missing", handoffPhase: handoff.phase, handoffHidden: true,
                packagedInstructions: handoff.instructionsSHA256 != nil, handoffTurnID: handoff.turnID, handoffInstructionsSHA256: handoff.instructionsSHA256,
                screenshots: [blockedImage, readyImage, approvedImage])
            let afterApproval = try retain(PipelineLayout.gatesFile, as: "playback-reanalysis-after-approval.yaml")
            let stale = try await PipelinePlaybackRangeWriter.capture(editor: editor)
            guard stale.requiresSelectionConfirmation, stale.kind == .fullSong, stale.selectionReceipt == oldReceipt,
                  stale.audio.sha256 == selected.audio.sha256, stale.analysis.sha256 != selected.analysis.sha256,
                  stale.analysis.sha256 == interpreted["sha256"] else { throw Failure("Reanalysis did not retain the old receipt as a stale CAS basis for the actual same source") }
            let brief = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "brief", dataRoot: root)
            var refused = false
            do { _ = try PipelinePlaybackRangeWriter.materialize(stale, brief: brief) } catch is GateBlocked { refused = true }
            guard refused else { throw Failure("The old range was materialized without an explicit new native confirmation") }
            try await driver.wait("native Full song reconfirmation available") { driver.text("playback-range.kind", in: self.window) == "Full song" && driver.state("playback-range.apply", in: self.window) == true }
            _ = try capture("stale-selection-awaits-explicit-apply")
            try driver.record("actual stale playback selection refused", fields: ["oldSelectionSHA256": oldReceipt.sha256,
                "analysisSHA256": stale.analysis.sha256, "kind": stale.kind.rawValue, "requiresConfirmation": stale.requiresSelectionConfirmation,
                "materializeRefused": refused, "applyEnabled": driver.state("playback-range.apply", in: window) == true])
            try await driver.click("playback-range.apply", in: window)
            try await driver.wait("actual Full song reconfirmed") { driver.text("playback-range.saved", in: self.window)?.hasPrefix("Saved: full song") == true }
            let current = try await PipelinePlaybackRangeWriter.capture(editor: editor)
            guard !current.requiresSelectionConfirmation, current.kind == .fullSong, current.startTicks == 0,
                  current.durationTicks == current.audioDurationTicks, let newReceipt = current.selectionReceipt, newReceipt != oldReceipt else { throw Failure("Native Apply did not replace the stale receipt with a current explicit full-song choice") }
            let currentSelection = try retain(newReceipt.path, as: "playback-reanalysis-current-selection.json")
            let appliedByUI = try PlanningWriterIO.read(PlaybackRangeV1.self, at: PlaybackRangeV1.currentPath, dataRoot: root)
            guard appliedByUI.kind == .fullSong, appliedByUI.startTicks == 0,
                  appliedByUI.durationTicks == current.audioDurationTicks, appliedByUI.analysis == current.analysis,
                  appliedByUI.timebase == current.timebase, appliedByUI.selectionReceipt == nil,
                  appliedByUI.header.inputs.contains(newReceipt) else { throw Failure("Native Apply did not materialize the current full-song selection before the Brief writer") }
            let appliedRangeFromUI = try retain(PlaybackRangeV1.currentPath, as: "playback-reanalysis-native-applied-range.json")
            try await tool("write_brief", ["mission": "single_release", "target_platform": "YouTube", "aspect_ratio": "16:9", "project_mode": "section",
                "concept_type": conceptType.rawValue, "visual_medium": "live_action_realistic", "figures": "none", "lyrics_integration": "metaphorical", "final_resolution": finalResolution.rawValue])
            let applied = try retain(PlaybackRangeV1.currentPath, as: "playback-reanalysis-applied-range.json")
            _ = try capture("explicit-full-song-current")
            transitions.append("native reanalysis: Analysis approved again; range explicitly reconfirmed")
            gateApprovals[index] = secondApproval
            try driver.record("native range reanalysis confirmed", fields: ["projectKey": editor.projectId ?? "", "viewport": try ProductionV2OwnerAcceptance.actualViewport(window), "sameSourceSHA256": current.audio.sha256,
                "oldSelection": oldSelection, "currentSelection": currentSelection, "oldAnalysis": oldAnalysis, "currentAnalysis": interpreted, "appliedRange": applied, "appliedRangeFromUI": appliedRangeFromUI,
                "beforeRewind": beforeRewind, "afterRewind": afterRewind, "afterApproval": afterApproval,
                "reanalysisRequest": nativeAnalysisRequests.last ?? [], "reanalysisResultIsError": nativeAnalysisResults.last?.isError ?? true,
                "firstApproval": try ProductionPlanningAcceptanceFixture.object(firstApproval), "secondApproval": try ProductionPlanningAcceptanceFixture.object(secondApproval),
                "currentAnalysisGateReplacesEarlierApproval": true, "liveAgent": false, "liveAnalyzerQualityClaim": false])
            try JSONSerialization.data(withJSONObject: driver.result(), options: [.prettyPrinted, .sortedKeys])
                .write(to: evidenceURL.appendingPathComponent("playback-reanalysis-result.json"), options: .atomic)
        } catch { driver.failure(error); throw error }
    }
}
