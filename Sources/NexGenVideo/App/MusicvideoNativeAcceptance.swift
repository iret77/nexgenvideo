import AppKit
import NexGenEngine

@MainActor
enum MusicvideoNativeAcceptance {
    struct GateEvidence: Codable {
        let phase: String
        let nextPhase: String
        let controlID: String
        let openControlID: String
        let surface: String
        let artifactTitle: String
        let openedFromPhase: String
        let artifactSHA256: String
        let gatesBeforeSHA256: String
        let gatesAfterSHA256: String
        let blockedReason: String
        let blockedBeforeApproval: Bool
        let readyBeforeClick: Bool
        let approvedPersisted: Bool
        let selectedPhaseAfter: String
        var handoffPhase: String
        var handoffHidden: Bool
        var packagedInstructions: Bool
        var handoffTurnID: String?
        var handoffInstructionsSHA256: String?
        let screenshots: [String]
    }

    private static var runtimes: [ObjectIdentifier: MusicvideoHostFlowAcceptance.RecordingRuntime] = [:]

    static func register(editor: EditorViewModel, runtime: MusicvideoHostFlowAcceptance.RecordingRuntime) {
        runtimes[ObjectIdentifier(editor)] = runtime
    }

    static func recordedPhases(for editor: EditorViewModel) throws -> [String] {
        guard let runtime = runtimes[ObjectIdentifier(editor)] else {
            throw FullflowAcceptanceFixture.Failure("The acceptance editor has no recording runtime.")
        }
        return runtime.phases
    }

    static func window(for editor: EditorViewModel) throws -> NSWindow {
        guard let window = NSApp.windows.first(where: {
            ($0.windowController as? EditorWindowController)?.editorViewModel === editor
        }) else { throw FullflowAcceptanceFixture.Failure("The native acceptance editor window is unavailable.") }
        return window
    }

    static func waitUntil(_ step: String = "native control or handoff", diagnostic: (() -> String)? = nil,
                          file: StaticString = #fileID, line: UInt = #line, _ ready: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if try ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FullflowAcceptanceFixture.Failure("Native Musicvideo did not settle (\(step), \(file):\(line)): \(diagnostic?() ?? "no state available").")
    }

    static func click(_ identifier: String, in window: NSWindow, requiringEnabled: Bool = true) async throws {
        window.makeKeyAndOrderFront(nil)
        try await waitUntil("control \(identifier)", diagnostic: {
            "enabled=\(String(describing: WorkspaceUIAcceptance.probeState(identifier: identifier, in: window))), text=\(WorkspaceUIAcceptance.probeText(identifier: identifier, in: window) ?? "none")"
        }) {
            requiringEnabled ? WorkspaceUIAcceptance.probeState(identifier: identifier, in: window) == true
                : WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: window) != nil
        }
        guard await WorkspaceUIAcceptance.revealProbe(identifier, in: window), let host = window.contentView,
              WorkspaceUIAcceptance.visibleProbe(identifier: identifier, in: window, containedBy: host.bounds,
                requiredState: requiringEnabled ? true : nil),
              WorkspaceUIAcceptance.click(identifier: identifier, in: window) == nil else {
            throw FullflowAcceptanceFixture.Failure("The native control is not reachable: \(identifier).")
        }
    }

    static func approve(_ phase: String, editor: EditorViewModel, evidenceURL: URL,
                        awaitHandoff: Bool = true) async throws -> GateEvidence {
        let order = ["project_init", "analysis", "brief", "production_design", "treatment", "storyboard",
            "bible", "shotlist", "sanity", "frames", "render"]
        let titles = ["project_init": "Project", "analysis": "Analysis", "brief": "Project Brief",
            "production_design": "Production Design", "treatment": "Treatment", "storyboard": "Storyboard",
            "bible": "Bible", "shotlist": "Shotlist", "sanity": "Review", "frames": "Review", "render": "Review"]
        guard let index = order.firstIndex(of: phase), let expectedTitle = titles[phase],
              let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              let runtime = runtimes[ObjectIdentifier(editor)] else {
            throw FullflowAcceptanceFixture.Failure("Native approval requires the hermetic Musicvideo host runtime.")
        }
        let next = index + 1 < order.count ? order[index + 1] : "complete"
        let service = editor.agentService
        func waitFor(_ step: String, until ready: () throws -> Bool) async throws {
            try await waitUntil("\(phase): \(step)", diagnostic: {
                "phase=\(editor.projectState?.nextPhaseName ?? "none"), selected=\(editor.productionSelectedPhase ?? "none"), pending=\(service.pendingGateApproval?.phase ?? "none"), dialog=\(service.pendingDialog?.title ?? "none"), streaming=\(service.isStreaming), recorded=\(runtime.phases.joined(separator: ",")), error=\(service.gateApprovalError ?? service.streamError?.localizedDescription ?? "none")"
            }, ready)
        }
        try await waitFor("agent idle") { !service.isStreaming }
        await editor.refreshEngineState()
        guard editor.projectState?.nextPhaseName == phase, let session = service.currentSessionId else {
            throw FullflowAcceptanceFixture.Failure("The native approval is not for the current phase: \(phase).")
        }
        let before = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
        let gates = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        guard !gates.get(phase).approved else { throw FullflowAcceptanceFixture.Failure("The fixture tried to approve an already approved phase.") }
        let result = await ToolExecutor(editor: editor).execute(name: "approve_gate", args: ["phase": phase, "project_dir": root.path],
            origin: .inAppChat(sessionID: session), toolUseID: "native-gate-\(UUID().uuidString)")
        guard !result.isError, let approval = service.pendingGateApproval, approval.phase == phase else {
            throw FullflowAcceptanceFixture.Failure("The canonical writer did not offer the native \(phase) approval.")
        }
        let window = try Self.window(for: editor)
        window.makeKeyAndOrderFront(nil)
        let controlID = "agent.gate.approve"
        try await waitFor("approval enabled") { WorkspaceUIAcceptance.probeState(identifier: controlID, in: window) == true }
        let otherPhase = phase == "project_init" ? "brief" : "project_init"
        try await click("pipeline.overview.select.\(otherPhase)", in: window, requiringEnabled: false)
        try await waitFor("select \(otherPhase)") { editor.productionSelectedPhase == otherPhase }
        try await click("agent.gate.open", in: window)
        try await waitFor("open \(expectedTitle)") {
            editor.workspaceFocus == .production && editor.productionSelectedPhase == phase
                && WorkspaceUIAcceptance.probeText(identifier: "production.artifact", in: window) == expectedTitle
        }
        guard let host = window.contentView,
              WorkspaceUIAcceptance.visibleProbe(identifier: "production.artifact", in: window, containedBy: host.bounds) else {
            throw FullflowAcceptanceFixture.Failure("Open did not reveal the actual \(phase) artifact surface.")
        }
        let artifact = try currentArtifact(phase: phase, root: root, approval: approval)
        let original = try Data(contentsOf: artifact)
        let held = FileManager.default.temporaryDirectory.appendingPathComponent("gate-held-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: artifact, to: held)
        var restored = false
        defer { if !restored { try? FileManager.default.moveItem(at: held, to: artifact) } }
        await editor.refreshEngineState()
        try await waitFor("missing artifact disables approval") {
            guard WorkspaceUIAcceptance.probeState(identifier: controlID, in: window) == false,
                  let reason = WorkspaceUIAcceptance.probeText(identifier: controlID, in: window) else { return false }
            return !reason.isEmpty && reason != "Checking the current phase…"
        }
        let blocked = await NativeGateWriter.controlReadiness(projectDir: home, phase: phase,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator)
        guard !blocked.approval.isReady, let reason = WorkspaceUIAcceptance.probeText(identifier: controlID, in: window),
              !reason.isEmpty, await WorkspaceUIAcceptance.revealProbe(controlID, in: window),
              WorkspaceUIAcceptance.visibleProbe(identifier: controlID, in: window, containedBy: host.bounds, requiredState: false),
              WorkspaceUIAcceptance.click(identifier: controlID, in: window) == nil else {
            throw FullflowAcceptanceFixture.Failure("The missing current \(phase) artifact did not disable native approval.")
        }
        try await Task.sleep(for: .milliseconds(150))
        guard try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) == before,
              service.pendingGateApproval?.id == approval.id else {
            throw FullflowAcceptanceFixture.Failure("Clicking disabled \(phase) approval changed the gate.")
        }
        let scale = UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)
        let scaleLabel = Int((scale > 0 ? scale : AppTheme.Typography.standardScale) * 100)
        let prefix = "scale-\(scaleLabel)-native-gate-\(phase)-\(UUID().uuidString)"
        var screenshots = [try capture(window, name: prefix + "-blocked", evidenceURL: evidenceURL)]
        try FileManager.default.moveItem(at: held, to: artifact)
        restored = true
        guard try Data(contentsOf: artifact) == original else { throw FullflowAcceptanceFixture.Failure("The fixture did not restore exact artifact bytes.") }
        await editor.refreshEngineState()
        try await waitFor("restored artifact enables approval") { WorkspaceUIAcceptance.probeState(identifier: controlID, in: window) == true }
        let ready = await NativeGateWriter.controlReadiness(projectDir: home, phase: phase,
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            executionCoordinator: editor.pipelinePhaseRunCoordinator)
        guard ready.approval.isReady else { throw FullflowAcceptanceFixture.Failure("Restored \(phase) is not ready for approval.") }
        screenshots.append(try capture(window, name: prefix + "-ready", evidenceURL: evidenceURL))
        let turnCount = runtime.phases.count
        try await click(controlID, in: window)
        try await waitFor("approval persisted") { service.pendingGateApproval == nil || service.gateApprovalError != nil }
        guard service.gateApprovalError == nil else { throw FullflowAcceptanceFixture.Failure("Native gate commit failed: \(phase).") }
        await editor.refreshEngineState()
        if awaitHandoff {
            try await waitFor("handoff to \(next)") {
                if let error = service.streamError {
                    throw FullflowAcceptanceFixture.Failure("Native Musicvideo \(phase) handoff to \(next) failed: \(error.localizedDescription)")
                }
                return !service.isStreaming && runtime.phases.dropFirst(turnCount).contains(next)
            }
        } else {
            try await waitFor("Existing story intake") { service.pendingDialog?.title == "Existing story" }
        }
        let after = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
        let persisted = try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile)
        let selected = next == "complete" ? phase : next
        guard persisted.get(phase).approved, before != after, editor.productionSelectedPhase == selected,
              editor.projectState?.nextPhaseName == (next == "complete" ? nil : next),
              next != "complete" || editor.projectState?.isComplete == true else {
            throw FullflowAcceptanceFixture.Failure("The native \(phase) click did not persist and advance the visible phase.")
        }
        let hidden = service.messages.last(where: { $0.role == .user }).map { $0.hidden && $0.userPresentation == nil } == true
        guard !awaitHandoff || hidden else { throw FullflowAcceptanceFixture.Failure("A host gate handoff appeared as a user turn.") }
        let handoffs = Array(runtime.handoffs.dropFirst(turnCount))
        let handoff = handoffs.last
        if awaitHandoff {
            guard handoffs.count == 1, handoff?.phase == next,
                  (handoff?.instructionsSHA256 != nil) == (next != "complete") else {
                throw FullflowAcceptanceFixture.Failure("The gate did not cause exactly one validated next-phase handoff.")
            }
        }
        screenshots.append(try capture(window, name: prefix + "-approved", evidenceURL: evidenceURL))
        return GateEvidence(phase: phase, nextPhase: next, controlID: controlID, openControlID: "agent.gate.open",
            surface: editor.workspaceFocus.rawValue, artifactTitle: expectedTitle, openedFromPhase: otherPhase,
            artifactSHA256: FileDigest.sha256(of: original),
            gatesBeforeSHA256: FileDigest.sha256(of: before), gatesAfterSHA256: FileDigest.sha256(of: after),
            blockedReason: reason, blockedBeforeApproval: !blocked.approval.isReady, readyBeforeClick: ready.approval.isReady,
            approvedPersisted: persisted.get(phase).approved, selectedPhaseAfter: editor.productionSelectedPhase ?? "missing",
            handoffPhase: handoff?.phase ?? "intake", handoffHidden: awaitHandoff && hidden,
            packagedInstructions: handoff?.instructionsSHA256 != nil, handoffTurnID: handoff?.turnID,
            handoffInstructionsSHA256: handoff?.instructionsSHA256, screenshots: screenshots)
    }

    private static func currentArtifact(phase: String, root: URL, approval: GateApproval) throws -> URL {
        if phase == "project_init", let song = AudioProjectLayout.songFiles(dataRoot: root).first { return song }
        if let fingerprint = approval.artifactFingerprint { return try ProjectLocalFile.resolve(fingerprint.path, dataRoot: root) }
        let paths = ["sanity": PipelineLayout.sanityReportFile, "frames": PipelineLayout.renderManifestFile(phase: "frames"),
            "render": "assembly.json"]
        guard let path = paths[phase] else { throw FullflowAcceptanceFixture.Failure("The current phase has no controlled artifact: \(phase).") }
        return try ProjectLocalFile.resolve(path, dataRoot: root)
    }

    private static func capture(_ window: NSWindow, name: String, evidenceURL: URL) throws -> String {
        guard let view = window.contentView else { throw FullflowAcceptanceFixture.Failure("The native host is unavailable.") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw FullflowAcceptanceFixture.Failure("The native gate could not be captured.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw FullflowAcceptanceFixture.Failure("The native gate capture is empty.") }
        let filename = name + ".png"
        try data.write(to: evidenceURL.appendingPathComponent(filename), options: .atomic)
        return filename
    }
}
