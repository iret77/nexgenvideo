import AppKit
import NexGenEngine

@MainActor
enum CaptionTranslationAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Caption translation requires the isolated native owner process.") }
        let package = output.appendingPathComponent("Caption translation.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var timeline = Timeline(); timeline.settingsConfigured = true; timeline.fps = 30
        let first = Clip(id: "translate-first", mediaRef: "text:translation-one", mediaType: .text, sourceClipType: .text,
            startFrame: 0, durationFrames: 60, captionGroupId: "existing-translation", textContent: "Good morning.")
        let second = Clip(id: "translate-second", mediaRef: "text:translation-two", mediaType: .text, sourceClipType: .text,
            startFrame: 75, durationFrames: 45, captionGroupId: first.captionGroupId, textContent: "We are ready.")
        timeline.tracks = [Track(id: "translation-track", type: .video, clips: [first, second])]
        try JSONEncoder().encode(timeline).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let runtime = Runtime()
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil })
        let document = try await VideoProject.load(from: package, agentService: service)
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        var closed = false
        defer { service.cancel(); if !closed { document.close() } }
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The translation document did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); NSApp.mainMenu = MainMenuBuilder.buildMenu()
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "caption-translation-owner")
        func save(_ name: String, _ value: Timeline) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(value).write(to: output.appendingPathComponent(name + ".json"))
        }
        do {
            try await driver.wait("translation viewport") {
                window.contentView?.bounds.size == AppTheme.Window.projectMin
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            try await driver.click("media.tab.Captions", in: window, enabled: false)
            let before = editor.timeline
            try save("before", before)
            for index in 1...2 {
                runtime.armed = true
                try await driver.menu("captions.actions", path: ["Translate", "German"], in: window)
                try await driver.wait("actual chosen translation language") {
                    service.pendingFunction?.title == "Translate Captions to German"
                        && service.pendingFunction?.captionRevisionScope?.kind == .captions
                }
                guard let staged = service.pendingFunction, let stagedScope = staged.captionRevisionScope else {
                    throw GateBlocked("The selected translation task lost its caption scope.")
                }
                let stagedScopeData = try JSONEncoder().encode(stagedScope)
                let stagedScopeJSON = try JSONSerialization.jsonObject(with: stagedScopeData)
                try await driver.fill("agent.composer.input", value: "Translate these captions to German; preserve their timing.", in: window)
                try await driver.click("agent.task.run", in: window)
                try await driver.wait("actual translated caption proposal", seconds: 30) {
                    runtime.failure != nil || (!service.isStreaming && service.pendingDialog?.purpose == .captionRevision)
                }
                guard runtime.failure == nil, let proposal = service.pendingDialog?.captionRevision,
                      driver.state("agent.dialog.confirm", in: window) == false,
                      service.dialogChoiceSelections["caption-revision"]?.isEmpty != false,
                      editor.timeline == before,
                      proposal.rows.map(\.id) == [first.id, second.id],
                      proposal.rows.map(\.before) == ["Good morning.", "We are ready."],
                      proposal.rows.map(\.after) == ["Guten Morgen.", "Wir sind bereit."] else {
                    throw GateBlocked(runtime.failure ?? "Translation was applied before the native language/text decision.")
                }
                try JSONEncoder().encode(proposal).write(to: output.appendingPathComponent("proposal-\(index).json"))
                var renderedRows: [String] = []
                for row in proposal.rows {
                    let id = "captions.revision.choice." + row.id
                    try await driver.reveal(id, in: window)
                    guard let rendered = driver.text(id, in: window), rendered == row.timeRange + " · " + row.before + " → " + row.after else {
                        throw GateBlocked("The selected language's actual before/after text and time are not visible.")
                    }
                    renderedRows.append(rendered)
                    try driver.visible([id], in: window)
                }
                try driver.record("translated proposal visible", fields: ["index": index, "language": "German",
                    "stagedTitle": staged.title, "stagedScope": stagedScopeJSON, "renderedRows": renderedRows,
                    "ids": proposal.rows.map(\.id), "before": proposal.rows.map(\.before), "after": proposal.rows.map(\.after),
                    "times": proposal.rows.map(\.timeRange), "selected": Array(service.dialogChoiceSelections["caption-revision"] ?? []),
                    "applyEnabled": driver.state("agent.dialog.confirm", in: window) == true])
                try driver.capture("german-proposal-\(index)", target: window)
                if index == 1 {
                    try await driver.click("agent.dialog.cancel", in: window)
                    try await driver.wait("translation cancel") { service.pendingDialog == nil && !service.isStreaming }
                    guard editor.timeline == before else { throw GateBlocked("Cancel translated the existing captions.") }
                    try save("cancelled", editor.timeline)
                } else {
                    try await driver.click("captions.revision.choice." + first.id, in: window)
                    try await driver.wait("explicit single translated row") { service.dialogChoiceSelections["caption-revision"] == [first.id] }
                    try await driver.click("agent.dialog.confirm", in: window)
                    try await driver.wait("native selective translation") { service.pendingDialog == nil && !service.isStreaming }
                }
            }
            var expected = before; expected.tracks[0].clips[0].textContent = "Guten Morgen."
            guard editor.timeline == expected else { throw GateBlocked("Translation changed an unselected caption, its timing or another timeline property.") }
            try save("applied", editor.timeline)
            try await GenericNLEAcceptance.pointerOnClip(first, editor: editor, window: window, driver: driver)
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("translation single Undo") { editor.timeline == before }
            try save("undo", editor.timeline)
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("translation single Redo") { editor.timeline == expected }
            try save("redo", editor.timeline)
            try driver.capture("selectively-translated", target: window)
            let bounds = window.contentView!.bounds
            guard let field = driver.interactions.compactMap({ $0["field"] as? [String: Any] }).last(where: { $0["id"] as? String == "agent.composer.input" }),
                  let font = field["fontPointSize"] as? CGFloat, abs(font - AppTheme.Typography.ui * scale) < 0.5 else {
                throw GateBlocked("The actual translation task typography does not match the outer scale.")
            }
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("translation native Save", seconds: 30) { !document.isDocumentEdited }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            defer { reopened.close() }
            guard reopened.editorViewModel.timeline == expected else { throw GateBlocked("Save/reopen lost the accepted translation.") }
            try save("reopened", reopened.editorViewModel.timeline)
            try JSONSerialization.data(withJSONObject: runtime.requests, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("requests.json"))
            var result = driver.result()
            result.merge(["language": "German", "viewport": [bounds.width, bounds.height], "scale": scale,
                "renderedFontPointSize": Double(font), "savedAndReopened": true, "liveAgent": false,
                "initialFixture": "Two existing English caption clips with a real gap; language choice and selective text decisions are native."] as [String: Any]) { _, new in new }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("translation-result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }

    @MainActor private final class Runtime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        var armed = false
        private(set) var failure: String?
        private(set) var requests: [[String: Any]] = []
        private var execute: AgentRuntimeToolExecutor?
        private var task: Task<Void, Never>?
        func start(_ request: AgentRuntimeSessionRequest) throws { execute = request.executeTool; state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            let isProposal = armed; armed = false
            let texts = request.currentMessage.content.compactMap { block -> String? in if case .text(let value) = block { value } else { nil } }
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            task = Task { @MainActor in
                do {
                    if isProposal {
                        guard let execute, texts.contains(where: { $0.contains("translate the captions to German") }) else {
                            throw GateBlocked("The real runtime request lost the selected German translation task.")
                        }
                        let args: [String: Any] = ["kind": "captions", "changes": [["clipId": "translate-first", "text": "Guten Morgen."],
                            ["clipId": "translate-second", "text": "Wir sind bereit."]]]
                        let result = await execute(UUID().uuidString, "propose_caption_revision",
                            String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self))
                        let output = result.content.compactMap { block -> String? in if case .text(let value) = block { value } else { nil } }.joined(separator: "\n")
                        requests.append(["sessionID": request.sessionID.uuidString, "turnID": request.turnID.uuidString,
                            "texts": texts, "tool": "propose_caption_revision", "arguments": args, "isError": result.isError, "result": output])
                        guard !result.isError else { throw GateBlocked("The actual schema-validated translation proposal failed: " + output) }
                    }
                } catch { failure = error.localizedDescription }
                pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
                pair.continuation.finish(); state = .ready(sessionID: request.sessionID)
            }
            return pair.stream
        }
        func cancel(sessionID: UUID) { task?.cancel(); state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { cancel(sessionID: sessionID); state = .ended(sessionID: sessionID) }
    }
}
