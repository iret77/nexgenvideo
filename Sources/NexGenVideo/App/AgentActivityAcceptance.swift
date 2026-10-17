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
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil },
            runtimeHostContextOverride: { .hostOwned(tools: []) })
        let editor = EditorViewModel(agentService: service)
        service.loadSessions(from: home)
        guard service.currentSessionId == saved.id, service.messages.map(\.id) == [answer.id] else {
            throw Failure("Reopening the project lost its last answer")
        }
        let host = NSHostingView(rootView: AgentPanelView(presentation: .activity)
            .environment(editor).environment(\.interfaceScale, scale)
            .background(AppTheme.Background.surfaceColor))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero,
            size: NSSize(width: AppTheme.Layout.activityFlyoutWidth, height: AppTheme.Layout.activityFlyoutHeight)),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            service.cancelRunningSpend()
            service.cancel()
            window.orderOut(nil)
            window.contentView = nil
        }
        let resultID = "agent.result.\(answer.id.uuidString)"
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return visibleProbes(resultID, in: host).count == 1 && visibleProbes("agent.stop", in: host).isEmpty
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
        screenshots.append(try capture(host, name: "agent-streaming", scale: scale, directory: evidenceURL))
        guard WorkspaceUIAcceptance.click(identifier: "agent.stop", in: window) == nil else {
            throw Failure("The native Stop task control is not clickable")
        }
        try await waitUntil { !service.isStreaming && service.currentTaskPhase == nil }

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
        guard WorkspaceUIAcceptance.click(identifier: "agent.stop", in: window) == nil else {
            throw Failure("The native Stop generation control is not clickable")
        }
        try await waitUntil { service.currentSpendRun == nil }
        FileHandle.standardOutput.write(Data("SELFTEST_AGENT_ACTIVITY_OK idleStop=0 streamingStop=1 generationStop=1 restoredAnswerVisible=true\n".utf8))
        return screenshots
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
