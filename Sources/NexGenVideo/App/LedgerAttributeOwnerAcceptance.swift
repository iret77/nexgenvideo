import AppKit
import NexGenEngine

@MainActor
enum LedgerAttributeOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw failed("Explicit native acceptance is required.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let runtime = Runtime()
        let context = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: runtime.service())
        var closed = false
        defer { context.editor.agentService.cancel(); if !closed { context.document.close() } }
        try await ProductionPlanningAcceptanceFixture.approve("script", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeStoryboard(in: context)
        _ = try await ProductionPlanningAcceptanceFixture.attachSketches(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("storyboard", in: context)
        _ = try await ProductionPlanningAcceptanceFixture.writeShotPlanning(in: context)
        try await ProductionPlanningAcceptanceFixture.approve("shot_planning", in: context)
        try await ProductionPlanningAcceptanceFixture.writeBible(in: context)
        let root = context.dataRoot
        let identity = "ledger_room", ledgerKey = "lighting", address = "location:" + identity
        let appearance = try await ProductionRetainedSpatialAcceptance.prepareAppearanceFixture(context: context,
            locationID: identity, locationName: "Ledger room")
        var initialBible = try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(Bible.self, at: PipelineLayout.bibleFile) }.value
        initialBible.locations.append(try Location(id: identity, name: "Ledger room", visualPrompt: "A room with one side-lit wall.", sheets: ["front": appearance]))
        try await ProductionPlanningAcceptanceFixture.run("write_bible", args: ProductionBibleToolFixture.arguments(initialBible), in: context)
        let initial: [String: Any] = ["kind": "location", "object_id": identity, "key": ledgerKey,
            "tag": "Hard side lighting", "directive": "Light the room from one side; retain the dark opposite wall.",
            "source": "Initial fixture direction", "locked": false]
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: initial, in: context)
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute", args: ["kind": "look", "key": "palette",
            "tag": "Pale walls", "directive": "Retain the pale wall palette.", "source": "Retained fixture direction", "locked": true], in: context)
        NSDocumentController.shared.addDocument(context.document); context.document.makeWindowControllers(); context.document.showWindows()
        guard let window = context.document.windowControllers.first?.window else { throw failed("The genuine Ledger document did not open.") }
        let editor = context.editor
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "native-ledger")
        do {
            await editor.refreshEngineState()
            try await ProductionV2PlanningAcceptance.selectPhase("bible", context: context, driver: driver)
            try await driver.segment("bible.section", title: "Locations", titles: ["Characters", "Ensembles", "Props", "Locations", "Look", "Shot references"], in: window)
            try await driver.click("bible.entity.select.location." + identity, in: window)
            try await driver.wait("actual entity Inspector selected") { editor.inspectedObject == .entity(.init(kind: .location, id: identity)) }
            let before = try await snapshot(root)
            let bibleBefore = try await bibleSnapshot(root)
            try PlanningWriterIO.json(before.0).write(to: output.appendingPathComponent("ledger-initial.json"))
            let initialBytes = before.2
            guard FileDigest.sha256(of: initialBytes) == before.1 else { throw failed("The initial Ledger bytes changed while capturing them.") }
            try initialBytes.write(to: output.appendingPathComponent("ledger-initial.yaml"))
            try PlanningWriterIO.json(bibleBefore.0).write(to: output.appendingPathComponent("bible-before.json"))
            try bibleBefore.2.write(to: output.appendingPathComponent("bible-before.yaml"))
            guard let initialAttribute = before.0.objects[address]?[ledgerKey] else { throw failed("The initial Ledger attribute is missing.") }
            try await showDetails(expected: initialAttribute, address: address, key: ledgerKey, window: window, driver: driver)
            try driver.capture("actual-directive-source", target: try await details(driver))
            try await driver.click("ledger.done", in: try await details(driver))
            var steps: [[String: Any]] = []
            var values: [String: (Ledger, String)] = [:]
            var busyUndo: [String: Any] = [:]
            func revise(_ name: String, tool: String, arguments: [String: Any], direction: String, expectsError: Bool = false, holdAfterResult: Bool = false) async throws {
                let previous = try await snapshot(root)
                guard let attribute = previous.0.objects[address]?[ledgerKey] else { throw failed("The actual Ledger attribute disappeared.") }
                try await showDetails(expected: attribute, address: address, key: ledgerKey, window: window, driver: driver)
                let popover = try await details(driver)
                try runtime.arm(tool: tool, arguments: arguments, direction: direction, objectID: identity, key: ledgerKey, holdAfterResult: holdAfterResult)
                try await driver.click("ledger.revise", in: popover)
                try await driver.wait("Ledger detail closed after genuine task staging") { !popover.isVisible || WorkspaceUIAcceptance.probeFrame(identifier: "ledger.details", in: popover) == nil }
                try await driver.wait("actual bounded Ledger task") { driver.text("agent.task.staged", in: window) == "Revise: " + ledgerKey }
                try await driver.fill("agent.composer.input", value: direction, in: window, requireFocusExit: true,
                    commitByClicking: "pipeline.overview.select.bible")
                let count = runtime.results.count
                try await driver.click("agent.task.run", in: window)
                try await driver.wait("actual Ledger tool result " + name, seconds: 30) { runtime.results.count > count && (holdAfterResult ? runtime.isHolding && editor.agentService.isStreaming : !editor.agentService.isStreaming) }
                guard let actual = runtime.results.last, actual.isError == expectsError,
                      editor.agentService.streamError == nil else { throw failed("The scoped Ledger tool did not produce its expected actual result.") }
                let current = try await snapshot(root)
                if expectsError {
                    guard current.1 == previous.1, current.0 == previous.0,
                          actual.text.contains("attributeLocked") else { throw failed("Locked removal changed the Ledger or failed for an unrelated reason.") }
                }
                let file = "ledger-" + name + ".json"
                try PlanningWriterIO.json(current.0).write(to: output.appendingPathComponent(file))
                let yaml = current.2
                guard FileDigest.sha256(of: yaml) == current.1 else { throw failed("The retained actual Ledger bytes changed during evidence capture.") }
                try yaml.write(to: output.appendingPathComponent("ledger-" + name + ".yaml"))
                let evidence: [String: Any] = ["name": name, "tool": tool, "arguments": arguments, "isError": actual.isError,
                    "result": actual.text, "direction": direction, "requestContext": actual.context,
                    "sha256Before": previous.1, "sha256After": current.1, "ledger": file]
                try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("step-" + name + ".json"))
                try driver.record("actual Ledger " + name, fields: evidence); steps.append(evidence)
                values[name] = (current.0, current.1)
            }
            let target: [String: Any] = ["kind": "location", "object_id": identity, "key": ledgerKey]
            try await revise("lock", tool: "lock_ledger_attribute", arguments: target.merging(["locked": true]) { _, new in new }, direction: "Lock this lighting attribute; preserve its tag, directive and original source.")
            try await revise("locked-removal-refused", tool: "remove_ledger_attribute", arguments: target, direction: "Remove this lighting attribute without unlocking it.", expectsError: true)
            try await revise("unlock", tool: "lock_ledger_attribute", arguments: target.merging(["locked": false]) { _, new in new }, direction: "Unlock only this lighting attribute so I can revise it.")
            let newDirection = "Keep warm side light and a dark opposite wall."
            try await revise("edit", tool: "set_ledger_attribute", arguments: target.merging(["tag": "Warm side lighting", "directive": newDirection,
                "source": newDirection, "locked": false]) { _, new in new }, direction: newDirection)
            try await revise("relock", tool: "lock_ledger_attribute", arguments: target.merging(["locked": true]) { _, new in new }, direction: "Lock the revised warm lighting for subsequent generation.", holdAfterResult: true)
            let final = try await snapshot(root)
            guard final.0.objects[address]?.count == 1, let attribute = final.0.objects[address]?[ledgerKey],
                  attribute.tag == "Warm side lighting", attribute.directive == newDirection, attribute.source == newDirection, attribute.locked,
                  final.0.objects.filter({ $0.key != address }) == before.0.objects.filter({ $0.key != address }),
                  try await bibleSnapshot(root).1 == bibleBefore.1 else { throw failed("Reconciliation duplicated the key or changed its actual source, lock or Bible entity.") }
            try await showDetails(expected: attribute, address: address, key: ledgerKey, window: window, driver: driver)
            let finalDetails = try await details(driver)
            try driver.capture("reconciled-locked-attribute", target: finalDetails)
            try await driver.click("ledger.done", in: finalDetails)
            func restore(_ expected: (Ledger, String), redo: Bool = false, name: String, observeBusy: Bool = false) async throws {
                try await driver.click("pipeline.overview.select.bible", in: window, enabled: false)
                try await driver.wait("document owns native Ledger Undo") {
                    !(window.firstResponder is NSTextView) && window.firstResponder?.undoManager === editor.undoManager
                }
                guard let action = redo ? editor.undoManager?.redoActionName : editor.undoManager?.undoActionName,
                      action == "Revise Attribute" else {
                    throw failed("The next native Undo/Redo action belongs to another edit.")
                }
                try driver.record("before native Ledger " + name, fields: ["actionName": action, "redo": redo,
                    "expectedRevisionSHA256": expected.1, "documentOwnsUndo": window.firstResponder?.undoManager === editor.undoManager])
                let revision = editor.engineStateRevision
                try driver.pressKey(6, characters: redo ? "Z" : "z", modifiers: redo ? [.command, .shift] : .command, in: window)
                if observeBusy {
                    try await driver.wait("visible Ledger restore waits for the actual held agent") {
                        PipelineLedgerWriter.isRestoring(editor: editor) && editor.agentService.isStreaming
                            && driver.text("ledger.restore.pending", in: window) == PipelineLedgerWriter.restoreMessage(editor: editor)
                    }
                    let held = try await snapshot(root)
                    guard held.1 == final.1, runtime.isHolding else { throw failed("The waiting restore changed Ledger values.") }
                    try held.2.write(to: output.appendingPathComponent("ledger-busy-before.yaml"))
                    guard let editMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else { throw failed("The real Edit menu is missing.") }
                    editMenu.update()
                    guard let undo = editMenu.items.first(where: { $0.action == NSSelectorFromString("undo:") }),
                          let redo = editMenu.items.first(where: { $0.action == NSSelectorFromString("redo:") }),
                          !undo.isEnabled, !redo.isEnabled else { throw failed("Native Undo/Redo remains enabled during restore.") }
                    try driver.capture("ledger-busy-waiting", target: window)
                    try driver.record("Ledger busy rapid begin", fields: ["ledgerSHA256": held.1, "undoEnabled": undo.isEnabled,
                        "redoEnabled": redo.isEnabled, "message": driver.text("ledger.restore.pending", in: window) ?? "", "streaming": editor.agentService.isStreaming])
                    let delivery = KeyDelivery(), windowNumber = window.windowNumber
                    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                        let number = event.windowNumber, code = event.keyCode, flags = event.modifierFlags.rawValue
                        MainActor.assumeIsolated {
                            if number == windowNumber && code == 6 { delivery.modifiers.append(flags) }
                        }
                        return event
                    }
                    defer { if let monitor { NSEvent.removeMonitor(monitor) } }
                    try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
                    try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
                    try await driver.wait("both rapid native Undo/Redo key-ups delivered") { delivery.modifiers.count == 2 }
                    let afterRapid = try await snapshot(root)
                    guard afterRapid.2 == held.2, runtime.isHolding, PipelineLedgerWriter.isRestoring(editor: editor),
                          editor.agentService.isStreaming else { throw failed("Rapid Undo/Redo bypassed the pending restore.") }
                    try afterRapid.2.write(to: output.appendingPathComponent("ledger-busy-after.yaml"))
                    try driver.record("Ledger busy rapid end", fields: ["ledgerSHA256": afterRapid.1, "deliveredModifiers": delivery.modifiers])
                    try await driver.click("ledger.restore.show-agent", in: window)
                    try await driver.wait("actual Stop action in visible Agent") {
                        NSApp.windows.contains { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: "agent.stop", in: $0) != nil }
                    }
                    guard let agentWindow = NSApp.windows.first(where: { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: "agent.stop", in: $0) != nil }) else { throw failed("The real Agent stop control did not appear.") }
                    try driver.capture("ledger-busy-agent-stop", target: agentWindow)
                    try await driver.click("agent.stop", in: agentWindow)
                    try await driver.wait("native Stop releases the actual held agent") { !runtime.isHolding && !editor.agentService.isStreaming }
                    busyUndo = ["beforeSHA256": held.1, "afterRapidSHA256": afterRapid.1,
                        "deliveredModifiers": delivery.modifiers, "stopReleasedAgent": true]
                    try driver.record("Ledger busy native Stop completed", fields: busyUndo)
                }
                try await driver.wait("actual Ledger " + name) { editor.engineStateRevision > revision }
                guard try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: editor) == expected.0 else {
                    throw failed("The actual native Ledger restore did not finish with its expected state.")
                }
                let actual = try await snapshot(root)
                guard actual.0 == expected.0 else { throw failed("Native Ledger Undo/Redo did not restore the full exact reconciled object state.") }
                try PlanningWriterIO.json(actual.0).write(to: output.appendingPathComponent("ledger-" + name + ".json"))
                try actual.2.write(to: output.appendingPathComponent("ledger-" + name + ".yaml"))
                try driver.record("native Ledger " + name, fields: ["ledgerSHA256": actual.1, "expectedRevisionSHA256": expected.1])
            }
            guard let unlockValue = values["unlock"], let editValue = values["edit"] else { throw failed("The actual Ledger revision values were not captured.") }
            try await restore(editValue, name: "undo-relock", observeBusy: true)
            try await restore(unlockValue, name: "undo-edit")
            try await restore(editValue, redo: true, name: "redo-edit")
            try await restore((final.0, final.1), redo: true, name: "redo-relock")
            let bounds = window.contentView!.bounds
            guard bounds.size == AppTheme.Window.projectMin,
                  AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else { throw failed("The actual Ledger viewport or interface scale changed.") }
            let beforeSave = try await snapshot(root)
            guard beforeSave.0 == final.0,
                  editor.workingRoot?.standardizedFileURL != context.packageURL.standardizedFileURL else { throw failed("The save proof does not have a separate current working copy.") }
            try await driver.wait("Ledger document dirty before native Save") { context.document.isDocumentEdited }
            try beforeSave.2.write(to: output.appendingPathComponent("ledger-before-save.yaml"))
            try driver.record("before native Ledger Save", fields: ["documentDirty": context.document.isDocumentEdited, "ledgerSHA256": beforeSave.1])
            try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
            try await driver.wait("Ledger saved natively", seconds: 30) { !context.document.isDocumentEdited }
            context.document.close(); closed = true
            let reopened = try await VideoProject.load(from: context.packageURL, agentService: Runtime().service())
            defer { reopened.close() }
            guard let reopenedHome = reopened.editorViewModel.workingRoot, let reopenedRoot = DataRootResolver.dataRoot(of: reopenedHome),
                  try await snapshot(reopenedRoot).0 == final.0 else { throw failed("Save/reopen lost the reconciled Ledger value, provenance or lock.") }
            let reopenedValue = try await snapshot(reopenedRoot), actualBible = try await bibleSnapshot(reopenedRoot)
            guard reopenedValue.1 == beforeSave.1, actualBible.1 == bibleBefore.1 else { throw failed("Save/reopen changed the actual Ledger or retained Bible bytes.") }
            try PlanningWriterIO.json(reopenedValue.0).write(to: output.appendingPathComponent("ledger-reopened.json"))
            try reopenedValue.2.write(to: output.appendingPathComponent("ledger-reopened.yaml"))
            try PlanningWriterIO.json(actualBible.0).write(to: output.appendingPathComponent("bible-after.json"))
            try actualBible.2.write(to: output.appendingPathComponent("bible-after.yaml"))
            NSDocumentController.shared.addDocument(reopened); reopened.makeWindowControllers(); reopened.showWindows()
            guard let reopenedWindow = reopened.windowControllers.first?.window else { throw failed("The saved Ledger document did not reopen visibly.") }
            reopenedWindow.setContentSize(AppTheme.Window.projectMin); reopenedWindow.makeKeyAndOrderFront(nil)
            let reopenedContext = ProductionPlanningAcceptanceFixture.Context(document: reopened, packageURL: context.packageURL,
                dataRoot: reopenedRoot, executor: ToolExecutor(editor: reopened.editorViewModel))
            try await reopened.editorViewModel.refreshEngineState()
            try await ProductionV2PlanningAcceptance.selectPhase("bible", context: reopenedContext, driver: driver)
            try await driver.segment("bible.section", title: "Locations", titles: ["Characters", "Ensembles", "Props", "Locations", "Look", "Shot references"], in: reopenedWindow)
            try await driver.click("bible.entity.select.location." + identity, in: reopenedWindow)
            guard let reopenedAttribute = reopenedValue.0.objects[address]?[ledgerKey] else { throw failed("The reopened Ledger attribute is missing.") }
            try await showDetails(expected: reopenedAttribute, address: address, key: ledgerKey, window: reopenedWindow, driver: driver)
            let reopenedDetails = try await details(driver)
            try driver.capture("saved-ledger-reopened", target: reopenedDetails)
            try driver.record("actual reopened Ledger details", fields: ["ledgerSHA256": reopenedValue.1, "bibleSHA256": actualBible.1])
            try await driver.click("ledger.done", in: reopenedDetails)
            guard let field = driver.interactions.compactMap({ $0["field"] as? [String: Any] }).last(where: { $0["id"] as? String == "agent.composer.input" }),
                  let font = field["fontPointSize"] as? CGFloat, abs(font - AppTheme.Typography.ui * scale) < 0.5 else { throw failed("The actual native Ledger task typography did not use its requested scale.") }
            let result: [String: Any] = ["objectKey": address, "attributeKey": ledgerKey, "steps": steps, "savedAndReopened": true, "nativeUndoRedo": true,
                "busyUndo": busyUndo,
                "initialFixture": "Canonical Core planning writers, confirmed appearance fixture, one initially unlocked Location attribute and a distinct retained locked Look attribute; later lock/revision decisions use real native input.",
                "bibleSHA256Before": bibleBefore.1, "bibleSHA256After": actualBible.1,
                "ledgerSHA256BeforeSave": beforeSave.1, "ledgerSHA256Reopened": reopenedValue.1,
                "viewport": [bounds.width, bounds.height], "scale": scale, "renderedFontPointSize": Double(font), "liveAgent": false, "native": driver.result()]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ledger-owner-result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func showDetails(expected: Attribute, address: String, key: String, window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("current Ledger tag") { driver.text("ledger.attribute." + address + "." + key, in: window) == expected.tag }
        try await driver.click("ledger.attribute." + address + "." + key, in: window)
        let popover = try await details(driver)
        try await driver.wait("actual Ledger directive and provenance") {
            driver.text("ledger.details", in: popover) == address + "." + key
                && driver.text("ledger.directive", in: popover) == expected.directive && driver.text("ledger.source", in: popover) == expected.source
                && driver.state("ledger.locked", in: popover) == expected.locked
        }
        guard let identifier = driver.text("ledger.details", in: popover), let directive = driver.text("ledger.directive", in: popover),
              let source = driver.text("ledger.source", in: popover), let locked = driver.state("ledger.locked", in: popover) else {
            throw failed("The actual Ledger detail disappeared before its evidence was captured.")
        }
        try driver.record("actual Ledger detail", fields: ["identifier": identifier,
            "directive": directive, "source": source, "locked": locked, "window": popover.windowNumber])
    }
    private static func details(_ driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("native Ledger details popover") { NSApp.windows.contains { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: "ledger.details", in: $0) != nil } }
        guard let window = NSApp.windows.first(where: { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: "ledger.details", in: $0) != nil }) else { throw failed("The Ledger detail view disappeared.") }
        return window
    }
    private static func snapshot(_ root: URL) async throws -> (Ledger, String, Data) {
        try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.ledgerFile, dataRoot: root))
            guard let text = String(data: bytes, encoding: .utf8) else { throw failed("The Ledger is not UTF-8.") }
            return (try YAMLCoding.decode(Ledger.self, from: text), FileDigest.sha256(of: bytes), bytes)
        }.value
    }
    private static func bibleSnapshot(_ root: URL) async throws -> (Bible, String, Data) {
        try await Task.detached {
            let bytes = try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.bibleFile, dataRoot: root))
            guard let text = String(data: bytes, encoding: .utf8) else { throw failed("The Bible is not UTF-8.") }
            return (try YAMLCoding.decode(Bible.self, from: text), FileDigest.sha256(of: bytes), bytes)
        }.value
    }
    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native Ledger acceptance: " + message) }

    @MainActor private final class KeyDelivery { var modifiers: [UInt] = [] }

    @MainActor private final class Runtime: AgentRuntimeAdapter {
        struct Result { let isError: Bool; let text: String; let context: String }
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: ["set_ledger_attribute", "lock_ledger_attribute", "remove_ledger_attribute"], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        private(set) var results: [Result] = []
        private var session: AgentRuntimeSessionRequest?
        private var next: (tool: String, arguments: String, direction: String, objectID: String, key: String, holdAfterResult: Bool)?
        private var task: Task<Void, Never>?
        private var heldResult: CheckedContinuation<Void, Never>?
        var isHolding: Bool { heldResult != nil }
        func service() -> AgentService { AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false, runtimeAdapterFactory: { _ in self }, runtimeReadinessOverride: { nil }) }
        func arm(tool: String, arguments: [String: Any], direction: String, objectID: String, key: String, holdAfterResult: Bool = false) throws {
            next = (tool, String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self), direction, objectID, key, holdAfterResult)
        }
        func start(_ request: AgentRuntimeSessionRequest) throws {
            guard WorkspaceUIAcceptance.isRequested, request.hostContext.pack == nil else { throw failed("The runtime fixture is confined to the actual Core document.") }
            session = request; state = .ready(sessionID: request.sessionID)
        }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            guard let session, let next else {
                return AsyncStream { continuation in
                    continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn)))); continuation.finish()
                }
            }
            let texts = request.currentMessage.content.compactMap { block -> String? in if case .text(let value) = block { value } else { nil } }
            guard session.sessionID == request.sessionID, texts.contains(where: { $0.contains(next.direction) }),
                  let context = texts.first(where: { $0.hasPrefix("<app-context>") }), context.contains(next.objectID),
                  ["set_ledger_attribute", "lock_ledger_attribute", "remove_ledger_attribute"].contains(next.tool) else { throw failed("The actual bounded task lost its selected entity or direction.") }
            self.next = nil; state = .running(sessionID: request.sessionID, turnID: request.turnID)
            return AsyncStream { continuation in
                task = Task { @MainActor in
                    let id = "native-ledger-" + UUID().uuidString
                    func emit(_ value: AgentRuntimeEvent) { continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: value)) }
                    emit(.toolCall(messageID: nil, id: id, name: next.tool, inputJSON: next.arguments))
                    let result = await session.executeTool(id, next.tool, next.arguments)
                    let text = result.content.compactMap { block -> String? in if case .text(let value) = block { value } else { nil } }.joined(separator: "\n")
                    results.append(.init(isError: result.isError, text: text, context: context))
                    emit(.toolResult(id: id, content: result.content, isError: result.isError))
                    if next.holdAfterResult, !Task.isCancelled {
                        await withCheckedContinuation { heldResult = $0 }
                    }
                    guard !Task.isCancelled else { continuation.finish(); return }
                    emit(.terminal(.completed(.endTurn))); state = .ready(sessionID: request.sessionID); continuation.finish()
                }
            }
        }
        func cancel(sessionID: UUID) { task?.cancel(); let held = heldResult; heldResult = nil; held?.resume(); task = nil; state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { task?.cancel(); let held = heldResult; heldResult = nil; held?.resume(); task = nil; session = nil; state = .ended(sessionID: sessionID) }
    }
}
