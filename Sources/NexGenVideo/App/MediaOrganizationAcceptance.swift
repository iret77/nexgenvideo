import AppKit
import NexGenEngine

@MainActor
enum MediaOrganizationAcceptance {
    static func run(savedProject: URL, output: URL, scale: Double) async throws -> [String: Any] {
        let name = "media-organization-\(Int(scale * 100))"
        let package = output.appendingPathComponent(name + ".ngv", isDirectory: true)
        let originalManifest = try Data(contentsOf: savedProject.appendingPathComponent(Project.manifestFilename))
        let originalTimeline = try Data(contentsOf: savedProject.appendingPathComponent(Project.timelineFilename))
        try FileManager.default.copyItem(at: savedProject, to: package)
        _ = try ProjectIdentity.regenerate(at: package)
        let runtime = FixtureRuntime()
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil },
            runtimeHostContextOverride: { .hostOwned(tools: []) })
        let document = try await VideoProject.load(from: package, agentService: service)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The organization project did not open.") }
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: name)
        var closed = false
        defer { if !closed { document.close() } }
        guard let video = editor.mediaAssets.first(where: { $0.userFacingFilename == "Original.mov" }),
              let image = editor.mediaAssets.first(where: { $0.userFacingFilename == "Reference.png" }) else {
            throw GateBlocked("Media organization needs the imported original video and image.")
        }
        let before = editor.mediaManifest, timeline = editor.timeline
        let sourceHashes = try Dictionary(uniqueKeysWithValues: editor.mediaAssets.map { ($0.id, try FileDigest.sha256(of: $0.url)) })
        func media() async throws {
            try await driver.click("editor.workspace.media", in: window, enabled: false)
            try await driver.wait("organization media workspace") { editor.workspaceFocus == .media }
            try await driver.click("media.breadcrumb.__root__", in: window)
        }
        func propose(revision: Bool = false) async throws {
            try await media()
            runtime.nextChanges = [["assetId": video.id, "name": revision ? "Second opening" : "Selected opening", "folderPath": ["Reviewed", "Shots"]],
                                   ["assetId": image.id, "name": "Unselected image", "folderPath": ["Unused"]]]
            try await driver.click("media.action.Organize", in: window)
            try await driver.wait("native staged organization") { service.pendingFunction?.mediaOrganizationScope == MediaOrganizationScope(folderID: nil) }
            try await driver.click("agent.task.run", in: window)
            try await driver.wait("native organization proposal", seconds: 30) { !service.isStreaming && service.pendingDialog?.purpose == .mediaOrganization }
            guard runtime.failure == nil, driver.state("agent.dialog.confirm", in: window) == false,
                  let plan = service.pendingDialog?.mediaOrganization, plan.rows.map(\.id) == [video.id, image.id] else {
                throw GateBlocked(runtime.failure ?? "Organization applied or preselected changes without review.")
            }
            let expected = [video.id: revision
                ? "Reviewed / Shots / Selected opening → Reviewed / Shots / Second opening"
                : "Archive / Selected / Opening movement → Reviewed / Shots / Selected opening",
                image.id: "Incoming / Reference → Unused / Unselected image"]
            for row in plan.rows {
                try await driver.reveal("media.organization.choice." + row.id, in: window)
                guard driver.text("media.organization.choice." + row.id, in: window) == expected[row.id] else {
                    throw GateBlocked("The proposal does not show its exact before/after paths.")
                }
            }
        }
        do {
            try await propose()
            guard editor.mediaManifest == before, editor.timeline == timeline else { throw GateBlocked("Preparing organization mutated the project.") }
            try driver.capture("proposal", target: window)
            try await driver.click("agent.dialog.cancel", in: window)
            try await driver.wait("native organization cancel") { service.pendingDialog == nil && !service.isStreaming }
            guard editor.mediaManifest == before, editor.timeline == timeline else { throw GateBlocked("Cancel changed the library.") }
            try await propose()
            try await driver.click("media.organization.choice." + video.id, in: window)
            try await driver.wait("single native organization selection") { service.dialogChoiceSelections["organization"] == [video.id] }
            try driver.capture("selected-change", target: window)
            try await driver.click("agent.dialog.confirm", in: window)
            try await driver.wait("native selected organization apply") { service.pendingDialog == nil && !service.isStreaming && video.name == "Selected opening" }
            let applied = editor.mediaManifest
            guard editor.folderPath(for: video.folderId).map(\.name) == ["Reviewed", "Shots"],
                  !editor.folders.contains(where: { $0.name == "Unused" }),
                  applied.entries.first(where: { $0.id == image.id }) == before.entries.first(where: { $0.id == image.id }),
                  editor.timeline == timeline else { throw GateBlocked("Organization changed unselected media or timeline clips.") }
            guard editor.undoManager?.undoActionName == "Organize Media" else { throw GateBlocked("The organization undo label is incorrect.") }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("one native organization undo") { editor.mediaManifest == before && editor.timeline == timeline }
            guard editor.undoManager?.redoActionName == "Organize Media" else { throw GateBlocked("Organization redo misleadingly names a destructive action.") }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("one native organization redo") { editor.mediaManifest == applied && editor.timeline == timeline }
            guard editor.undoManager?.undoActionName == "Organize Media" else { throw GateBlocked("Organization redo lost its undo identity.") }
            try driver.capture("applied-undo-redo", target: window)
            try await propose(revision: true)
            try await media()
            try await driver.menu("media.menu.View", title: MediaBrowserViewMode.flat.title, in: window)
            try await driver.contextMenu("media.asset." + image.id, path: ["Rename"], in: window)
            try await driver.fill("media.rename." + image.id, value: "Independent edit", in: window, requireFocusExit: true)
            try await driver.wait("independent native rename") { image.name == "Independent edit" }
            let staleBaseline = editor.mediaManifest
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            try await driver.wait("return to organization decision") { editor.workspaceFocus == .production }
            try await driver.click("media.organization.choice." + video.id, in: window)
            try await driver.click("agent.dialog.confirm", in: window)
            try await driver.wait("visible stale organization refusal") { driver.text("agent.dialog.error", in: window)?.contains("library changed") == true }
            guard editor.mediaManifest == staleBaseline, editor.timeline == timeline else { throw GateBlocked("A stale organization proposal partially applied.") }
            try driver.capture("stale-proposal", target: window)
            try await driver.click("agent.dialog.cancel", in: window)
            try await driver.wait("dismiss stale organization") { service.pendingDialog == nil && !service.isStreaming }
            for asset in editor.mediaAssets {
                guard try FileDigest.sha256(of: asset.url) == sourceHashes[asset.id] else { throw GateBlocked("Organization changed original source bytes.") }
            }
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("native organization save", seconds: 30) { !document.isDocumentEdited }
            document.close(); closed = true
            let reopened = try await VideoProject.load(from: package, agentService: AgentService(refreshBackendStatusOnInit: false))
            NSDocumentController.shared.addDocument(reopened)
            reopened.makeWindowControllers()
            defer { reopened.close() }
            guard reopened.editorViewModel.mediaManifest == staleBaseline, reopened.editorViewModel.timeline == timeline,
                  try Data(contentsOf: savedProject.appendingPathComponent(Project.manifestFilename)) == originalManifest,
                  try Data(contentsOf: savedProject.appendingPathComponent(Project.timelineFilename)) == originalTimeline,
                  runtime.mutationRefusals == 6, runtime.reproposalRefusals == 3 else { throw GateBlocked("Organization did not preserve its saved project or reject direct agent mutation.") }
            var result = driver.result()
            result.merge(["selectedAssetID": video.id, "unselectedAssetID": image.id, "nativeProposal": true,
                          "nativeCancel": true, "nativeSelectiveApply": true, "nativeSingleUndoRedo": true,
                          "nativeStaleRefusal": true, "nativeSaveAndReopen": true, "sourceBytesPreserved": true,
                          "originalProjectPreserved": true, "directMutationRefusals": runtime.mutationRefusals,
                          "completedProposalRefusals": runtime.reproposalRefusals, "stableUndoLabels": true,
                          "liveAgent": false]) { _, new in new }
            return result
        } catch { driver.failure(error); throw error }
    }

    private final class FixtureRuntime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        var nextChanges: [[String: Any]]?
        private(set) var mutationRefusals = 0
        private(set) var reproposalRefusals = 0
        private(set) var failure: String?
        private var execute: AgentRuntimeToolExecutor?
        private var task: Task<Void, Never>?

        func start(_ request: AgentRuntimeSessionRequest) throws { execute = request.executeTool; state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            let changes = nextChanges; nextChanges = nil
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            task = Task { @MainActor in
                if let execute {
                    let refused = await execute(UUID().uuidString, "rename_media", "{\"mediaRef\":\"unapproved\",\"name\":\"Must not run\"}")
                    if refused.isError && refused.content.contains(where: { if case .text(let text) = $0 { return text.contains("organization task") }; return false }) {
                        mutationRefusals += 1
                    } else { failure = "The organization turn allowed a direct mutation." }
                    if let changes {
                        do {
                            let bytes = try JSONSerialization.data(withJSONObject: ["changes": changes])
                            let result = await execute(UUID().uuidString, "propose_media_organization", String(decoding: bytes, as: UTF8.self))
                            if result.isError { failure = "The real organization tool rejected the isolated proposal." }
                        } catch { failure = error.localizedDescription }
                    } else {
                        let result = await execute(UUID().uuidString, "propose_media_organization", "{\"changes\":[]}")
                        if result.isError && result.content.contains(where: { if case .text(let text) = $0 { return text.contains("organization task") }; return false }) {
                            reproposalRefusals += 1
                        } else { failure = "The finished organization task repeated its proposal." }
                    }
                }
                pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
                pair.continuation.finish(); state = .ready(sessionID: request.sessionID)
            }
            return pair.stream
        }
        func cancel(sessionID: UUID) { task?.cancel(); state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { cancel(sessionID: sessionID); state = .ended(sessionID: sessionID) }
    }
}
