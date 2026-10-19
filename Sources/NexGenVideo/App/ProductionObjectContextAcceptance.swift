import AppKit
import NexGenEngine

@MainActor
enum ProductionObjectContextAcceptance {
    static func run(savedProject: URL, output: URL, scale: Double) async throws -> [[String: Any]] {
        let original = try ExportQueue.PathState.capture(savedProject)
        guard let identity = ProjectIdentity.existingUUID(for: savedProject), original.digest != nil,
              !NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject }).contains(where: { $0.editorViewModel.projectId == identity }),
              try ProjectWorkingCopy.recoverableDirtyHome(for: savedProject) == nil else {
            throw failure("Save and close the original production before its isolated object/history acceptance.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard [AppTheme.Typography.standardScale, AppTheme.Typography.largeScale, AppTheme.Typography.largestScale].contains(scale),
              AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else {
            throw failure("The actual outer owner interface scale changed before object/history acceptance.")
        }
        var results: [[String: Any]] = []
        do {
            let directory = output.appendingPathComponent("object-context-\(Int(scale * 100))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let package = directory.appendingPathComponent("Production objects.ngv")
            try FileManager.default.copyItem(at: savedProject, to: package)
            let legacy = try legacyFixture(package: package, directory: directory)
            let seed = legacy.session
            let runtime = RecordingRuntime()
            let service = runtime.service()
            let document = try await VideoProject.load(from: package, agentService: service)
            NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
            var closed = false
            defer { if !closed { document.close() } }
            guard let window = document.windowControllers.first?.window, let home = document.editorViewModel.workingRoot,
                  let root = DataRootResolver.dataRoot(of: home) else { throw failure("The isolated genuine production did not open.") }
            let editor = document.editorViewModel
            window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let originalMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = originalMenu }
            NSApp.mainMenu = MainMenuBuilder.buildMenu()
            let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: "native-object-context")
            do {
                await editor.refreshEngineState()
                guard editor.projectId == identity, editor.usesProductionPlanningV2,
                      let readContext = ProductionObjectNavigation.Context(editor) else { throw failure("Opening the copy changed its authenticated production identity.") }
                let navigation = try await Task.detached { try ProductionObjectNavigation.read(readContext) }.value
                guard let link = navigation.links.first(where: { $0.input != nil && !$0.referenceAssetIDs.isEmpty }),
                      let input = link.input, let originalID = link.referenceAssetIDs.first,
                      let reference = editor.mediaAssets.first(where: { $0.id == originalID }),
                      editor.clipFor(id: link.clipID) != nil, let currentPackage = link.package else {
                    throw failure("This owner path needs a genuinely generated assembled clip with an actual project-local conditioning reference.")
                }
                let packageID = currentPackage.id
                let mediaURL = try requireURL(editor.mediaResolver.resolveURL(for: link.mediaID))
                let outputSHA = try await Task.detached { try FileDigest.sha256(of: mediaURL) }.value
                let originalURL = reference.url
                let isolatedHome = home.resolvingSymlinksInPath().standardizedFileURL
                let originalProject = savedProject.resolvingSymlinksInPath().standardizedFileURL
                let resolvedReference = originalURL.resolvingSymlinksInPath().standardizedFileURL
                let properties = try originalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      resolvedReference.path.hasPrefix(isolatedHome.path + "/"),
                      !resolvedReference.path.hasPrefix(originalProject.path + "/") else {
                    throw failure("The conditioning reference must be a regular file inside this isolated working copy, outside the original production.")
                }
                let isolatedReferencePath = String(resolvedReference.path.dropFirst(isolatedHome.path.count + 1))
                let referenceSHA = try await Task.detached { try FileDigest.sha256(of: originalURL) }.value
                try await Task.detached {
                    let proof = try PipelineProductionAssemblyWriter.requireCurrent(dataRoot: root)
                    guard let placement = proof.placements.first(where: { $0.clipID == link.clipID }), let takeID = placement.takeID else { throw failure("The genuine assembled clip has no selected take.") }
                    let take = try PipelineProductionRenderWriter.requireRecord(takeID: takeID, dataRoot: root)
                    let receipt = try GenerationOutputReceipt.load(assetID: take.generation.id, home: home)
                    try PlanningWriterIO.json(proof).write(to: directory.appendingPathComponent("actual-assembly.json"))
                    try Data(contentsOf: ProjectLocalFile.resolve(PipelineProductionAssemblyWriter.receiptPath, dataRoot: root))
                        .write(to: directory.appendingPathComponent("actual-assembly-host.json"))
                    try PlanningWriterIO.json(take).write(to: directory.appendingPathComponent("actual-take.json"))
                    try PlanningWriterIO.json(receipt).write(to: directory.appendingPathComponent("actual-output-receipt.json"))
                }.value
                guard let actualReference = currentPackage.payload.references.first(where: { $0.assetID == originalID }),
                      actualReference.sourceSHA256 == referenceSHA else { throw failure("The chosen reference differs from its genuine generation package.") }
                try PlanningWriterIO.json(navigation.planning.projection).write(to: directory.appendingPathComponent("actual-production-plan.json"))
                try JSONEncoder().encode(input).write(to: directory.appendingPathComponent("actual-generation-input.json"))
                try PlanningWriterIO.json(currentPackage).write(to: directory.appendingPathComponent("actual-generation-package.json"))
                try FileManager.default.copyItem(at: mediaURL, to: directory.appendingPathComponent("actual-assembled-source.mov"))
                try FileManager.default.copyItem(at: reference.url, to: directory.appendingPathComponent("actual-input-reference"))
                let canonical = try await canonicalBytes(root)
                guard let bounds = window.contentView?.bounds, bounds.size == AppTheme.Window.projectMin else {
                    throw failure("The actual minimum document viewport changed.")
                }
                let viewport = [bounds.width, bounds.height], backingScale = window.backingScaleFactor
                func productionShot() async throws {
                    if WorkspaceUIAcceptance.probeFrame(identifier: "production.activity.close", in: window) != nil {
                        try await driver.click("production.activity.close", in: window)
                    }
                    try await driver.click("editor.workspace.production", in: window, enabled: false)
                    if !editor.inspectorPanelVisible { try await AppNativeMenuAcceptance.choose(["View", "Inspector"], in: window, driver: driver) }
                    try await driver.click("pipeline.overview.select.shotlist", in: window, enabled: false)
                    try await driver.click("production.plan.select." + link.shotID, in: window)
                    try await driver.wait("actual selected production shot") {
                        editor.productionPlanSelection?.shotID == link.shotID
                            && driver.state("production.object.clip." + link.clipID, in: window) == true
                    }
                }
                let performer = BibleEntityRef(kind: .character, id: ProductionBibleEntityAcceptance.performerID)
                guard navigation.planning.projection.shots.first(where: { $0.id == link.shotID })?.blocking.contains(where: { $0.entityID == performer.id }) == true,
                      editor.bible?.entity(performer) != nil else { throw failure("The actual generated shot must canonically use the prepared character.") }
                try await Task.detached {
                    guard let bible = try loadBible(dataRoot: root) else { throw failure("The canonical References document is missing.") }
                    try PlanningWriterIO.json(bible).write(to: directory.appendingPathComponent("actual-bible.json"))
                }.value
                try await productionShot()
                try await driver.click("pipeline.overview.select.bible", in: window, enabled: false)
                try await driver.segment("bible.section", title: "Characters", titles: BiblePanelView.Section.allCases.map(\.rawValue), in: window)
                try await driver.click("bible.entity.select.character." + performer.id, in: window)
                try await driver.wait("actual used character Inspector") { editor.inspectedObject == .entity(performer) && editor.inspectorPanelVisible }
                let usageProbe = "inspector.usage.shot." + link.shotID
                try await driver.reveal(usageProbe, in: window)
                guard let shotLabel = driver.text(usageProbe, in: window), !shotLabel.isEmpty else { throw failure("The canonical used character has no visible Used in shots link.") }
                try driver.capture("character-used-in-shots", target: window)
                try await driver.click(usageProbe, in: window)
                try await driver.wait("actual shot Inspector from character usage") {
                    editor.inspectedObject == .shot(link.shotID) && driver.text("inspector.shot." + link.shotID, in: window) == link.shotID
                }
                try driver.capture("character-usage-shot-inspector", target: window)
                try driver.record("canonical character usage navigation", fields: ["entityID": performer.id, "entityKind": performer.kind.rawValue,
                    "shotID": link.shotID, "visibleShotLabel": shotLabel, "inspectedShotID": link.shotID,
                    "bibleSHA256": try FileDigest.sha256(of: directory.appendingPathComponent("actual-bible.json")),
                    "planSHA256": try FileDigest.sha256(of: directory.appendingPathComponent("actual-production-plan.json"))])
                try await productionShot()
                try driver.capture("production-shot", target: window)
                try await driver.click("production.object.clip." + link.clipID, in: window)
                try await driver.wait("actual assembly clip and verified origin") {
                    editor.workspaceFocus == .edit && editor.selectedClipIds == [link.clipID]
                        && driver.text("asset.\(link.mediaID).origin.Model ID", in: window) == input.model
                        && driver.text("asset.\(link.mediaID).origin.Generation receipt", in: window) == "Verified"
                        && driver.text("asset.\(link.mediaID).origin.Submitted prompt", in: window) == currentPackage.payload.prompt
                }
                let visibleModel = driver.text("asset.\(link.mediaID).origin.Model ID", in: window) ?? ""
                let visiblePrompt = driver.text("asset.\(link.mediaID).origin.Submitted prompt", in: window) ?? ""
                let visibleReceipt = driver.text("asset.\(link.mediaID).origin.Generation receipt", in: window) ?? ""
                try await driver.wait("actual placed clip relationship label") {
                    driver.text("production.object.shot." + link.shotID, in: window)?.hasSuffix(" · Placed clip") == true
                }
                let placedRelation = driver.text("production.object.shot." + link.shotID, in: window) ?? ""
                guard placedRelation.hasSuffix(" · Placed clip") else { throw failure("The actual clip relation was not distinguished from a reference input.") }
                try await driver.reveal("asset.\(link.mediaID).original.\(originalID)", in: window)
                try driver.capture("clip-origin", target: window)
                let referenceBytes = try Data(contentsOf: originalURL)
                var referenceRestored = false
                defer { if !referenceRestored { try? referenceBytes.write(to: originalURL, options: .atomic) } }
                try Data("changed input revision".utf8).write(to: originalURL, options: .atomic)
                try await driver.click("asset.\(link.mediaID).original.\(originalID)", in: window)
                try await driver.wait("changed original source refused visibly") {
                    driver.text("asset.original.error", in: window)?.contains("original input revision changed") == true
                        && editor.activePreviewTab == .timeline && editor.selectedClipIds == [link.clipID]
                }
                let sourceError = driver.text("asset.original.error", in: window) ?? ""
                try driver.capture("changed-original-refused", target: window)
                try referenceBytes.write(to: originalURL, options: .atomic); referenceRestored = true
                try await driver.click("asset.\(link.mediaID).original.\(originalID)", in: window)
                try await driver.wait("actual input reference selected") {
                    guard case .mediaAsset(let id, _, _) = editor.activePreviewTab, id == originalID else { return false }
                    return editor.inspectedObject == .mediaAsset(originalID)
                        && driver.state("production.object.shot." + link.shotID, in: window) == true
                }
                try driver.capture("actual-reference", target: window)
                let referenceRelation = driver.text("production.object.shot." + link.shotID, in: window) ?? ""
                guard referenceRelation.hasSuffix(" · Reference input") else { throw failure("The actual original reference relation did not identify its purpose.") }
                try await driver.click("production.object.shot." + link.shotID, in: window)
                try await driver.wait("return to actual originating shot") {
                    editor.workspaceFocus == .production && editor.productionPlanSelection?.shotID == link.shotID
                }
                try driver.record("verified object navigation", fields: ["shotID": link.shotID, "clipID": link.clipID,
                    "mediaID": link.mediaID, "referenceAssetID": originalID, "generationPackageID": packageID,
                    "isolatedReferencePath": isolatedReferencePath,
                    "modelID": input.model, "outputSHA256": outputSHA, "referenceSHA256": referenceSHA,
                    "visibleModelID": visibleModel, "visibleSubmittedPrompt": visiblePrompt, "visibleGenerationReceipt": visibleReceipt,
                    "visiblePlacedRelation": placedRelation, "visibleReferenceRelation": referenceRelation,
                    "changedOriginalRefused": true, "changedOriginalError": sourceError])
                try await AppNativeMenuAcceptance.choose(["Agent", "Conversation History"], in: window, driver: driver)
                let history = try await containing("agent.history.search", driver: driver)
                try await driver.fill("agent.history.search", value: seed.title, in: history)
                try await driver.click("agent.history.select." + seed.id.uuidString, in: history)
                try await driver.wait("older decoded conversation selected") { service.currentSessionId == seed.id && window.isKeyWindow }
                guard service.messages == seed.messages else { throw failure("Selecting the older conversation rewrote its original messages.") }
                let oldPrefix = try messageBytes(service.messages)
                try oldPrefix.write(to: directory.appendingPathComponent("history-prefix-before.json"))
                let preservedSessions = service.sessions.filter { $0.id != seed.id }.map { ($0.id, $0.messages) }
                func task(_ kind: String, expected: AgentTaskSelectionContext, switchAfterStaging: Bool) async throws {
                    guard let expectedLabel = expected.label, !expectedLabel.isEmpty else { throw failure("The actual task has no readable captured selection label.") }
                    let count = runtime.requests.count
                    if kind == "shot" { try await driver.menu("agent.task.choose", title: "Revise Selected Object", in: window) }
                    else { try await driver.click("inspector.task.stage", in: window) }
                    try await driver.wait("visible frozen task " + kind) { driver.text("agent.task.staged", in: window) == "Revise: " + expectedLabel }
                    let visibleStagedTitle = driver.text("agent.task.staged", in: window) ?? ""
                    guard let staged = service.pendingFunction, let hint = staged.originContext,
                          try selection(hint) == expected else { throw failure("The staged task title and actual selection snapshot differ.") }
                    if switchAfterStaging { try await productionShot() }
                    try await driver.fill("agent.composer.input", value: "Describe only this captured \(kind); do not change the project.", in: window)
                    try await driver.click("agent.task.run", in: window)
                    try await driver.wait("actual runtime request " + kind, seconds: 30) { runtime.requests.count == count + 1 && !service.isStreaming }
                    guard service.streamError == nil, service.currentSessionId == seed.id,
                          let request = runtime.requests.last, request.sessionID == seed.id,
                          let raw = request.currentMessage.content.compactMap({ block -> String? in
                              if case .text(let value) = block { value } else { nil }
                          }).first(where: { $0.hasPrefix("<app-context>") }),
                          try selection(raw) == expected,
                          Array(service.messages.prefix(seed.messages.count)) == seed.messages else {
                        throw failure("The real request lost the frozen selection or replaced the selected conversation.")
                    }
                    let record: [String: Any] = ["kind": kind, "sessionID": request.sessionID.uuidString,
                        "turnID": request.turnID.uuidString, "rawAppContext": raw,
                        "selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)),
                        "stagedTitle": visibleStagedTitle, "workspaceChangedAfterStage": switchAfterStaging]
                    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("request-" + kind + ".json"))
                    try driver.record("actual captured task " + kind, fields: record)
                }
                try await task("shot", expected: AgentTaskSelectionContext.capture(editor: editor), switchAfterStaging: false)
                try await productionShot()
                try await driver.click("production.object.clip." + link.clipID, in: window)
                try await driver.wait("timeline edit context") { editor.workspaceFocus == .edit && editor.activePreviewTab == .timeline }
                let first = editor.timeline.fps / 2, end = editor.timeline.fps * 3 / 2
                guard first > 0, editor.timeline.totalFrames > end else { throw failure("The genuine film is too short for the actual one-second range.") }
                try await markTimeline(first: first, end: end, editor: editor, driver: driver)
                let timelineContext = AgentTaskSelectionContext.capture(editor: editor)
                guard timelineContext.timelineRange == .init(start: first, end: end), !timelineContext.clips.isEmpty else { throw failure("The native IN/OUT selection did not bind its actual clips.") }
                try await task("timeline", expected: timelineContext, switchAfterStaging: true)
                try await productionShot()
                try await driver.click("production.object.clip." + link.clipID, in: window)
                if !editor.mediaPanelVisible { try await AppNativeMenuAcceptance.choose(["View", "Sidebar"], in: window, driver: driver) }
                try await driver.click("media.breadcrumb.__root__", in: window)
                try await driver.menu("media.menu.View", title: MediaBrowserViewMode.flat.title, in: window)
                try await driver.click("media.asset." + link.mediaID, in: window)
                try await driver.wait("actual source range controls") { driver.state("source.in." + link.mediaID, in: window) == true }
                let total = editor.activePreviewDurationFrames
                guard total > end else { throw failure("The genuine generated source is too short for the reviewed source range.") }
                for (frame, mark) in [(first, "in"), (end, "out")] {
                    try await driver.click("preview.scrubber", in: window, fraction: .init(x: (Double(frame) + 0.5) / Double(total), y: 0.5))
                    try await driver.wait("actual source playhead") { editor.sourcePlayheadFrame == frame }
                    try await driver.click("source." + mark + "." + link.mediaID, in: window)
                    try await driver.wait("actual source mark") { driver.text("source." + mark + "." + link.mediaID, in: window) == String(frame) }
                }
                let sourceContext = AgentTaskSelectionContext.capture(editor: editor)
                guard sourceContext.source?.assetID == link.mediaID, sourceContext.source?.range == .init(start: first, end: end), sourceContext.timelineRange == nil else { throw failure("The source task borrowed the hidden timeline selection.") }
                try await task("source", expected: sourceContext, switchAfterStaging: true)
                try messageBytes(Array(service.messages.prefix(seed.messages.count)))
                    .write(to: directory.appendingPathComponent("history-prefix-after.json"))
                guard (readContext.declaration.binding != nil || readContext.declaration.productionContract == .current),
                      !runtime.hostContexts.isEmpty, runtime.hostContexts.allSatisfy({ context in
                    !context.baseInstructions.isEmpty && context.pack?.id == readContext.declaration.binding?.id
                        && context.pack?.version == readContext.declaration.binding?.version
                }) else { throw failure("The real runtime did not retain its actual production declaration.") }
                try await AppNativeMenuAcceptance.choose(["Agent", "Conversation History"], in: window, driver: driver)
                let deleting = try await containing("agent.history.search", driver: driver)
                try await driver.fill("agent.history.search", value: seed.title, in: deleting)
                try await driver.click("agent.history.delete." + seed.id.uuidString, in: deleting)
                let deleteTitle = "Delete “" + seed.title + "”"
                let cancelling = try await confirmationWindow(title: deleteTitle, driver: driver)
                try driver.pressKey(53, characters: "\u{1b}", in: cancelling)
                try await driver.wait("delete conversation cancelled") {
                    service.sessions.contains { $0.id == seed.id }
                        && !NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && hasButton(deleteTitle, in: $0) }
                }
                if !editor.agentConversationHistoryPresented {
                    try await AppNativeMenuAcceptance.choose(["Agent", "Conversation History"], in: window, driver: driver)
                    let reopenedHistory = try await containing("agent.history.search", driver: driver)
                    try await driver.fill("agent.history.search", value: seed.title, in: reopenedHistory)
                }
                let retry = try await containing("agent.history.delete." + seed.id.uuidString, driver: driver)
                try await driver.click("agent.history.delete." + seed.id.uuidString, in: retry)
                let title = "Delete “" + seed.title + "”"
                let confirmation = try await confirmationWindow(title: title, driver: driver)
                try AppNativeMenuAcceptance.accessibilityClick(title, in: confirmation, driver: driver)
                try await driver.wait("actual historical conversation deleted") { !service.sessions.contains { $0.id == seed.id } }
                try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]).write(to: directory.appendingPathComponent("canonical-before.json"))
                try JSONSerialization.data(withJSONObject: try await canonicalBytes(root), options: [.sortedKeys]).write(to: directory.appendingPathComponent("canonical-after.json"))
                guard preservedSessions.allSatisfy({ id, messages in service.sessions.first(where: { $0.id == id })?.messages == messages }),
                      editor.timeline == readContext.timeline, try await canonicalBytes(root) == canonical else { throw failure("Object/history actions altered unrelated conversations or canonical production.") }
                if editor.agentConversationHistoryPresented {
                    let done = try await containing("agent.sessions.done", driver: driver)
                    try await driver.click("agent.sessions.done", in: done)
                }
                try await driver.wait("actual document is dirty before native history Save") { document.isDocumentEdited }
                try driver.record("before native history Save", fields: ["documentDirty": document.isDocumentEdited])
                try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
                try await driver.wait("native conversation deletion saved", seconds: 30) { !document.isDocumentEdited }
                document.close(); closed = true
                let reopened = try await VideoProject.load(from: package, agentService: RecordingRuntime().service())
                var reopenedClosed = false
                defer { if !reopenedClosed { reopened.close() } }
                guard !reopened.editorViewModel.agentService.sessions.contains(where: { $0.id == seed.id }),
                      preservedSessions.allSatisfy({ id, messages in reopened.editorViewModel.agentService.sessions.first(where: { $0.id == id })?.messages == messages }),
                      reopened.editorViewModel.timeline == readContext.timeline,
                      try ExportQueue.PathState.capture(savedProject) == original else { throw failure("Save/reopen lost deletion or changed the untouched original production.") }
                let retained = try preservedSessions.map { id, messages in
                    ["id": id.uuidString, "messagesSHA256": FileDigest.sha256(of: try PlanningWriterIO.json(messages))]
                }
                let reopenedEvidence = try reopened.editorViewModel.agentService.sessions.map { session in
                    ["id": session.id.uuidString, "messagesSHA256": FileDigest.sha256(of: try PlanningWriterIO.json(session.messages))]
                }
                try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys]).write(to: directory.appendingPathComponent("other-conversations-before.json"))
                try JSONSerialization.data(withJSONObject: reopenedEvidence, options: [.sortedKeys]).write(to: directory.appendingPathComponent("conversations-after-reopen.json"))
                let font = try requireFont(driver.interactions, scale: scale)
                try driver.record("older conversation continued and deleted", fields: ["sessionID": seed.id.uuidString,
                    "sourceSessionID": legacy.sourceSessionID.uuidString,
                    "legacyFormatFixture": true, "oldMessageCount": seed.messages.count, "continuedTurns": runtime.requests.count,
                    "prefixSHA256": FileDigest.sha256(of: oldPrefix), "deleteCancelled": true, "nativeDeleteConfirmed": true,
                    "nativeSaveReopen": true, "otherConversationsPreserved": true, "originalPackageSHA256": original.digest!,
                    "originalPackageAfterSHA256": try ExportQueue.PathState.capture(savedProject).digest!,
                    "renderedFontPointSize": font, "liveAgent": false])
                var result = driver.result()
                result.merge(["scale": scale, "viewport": viewport,
                    "backingScale": backingScale, "fixture": "genuine saved V2 production; legacy-format copy of its actual text turns", "liveAgent": false]) { _, new in new }
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("object-context-result.json"))
                reopened.close(); reopenedClosed = true
                try await driver.wait("isolated object working copy discarded before original can reopen", seconds: 30) {
                    do { return try ProjectWorkingCopy.recoverableDirtyHome(for: savedProject) == nil }
                    catch { return false }
                }
                results.append(result)
            } catch { driver.failure(error); throw error }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("object-context-result.json"))
        return results
    }

    private struct LegacyFixture { let session: ChatSession; let sourceSessionID: UUID }
    private static func legacyFixture(package: URL, directory: URL) throws -> LegacyFixture {
        let sessions = try ChatSessionStore.loadThrowing(from: package)
        guard let actual = sessions.first(where: { session in
            session.messages.contains { $0.role == .user && $0.hostStateRecords.isEmpty }
                && session.messages.contains { $0.role == .assistant && $0.hostStateRecords.isEmpty }
        }) else { throw failure("The real saved production has no actual prior conversation for its old-format fixture.") }
        let messages = actual.messages.filter { message in
            message.hostStateRecords.isEmpty && !message.blocks.isEmpty && message.blocks.allSatisfy { if case .text = $0 { true } else { false } }
        }
        guard messages.contains(where: { $0.role == .user }), messages.contains(where: { $0.role == .assistant }) else { throw failure("The earlier thread has no complete actual text exchange.") }
        var legacy = ChatSession(title: "Earlier production discussion \(UUID().uuidString.prefix(8))", messages: messages)
        legacy.updatedAt = Date(timeIntervalSince1970: 1_000_000)
        guard let encoded = ChatSessionStore.encodeSession(legacy), var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw failure("The old-format conversation cannot be encoded.") }
        for key in ["isOpen", "claudeSessionId", "draft", "decision", "workTime", "approvalEvidence", "tokenUsage", "toolSearchPinnedTools"] { payload.removeValue(forKey: key) }
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let chat = package.appendingPathComponent(ChatSessionStore.dirName)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        try bytes.write(to: chat.appendingPathComponent(legacy.id.uuidString + ".json"))
        try bytes.write(to: directory.appendingPathComponent("initial-legacy-conversation.json"))
        try PlanningWriterIO.json(actual.messages).write(to: directory.appendingPathComponent("legacy-source-conversation.json"))
        return LegacyFixture(session: legacy, sourceSessionID: actual.id)
    }

    private static func messageBytes(_ messages: [AgentMessage]) throws -> Data {
        guard let bytes = ChatSessionStore.encodeSession(ChatSession(title: "", messages: messages)),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let values = object["messages"] as? [Any] else { throw failure("The actual persisted message representation could not be encoded.") }
        return try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    }

    private static func markTimeline(first: Int, end: Int, editor: EditorViewModel, driver: ProductionVisualSourcesDriver) async throws {
        for frame in [first, end] {
            for _ in 0..<12 {
                let timeline = try timelineView(driver.window)
                if timeline.visibleRect.contains(NSPoint(x: timeline.geometry.xForFrame(frame), y: timeline.visibleRect.minY + timeline.geometry.rulerHeight / 2)) { break }
                try await driver.click("timeline.zoom.out", in: driver.window)
            }
            try GenericNLEAcceptance.pointerOnRuler(frame: frame, window: driver.window, driver: driver)
            try await driver.wait("actual marked timeline playhead") { editor.currentFrame == frame }
            try driver.pressKey(frame == first ? 34 : 31, characters: frame == first ? "i" : "o", in: driver.window)
        }
        try await driver.wait("actual timeline IN/OUT") { editor.validSelectedTimelineRange?.startFrame == first && editor.validSelectedTimelineRange?.endFrame == end }
    }

    private static func containing(_ id: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("native window containing " + id) { NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: id, in: $0) != nil } }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: id, in: $0) != nil }) else { throw failure("The native control window disappeared.") }
        return window
    }

    private static func hasButton(_ title: String, in window: NSWindow) -> Bool {
        guard window.isVisible, let root = window.contentView else { return false }
        var pending: [any NSAccessibilityProtocol] = [root], visited = Set<ObjectIdentifier>()
        while let item = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if item.accessibilityRole() == .button, item.isAccessibilityEnabled(),
               [item.accessibilityTitle(), item.accessibilityLabel()].contains(title) { return true }
            pending += (item.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        }
        return false
    }
    private static func confirmationWindow(title: String, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        try await driver.wait("actual destructive confirmation") { NSApp.windows.contains { $0.isKeyWindow && hasButton(title, in: $0) } }
        guard let window = NSApp.windows.first(where: { $0.isKeyWindow && hasButton(title, in: $0) }) else { throw failure("The native delete confirmation disappeared.") }
        return window
    }

    private static func timelineView(_ window: NSWindow) throws -> TimelineView {
        guard let root = window.contentView, let view = AppNativeMenuAcceptance.views(root).compactMap({ $0 as? TimelineView }).first else { throw failure("No actual timeline view.") }
        return view
    }
    private static func selection(_ hint: String) throws -> AgentTaskSelectionContext {
        guard let start = hint.firstIndex(of: "{"), let end = hint.lastIndex(of: "}") else { throw failure("No serialized task selection in the actual request.") }
        return try JSONDecoder().decode(AgentTaskSelectionContext.self, from: Data(hint[start...end].utf8))
    }
    private static func canonicalBytes(_ root: URL) async throws -> [String: String] {
        try await Task.detached {
            let paths = try HostProductionPhaseLineage.artifactPaths(phase: "render", dataRoot: root)
            return try Dictionary(uniqueKeysWithValues: Set(paths).sorted().map { ($0, try FileDigest.sha256(of: ProjectLocalFile.resolve($0, dataRoot: root))) })
        }.value
    }
    nonisolated private static func failure(_ message: String) -> GateBlocked { GateBlocked("Native production object/context acceptance: " + message) }
    private static func requireURL(_ value: URL?) throws -> URL { guard let value else { throw failure("The actual assembled media URL is missing.") }; return value }
    private static func requireFont(_ interactions: [[String: Any]], scale: Double) throws -> Double {
        guard let field = interactions.compactMap({ $0["field"] as? [String: Any] }).last(where: { $0["id"] as? String == "agent.composer.input" }),
              let font = field["fontPointSize"] as? CGFloat, abs(font - AppTheme.Typography.ui * scale) < 0.5 else { throw failure("The actual composer font did not use the requested interface scale.") }
        return Double(font)
    }

    @MainActor private final class RecordingRuntime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        private(set) var requests: [AgentRuntimeTurnRequest] = []
        private(set) var hostContexts: [AgentRuntimeHostContext] = []
        func service() -> AgentService {
            AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
                runtimeAdapterFactory: { [self] _ in self }, runtimeReadinessOverride: { nil })
        }
        func start(_ request: AgentRuntimeSessionRequest) throws { hostContexts.append(request.hostContext); state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            requests.append(request)
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                event: .text(messageID: "isolated-object-context-" + request.turnID.uuidString, value: "The captured selection was received. No project changes were made.", isDelta: false)))
            pair.continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
            pair.continuation.finish(); state = .ready(sessionID: request.sessionID)
            return pair.stream
        }
        func cancel(sessionID: UUID) { state = .ready(sessionID: sessionID) }
        func end(sessionID: UUID) { state = .ended(sessionID: sessionID) }
    }
}
