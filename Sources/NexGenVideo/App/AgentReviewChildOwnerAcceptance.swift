import AppKit
import NexGenEngine

@MainActor
enum AgentReviewChildOwnerAcceptance {
    static func run(output: URL, scale: Double) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw failed("Explicit native acceptance is required.") }
        var results: [[String: Any]] = []
        for backend in [AgentBackend.anthropicAPI, .claudeCode] {
            results.append(try await run(backend: backend, output: output.appendingPathComponent(backend.rawValue), scale: scale))
        }
        let result: [String: Any] = ["scale": scale, "liveAgent": false, "backends": results,
            "scope": "Native review preparation, authorization, cancellation and explicit resume with controlled API HTTP/SSE and separate CLI decoded-line responses. No live model, CLI process, installed CLI policy or semantic image-quality claim."]
        try write(result, to: output.appendingPathComponent("review-child-owner-result.json"))
        return result
    }

    private static func run(backend: AgentBackend, output: URL, scale: Double) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "ngv-review-owner-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw failed("The isolated model defaults could not be created.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AnthropicModelCatalogStore(defaults: defaults)
        store.saveCatalog([.unlisted(AgentReviewChildOwnerTransport.modelID)])
        store.storedModelID = AgentReviewChildOwnerTransport.modelID
        let service = AgentService(backend: backend, refreshBackendStatusOnInit: false,
            modelCatalogDefaults: defaults, apiKeyLoader: { nil })
        let transport = AgentReviewChildOwnerTransport()
        defer { transport.close() }
        service.reviewChildRuntimeFactory = { request in try transport.runtime(request) }
        if backend == .anthropicAPI {
            AgentReviewChildOwnerHTTP.reset()
        }
        let context = try await AgentReviewChildOwnerFixture.make(service: service)
        let editor = context.editor, root = context.dataRoot
        defer { context.document.close() }
        NSDocumentController.shared.addDocument(context.document)
        if context.document.windowControllers.isEmpty { context.document.makeWindowControllers() }
        context.document.showWindows()
        guard let window = context.document.windowControllers.first?.window else { throw failed("The actual review document window did not open.") }
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "native-review-child")
        let heartbeat = Heartbeat(run: editor.renderReviewRun)
        defer { heartbeat.stop() }
        do {
            await editor.refreshEngineState()
            guard window.contentView?.bounds.size == AppTheme.Window.projectMin,
                  AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale else {
                throw failed("The actual review window or interface scale differs from its requested case.")
            }
            try await ProductionV2PlanningAcceptance.selectPhase("render_review", context: context, driver: driver)
            guard service.currentSessionId != nil else { throw failed("The actual document has no originating conversation.") }
            let before = try chatBytes(service)
            try before.write(to: output.appendingPathComponent("chat-before.json"))
            heartbeat.mark("prepare-start")
            try await driver.click("render-review.agent.prepare", in: window)
            try await driver.wait("actual bounded review proposal", seconds: 120) { editor.renderReviewRun.state == .awaitingApproval || editor.renderReviewRun.state == .failed }
            guard let proposal = editor.renderReviewRun.proposal, proposal.pageCount >= 4, !proposal.isResume else {
                throw failed(editor.renderReviewRun.errorMessage ?? "The 34-shot review did not prepare multiple pages.")
            }
            heartbeat.mark("prepared")
            let manifestID = proposal.manifestID
            let manifest = try await Task.detached {
                try PlanningWriterIO.read(PipelineRenderReviewManifest.self, at: "render-review/manifests/\(manifestID).v2.json", dataRoot: root)
            }.value
            guard manifest.snapshot.shots.count == AgentReviewChildOwnerFixture.shotCount,
                  manifest.derivatives.count >= AgentReviewChildOwnerFixture.shotCount else { throw failed("The actual manifest lost distinct shot images.") }
            try PlanningWriterIO.json(manifest).write(to: output.appendingPathComponent("actual-manifest.json"))
            try driver.capture("bounded-review-proposal", target: window)
            try driver.record("actual initial review proposal", fields: ["pageCount": proposal.pageCount,
                "shotCount": manifest.snapshot.shots.count, "imageCount": manifest.derivatives.count,
                "manifestID": manifestID, "isResume": proposal.isResume])
            try await driver.click("render-review.agent.approve", in: window)
            try await driver.wait("actual committed page held before shutdown completion", seconds: 120) {
                transport.shutdownHeld || editor.renderReviewRun.state == .failed
            }
            guard editor.renderReviewRun.state == .running, editor.renderReviewRun.completedPages >= 2,
                  transport.shutdownHeld, let held = transport.heldRequest,
                  service.reviewChildRegistry.activeRunID != nil,
                  (editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil) else { throw failed(editor.renderReviewRun.errorMessage ?? "The bounded run did not retain its phase lifetime.") }
            let interruptedPages = editor.renderReviewRun.completedPages
            let checkpoint = try await Task.detached { () -> (PipelineRenderReviewRunStore.Journal, CanonicalArtifactReferenceV1) in
                guard let journal = try PipelineRenderReviewRunStore.load(manifest: manifestReference(manifest, root: root), dataRoot: root) else {
                    throw failed("The successful write has no journal checkpoint before shutdown.")
                }
                for reference in journal.children {
                    let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
                    let page = try JSONDecoder().decode(PipelineRenderReviewRunReceipt.Page.self, from: Data(contentsOf: url))
                    if page.submission.pageID == held.pageID, page.writeEvidence.authID == held.authID { return (journal, reference) }
                }
                throw failed("The committed held page was orphaned before child shutdown completed.")
            }.value
            guard checkpoint.0.status == .running, checkpoint.0.children.count > interruptedPages else {
                throw failed("The regression did not stop between Page publication and child completion.")
            }
            try PlanningWriterIO.json(checkpoint.0).write(to: output.appendingPathComponent("write-checkpoint-journal.json"))
            let checkpointFields: [String: Any] = ["pageID": held.pageID, "authID": held.authID.uuidString.lowercased(),
                "page": ["id": checkpoint.1.id, "role": checkpoint.1.role, "path": checkpoint.1.path, "sha256": checkpoint.1.sha256],
                "publishedPages": checkpoint.0.children.count, "completedPages": interruptedPages,
                "shutdownHeld": transport.shutdownHeld, "phaseLeaseHeld": editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil]
            try driver.record("actual committed page before cancellation", fields: checkpointFields)
            try driver.capture("committed-page-shutdown-held", target: window)
            try await driver.click("render-review.agent.cancel", in: window)
            try await driver.wait("Cancel retains ownership until held shutdown finishes") {
                editor.renderReviewRun.state == .stopping && service.reviewChildRegistry.activeRunID != nil
                    && editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil
            }
            try driver.record("actual Cancel waits for owned shutdown", fields: ["pageID": held.pageID,
                "phaseLeaseHeld": true, "registryActive": true, "state": editor.renderReviewRun.state.rawValue])
            transport.releaseShutdown()
            try await driver.wait("owned child shutdown before explicit resume", seconds: 30) {
                editor.renderReviewRun.state == .interrupted && service.reviewChildRegistry.activeRunID == nil
                    && !(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil)
            }
            let interrupted = try await Task.detached { try PipelineRenderReviewRunStore.load(manifest: manifestReference(manifest, root: root), dataRoot: root) }.value
            guard let interrupted, interrupted.status == .interrupted, interrupted.children == checkpoint.0.children,
                  interrupted.authorizations.count == 1, interrupted.children.contains(checkpoint.1) else {
                throw failed("Cancellation did not preserve the exact already committed page checkpoint.")
            }
            try PlanningWriterIO.json(interrupted).write(to: output.appendingPathComponent("interrupted-journal.json"))
            try driver.capture("cancelled-review-progress", target: window)
            try driver.record("actual cancelled review", fields: ["completedPages": interruptedPages,
                "runID": interrupted.runID.uuidString.lowercased(), "authorizationCount": interrupted.authorizations.count])
            try await driver.click("render-review.agent.prepare", in: window)
            try await driver.wait("explicit review resume proposal", seconds: 120) { editor.renderReviewRun.state == .awaitingApproval || editor.renderReviewRun.state == .failed }
            guard let resumed = editor.renderReviewRun.proposal, resumed.isResume,
                  resumed.manifestID == manifestID, resumed.remainingPages < resumed.pageCount,
                  driver.text("render-review.agent.approve", in: window) == "Resume review" else { throw failed("The actual partial review was not offered as explicit Resume review.") }
            try driver.record("actual resume proposal", fields: ["manifestID": resumed.manifestID, "isResume": resumed.isResume,
                "pageCount": resumed.pageCount, "remainingPages": resumed.remainingPages])
            try await driver.click("render-review.agent.approve", in: window)
            try await driver.wait("complete actual aggregate review", seconds: 300) { editor.renderReviewRun.state == .completed || editor.renderReviewRun.state == .failed }
            guard editor.renderReviewRun.state == .completed, service.reviewChildRegistry.activeRunID == nil,
                  !(editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil) else { throw failed(editor.renderReviewRun.errorMessage ?? "The actual aggregate review did not finish.") }
            let final = try await Task.detached { () -> PipelineRenderReviewRunStore.Journal in
                guard let journal = try PipelineRenderReviewRunStore.load(manifest: manifestReference(manifest, root: root), dataRoot: root),
                      let review = try PipelineRenderReviewWriter.loadIfPresent(dataRoot: root) else { throw failed("The completed review has no actual current publication.") }
                try PipelineRenderReviewWriter.requireCurrent(review, root)
                return journal
            }.value
            guard final.status == .completed, final.runID == interrupted.runID, final.authorizations.count == 2,
                  Set(interrupted.children).isSubset(of: Set(final.children)),
                  transport.children.filter({ $0.pageID == held.pageID }).count == 1,
                  final.children.contains(checkpoint.1) else { throw failed("Resume replaced or reran an already committed page, or reused its old authorization.") }
            let after = try chatBytes(service)
            guard before == after else { throw failed("The isolated child review changed the originating conversation or its provider session.") }
            try after.write(to: output.appendingPathComponent("chat-after.json"))
            try PlanningWriterIO.json(final).write(to: output.appendingPathComponent("completed-journal.json"))
            let receipts = try await Task.detached { try archive(manifest: manifest, journal: final, root: root, output: output) }.value
            if backend == .anthropicAPI {
                let http = AgentReviewChildOwnerHTTP.evidence
                guard http.errors.isEmpty, !http.bodies.isEmpty, http.bodies.count == http.responses.count else { throw failed("The actual API HTTP fixture recorded an unexpected transport failure.") }
                for (index, body) in http.bodies.enumerated() {
                    try body.write(to: output.appendingPathComponent("api-request-\(index).json"))
                    try http.responses[index].write(to: output.appendingPathComponent("api-response-\(index).sse"))
                }
            } else {
                guard transport.stoppedCLIChildren == transport.children.count else { throw failed("An owned CLI-line context outlived completion or cancellation.") }
                try write(transport.cliLines, to: output.appendingPathComponent("actual-cli-decoder-lines.json"))
            }
            heartbeat.mark("completed")
            guard Set(transport.children.map(\.generationKey)).count == transport.children.count else { throw failed("A child context identity was reused.") }
            let requests: [[String: Any]] = transport.children.map { ["runID": $0.runID.uuidString.lowercased(), "authID": $0.authID.uuidString.lowercased(),
                "manifestID": $0.manifestID, "pageID": $0.pageID, "kind": $0.kind.rawValue, "backend": $0.backend.rawValue,
                "requestedModelID": $0.modelID as Any? ?? NSNull(), "bootstrapSHA256": FileDigest.sha256(of: Data($0.bootstrap.utf8))] }
            try write(requests, to: output.appendingPathComponent("actual-child-requests.json"))
            try driver.capture("completed-aggregate-review", target: window)
            try driver.record("actual completed aggregate", fields: ["runID": final.runID.uuidString.lowercased(),
                "authorizationCount": final.authorizations.count, "completedPages": manifest.pages.count,
                "chatSHA256": FileDigest.sha256(of: after), "receiptCount": receipts])
            let responsiveness = try heartbeat.result()
            try write(responsiveness, to: output.appendingPathComponent("actual-ui-heartbeats.json"))
            let result: [String: Any] = ["backend": backend.rawValue, "liveAgent": false,
                "transport": backend == .anthropicAPI ? "Actual AnthropicClient HTTP/SSE through isolated URLProtocol fixture" : "Controlled CLI NDJSON through actual ClaudeStreamDecoder; no CLI launch",
                "scale": scale, "viewport": [window.contentView!.bounds.width, window.contentView!.bounds.height],
                "shotCount": manifest.snapshot.shots.count, "imageCount": manifest.derivatives.count, "pageCount": manifest.pages.count,
                "manifestID": manifest.id, "runID": final.runID.uuidString.lowercased(), "authorizationCount": final.authorizations.count,
                "interruptedPages": interruptedPages, "childContexts": transport.children.count, "receiptCount": receipts,
                "committedPageCheckpoint": checkpointFields,
                "chatSHA256Before": FileDigest.sha256(of: before), "chatSHA256After": FileDigest.sha256(of: after),
                "heartbeats": responsiveness, "native": driver.result()]
            try write(result, to: output.appendingPathComponent("backend-result.json")); return result
        } catch { driver.failure(error); throw error }
    }

    private static func chatBytes(_ service: AgentService) throws -> Data {
        struct Transcript: Encodable { let currentSessionID: UUID?; let messages: [AgentMessage]; let sessions: [ChatSession] }
        return try PlanningWriterIO.json(Transcript(currentSessionID: service.currentSessionId, messages: service.messages, sessions: service.sessions))
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?
        private var samples: [[String: Any]] = []
        private var boundaries: [[String: Any]] = []
        private var maximumGap = 0.0
        init(run: PipelineRenderReviewRun) {
            task = Task { @MainActor [weak self] in
                var previous = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime, gap = now - previous
                    previous = now; maximumGap = max(maximumGap, gap)
                    samples.append(["time": now, "gapSeconds": gap, "state": run.state.rawValue, "stage": run.currentStage])
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
        func mark(_ label: String) { boundaries.append(["label": label, "time": ProcessInfo.processInfo.systemUptime]) }
        func result() throws -> [String: Any] {
            guard samples.count >= 2, maximumGap.isFinite, maximumGap <= 0.5,
                  samples.contains(where: { $0["state"] as? String == "running" }) else {
                throw failed("The actual main-actor heartbeat exceeded 500 ms or did not observe running review.")
            }
            return ["intervalSeconds": 0.05, "maximumAllowedGapSeconds": 0.5, "maximumGapSeconds": maximumGap,
                "boundaries": boundaries, "samples": samples]
        }
    }
    nonisolated private static func manifestReference(_ manifest: PipelineRenderReviewManifest, root: URL) throws -> CanonicalArtifactReferenceV1 {
        try PlanningWriterIO.reference("render-review/manifests/\(manifest.id).v2.json", id: manifest.id, role: "host.render-review-manifest", dataRoot: root)
    }
    nonisolated private static func archive(manifest: PipelineRenderReviewManifest, journal: PipelineRenderReviewRunStore.Journal,
                                          root: URL, output: URL) throws -> Int {
        var pending = manifest.snapshot.references + manifest.derivatives.map(\.reference) + journal.authorizations + journal.children
        pending.append(try manifestReference(manifest, root: root))
        pending.append(try PlanningWriterIO.reference(RenderReviewV1.currentPath, id: "actual-current-review",
            role: "host.actual-current-review", dataRoot: root))
        var seen = [String: String](), artifacts: [[String: Any]] = []
        func references(_ value: Any) -> [CanonicalArtifactReferenceV1] {
            if let object = value as? [String: Any] {
                if Set(["id", "role", "path", "sha256"]).isSubset(of: Set(object.keys)),
                   let data = try? JSONSerialization.data(withJSONObject: object),
                   let reference = try? JSONDecoder().decode(CanonicalArtifactReferenceV1.self, from: data) { return [reference] }
                return object.values.flatMap(references)
            }
            if let values = value as? [Any] { return values.flatMap(references) }
            return []
        }
        while let reference = pending.popLast() {
            if let hash = seen[reference.path] { guard hash == reference.sha256 else { throw failed("The archived receipt path has conflicting hashes.") }; continue }
            let source = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
            let bytes = try Data(contentsOf: source)
            guard FileDigest.sha256(of: bytes) == reference.sha256 else { throw failed("An actual receipt changed during archival.") }
            seen[reference.path] = reference.sha256
            let relative = "artifacts/" + reference.path
            let destination = output.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
            artifacts.append(["path": reference.path, "artifact": relative, "sha256": reference.sha256])
            if reference.path.hasSuffix(".json"), let value = try? JSONSerialization.jsonObject(with: bytes) { pending += references(value) }
        }
        try write(artifacts, to: output.appendingPathComponent("artifact-index.json")); return artifacts.count
    }
    nonisolated private static func write(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native child review acceptance: " + message) }
}

private extension AgentReviewChildRequest {
    var generationKey: String { authID.uuidString + "/" + pageID }
}
