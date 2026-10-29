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
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var measurements: [[String: String]] = []
            var snapshots: [String: [String: String]] = [:]
            func retain(_ stage: String, _ timeline: Timeline) throws {
                let bytes = try encoder.encode(timeline), path = "timeline-" + stage + ".json"
                try bytes.write(to: directory.appendingPathComponent(path))
                let ref = ["path": path, "sha256": FileDigest.sha256(of: bytes)]
                snapshots[stage] = ref
                try driver.record("native color timeline", fields: ["stage": stage, "artifact": ref])
            }
            func capture(_ stage: String) throws {
                try driver.capture(stage, target: window)
                guard let path = (driver.result()["screenshots"] as? [String])?.last else { throw GateBlocked("The native color screenshot is missing.") }
                let bytes = try Data(contentsOf: directory.appendingPathComponent(path))
                try driver.record("native color capture", fields: ["stage": stage, "path": path, "sha256": FileDigest.sha256(of: bytes)])
            }
            try retain("before", before)
            func measure() async throws {
                let previous = driver.text("color.reference.comparison", in: window)
                let seen = Set(measurements.compactMap { $0["comparisonID"] })
                try await driver.click("color.reference.measure", in: window)
                try await driver.wait("fresh measured color comparison") {
                    guard let id = driver.text("color.reference.comparison", in: window), UUID(uuidString: id) != nil else { return false }
                    return id != previous && !seen.contains(id)
                        && driver.text("color.reference.measured.mean", in: window) != nil && driver.state("color.reference.propose", in: window) == true
                }
                guard let id = driver.text("color.reference.comparison", in: window) else { throw GateBlocked("The actual native comparison identifier is missing.") }
                let measuredFrame = editor.currentFrame
                let actual = await ToolExecutor(editor: editor).execute(name: "inspect_color",
                    args: ["clipId": clip.id, "reference": reference.id, "atFrame": measuredFrame])
                guard !actual.isError else { throw GateBlocked("The independent inspect_color measurement failed.") }
                let raw = try encoder.encode(actual.content), path = "actual-color-tool-\(measurements.count + 1).json"
                try raw.write(to: directory.appendingPathComponent(path))
                guard let text = actual.content.compactMap({ block -> String? in if case .text(let value) = block { value } else { nil } }).last else { throw GateBlocked("Actual color measurement is missing.") }
                let measured = try JSONDecoder().decode(ColorReferenceMeasurements.self, from: Data(text.utf8))
                let expected = [
                    "mean": "\(measured.clip.luma.mean)|\(measured.reference.luma.mean)|\(measured.gap.lumaMean)",
                    "black": "\(measured.clip.luma.black)|\(measured.reference.luma.black)|\(measured.gap.lumaBlack)",
                    "white": "\(measured.clip.luma.white)|\(measured.reference.luma.white)|\(measured.gap.lumaWhite)",
                    "saturation": "\(measured.clip.saturation)|\(measured.reference.saturation)|\(measured.gap.saturation)",
                    "warmCool": "\(measured.clip.balance.warmCool)|\(measured.reference.balance.warmCool)|\(measured.gap.warmCool)",
                    "greenMagenta": "\(measured.clip.balance.greenMagenta)|\(measured.reference.balance.greenMagenta)|\(measured.gap.greenMagenta)",
                    "clipping": "\(measured.clip.luma.clipLowPct)|\(measured.clip.luma.clipHighPct)|\(measured.reference.luma.clipLowPct)|\(measured.reference.luma.clipHighPct)",
                ]
                guard driver.text("color.reference.comparison", in: window) == id,
                      editor.currentFrame == measuredFrame, editor.timeline == before,
                      expected.allSatisfy({ driver.text("color.reference.measured." + $0.key, in: window) == $0.value }) else { throw GateBlocked("The native color comparison differs from actual inspect_color output.") }
                guard let clipImage = driver.text("color.reference.frame.clip", in: window),
                      let referenceImage = driver.text("color.reference.frame.reference", in: window) else { throw GateBlocked("The displayed measured-frame identities are missing.") }
                let images = actual.content.compactMap { block -> Data? in
                    if case .image(let bytes, let type) = block, type == "image/jpeg" { return Data(base64Encoded: bytes) }; return nil
                }
                guard images.count == 2, FileDigest.sha256(of: images[0]) == clipImage,
                      FileDigest.sha256(of: images[1]) == referenceImage else { throw GateBlocked("The displayed comparison frames differ from the independently sampled tool frames.") }
                var observation = expected
                observation.merge(["comparisonID": id, "toolPath": path, "toolSHA256": FileDigest.sha256(of: raw),
                    "clipImageSHA256": clipImage, "referenceImageSHA256": referenceImage,
                    "toolClipImageSHA256": FileDigest.sha256(of: images[0]), "toolReferenceImageSHA256": FileDigest.sha256(of: images[1])]) { _, new in new }
                measurements.append(observation)
                try driver.record("actual native color measurement", fields: observation)
            }
            func propose() async throws -> Double {
                guard let measurement = measurements.last, let id = measurement["comparisonID"],
                      driver.text("color.reference.comparison", in: window) == id else { throw GateBlocked("The current native measurement is missing.") }
                let count = runtime.requests.count
                try await driver.click("color.reference.propose", in: window)
                try await driver.wait("fresh schema-validated AI color proposal") {
                    runtime.failure != nil || (runtime.requests.count == count + 1 && runtime.proposals.count == count + 1
                        && !service.isStreaming && driver.state("color.reference.apply", in: window) == true
                        && driver.text("color.reference.proposal", in: window) == id)
                }
                guard runtime.failure == nil, editor.timeline == before,
                      runtime.requests.count == count + 1, runtime.proposals.count == count + 1,
                      let request = runtime.requests.last, let proposed = runtime.proposals.last,
                      let requestValue = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                      let scope = requestValue["scope"] as? [String: String], scope["comparisonID"] == id,
                      requestValue["sessionID"] as? String == service.currentSessionId?.uuidString else {
                    throw GateBlocked(runtime.failure ?? "The color proposal did not bind the fresh native comparison.")
                }
                let proposal = try JSONDecoder().decode(ColorReferenceProposal.self, from: proposed)
                try proposal.validate()
                guard proposal.comparisonID.uuidString == id, proposal.clipID == clip.id, proposal.referenceID == reference.id,
                      proposal.grade.keys.sorted() == ["exposure"], let exposure = proposal.grade["exposure"],
                      let visibleExposure = driver.text("color.reference.control.exposure", in: window),
                      visibleExposure == String(exposure) else { throw GateBlocked("The displayed correction differs from the actual retained proposal.") }
                let requestPath = "actual-color-request-\(count + 1).json", proposalPath = "actual-color-proposal-\(count + 1).json"
                try request.write(to: directory.appendingPathComponent(requestPath)); try proposed.write(to: directory.appendingPathComponent(proposalPath))
                try driver.record("actual native color proposal", fields: ["comparisonID": id, "requestPath": requestPath,
                    "requestSHA256": FileDigest.sha256(of: request), "proposalPath": proposalPath, "proposalSHA256": FileDigest.sha256(of: proposed),
                    "visibleExposure": visibleExposure])
                return exposure
            }
            try await measure()
            for id in ["clip", "reference"] {
                try await driver.reveal("color.reference.frame." + id, in: window)
                try driver.visible(["color.reference.frame." + id], in: window)
                try capture("measured-frame-" + id)
            }
            try capture("measured")
            _ = try await propose(); try capture("proposal")
            let discardedID = driver.text("color.reference.comparison", in: window)
            try await driver.click("color.reference.discard", in: window)
            try await driver.wait("native comparison and proposal discarded") {
                ["comparison", "proposal"].allSatisfy { driver.text("color.reference." + $0, in: window) == nil }
                    && ["apply", "propose"].allSatisfy { driver.state("color.reference." + $0, in: window) == nil }
                    && driver.text("color.reference.status", in: window) == "Color proposal discarded. Measure again for a new comparison."
            }
            guard editor.timeline == before else { throw GateBlocked("Discard changed the clip.") }
            try driver.record("native color discard", fields: ["comparisonID": discardedID ?? "",
                "proposalAbsent": driver.text("color.reference.proposal", in: window) == nil,
                "comparisonAbsent": driver.text("color.reference.comparison", in: window) == nil,
                "applyAbsent": driver.state("color.reference.apply", in: window) == nil,
                "proposeAbsent": driver.state("color.reference.propose", in: window) == nil,
                "status": driver.text("color.reference.status", in: window) ?? ""])
            try retain("discarded", editor.timeline)
            try await measure(); let reviewedExposure = try await propose()
            let preview = try await PostproductionControlsAcceptance.readablePreview(editor)
            try await driver.click("color.reference.apply", in: window)
            try await driver.wait("explicit native color application") { editor.timeline != before && driver.text("color.reference.status", in: window)?.contains("Color correction applied") == true }
            let after = editor.timeline
            try requireExposureChange(before: before, after: after, clipID: clip.id, value: reviewedExposure)
            try retain("applied", after)
            _ = try await PostproductionControlsAcceptance.changedPreview(editor, from: preview)
            try capture("applied")
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native correction undo") { editor.timeline == before }
            try retain("undone", editor.timeline)
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native correction redo") { editor.timeline == after }
            try retain("redone", editor.timeline)
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("restore baseline before stale comparison") { editor.timeline == before }
            try retain("restored", editor.timeline)
            try await measure(); _ = try await propose()
            if driver.text("inspector.section.Basic Correction", in: window) != "expanded" {
                try await driver.click("inspector.section.Basic Correction", in: window)
            }
            try await driver.fill("inspector.adjust.value.color.exposure.ev", value: "0.37", in: window, requireFocusExit: true)
            try await driver.wait("independent native clip edit") {
                guard let value = editor.clipFor(id: clip.id)?.effects?.first(where: { $0.type == "color.exposure" })?.params["ev"]?.value else { return false }
                return abs(value - 0.37) < 0.000001
            }
            let independentlyChanged = editor.timeline
            try requireExposureChange(before: before, after: independentlyChanged, clipID: clip.id, value: 0.37)
            try retain("stale-before", independentlyChanged)
            try await driver.click("color.reference.apply", in: window)
            try await driver.wait("visible stale color refusal") { driver.text("color.reference.error", in: window)?.contains("Measure a new comparison") == true }
            guard editor.timeline == independentlyChanged, runtime.mutationRefusals == 3,
                  try ExportQueue.PathState.capture(savedProject) == original else { throw GateBlocked("Color comparison lost its source, native decision, or stale-target protection.") }
            try retain("stale-after", editor.timeline)
            try capture("stale-refusal")
            guard runtime.requests.count == 3, runtime.proposals.count == 3 else { throw GateBlocked("The three actual bounded runtime turns are missing.") }
            var result = driver.result()
            result.merge(["nativeMeasuredComparison": true, "actualToolReadout": true, "nativeProposalDiscard": true,
                "nativeProposalApply": true, "nativeUndoRedo": true, "nativeStaleRefusal": true,
                "sourceProjectPreserved": true, "directMutationRefusals": runtime.mutationRefusals,
                "liveAgent": false, "clipID": clip.id, "referenceID": reference.id,
                "measurements": measurements, "timelines": snapshots,
                "nativeReferenceImport": true, "referenceSHA256": referenceSHA,
                "viewport": window.contentView.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? [],
                "scale": AppTheme.Typography.validatedScale(UserDefaults.standard.double(forKey: AppTheme.Typography.scaleKey))]) { _, new in new }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("color-reference-result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }

    private static func requireExposureChange(before: Timeline, after: Timeline, clipID: String, value: Double) throws {
        let locations = before.tracks.indices.flatMap { track in
            before.tracks[track].clips.indices.compactMap { clip in before.tracks[track].clips[clip].id == clipID ? ClipLocation(trackIndex: track, clipIndex: clip) : nil }
        }
        guard locations.count == 1, let location = locations.first, before.tracks.count == after.tracks.count,
              after.tracks[location.trackIndex].clips.count == before.tracks[location.trackIndex].clips.count else { throw GateBlocked("The color correction changed its target layout.") }
        let original = before.tracks[location.trackIndex].clips[location.clipIndex]
        let changed = after.tracks[location.trackIndex].clips[location.clipIndex]
        let oldExposure = (original.effects ?? []).filter { $0.type == "color.exposure" }
        let exposure = (changed.effects ?? []).filter { $0.type == "color.exposure" }
        let expectedIndex = (original.effects ?? []).firstIndex { $0.type == "color.exposure" }
            ?? EffectRegistry.insertIndex(original.effects ?? [], for: "color.exposure")
        guard oldExposure.count <= 1, exposure.count == 1, var expected = exposure.first,
              (changed.effects ?? []).firstIndex(where: { $0.type == "color.exposure" }) == expectedIndex,
              expected.params["ev"] == EffectParam(value: value),
              (original.effects ?? []).filter({ $0.type != "color.exposure" }) == (changed.effects ?? []).filter({ $0.type != "color.exposure" }) else {
            throw GateBlocked("The applied color controls differ from the reviewed exposure or changed another effect.")
        }
        if let previous = oldExposure.first {
            expected.params["ev"] = previous.params["ev"]
            guard expected == previous else { throw GateBlocked("The color correction changed another exposure property.") }
        } else {
            guard expected.enabled, UUID(uuidString: expected.id) != nil, expected.params.keys.sorted() == ["ev"] else { throw GateBlocked("The added exposure differs from the reviewed control.") }
        }
        var normalized = after
        normalized.tracks[location.trackIndex].clips[location.clipIndex].effects = original.effects
        guard normalized == before else { throw GateBlocked("The color correction changed a non-target clip or property.") }
    }

    @MainActor private final class FixtureRuntime: AgentRuntimeAdapter {
        let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
        private(set) var state: AgentRuntimeState = .idle
        private var execute: AgentRuntimeToolExecutor?
        private var task: Task<Void, Never>?
        private(set) var mutationRefusals = 0
        private(set) var failure: String?
        private(set) var requests: [Data] = []
        private(set) var proposals: [Data] = []
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
                    guard let measuredStart = text.range(of: "Actual inspect_color measurements:\n")?.upperBound,
                          let measuredEnd = text.range(of: "\nAttached images", range: measuredStart..<text.endIndex)?.lowerBound else {
                        throw GateBlocked("The actual model request lost its measurement JSON.")
                    }
                    let measuredJSON = String(text[measuredStart..<measuredEnd])
                    _ = try JSONDecoder().decode(ColorReferenceMeasurements.self, from: Data(measuredJSON.utf8))
                    let refusalID = UUID().uuidString
                    let refusalArguments: [String: Any] = ["clipIds": [clip], "exposure": 2]
                    let refusalBytes = try JSONSerialization.data(withJSONObject: refusalArguments, options: [.sortedKeys])
                    let refused = await execute(refusalID, "apply_color", String(decoding: refusalBytes, as: UTF8.self))
                    guard refused.isError, refused.content.contains(where: { if case .text(let t) = $0 { return t.contains("color-comparison turn") }; return false }) else {
                        throw GateBlocked("The comparison turn allowed an unapproved direct grade.")
                    }
                    let refusalContent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(refused.content))
                    requests.append(try JSONSerialization.data(withJSONObject: ["text": text, "scope": scope,
                        "sessionID": request.sessionID.uuidString, "turnID": request.turnID.uuidString, "measurementsJSON": measuredJSON,
                        "images": images.map { ["mediaType": $0.mediaType, "base64": $0.base64] },
                        "imageSHA256": images.map { FileDigest.sha256(of: Data(base64Encoded: $0.base64)!) },
                        "mutationAttempt": ["toolUseID": refusalID, "toolName": "apply_color", "arguments": refusalArguments,
                            "isError": refused.isError, "content": refusalContent]], options: [.sortedKeys]))
                    mutationRefusals += 1
                    let input = ColorReferenceProposal(comparisonID: try UUID(uuidString: comparison).unwrapColor(), clipID: clip, referenceID: reference,
                        rationale: "Isolated model response: raise the clip exposure for native review; this is a proposal, not a measured value.", grade: ["exposure": 0.5])
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let bytes = try encoder.encode(input)
                    proposals.append(bytes)
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
