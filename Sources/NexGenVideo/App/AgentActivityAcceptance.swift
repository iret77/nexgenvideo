import AppKit
import SwiftUI

@MainActor
enum AgentActivityAcceptance {
    static func run(evidenceURL: URL, scale: Double) async throws -> [String] {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentResume-\(UUID().uuidString)")
        let chat = home.appendingPathComponent(ChatSessionStore.dirName)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let answer = AgentMessage(role: .assistant, blocks: [.text("The Bible is ready for the remaining character sheets. The approved treatment is preserved.")])
        let saved = ChatSession(title: "Complete Bible images", messages: [answer])
        guard let bytes = ChatSessionStore.encodeSession(saved) else { throw Failure("Could not save resume fixture") }
        try bytes.write(to: chat.appendingPathComponent("\(saved.id.uuidString).json"))
        let runtime = FixtureRuntime()
        var needsAuthentication = false
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { needsAuthentication ? .authenticationRequired : nil },
            runtimeHostContextOverride: { .hostOwned(tools: []) })
        let editor = EditorViewModel(agentService: service)
        service.loadSessions(from: home)
        guard service.currentSessionId == saved.id, service.messages.map(\.id) == [answer.id] else {
            throw Failure("Reopening the project lost its last answer")
        }
        let statusHost = NSHostingView(rootView: WorkbenchStatusBar()
            .frame(maxHeight: .infinity, alignment: .bottom)
            .environment(editor).environment(\.interfaceScale, scale)
            .background(AppTheme.Background.surfaceColor))
        statusHost.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero,
            size: NSSize(width: AppTheme.Layout.activityFlyoutWidth, height: AppTheme.Layout.activityFlyoutHeight)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = statusHost
        let controller = EditorWindowController(editorViewModel: editor, window: window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            editor.showsAgentActivity = false
            service.cancelRunningSpend()
            service.cancel()
            window.orderOut(nil)
            window.contentView = nil
        }
        let resultID = "agent.result.\(answer.id.uuidString)"
        try await openActivity(in: window, evidenceURL: evidenceURL, scale: scale)
        try await waitUntil { utilityWindow(resultID) != nil && utilityWindow("agent.stop") == nil }
        try await verifyUtilities(editor: editor, controller: controller, evidenceURL: evidenceURL, scale: scale)
        try await openActivity(in: window, evidenceURL: evidenceURL, scale: scale)
        guard let activityWindow = utilityWindow(resultID), let host = activityWindow.contentView else {
            throw Failure("The status bar did not present the restored activity popover")
        }
        var screenshots = [try capture(host, name: "agent-resumed", scale: scale, directory: evidenceURL)]
        guard service.sendWorkOrder(.init(title: "Complete Bible images", systemImage: "photo",
            prompt: "Continue the remaining Bible image work.", phase: "bible"), direction: "", mentions: []) else {
            throw Failure("Could not start the fixture work order")
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return service.isStreaming && service.activityEvents.last?.label == "Reading · treatment.md"
                && service.currentTaskPhase == "bible"
                && visibleProbes("agent.stop", in: host).count == 1
                && visibleProbes(resultID, in: host).count == 1
        }
        guard visibleProbes("agent.stop", in: host).first?.acceptanceText == "Stop task" else {
            throw Failure("The streaming action does not name the task")
        }
        let phaseRelease = DispatchSemaphore(value: 0)
        defer { phaseRelease.signal() }
        let phaseTask = Task { @MainActor in
            await editor.pipelinePhaseRunCoordinator.run(projectRoot: home, phase: "bible", sourceFilename: nil,
                runner: { _ in
                    guard phaseRelease.wait(timeout: .now() + 15) == .success else {
                        throw Failure("The bounded phase fixture was not released")
                    }
                }, progressRunner: nil, state: editor.pipelinePhaseExecution)
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return editor.pipelinePhaseExecution.snapshot?.isRunning == true
                && visibleProbes("agent.stop", in: host).count == 1
                && visibleProbes("agent.stop", in: host).first?.acceptanceText == "Stop agent"
        }
        screenshots.append(try capture(host, name: "agent-streaming", scale: scale, directory: evidenceURL))
        try await activate("agent.stop", in: activityWindow, evidenceURL: evidenceURL, scale: scale)
        try await waitUntil { !service.isStreaming && service.currentTaskPhase == nil }
        guard editor.pipelinePhaseExecution.snapshot?.isRunning == true,
              editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: home) == "bible" else {
            throw Failure("Stopping the agent changed the independent canonical phase job")
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return visibleProbes("agent.stop", in: host).isEmpty
        }
        phaseRelease.signal()
        guard await phaseTask.value == .completed else { throw Failure("The canonical phase did not complete after its runner was released") }

        let option = SpendOption(modelId: "fixture-image", modelName: "Fixture image",
            target: .init(modelId: "fixture-image", provider: .fal, endpoint: "fixture-only", binding: nil),
            credits: nil, requiresCatalogAvailability: false)
        _ = try service.requestSpendApproval(.init(id: "fixture-spend", recommendedOptionId: option.id,
            options: [option], actionLabel: "Generate image"), origin: .direct, editor: editor,
            execute: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return .ok("Fixture complete")
            })
        await service.approveSpend(option, recordSelection: false)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return service.currentSpendRun != nil && visibleProbes("agent.stop", in: host).count == 1
        }
        guard visibleProbes("agent.stop", in: host).first?.acceptanceText == "Stop generation" else {
            throw Failure("The generation action does not name generation")
        }
        screenshots.append(try capture(host, name: "agent-generating", scale: scale, directory: evidenceURL))
        try await activate("agent.stop", in: activityWindow, evidenceURL: evidenceURL, scale: scale)
        try await waitUntil { service.currentSpendRun == nil }
        editor.showsAgentActivity = false
        try await waitUntil { utilityWindow(resultID) == nil }
        needsAuthentication = true
        guard !editor.continueProductionPhase("bible"), editor.showsAgentActivity, !service.isStreaming else {
            throw Failure("Unavailable backend did not reveal recovery without starting a task")
        }
        try await waitUntil { utilityWindow("agent.backend-recovery") != nil }
        FileHandle.standardOutput.write(Data("SELFTEST_AGENT_ACTIVITY_OK idleStop=0 streamingStop=1 generationStop=1 restoredAnswerVisible=true\n".utf8))
        return screenshots
    }

    private static func verifyUtilities(editor: EditorViewModel, controller: EditorWindowController,
                                        evidenceURL: URL, scale: Double) async throws {
        guard let statusWindow = controller.window else { throw Failure("The editor window is unavailable") }
        for utility in ["sessions", "decisions", "diagnostics"] {
            let action = "agent.\(utility)"
            let done = "\(action).done"
            try await openActivity(in: statusWindow, evidenceURL: evidenceURL, scale: scale)
            guard let window = utilityWindow(action) else {
                throw Failure("The activity flyout cannot open \(utility)")
            }
            try await activate(action, in: window, evidenceURL: evidenceURL, scale: scale)
            try await waitUntil { utilityWindow(done) != nil }
            guard let presented = utilityWindow(done) else {
                throw Failure("The activity flyout did not present usable \(utility)")
            }
            try await activate(done, in: presented, evidenceURL: evidenceURL, scale: scale)
            try await waitUntil { utilityWindow(done) == nil }
        }
        editor.showsAgentActivity = false
        try await waitUntil { utilityWindow("agent.sessions") == nil && utilityWindow("agent.sessions.done") == nil }
        statusWindow.makeKeyAndOrderFront(nil)
        guard NSApp.sendAction(#selector(EditorWindowController.showAgentConversationHistory(_:)),
            to: controller, from: nil) else {
            throw Failure("The Sessions menu action was not handled by the editor window")
        }
        try await waitUntil { utilityWindow("agent.sessions.done") != nil }
        guard let history = utilityWindow("agent.sessions.done") else {
            throw Failure("The Sessions menu action did not present usable history from the closed flyout")
        }
        try await activate("agent.sessions.done", in: history, evidenceURL: evidenceURL, scale: scale)
        try await waitUntil { utilityWindow("agent.sessions.done") == nil }
    }

    private static func openActivity(in window: NSWindow, evidenceURL: URL, scale: Double) async throws {
        if utilityWindow("agent.sessions") != nil { return }
        try await activate("production.ai", in: window, evidenceURL: evidenceURL, scale: scale)
        try await waitUntil { utilityWindow("agent.sessions") != nil }
    }

    private static func activate(_ identifier: String, in window: NSWindow, evidenceURL: URL, scale: Double) async throws {
        var stage = "window activation"
        do {
            window.makeKeyAndOrderFront(nil)
            try await waitUntil { window.isVisible && window.isKeyWindow && !window.ignoresMouseEvents }
            stage = "control layout"
            guard await WorkspaceUIAcceptance.revealProbe(identifier, in: window) else {
                throw Failure("The control did not settle with its full click area inside the window")
            }
            stage = "native click"
            if let reason = WorkspaceUIAcceptance.click(identifier: identifier, in: window) {
                throw Failure(reason)
            }
        } catch {
            let root = window.contentView
            let probe = root.flatMap { WorkspaceUIAcceptance.findProbe(in: $0, identifier: identifier) }
            let screenshot = root.flatMap {
                try? capture($0, name: "agent-control-failed", scale: scale, directory: evidenceURL)
            }
            let diagnostic: [String: Any] = ["event": "agent-activity-control-diagnostic", "scale": scale,
                "controlID": identifier, "stage": stage, "reason": error.localizedDescription,
                "windowVisible": window.isVisible, "windowKey": window.isKeyWindow,
                "windowNumber": window.windowNumber, "keyWindowNumber": NSApp.keyWindow?.windowNumber ?? -1,
                "windowBounds": root.map { NSStringFromRect($0.bounds) } ?? "unavailable",
                "probeFound": probe != nil, "probeHidden": probe?.isHiddenOrHasHiddenAncestor ?? true,
                "probeFrameInWindow": probe.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "unavailable",
                "probeVisibleRect": probe.map { NSStringFromRect($0.visibleRect) } ?? "unavailable",
                "screenshot": screenshot ?? "unavailable"]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            throw Failure("The native control \(identifier) failed during \(stage): \(error.localizedDescription)")
        }
    }

    private static func utilityWindow(_ identifier: String) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible, let content = window.contentView else { return false }
            return !visibleProbes(identifier, in: content).isEmpty
        }
    }

    private static func visibleProbes(_ id: String, in view: NSView) -> [AppRelaunchClickProbeView] {
        var found: [AppRelaunchClickProbeView] = []
        if let probe = view as? AppRelaunchClickProbeView, probe.identifier?.rawValue == id,
           !probe.isHiddenOrHasHiddenAncestor, !probe.visibleRect.isEmpty,
           probe.window?.isVisible == true {
            found.append(probe)
        }
        return found + view.subviews.flatMap { visibleProbes(id, in: $0) }
    }

    private static func capture(_ view: NSView, name: String, scale: Double, directory: URL) throws -> String {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("Could not capture agent state") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Could not encode agent state") }
        let filename = "scale-\(Int((scale * 100).rounded()))-\(name).png"
        try bytes.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    private static func waitUntil(_ ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("The native agent state did not settle")
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class FixtureRuntime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        private var continuation: AsyncStream<AgentRuntimeEventEnvelope>.Continuation?

        func start(_ request: AgentRuntimeSessionRequest) throws { state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }

        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            continuation = pair.continuation
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            continuation?.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                event: .toolCall(messageID: "fixture", id: "fixture-read", name: "Read",
                    inputJSON: #"{"file_path":"treatment.md"}"#)))
            return pair.stream
        }

        func cancel(sessionID: UUID) {
            continuation?.finish()
            continuation = nil
            state = .ready(sessionID: sessionID)
        }

        func end(sessionID: UUID) {
            cancel(sessionID: sessionID)
            state = .ended(sessionID: sessionID)
        }
    }
}
