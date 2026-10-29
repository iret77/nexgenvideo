import AppKit
import NexGenEngine

@MainActor
enum AgentStructuredResultsOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw failed("Explicit native acceptance is required.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let package = output.appendingPathComponent("Structured results.ngv", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var initial = Timeline(); initial.width = 320; initial.height = 180; initial.fps = 30; initial.settingsConfigured = true
        try JSONEncoder().encode(initial).write(to: package.appendingPathComponent(Project.timelineFilename))
        try JSONEncoder().encode(MediaManifest()).write(to: package.appendingPathComponent(Project.manifestFilename))
        try JSONEncoder().encode(GenerationLog()).write(to: package.appendingPathComponent(Project.generationLogFilename))
        let reference = output.appendingPathComponent("Actual result source.png")
        try FullflowAcceptanceFixture.writeReference(to: reference)
        let sourceSHA = try FileDigest.sha256(of: reference)
        let runtime = Runtime()
        let document = try await VideoProject.load(from: package, agentService: runtime.service())
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        var documentClosed = false
        defer { if !documentClosed { document.close() } }
        guard let window = document.windowControllers.first?.window else { throw failed("The actual document did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = MainMenuBuilder.buildMenu(); NSApp.activate(ignoringOtherApps: true)
        let editor = document.editorViewModel, service = editor.agentService
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "agent-structured-owner")
        do {
            try await driver.wait("actual document scale and viewport") {
                window.contentView?.bounds.size == AppTheme.Window.projectMin
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            try await driver.click("editor.workspace.media", in: window, enabled: false)
            try await driver.chooseFile(reference, in: window, trigger: "media.action.Import")
            try await driver.wait("actual image import", seconds: 30) { editor.mediaImportProgress == nil && editor.mediaAssets.count == 1 }
            guard let asset = editor.mediaAssets.first, asset.type == .image,
                  try FileDigest.sha256(of: asset.url) == sourceSHA else { throw failed("The actual import changed its image bytes.") }
            try Data(contentsOf: asset.url).write(to: output.appendingPathComponent("actual-imported-image.bin"))
            runtime.mediaID = asset.id
            let before = editor.timeline, manifest = editor.mediaManifest
            try PlanningWriterIO.json(before).write(to: output.appendingPathComponent("timeline-before.json"))
            try PlanningWriterIO.json(manifest).write(to: output.appendingPathComponent("manifest-before.json"))
            try await driver.click("production.ai", in: window)
            var rendered: [[String: Any]] = []
            for number in 1...3 {
                let tone = ["info", "warn", "success"][number - 1]
                try await send("Show native result \(number).", expected: number, runtime: runtime, service: service, driver: driver)
                guard let call = runtime.calls.last, call.name == "show_blocks", !call.result.isError else { throw failed("The native result did not pass the real schema tool.") }
                let messageID = try structuredMessageID(for: call.id, messages: service.messages)
                let prefix = "agent.structured." + messageID.uuidString.lowercased()
                let target = try await containing(prefix + ".0", driver: driver)
                let expectedObjects: [[String: Any]] = [
                    ["type": "headline", "text": "Native result"],
                    ["type": "text", "body": "Read | compare = actual source before editing."],
                    ["type": "status", "badges": [["label": "State", "value": "Ready"], ["label": "Items", "value": "1"]]],
                    ["type": "keyvalue", "title": "Source", "rows": [["Filename", "Actual result source.png"]]],
                    ["type": "keyvalue", "title": "Timing", "rows": [["Duration", "Still image"]]],
                    ["type": "callout", "tone": tone, "text": "Native \(tone) observation."]]
                let expected = try expectedObjects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0,
                    options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
                for (index, value) in expected.enumerated() {
                    let id = prefix + ".\(index)"
                    try await driver.reveal(id, in: target)
                    try driver.visible([id], in: target)
                    guard driver.text(id, in: target) == value else { throw failed("A visible native block differs from its actual schema tool payload.") }
                    try driver.record("visible structured block", fields: ["turn": number, "index": index, "value": value])
                    if number == 1 || index == 5 { try driver.capture("result-\(number)-block-\(index)", target: target) }
                }
                guard WorkspaceUIAcceptance.probeFrame(identifier: "agent.toolrow.show_blocks", in: target) == nil else {
                    throw failed("A valid structured result fell back to a technical JSON tool row.")
                }
                rendered.append(["turn": number, "tone": tone, "values": expected, "toolUseID": call.id, "messageID": messageID.uuidString])
            }
            try await send("Show a deliberately invalid result to verify refusal.", expected: 4, runtime: runtime, service: service, driver: driver)
            let invalid = try await containing("agent.toolrow.show_blocks", driver: driver)
            try await driver.click("agent.toolrow.show_blocks", in: invalid)
            try await driver.wait("visible actual schema refusal") {
                driver.text("agent.tool.detail.show_blocks", in: invalid)?.hasPrefix("error|") == true
            }
            guard let rejected = runtime.calls.last, rejected.result.isError,
                  driver.text("agent.tool.detail.show_blocks", in: invalid)?.contains("symbol") == true else {
                throw failed("The invalid result was accepted or failed for an unrelated reason.")
            }
            try await driver.reveal("agent.tool.detail.show_blocks", in: invalid)
            try driver.capture("actual-invalid-payload-refusal", target: invalid)
            let errorText = driver.text("agent.tool.detail.show_blocks", in: invalid) ?? ""
            try await send("Inspect the actual imported image.", expected: 5, runtime: runtime, service: service, driver: driver)
            guard let inspected = runtime.calls.last, inspected.name == "inspect_media", !inspected.result.isError,
                  let imageBytes = inspected.result.content.compactMap({ block -> Data? in
                      if case .image(let base64, _) = block { return Data(base64Encoded: base64) }; return nil
                  }).first, let image = NSImage(data: imageBytes),
                  let bitmap = NSBitmapImageRep(data: imageBytes), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
                throw failed("The actual image inspection returned no decodable image.")
            }
            try imageBytes.write(to: output.appendingPathComponent("actual-inspection-image.bin"))
            let activityID = "agent.activity.details." + inspected.id
            let activity = try await containing(activityID, driver: driver)
            try await driver.click(activityID, in: activity)
            try await driver.wait("actual media detail expanded") { driver.text(activityID, in: activity) == "expanded" }
            try await driver.reveal("agent.tool.image", in: activity)
            let dimensions = "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
            let probeDimensions = "\(Int(image.size.width))x\(Int(image.size.height))"
            let pointSize = [Double(image.size.width), Double(image.size.height)]
            guard driver.text("agent.tool.image", in: activity) == probeDimensions else { throw failed("The image renderer differs from the actual tool result.") }
            try driver.capture("actual-image-inline", target: activity)
            try await driver.click("agent.tool.image", in: activity)
            let preview = try await containing("agent.tool.image.preview", driver: driver)
            guard driver.text("agent.tool.image.preview", in: preview) == probeDimensions,
                  driver.state("agent.tool.image.fit", in: preview) == false else { throw failed("The actual image preview did not begin fitted.") }
            try await driver.click("agent.tool.image.larger", in: preview)
            try await driver.wait("actual image zoom available to reset") { driver.state("agent.tool.image.fit", in: preview) == true }
            try driver.capture("actual-image-detail-zoom", target: preview)
            try await driver.click("agent.tool.image.fit", in: preview)
            try await driver.wait("actual fitted image restored") { driver.state("agent.tool.image.fit", in: preview) == false }
            try await driver.click("agent.tool.image.done", in: preview)
            try await driver.wait("actual image detail closed") { !preview.isVisible }
            let sourceAfter = try Data(contentsOf: asset.url)
            let sourceAfterSHA = FileDigest.sha256(of: sourceAfter)
            guard sourceAfterSHA == sourceSHA else { throw failed("A tool changed the actual imported source bytes.") }
            try sourceAfter.write(to: output.appendingPathComponent("actual-imported-image-after.bin"))
            guard editor.timeline == before, editor.mediaManifest == manifest, service.streamError == nil else {
                throw failed("Read-only results changed the film, sources, or failed outside the tested refusal.")
            }
            let requests = runtime.requests, messages = service.messages
            try PlanningWriterIO.json(messages).write(to: output.appendingPathComponent("actual-messages.json"))
            try JSONSerialization.data(withJSONObject: runtime.calls.map(\.record), options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("actual-tool-calls.json"))
            try JSONSerialization.data(withJSONObject: requests, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("actual-requests.json"))
            try PlanningWriterIO.json(editor.timeline).write(to: output.appendingPathComponent("timeline-after.json"))
            try PlanningWriterIO.json(editor.mediaManifest).write(to: output.appendingPathComponent("manifest-after.json"))
            guard let sessionID = service.currentSessionId else { throw failed("The actual conversation has no session identity.") }
            window.makeKeyAndOrderFront(nil)
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            let sessionPath = ChatSessionStore.dirName + "/" + sessionID.uuidString + ".json"
            let sessionFile = package.appendingPathComponent(sessionPath)
            try await driver.wait("actual structured transcript saved", seconds: 30) {
                !document.isDocumentEdited && FileManager.default.fileExists(atPath: sessionFile.path)
            }
            let sessionBytes = try Data(contentsOf: sessionFile)
            let sessionSHA = FileDigest.sha256(of: sessionBytes)
            guard let saved = try ChatSessionStore.loadThrowing(from: package).first(where: { $0.id == sessionID }),
                  saved.messages.count == messages.count,
                  zip(saved.messages, messages).allSatisfy({ $0.0.id == $0.1.id && $0.0.role == $0.1.role && $0.0.blocks == $0.1.blocks }) else {
                throw failed("The product's saved session lost its actual tool transcript.")
            }
            try sessionBytes.write(to: output.appendingPathComponent("actual-session.json"))
            document.close(); documentClosed = true
            let reopenedRuntime = Runtime()
            let reopened = try await VideoProject.load(from: package, agentService: reopenedRuntime.service())
            defer { reopened.close() }
            NSDocumentController.shared.addDocument(reopened); reopened.makeWindowControllers(); reopened.showWindows()
            guard let reopenedWindow = reopened.windowControllers.first?.window else { throw failed("The saved document did not reopen.") }
            reopenedWindow.setContentSize(AppTheme.Window.projectMin); reopenedWindow.makeKeyAndOrderFront(nil)
            let reopenedEditor = reopened.editorViewModel, reopenedService = reopenedEditor.agentService
            guard reopenedService.currentSessionId == sessionID, reopenedService.messages.count == saved.messages.count,
                  zip(reopenedService.messages, saved.messages).allSatisfy({ $0.0.id == $0.1.id && $0.0.role == $0.1.role && $0.0.blocks == $0.1.blocks }),
                  reopenedEditor.timeline == before,
                  let reopenedAsset = reopenedEditor.mediaAssets.first(where: { $0.id == asset.id }),
                  try FileDigest.sha256(of: reopenedAsset.url) == sourceSHA else {
                throw failed("Reopening changed the saved conversation, film or imported source.")
            }
            if reopenedEditor.showsAgentActivity { try await driver.click("production.ai", in: reopenedWindow) }
            try await driver.click("production.ai", in: reopenedWindow)
            for number in 1...3 {
                let messageID = try structuredMessageID(for: runtime.calls[number - 1].id, messages: saved.messages)
                let prefix = "agent.structured." + messageID.uuidString.lowercased()
                let target = try await containing(prefix + ".0", driver: driver)
                let values = try requireValues(rendered[number - 1])
                for (index, value) in values.enumerated() {
                    let id = prefix + ".\(index)"
                    try await driver.reveal(id, in: target)
                    try driver.visible([id], in: target)
                    guard driver.text(id, in: target) == value else { throw failed("A saved native result changed after reopening.") }
                    try driver.record("reopened structured block", fields: ["turn": number, "index": index, "value": value])
                }
                try driver.capture("reopened-result-\(number)", target: target)
            }
            let reopenedInvalid = try await containing("agent.toolrow.show_blocks", driver: driver)
            try await driver.reveal("agent.toolrow.show_blocks", in: reopenedInvalid)
            try await driver.click("agent.toolrow.show_blocks", in: reopenedInvalid)
            try await driver.wait("reopened actual schema refusal") { driver.text("agent.tool.detail.show_blocks", in: reopenedInvalid) == errorText }
            try driver.capture("reopened-invalid-payload-refusal", target: reopenedInvalid)
            let reopenedActivity = try await containing(activityID, driver: driver)
            try await driver.reveal(activityID, in: reopenedActivity)
            try await driver.click(activityID, in: reopenedActivity)
            try await driver.reveal("agent.tool.image", in: reopenedActivity)
            guard driver.text("agent.tool.image", in: reopenedActivity) == probeDimensions else { throw failed("The saved tool image did not render after reopening.") }
            try await driver.click("agent.tool.image", in: reopenedActivity)
            let reopenedPreview = try await containing("agent.tool.image.preview", driver: driver)
            guard driver.text("agent.tool.image.preview", in: reopenedPreview) == probeDimensions else { throw failed("The saved image detail changed after reopening.") }
            try driver.visible(["agent.tool.image.preview"], in: reopenedPreview)
            try driver.capture("reopened-image-detail", target: reopenedPreview)
            try await driver.click("agent.tool.image.done", in: reopenedPreview)
            guard reopenedRuntime.requests.isEmpty, reopenedRuntime.calls.isEmpty,
                  try FileDigest.sha256(of: sessionFile) == sessionSHA else {
                throw failed("Reopening regenerated results or changed the saved session bytes.")
            }
            try PlanningWriterIO.json(reopenedService.messages).write(to: output.appendingPathComponent("reopened-messages.json"))
            try driver.record("actual structured result and media binding", fields: ["assetID": asset.id,
                "sourceSHA256": sourceSHA, "sourceAfterSHA256": sourceAfterSHA,
                "inspectionSHA256": FileDigest.sha256(of: imageBytes), "dimensions": dimensions, "probeDimensions": probeDimensions,
                "invalidToolUseID": rejected.id, "inspectionToolUseID": inspected.id, "error": errorText])
            var result = driver.result()
            result.merge(["schema": "native-agent-structured-results/v1", "scale": scale,
                "viewport": reopenedWindow.contentView.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
                "rendered": rendered, "sourceSHA256": sourceSHA, "assetID": asset.id,
                "inspectionSHA256": FileDigest.sha256(of: imageBytes), "dimensions": dimensions,
                "probeDimensions": probeDimensions, "pointSize": pointSize, "sourceAfterSHA256": sourceAfterSHA,
                "sessionID": sessionID.uuidString, "sessionFile": package.lastPathComponent + "/" + sessionPath,
                "sessionSHA256": sessionSHA, "reopenedWithoutRuntime": true,
                "invalidError": errorText, "inspectionToolUseID": inspected.id, "invalidToolUseID": rejected.id,
                "sourceFile": reference.lastPathComponent, "liveAgent": false,
                "readOnlyTimeline": true, "readOnlyManifest": true]) { _, new in new }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("agent-structured-result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func send(_ text: String, expected: Int, runtime: Runtime, service: AgentService,
        driver: ProductionVisualSourcesDriver) async throws {
        let target = try await containing("agent.composer.input", driver: driver)
        try await driver.fill("agent.composer.input", value: text, in: target)
        try await driver.click("agent.task.run", in: target)
        try await driver.wait("actual structured runtime turn \(expected)", seconds: 30) {
            runtime.calls.count == expected && !service.isStreaming
        }
        guard runtime.failure == nil, (runtime.requests.last?["textBlocks"] as? [String])?.contains(text) == true else {
            throw failed(runtime.failure ?? "The actual native composer direction did not reach its runtime request.")
        }
    }

    private static func containing(_ id: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("native result surface " + id) {
            NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: id, in: $0) != nil }
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: id, in: $0) != nil }) else {
            throw failed("The real result surface disappeared.")
        }
        return window
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native structured results: " + message) }

    private static func structuredMessageID(for callID: String, messages: [AgentMessage]) throws -> UUID {
        let matches = messages.filter { message in
            message.role == .assistant && message.blocks.contains { block in
                if case .toolUse(let id, _, _) = block { return id == callID }
                return false
            }
        }
        guard matches.count == 1, let message = matches.first else { throw failed("The actual structured call has no unique assistant message.") }
        return message.id
    }

    private static func requireValues(_ row: [String: Any]) throws -> [String] {
        guard let values = row["values"] as? [String], values.count == 6 else { throw failed("The original rendered values are missing.") }
        return values
    }

    @MainActor private final class Runtime: AgentRuntimeAdapter {
        struct Call {
            let id: String
            let name: String
            let arguments: String
            let result: ToolResult
            var record: [String: Any] { ["id": id, "name": name, "arguments": arguments,
                "isError": result.isError, "content": result.content.map { value -> [String: Any] in
                    switch value {
                    case .text(let text): ["type": "text", "text": text]
                    case .image(let base64, let mime): ["type": "image", "base64": base64, "mimeType": mime]
                    }
                }] }
        }
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        private var execute: AgentRuntimeToolExecutor?
        private var task: Task<Void, Never>?
        private(set) var calls: [Call] = []
        private(set) var requests: [[String: Any]] = []
        private(set) var failure: String?
        var mediaID: String?
        func service() -> AgentService {
            AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
                runtimeAdapterFactory: { _ in self }, runtimeReadinessOverride: { nil })
        }
        func start(_ request: AgentRuntimeSessionRequest) throws { execute = request.executeTool; state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            task = Task { @MainActor in
                defer { pair.continuation.finish(); state = .ready(sessionID: request.sessionID) }
                do {
                    guard let execute else { throw AgentStructuredResultsOwnerAcceptance.failed("The real host tool executor is unavailable.") }
                    let texts = request.currentMessage.content.compactMap { block -> String? in
                        if case .text(let value) = block { value } else { nil }
                    }
                    requests.append(["sessionID": request.sessionID.uuidString, "turnID": request.turnID.uuidString,
                        "text": texts.joined(separator: "\n"), "textBlocks": texts])
                    let number = requests.count, name: String, arguments: [String: Any]
                    if number <= 3 {
                        let tone = ["info", "warn", "success"][number - 1]
                        name = "show_blocks"
                        arguments = ["version": "1", "blocks": [
                            ["type": "headline", "text": "Native result"],
                            ["type": "text", "body": "Read | compare = actual source before editing."],
                            ["type": "status", "badges": [["label": "State", "value": "Ready"], ["label": "Items", "value": "1"]]],
                            ["type": "keyvalue", "title": "Source", "rows": [["Filename", "Actual result source.png"]]],
                            ["type": "keyvalue", "title": "Timing", "rows": [["Duration", "Still image"]]],
                            ["type": "callout", "tone": tone, "text": "Native \(tone) observation."]]]
                    } else if number == 4 {
                        name = "show_blocks"
                        arguments = ["version": "1", "blocks": [["type": "headline", "text": "Invalid result", "symbol": "not-an-allowed-field"]]]
                    } else {
                        guard number == 5, let mediaID else { throw AgentStructuredResultsOwnerAcceptance.failed("The actual imported inspection target is unavailable.") }
                        name = "inspect_media"; arguments = ["mediaRef": mediaID]
                    }
                    let input = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
                    let id = UUID().uuidString
                    pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                        event: .toolCall(messageID: "structured-\(number)", id: id, name: name, inputJSON: input)))
                    let result = await execute(id, name, input)
                    try Task.checkCancellation()
                    calls.append(.init(id: id, name: name, arguments: input, result: result))
                    pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                        event: .toolResult(id: id, content: result.content, isError: result.isError)))
                    pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
                } catch {
                    failure = error.localizedDescription
                    pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                        event: .error(.init(kind: .protocolViolation, message: error.localizedDescription))))
                    pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.failed)))
                }
            }
            return pair.stream
        }
        func cancel(sessionID: UUID) { task?.cancel(); state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { cancel(sessionID: sessionID); state = .ended(sessionID: sessionID) }
    }
}
