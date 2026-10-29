import AppKit
import NexGenEngine

@MainActor
enum ColorReferenceComparisonAcceptance {
    static func run(savedProject: URL, output: URL, scale: Double) async throws -> [String: Any] {
        let directory = output.appendingPathComponent("color-reference-\(Int(scale * 100))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = directory.appendingPathComponent("Color comparison.ngv")
        let original = try ExportQueue.PathState.capture(savedProject)
        try FileManager.default.copyItem(at: savedProject, to: package)
        _ = try ProjectIdentity.regenerate(at: package)
        let runtime = FixtureRuntime()
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in runtime }, runtimeReadinessOverride: { nil })
        let document = try await VideoProject.load(from: package, agentService: service)
        NSDocumentController.shared.addDocument(document); document.makeWindowControllers(); document.showWindows()
        defer { document.close() }
        guard let window = document.windowControllers.first?.window else { throw GateBlocked("The color-comparison document did not open.") }
        let editor = document.editorViewModel
        guard let clip = editor.timeline.tracks.flatMap(\.clips).first(where: { [.image, .video].contains($0.mediaType) && $0.durationFrames > 0 }) else {
            throw GateBlocked("Native color acceptance needs an actual visual timeline clip.")
        }
        let referenceURL = directory.appendingPathComponent("Cool comparison reference.mov")
        try await FullflowAcceptanceFixture.writeVideo(to: referenceURL, duration: 3, fps: 30, warm: false)
        let referenceSHA = try await Task.detached { try FileDigest.sha256(of: referenceURL) }.value
        NSApp.mainMenu = MainMenuBuilder.buildMenu()
        window.setContentSize(AppTheme.Window.projectMin); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: "native-color-reference")
        do {
            try await driver.wait("actual comparison viewport and scale") {
                guard let host = window.contentView else { return false }
                return abs(host.bounds.width - 960) < 1 && abs(host.bounds.height - 640) < 1
                    && AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey)) == scale
            }
            let baseline = editor.timeline, importedIDs = Set(editor.mediaAssets.map(\.id))
            try await driver.click("editor.workspace.media", in: window, enabled: false)
            try await driver.chooseFile(referenceURL, in: window, trigger: "media.action.Import")
            try await driver.wait("actual cool reference import", seconds: 30) {
                editor.mediaImportProgress == nil && editor.mediaAssets.contains {
                    !importedIDs.contains($0.id) && $0.userFacingFilename == referenceURL.lastPathComponent && $0.duration > 0
                }
            }
            guard let reference = editor.mediaAssets.first(where: { !importedIDs.contains($0.id) && $0.userFacingFilename == referenceURL.lastPathComponent }),
                  let actualReferenceURL = editor.mediaResolver.resolveURL(for: reference.id),
                  try await Task.detached(operation: { try FileDigest.sha256(of: actualReferenceURL) }).value == referenceSHA,
                  editor.timeline == baseline else { throw GateBlocked("Native reference import changed the cut or source bytes.") }
            try await driver.click("editor.workspace.edit", in: window, enabled: false)
            try GenericNLEAcceptance.pointerOnClip(clip, editor: editor, window: window, driver: driver)
            try GenericNLEAcceptance.pointerOnRuler(frame: clip.startFrame, window: window, driver: driver)
            try await driver.wait("native color target selection") { editor.selectedClipIds == [clip.id] && editor.activePreviewTab == .timeline && editor.currentFrame == clip.startFrame }
            try await driver.click("inspector.tab.Adjust", in: window, enabled: false)
            try await driver.click("color.reference.open", in: window, enabled: false)
            try await driver.click("color.reference.choose", in: window)
            let libraryID = "library.pick." + reference.id
            try await driver.wait("native reference library popover") {
                NSApp.windows.contains { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: libraryID, in: $0) != nil }
            }
            guard let library = NSApp.windows.first(where: { $0.isVisible && WorkspaceUIAcceptance.probeFrame(identifier: libraryID, in: $0) != nil }), library.isKeyWindow else {
                throw GateBlocked("The native reference picker did not take focus.")
            }
            try await driver.click(libraryID, in: library)
            try await driver.wait("return to native comparison") { window.isKeyWindow }
            let before = editor.timeline
            func measure() async throws {
                try await driver.click("color.reference.measure", in: window)
                try await driver.wait("actual measured color comparison") { driver.text("color.reference.measured.mean", in: window) != nil && driver.state("color.reference.propose", in: window) == true }
                let actual = await ToolExecutor(editor: editor).execute(name: "inspect_color",
                    args: ["clipId": clip.id, "reference": reference.id, "atFrame": editor.currentFrame])
                let raw = try JSONEncoder().encode(actual.content)
                try raw.write(to: directory.appendingPathComponent("actual-color-tool.json"))
                guard let text = actual.content.compactMap({ if case .text(let value) = $0 { value } else { nil } }).last else { throw GateBlocked("Actual color measurement is missing.") }
                let measured = try JSONDecoder().decode(ColorReferenceMeasurements.self, from: Data(text.utf8))
                let expected = "\(measured.clip.luma.mean)|\(measured.reference.luma.mean)|\(measured.gap.lumaMean)"
                guard driver.text("color.reference.measured.mean", in: window) == expected else { throw GateBlocked("The native color comparison differs from actual inspect_color output.") }
                try driver.record("actual native color measurement", fields: ["mean": expected, "toolSHA256": FileDigest.sha256(of: raw)])
            }
            func propose() async throws {
                try await driver.click("color.reference.propose", in: window)
                try await driver.wait("schema-validated AI color proposal") { !service.isStreaming && driver.state("color.reference.apply", in: window) == true }
                guard runtime.failure == nil, editor.timeline == before else { throw GateBlocked(runtime.failure ?? "A color proposal changed the clip before native approval.") }
            }
            try await measure()
            for id in ["clip", "reference"] {
                try await driver.reveal("color.reference.frame." + id, in: window)
                try driver.visible(["color.reference.frame." + id], in: window)
                try driver.capture("measured-frame-" + id, target: window)
            }
            try driver.capture("measured", target: window)
            try await propose(); try driver.capture("proposal", target: window)
            try await driver.click("color.reference.discard", in: window)
            guard editor.timeline == before else { throw GateBlocked("Discard changed the clip.") }
            try await measure(); try await propose()
            let preview = try await PostproductionControlsAcceptance.readablePreview(editor)
            try await driver.click("color.reference.apply", in: window)
            try await driver.wait("explicit native color application") { editor.timeline != before && driver.text("color.reference.status", in: window)?.contains("Color correction applied") == true }
            let after = editor.timeline
            _ = try await PostproductionControlsAcceptance.changedPreview(editor, from: preview)
            try driver.capture("applied", target: window)
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native correction undo") { editor.timeline == before }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native correction redo") { editor.timeline == after }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("restore baseline before stale comparison") { editor.timeline == before }
            try await measure(); try await propose()
            if driver.text("inspector.section.Basic Correction", in: window) != "expanded" {
                try await driver.click("inspector.section.Basic Correction", in: window)
            }
            try await driver.fill("inspector.adjust.value.color.exposure.ev", value: "0.37", in: window, requireFocusExit: true)
            try await driver.wait("independent native clip edit") { editor.clipFor(id: clip.id)?.effects?.first(where: { $0.type == "color.exposure" })?.params["ev"]?.value == 0.37 }
            let independentlyChanged = editor.timeline
            try await driver.click("color.reference.apply", in: window)
            try await driver.wait("visible stale color refusal") { driver.text("color.reference.error", in: window)?.contains("Measure a new comparison") == true }
            guard editor.timeline == independentlyChanged, runtime.mutationRefusals == 3,
                  try ExportQueue.PathState.capture(savedProject) == original else { throw GateBlocked("Color comparison lost its source, native decision, or stale-target protection.") }
            try driver.capture("stale-refusal", target: window)
            guard let request = runtime.lastRequest, let proposed = runtime.lastProposal else { throw GateBlocked("The real bounded runtime evidence is missing.") }
            try request.write(to: directory.appendingPathComponent("actual-color-request.json"))
            try proposed.write(to: directory.appendingPathComponent("actual-color-proposal.json"))
            var result = driver.result()
            result.merge(["nativeMeasuredComparison": true, "actualToolReadout": true, "nativeProposalDiscard": true,
                "nativeProposalApply": true, "nativeUndoRedo": true, "nativeStaleRefusal": true,
                "sourceProjectPreserved": true, "directMutationRefusals": runtime.mutationRefusals,
                "liveAgent": false, "clipID": clip.id, "referenceID": reference.id,
                "requestSHA256": FileDigest.sha256(of: request), "proposalSHA256": FileDigest.sha256(of: proposed),
                "nativeReferenceImport": true, "referenceSHA256": referenceSHA,
                "viewport": window.contentView.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
                "scale": AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))]) { _, new in new }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("color-reference-result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }

    @MainActor private final class FixtureRuntime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        private var execute: AgentRuntimeToolExecutor?
        private var task: Task<Void, Never>?
        private(set) var mutationRefusals = 0
        private(set) var failure: String?
        private(set) var lastRequest: Data?
        private(set) var lastProposal: Data?
        func start(_ request: AgentRuntimeSessionRequest) throws { execute = request.executeTool; state = .ready(sessionID: request.sessionID) }
        func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
        func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
            let pair = AsyncStream<AgentRuntimeEventEnvelope>.makeStream()
            state = .running(sessionID: request.sessionID, turnID: request.turnID)
            task = Task { @MainActor in
                do {
                    guard let execute else { throw GateBlocked("Color runtime has no actual host executor.") }
                    let text = request.currentMessage.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n")
                    guard let start = text.range(of: "Native comparison scope: ")?.upperBound,
                          let scope = try JSONSerialization.jsonObject(with: Data(text[start...].prefix { $0 != "\n" }.utf8)) as? [String: String],
                          let comparison = scope["comparisonID"], let clip = scope["clipID"], let reference = scope["referenceID"] else {
                        throw GateBlocked("The actual native color scope is missing.")
                    }
                    let images = request.currentMessage.content.compactMap { value -> AgentRuntimeImage? in
                        if case .image(let image) = value { return image }; return nil
                    }
                    guard images.count == 2, images.allSatisfy({ Data(base64Encoded: $0.base64).flatMap(NSImage.init(data:)) != nil }),
                          text.contains("Actual inspect_color measurements:") else { throw GateBlocked("The actual model request lost its measured frame inputs.") }
                    lastRequest = try JSONSerialization.data(withJSONObject: ["text": text, "scope": scope,
                        "imageSHA256": images.map { FileDigest.sha256(of: Data(base64Encoded: $0.base64)!) }], options: [.sortedKeys])
                    let refused = await execute(UUID().uuidString, "apply_color", "{\"clipIds\":[\"\(clip)\"],\"exposure\":2}")
                    guard refused.isError, refused.content.contains(where: { if case .text(let t) = $0 { return t.contains("color-comparison turn") }; return false }) else {
                        throw GateBlocked("The comparison turn allowed an unapproved direct grade.")
                    }
                    mutationRefusals += 1
                    let input = ColorReferenceProposal(comparisonID: try UUID(uuidString: comparison).unwrapColor(), clipID: clip, referenceID: reference,
                        rationale: "Isolated model response: raise the clip exposure for native review; this is a proposal, not a measured value.", grade: ["exposure": 0.5])
                    let bytes = try JSONEncoder().encode(input)
                    lastProposal = bytes
                    let result = await execute(UUID().uuidString, "propose_color_match", String(decoding: bytes, as: UTF8.self))
                    guard !result.isError else { throw GateBlocked("The actual schema-validated proposal failed: \(result.content)") }
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

private extension Optional where Wrapped == UUID {
    func unwrapColor() throws -> UUID {
        guard let self else { throw GateBlocked("The actual color comparison identifier is invalid.") }; return self
    }
}
