import AppKit
import NexGenEngine

@MainActor
enum GenerationRecoveryOwnerAcceptance {
    struct Saved: Codable {
        let processID: Int32
        let batchID: String
        let itemIDs: [String]
        let firstOutputID: String
        let firstOutputSHA256: String
        let acceptedRequestID: String
        let packageIDs: [String]
    }

    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested,
              let stage = ProcessInfo.processInfo.environment["NGV_GENERATION_RECOVERY_STAGE"], ["prepare", "resume", "authoritylost"].contains(stage) else {
            throw GateBlocked("Generation recovery requires an explicit native recovery stage.")
        }
        let directory = output.appendingPathComponent("generation-recovery-" + String(Int(scale * 100)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = directory.appendingPathComponent(stage == "authoritylost" ? "History only.ngv" : "Recovery.ngv", isDirectory: true)
        if stage == "prepare" {
            guard !FileManager.default.fileExists(atPath: project.path) else { throw GateBlocked("The recovery project already exists; previous evidence cannot be reused.") }
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var timeline = Timeline(); timeline.width = 320; timeline.height = 180; timeline.fps = 30; timeline.settingsConfigured = true
            try JSONEncoder().encode(timeline).write(to: project.appendingPathComponent(Project.timelineFilename))
            try JSONEncoder().encode(MediaManifest()).write(to: project.appendingPathComponent(Project.manifestFilename))
            try JSONEncoder().encode(GenerationLog()).write(to: project.appendingPathComponent(Project.generationLogFilename))
        }
        if stage == "authoritylost" {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
            let batch = try JSONDecoder().decode(GenerationBatch.self, from: Data(contentsOf: directory.appendingPathComponent("prepare-batch.json")))
            let authority = try GenerationExecutionAuthorityStore.live()
            let record = try authority.load(projectKey: batch.payload.projectKey, batchID: saved.batchID)
            guard record.batch == batch, record.journal.executions.map(\.state) == [.complete, .complete, .canceled],
                  record.journal.executions[1].providerRequestID == saved.acceptedRequestID else {
                throw GateBlocked("The fixture authority does not belong to the completed recovery fixture.")
            }
            try GenerationPackageV1.canonicalData(record).write(to: directory.appendingPathComponent("authority-before-loss.json"))
            try authority.removeForTesting(projectKey: batch.payload.projectKey, batchID: saved.batchID)
            guard try authority.loadIfPresent(projectKey: batch.payload.projectKey, batchID: saved.batchID) == nil else {
                throw GateBlocked("The fixture batch authority was not actually removed.")
            }
            try JSONEncoder().encode(try authority.all(projectKey: batch.payload.projectKey).map { $0.batch.id })
                .write(to: directory.appendingPathComponent("authority-remaining-batches.json"))
        }
        let bytes = try await Task.detached { try ManualAudioGenerationTransport.wave(seconds: 3, frequency: stage == "prepare" ? 997 : 523.25) }.value
        let catalog = ModelCatalog(); catalog.load(entries: ModelCatalog.launchEntries)
        guard let model = catalog.audio.first(where: { $0.id == "fal-ai/elevenlabs/music" }) else { throw GateBlocked("The real audio adapter fixture is unavailable.") }
        let defaultsName = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsName) else { throw GateBlocked("The isolated model preferences cannot be opened.") }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let services = GenerationPanelServices(catalog: catalog, preferences: ModelPreferences(defaults: defaults),
            activation: { .init(active: [.init(provider: .fal, transport: .api)]) },
            quoteLoader: { _, _ in throw GenerationBackendError.transport("No live price in the isolated recovery transport.") })
        let target = services.target(model.id)
        guard target.binding != nil else { throw GateBlocked("The actual audio fixture has no executable offering.") }
        GenerationRecoveryHTTP.install(resumed: stage != "prepare", endpoint: target.endpoint, output: bytes)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GenerationRecoveryHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var configuredBeforeLoad = false
        let document = try await VideoProject.load(from: project, configureEditor: { editor in
            configuredBeforeLoad = editor.workingRoot == nil && editor.generationService.reconcilingHomes.isEmpty
                && editor.generationService.lastReconciliation.isEmpty
            editor.generationService.reconciliation = .init(session: session,
                providerKey: { $0 == .fal ? "isolated-recovery-key" : nil }, falCharge: { requestID, endpoint, _ in
                    GenerationRecoveryHTTP.recordBillingLookup(requestID: requestID, endpoint: endpoint)
                    return nil
                })
            editor.generationBatchCoordinator.catalogReadiness = {}
            editor.generationBatchCoordinator.modelCatalog = catalog
            editor.generationBatchCoordinator.providerActivation = services.activation
            editor.generationBatchCoordinator.quoteLoader = services.quoteLoader
            editor.generationPanelServicesOverride = services
        })
        guard configuredBeforeLoad, document.generationRestorationTask == nil,
              document.editorViewModel.generationService.reconciliation.session === session else {
            throw GateBlocked("The isolated recovery transport was not installed before project restoration.")
        }
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The actual recovery document window did not open.") }
        let editor = document.editorViewModel
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: "generation-recovery-" + stage)
        do {
        if stage == "prepare" {
            try await prepare(document: document, model: model, target: target, services: services, bytes: bytes, driver: driver, window: window)
        } else if stage == "resume" {
            try await resume(document: document, bytes: bytes, driver: driver, window: window)
        } else {
            try await historyWithoutAuthority(document: document, driver: driver, window: window, session: session)
        }
        } catch { driver.failure(error); throw error }
        guard let home = editor.workingRoot else { throw GateBlocked("The recovery project closed before evidence capture.") }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        let snapshot = try GenerationBatchStore.load(id: saved.batchID, home: home)
        try GenerationPackageV1.canonicalData(snapshot.batch).write(to: directory.appendingPathComponent(stage + "-batch.json"))
        try GenerationPackageV1.canonicalData(snapshot.journal).write(to: directory.appendingPathComponent(stage + "-journal.json"))
        try GenerationPackageV1.canonicalData(editor.generationLog).write(to: directory.appendingPathComponent(stage + "-spend.json"))
        if stage == "authoritylost" {
            guard document.fileURL?.standardizedFileURL == project.standardizedFileURL else {
                throw GateBlocked("The history document no longer owns the saved fixture package.")
            }
            document.close()
            let started = ProcessInfo.processInfo.systemUptime
            var samples: [[String: Any]] = []
            for index in 0...15 {
                if index > 0 { try await Task.sleep(for: .milliseconds(100)) }
                let inFlight = await withCheckedContinuation { continuation in
                    session.getAllTasks { tasks in continuation.resume(returning: tasks.count) }
                }
                let sample: [String: Any] = ["elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                    "documentClosed": editor.workingRoot == nil && !window.isVisible,
                    "providerRequests": GenerationRecoveryHTTP.requests.count,
                    "billingLookups": GenerationRecoveryHTTP.billingRequests.count,
                    "sessionTasks": inFlight, "reconcilingProjects": editor.generationService.reconcilingHomes.count,
                    "injectedSessionRetained": editor.generationService.reconciliation.session === session]
                samples.append(sample)
                try JSONSerialization.data(withJSONObject: samples, options: .sortedKeys)
                    .write(to: directory.appendingPathComponent("authoritylost-quiescence.json"), options: .atomic)
                guard editor.workingRoot == nil, !window.isVisible, inFlight == 0,
                      editor.generationService.reconciliation.session === session,
                      editor.generationService.reconcilingHomes.isEmpty,
                      GenerationRecoveryHTTP.requests.isEmpty, GenerationRecoveryHTTP.billingRequests.isEmpty else {
                    throw GateBlocked("History-only closure did not remain free of provider requests throughout observation.")
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard elapsed >= 1.5 else { throw GateBlocked("The history-only quiescence window was incomplete.") }
            let batchID = saved.batchID
            let closed = try await Task.detached {
                let stored = try GenerationBatchStore.load(id: batchID, home: project)
                guard !stored.authorityAvailable else { throw GateBlocked("Closed history unexpectedly regained execution authority.") }
                let folder = project.appendingPathComponent("generation-batches/" + batchID)
                return (try Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                    try Data(contentsOf: folder.appendingPathComponent("journal.json")),
                    try Data(contentsOf: project.appendingPathComponent(Project.generationLogFilename)))
            }.value
            try closed.0.write(to: directory.appendingPathComponent("authoritylost-closed-batch.json"), options: .atomic)
            try closed.1.write(to: directory.appendingPathComponent("authoritylost-closed-journal.json"), options: .atomic)
            try closed.2.write(to: directory.appendingPathComponent("authoritylost-closed-spend.json"), options: .atomic)
            guard try JSONDecoder().decode(GenerationBatch.self, from: closed.0) == snapshot.batch,
                  try JSONDecoder().decode(GenerationBatchJournal.self, from: closed.1) == snapshot.journal,
                  try GenerationPackageV1.canonicalData(JSONDecoder().decode(GenerationLog.self, from: closed.2))
                    == Data(contentsOf: directory.appendingPathComponent("authoritylost-spend.json")) else {
                throw GateBlocked("Closing history changed the saved batch, journal or spend history.")
            }
            let finalTasks = await withCheckedContinuation { continuation in
                session.getAllTasks { tasks in continuation.resume(returning: tasks.count) }
            }
            guard finalTasks == 0, editor.generationService.reconcilingHomes.isEmpty,
                  GenerationRecoveryHTTP.requests.isEmpty, GenerationRecoveryHTTP.billingRequests.isEmpty else {
                throw GateBlocked("Provider work appeared while reading the closed history package.")
            }
            try driver.record("history-only document closed after restoration", fields: ["documentClosed": true,
                "providerRequests": GenerationRecoveryHTTP.requests.count, "billingLookups": GenerationRecoveryHTTP.billingRequests.count,
                "sessionTasks": finalTasks,
                "reconcilingProjects": editor.generationService.reconcilingHomes.count,
                "quiescenceSeconds": elapsed, "quiescenceSamples": samples.count,
                "savedPackageHistoryReadAfterClose": true])
        }
        try JSONEncoder().encode(GenerationRecoveryHTTP.billingRequests).write(to: directory.appendingPathComponent(stage + "-billing.json"), options: .atomic)
        guard GenerationRecoveryHTTP.unexpected.isEmpty else { throw GateBlocked("Unexpected recovery transport request: " + GenerationRecoveryHTTP.unexpected.joined(separator: ", ")) }
        try JSONEncoder().encode(GenerationRecoveryHTTP.requests).write(to: directory.appendingPathComponent(stage + "-http.json"), options: .atomic)
        let progressName = "generation-recovery-" + stage + ".json"
        guard let progress = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(progressName))) as? [String: Any],
              progress["failure"] is NSNull,
              let actions = progress["interactions"] as? [[String: Any]], let images = progress["screenshots"] as? [String] else {
            throw GateBlocked("The actual recovery interaction log is missing.")
        }
        return ["stage": stage, "processID": ProcessInfo.processInfo.processIdentifier, "batchID": saved.batchID,
            "interactions": actions, "screenshots": images.map { directory.lastPathComponent + "/" + $0 },
            "directory": directory.lastPathComponent, "liveProvider": false]
    }

    private static func prepare(document: VideoProject, model: AudioModelConfig, target: ResolvedGenerationTarget,
                                services: GenerationPanelServices, bytes: Data,
                                driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        let editor = document.editorViewModel
        var items: [GenerationBatch.Item] = []
        for number in 1...3 {
            let intent = "A sparse instrumental piano motif, request " + String(number) + "."
            let request = GenerationRequest(modality: .audio, modelId: model.id, intent: intent, durationSeconds: 3,
                placement: .mediaLibrary(folderId: nil), origin: .panel, target: target,
                submission: .audio { prompt in
                    .make(genInput: .init(prompt: prompt, intent: intent, model: model.id, duration: 3, aspectRatio: ""), model: model,
                        params: .init(prompt: prompt, voice: nil, lyrics: nil, styleInstructions: nil, instrumental: true, durationSeconds: 3))
                })
            let generation = try await GenerationController.prepare(request, editor: editor).get()
            let package = try await GenerationController.prepareReviewPackage(generation, editor: editor, quoteLoader: services.quoteLoader)
            items.append(.init(id: UUID().uuidString, purpose: "Audio request " + String(number), package: package))
        }
        let batch = try GenerationBatch(payload: .init(nonce: UUID(), projectKey: items[0].package.payload.binding.projectKey, phase: nil, items: items))
        try editor.generationBatchCoordinator.present(batch, recoveries: Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, GenerationBatchRecovery(options: []) { _, _ in item.package })
        }))
        let activity = try await activityWindow(parent: window, driver: driver, identifier: "generation-batch.approve")
        try await driver.wait("native batch approval ready") { driver.state("generation-batch.approve", in: activity) == true }
        guard GenerationRecoveryHTTP.requests.isEmpty, editor.generationLog.spendEvents.isEmpty else { throw GateBlocked("Preparing the batch already submitted a paid request.") }
        try driver.capture("review-before-one-approval", target: activity)
        try await driver.click("generation-batch.approve", in: activity)
        try await driver.wait("one output complete and a second real job accepted", seconds: 60) {
            let states = editor.generationBatchCoordinator.snapshots.first { $0.batch.id == batch.id }?.journal.executions
            return states?.map(\.state) == [.complete, .running, .queued]
                && states?[1].providerRequestID == "native-recovery-job-2"
        }
        let runningActivity = try await activityWindow(parent: window, driver: driver, identifier: "agent.stop")
        guard driver.text("agent.stop", in: runningActivity) == "Stop remaining requests" else {
            throw GateBlocked("The native batch control does not explain that accepted jobs continue.")
        }
        try await driver.click("agent.stop", in: runningActivity)
        try await driver.wait("native remaining-request stop persisted") {
            editor.generationBatchCoordinator.snapshots.first { $0.batch.id == batch.id }?.journal.executions.map(\.state) == [.complete, .running, .canceled]
        }
        let stoppedActivity = try await history(parent: window, driver: driver)
        try await requireVisibleStates([.complete, .running, .canceled], items: items.map(\.id), window: stoppedActivity, driver: driver)
        try driver.capture("remaining-canceled-known-job-retained", target: stoppedActivity)
        guard let home = editor.workingRoot else { throw GateBlocked("The recovery project closed during its batch.") }
        let snapshot = try GenerationBatchStore.load(id: batch.id, home: home)
        guard let firstID = snapshot.journal.executions[0].outputAssetIDs.first,
              let first = editor.mediaAssets.first(where: { $0.id == firstID }),
              try FileDigest.sha256(of: first.url) == FileDigest.sha256(of: bytes),
              GenerationRecoveryHTTP.requests.filter({ $0.method == "POST" }).count == 2 else {
            throw GateBlocked("Native stop discarded the completed result or submitted the canceled request.")
        }
        let saved = Saved(processID: ProcessInfo.processInfo.processIdentifier, batchID: batch.id, itemIDs: items.map(\.id),
            firstOutputID: firstID, firstOutputSHA256: try FileDigest.sha256(of: first.url), acceptedRequestID: try require(snapshot.journal.executions[1].providerRequestID), packageIDs: items.map { $0.package.id })
        try JSONEncoder().encode(saved).write(to: driver.output.appendingPathComponent("state.json"), options: .atomic)
        window.makeKeyAndOrderFront(nil)
        try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
        try await driver.wait("native save checkpoints accepted jobs") { !document.isDocumentEdited }
        let savedLog = try JSONDecoder().decode(GenerationLog.self,
            from: Data(contentsOf: try require(document.fileURL).appendingPathComponent(Project.generationLogFilename)))
        guard savedLog.spendEvents.filter({ $0.kind == .submitted }).count == 2,
              savedLog.spendEvents.contains(where: { $0.kind == .submitted && $0.providerRequestId == saved.acceptedRequestID }) else {
            throw GateBlocked("Native Save did not persist the actual accepted job receipts.")
        }
        try FileManager.default.copyItem(at: try require(document.fileURL), to: driver.output.appendingPathComponent("History only.ngv"))
        try Data(contentsOf: first.url).write(to: driver.output.appendingPathComponent("first-output.wav"))
        try driver.record("native queued requests stopped before process restart", fields: ["batchID": batch.id,
            "acceptedRequestID": saved.acceptedRequestID, "providerSubmissions": 2,
            "completedRetained": true, "thirdCanceledWithoutSubmission": true])
    }

    private static func resume(document: VideoProject, bytes: Data, driver: ProductionVisualSourcesDriver, window: NSWindow) async throws {
        let editor = document.editorViewModel
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: driver.output.appendingPathComponent("state.json")))
        guard saved.processID != ProcessInfo.processInfo.processIdentifier else { throw GateBlocked("This is not a separate restarted process.") }
        if editor.recoveredUnsavedWork {
            try await driver.wait("actual unsaved-work Recovery alert") {
                window.attachedSheet?.defaultButtonCell?.title == "Keep"
            }
            let alert = try require(window.attachedSheet)
            guard alert.isKeyWindow, alert.defaultButtonCell?.title == "Keep" else { throw GateBlocked("The actual Recovery default action is not Keep.") }
            try driver.pressKey(36, characters: "\r", in: alert)
            try await driver.wait("native Keep restores the saved job authority") { !editor.recoveredUnsavedWork }
            try driver.record("native Keep recovery choice", fields: ["actualDefaultButton": "Keep", "keyboardReturn": true])
        }
        try await driver.wait("the accepted audio job completes after actual restart", seconds: 60) {
            editor.generationBatchCoordinator.snapshots.first { $0.batch.id == saved.batchID }?.journal.executions.map(\.state) == [.complete, .complete, .canceled]
        }
        let activity = try await history(parent: window, driver: driver)
        try await requireVisibleStates([.complete, .complete, .canceled], items: saved.itemIDs, window: activity, driver: driver)
        let snapshot = try GenerationBatchStore.load(id: saved.batchID, home: require(editor.workingRoot))
        guard snapshot.authorityAvailable, snapshot.journal.executions[1].providerRequestID == saved.acceptedRequestID,
              let secondID = snapshot.journal.executions[1].outputAssetIDs.first,
              let first = editor.mediaAssets.first(where: { $0.id == saved.firstOutputID }),
              let second = editor.mediaAssets.first(where: { $0.id == secondID }),
              try FileDigest.sha256(of: first.url) == saved.firstOutputSHA256,
              try FileDigest.sha256(of: second.url) == FileDigest.sha256(of: bytes),
              try FileDigest.sha256(of: second.url) != saved.firstOutputSHA256,
              GenerationRecoveryHTTP.requests.allSatisfy({ $0.method == "GET" }),
              GenerationRecoveryHTTP.requests.contains(where: { $0.url.hasSuffix(saved.acceptedRequestID + "/status") }) else {
            throw GateBlocked("Restart lost a result, changed the known job identity, or submitted another paid request.")
        }
        try await driver.click("generation-batch.open." + first.id, in: activity)
        try await driver.wait("native completed-result selection") { editor.selectedMediaAssetIds == [first.id] }
        let history = try await activityWindow(parent: window, driver: driver, identifier: "generation-batch.open." + second.id)
        try await driver.click("generation-batch.open." + second.id, in: history)
        try await driver.wait("native resumed-result selection") { editor.selectedMediaAssetIds == [second.id] }
        try driver.capture("restarted-history-and-results", target: history)
        try Data(contentsOf: second.url).write(to: driver.output.appendingPathComponent("second-output.wav"))
        try driver.record("actual process restart resumes only the recorded audio job", fields: ["previousProcessID": saved.processID,
            "acceptedRequestID": saved.acceptedRequestID, "providerSubmissions": 0,
            "firstOutputSHA256": try FileDigest.sha256(of: first.url), "secondOutputSHA256": try FileDigest.sha256(of: second.url),
            "completedRetained": true, "thirdStillCanceled": true, "nativeHistoryResultsOpened": true])
        window.makeKeyAndOrderFront(nil)
        try driver.pressKey(1, characters: "s", modifiers: .command, in: window)
        try await driver.wait("save resumed outputs before testing older saved history", seconds: 30) { !document.isDocumentEdited }
        guard let package = document.fileURL,
              try JSONDecoder().decode(GenerationBatchJournal.self, from: Data(contentsOf:
                package.appendingPathComponent("generation-batches/\(saved.batchID)/journal.json"))) == snapshot.journal else {
            throw GateBlocked("The resumed batch was not actually saved before opening its older history copy.")
        }
        try Data(contentsOf: package.appendingPathComponent("generation-batches/\(saved.batchID)/journal.json"))
            .write(to: driver.output.appendingPathComponent("resume-saved-journal.json"), options: .atomic)
    }

    private static func historyWithoutAuthority(document: VideoProject, driver: ProductionVisualSourcesDriver,
                                                window: NSWindow, session: URLSession) async throws {
        let editor = document.editorViewModel
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: driver.output.appendingPathComponent("state.json")))
        guard saved.processID != ProcessInfo.processInfo.processIdentifier, !editor.recoveredUnsavedWork else {
            throw GateBlocked("The history-only copy did not open as a separate saved document.")
        }
        guard let restoration = document.generationRestorationTask else {
            throw GateBlocked("The actual project restoration pass did not start.")
        }
        await restoration.value
        guard !restoration.isCancelled, let home = editor.workingRoot,
              editor.generationService.lastReconciliation[home] != nil,
              editor.generationService.reconciliation.session === session,
              !editor.generationService.reconcilingHomes.contains(home) else {
            throw GateBlocked("The actual provider reconciliation pass did not finish.")
        }
        try await driver.wait("saved batch is history only on a host without authority") {
            editor.generationBatchCoordinator.snapshots.first { $0.batch.id == saved.batchID }?.authorityAvailable == false
        }
        let activity = try await history(parent: window, driver: driver)
        let warning = "generation-batch.authority-missing." + saved.batchID
        try await driver.reveal(warning, in: activity)
        try driver.visible([warning], in: activity)
        let expected = "Execution authority is not available on this Mac. This batch is history only."
        guard driver.text(warning, in: activity) == expected,
              WorkspaceUIAcceptance.probeFrame(identifier: "generation-batch.resume." + saved.batchID, in: activity) == nil,
              WorkspaceUIAcceptance.probeFrame(identifier: "generation-batch.approve", in: activity) == nil else {
            throw GateBlocked("History without authority offers execution or omits the explanation.")
        }
        try await requireVisibleStates([.complete, .running, .canceled], items: saved.itemIDs, window: activity, driver: driver)
        try await driver.click("generation-batch.open." + saved.firstOutputID, in: activity)
        try await driver.wait("history-only completed output opens") { editor.selectedMediaAssetIds == [saved.firstOutputID] }
        let shown: NSWindow
        if activity.isVisible { shown = activity; shown.makeKeyAndOrderFront(nil) }
        else { shown = try await history(parent: window, driver: driver) }
        try await driver.reveal(warning, in: shown)
        try driver.capture("history-without-authority", target: shown)
        let snapshot = try GenerationBatchStore.load(id: saved.batchID, home: require(editor.workingRoot))
        guard editor.projectId == snapshot.batch.payload.projectKey,
              editor.generationBatchCoordinator.activeBatchID == nil, editor.generationBatchCoordinator.error == nil,
              !snapshot.authorityAvailable, snapshot.journal.executions.map(\.state) == [.complete, .running, .canceled],
              let first = editor.mediaAssets.first(where: { $0.id == saved.firstOutputID }),
              try FileDigest.sha256(of: first.url) == saved.firstOutputSHA256,
              GenerationRecoveryHTTP.requests.isEmpty, GenerationRecoveryHTTP.billingRequests.isEmpty else {
            throw GateBlocked("History-only open changed a job, lost a result or contacted the provider.")
        }
        try Data(contentsOf: first.url).write(to: driver.output.appendingPathComponent("history-output.wav"))
        try driver.record("missing local authority preserves readable history without execution", fields: [
            "projectKey": editor.projectId ?? "", "coordinatorIdle": editor.generationBatchCoordinator.activeBatchID == nil,
            "restorationCompleted": true, "reconciliationCompleted": true,
            "configurationInstalledBeforeRestoration": true, "injectedSessionRetained": true,
            "reconciledAt": editor.generationService.lastReconciliation[home]?.timeIntervalSince1970 ?? 0,
            "billingLookups": GenerationRecoveryHTTP.billingRequests.count,
            "coordinatorErrorFree": editor.generationBatchCoordinator.error == nil,
            "authorityAvailable": snapshot.authorityAvailable, "warning": driver.text(warning, in: shown) ?? "",
            "providerRequests": GenerationRecoveryHTTP.requests.count, "firstOutputSHA256": try FileDigest.sha256(of: first.url),
            "acceptedRequestID": snapshot.journal.executions[1].providerRequestID ?? ""])
    }

    private static func history(parent: NSWindow, driver: ProductionVisualSourcesDriver) async throws -> NSWindow {
        let window = try await activityWindow(parent: parent, driver: driver, identifier: "generation-batch.history")
        if driver.text("generation-batch.history", in: window) == "closed" {
            try await driver.click("generation-batch.history", in: window)
        }
        return window
    }

    private static func requireVisibleStates(_ states: [GenerationBatchJournal.State], items: [String],
                                             window: NSWindow, driver: ProductionVisualSourcesDriver) async throws {
        guard states.count == items.count else { throw GateBlocked("Wrong recovery inventory.") }
        for (id, state) in zip(items, states) {
            let probe = "generation-batch.state." + id
            try await driver.reveal(probe, in: window)
            try driver.visible([probe], in: window)
            guard driver.text(probe, in: window) == state.rawValue else { throw GateBlocked("The visible job history does not match the actual durable state.") }
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw GateBlocked("The recovery project is no longer open.") }; return value
    }

    private static func activityWindow(parent: NSWindow, driver: ProductionVisualSourcesDriver, identifier: String) async throws -> NSWindow {
        if let open = NSApp.windows.first(where: { $0.isVisible && $0 !== parent && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil }) {
            open.makeKeyAndOrderFront(nil); return open
        }
        parent.makeKeyAndOrderFront(nil)
        try await driver.click("production.ai", in: parent)
        try await driver.wait("actual AI activity popover") {
            NSApp.windows.contains { $0 !== parent && $0.isVisible && $0.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil }
        }
        return try require(NSApp.windows.first { $0 !== parent && $0.isVisible && $0.isKeyWindow && WorkspaceUIAcceptance.probeFrame(identifier: identifier, in: $0) != nil })
    }
}
