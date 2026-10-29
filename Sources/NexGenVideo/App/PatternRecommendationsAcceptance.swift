import AppKit
import NexGenEngine

@MainActor
enum PatternRecommendationsAcceptance {
    static func run(editor: EditorViewModel, directory: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? VideoProject }).first(where: { $0.editorViewModel === editor }),
              let window = document.windowControllers.first?.window, window.isVisible,
              let home = editor.workingRoot, let root = DataRootResolver.dataRoot(of: home),
              editor.projectState?.nextPhaseName == "brief" else {
            throw GateBlocked("Native pattern acceptance requires the actual open document at its unapproved Brief.")
        }
        let evidencePath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard evidencePath != canonicalPath, !evidencePath.hasPrefix(canonicalPath + "/") else {
            throw GateBlocked("Retain pattern evidence outside its canonical project tree.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: "native-pattern")
        do {
            window.makeKeyAndOrderFront(nil)
            try await driver.wait("pattern action can start") { !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked }
            let beforeGates = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
            try beforeGates.write(to: directory.appendingPathComponent("pattern-gates-before.yaml"))
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            try await driver.click("pipeline.overview.select.brief", in: window, enabled: false)
            try await driver.wait("native pattern disclosure") {
                ["open", "closed"].contains(driver.text("production.pattern.open", in: window) ?? "missing")
            }
            if driver.text("production.pattern.open", in: window) == "closed" {
                try await driver.click("production.pattern.open", in: window, enabled: false)
            }
            func displayedSnapshot() async throws -> PatternRecommendationsStore.Snapshot {
                try await driver.wait("actual pattern response binding") {
                    driver.state("production.pattern.refresh", in: window) == true
                        && driver.text("production.pattern.response", in: window) != nil
                }
                guard let text = driver.text("production.pattern.response", in: window) else {
                    throw GateBlocked("The actual pattern view has no response binding.")
                }
                let binding = try JSONDecoder().decode(PatternRecommendationsStore.ResponseBinding.self, from: Data(text.utf8))
                let current = try await PatternRecommendationsStore.capture(editor: editor, mode: binding.mode, excluded: binding.excluded)
                guard current.responseBinding == binding, driver.text("production.pattern.response", in: window) == text else {
                    throw GateBlocked("The displayed comparison changed during native evidence capture.")
                }
                return current
            }
            let before = try await displayedSnapshot()
            guard before.canEdit, before.excluded.isEmpty,
                  let result = before.envelope.recommendations?.results.first(where: { !$0.excluded && $0.fitScore != nil && $0.id != before.selectedID }),
                  let score = result.fitScore else {
                throw GateBlocked("The actual pack fixture has no selectable authored pattern with an initially empty exclusion set.")
            }
            let brief = try YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile)
            let providerBytes = before.rawResult
            try providerBytes.write(to: directory.appendingPathComponent("pattern-provider.json"))
            func retain(_ stage: String, snapshot: PatternRecommendationsStore.Snapshot) async throws -> [String: Data] {
                guard editor.workingRoot == home, editor.openWorkingCopyKey == before.key,
                      editor.openWorkingCopyGeneration == before.generation else { throw GateBlocked("The pattern evidence project changed.") }
                let verified = try PipelinePatternSelectionEvidence.read(dataRoot: root)
                guard verified?.decision == snapshot.decision else { throw GateBlocked("The current pattern receipt changed before observation.") }
                let retained = try await Task.detached(priority: .userInitiated) { () throws -> [String: Data] in
                    let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
                    var bytes: [String: Data] = [:]
                    func collect(_ relative: String) throws {
                        let url = root.appendingPathComponent(relative)
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isSymbolicLink != true else { throw GateBlocked("The pattern evidence contains an aliased artifact.") }
                        if values.isDirectory == true {
                            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                                try collect(relative.isEmpty ? name : relative + "/" + name)
                            }
                        } else if values.isRegularFile == true { bytes[relative] = try Data(contentsOf: url) }
                        else { throw GateBlocked("The pattern evidence contains an unsupported artifact.") }
                    }
                    try collect("")
                    try fence.requireUnchanged()
                    return bytes
                }.value
                guard editor.workingRoot == home, editor.openWorkingCopyKey == before.key,
                      editor.openWorkingCopyGeneration == before.generation,
                      try PipelinePatternSelectionEvidence.read(dataRoot: root)?.decision == snapshot.decision,
                      Set(verified?.references.map(\.path) ?? []).isSubset(of: Set(retained.keys)),
                      retained[PipelineLayout.briefFile].map({ FileDigest.sha256(of: $0) }) == snapshot.briefSHA256,
                      retained[PipelineLayout.projectFile].map({ FileDigest.sha256(of: $0) }) == snapshot.projectSHA256 else {
                    throw GateBlocked("The complete canonical pattern tree changed before retention.")
                }
                var files: [[String: Any]] = []
                for path in retained.keys.sorted() {
                    let bytes = retained[path]!
                    let url = root.appendingPathComponent(path)
                    let name = "pattern-state-\(stage)-\(files.count)." + url.pathExtension
                    try bytes.write(to: directory.appendingPathComponent(name))
                    files.append(["canonicalPath": path, "retainedPath": name, "sha256": FileDigest.sha256(of: bytes)])
                }
                guard let projectBytes = retained[PipelineLayout.projectFile],
                      try YAMLCoding.decode(ProjectMeta.self, from: String(decoding: projectBytes, as: UTF8.self)).project == brief.project else {
                    throw GateBlocked("The retained canonical project identity changed.")
                }
                let state: [String: Any] = ["sourceRoot": root.path, "projectID": brief.project,
                    "selectedID": snapshot.selectedID as Any? ?? NSNull(), "decisionID": snapshot.decision?.id as Any? ?? NSNull(),
                    "briefSHA256": snapshot.briefSHA256, "files": files]
                try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("pattern-state-" + stage + ".json"))
                try driver.record("pattern persisted " + stage, fields: state)
                return retained
            }
            func responseBinding(_ snapshot: PatternRecommendationsStore.Snapshot) throws -> Any {
                try JSONSerialization.jsonObject(with: PlanningWriterIO.json(snapshot.responseBinding))
            }
            func retainComparison(_ stage: String, excluded: [String]) async throws {
                let current = try await displayedSnapshot()
                guard current.mode == before.mode, current.excluded == excluded,
                      let value = current.envelope.recommendations?.results.first(where: { $0.id == result.id }),
                      value.excluded == excluded.contains(result.id) else { throw GateBlocked("The displayed exclusion response lost its candidate.") }
                let name = "pattern-" + stage + "-provider.json"
                try current.rawResult.write(to: directory.appendingPathComponent(name))
                try driver.record("pattern comparison " + stage, fields: ["response": name,
                    "sha256": FileDigest.sha256(of: current.rawResult), "excludedIDs": excluded,
                    "responseBinding": try responseBinding(current),
                    "index": driver.text("production.pattern.index." + result.id, in: window) as Any? ?? NSNull(),
                    "confidenceCoverage": driver.text("production.pattern.confidence." + result.id, in: window) ?? "missing",
                    "library": driver.text("production.pattern.library", in: window) ?? "missing",
                    "chooseEnabled": driver.state("production.pattern.choose." + result.id, in: window) as Any? ?? NSNull()])
            }
            _ = try await retain("before", snapshot: before)
            try await driver.wait("actual pattern comparison") {
                driver.text("production.pattern.index." + result.id, in: window) == String(Int(score.rounded()))
                    && driver.text("production.pattern.library", in: window) != nil
            }
            try driver.record("pattern visible provider values", fields: ["patternID": result.id,
                "index": driver.text("production.pattern.index." + result.id, in: window) ?? "missing",
                "confidenceCoverage": driver.text("production.pattern.confidence." + result.id, in: window) ?? "missing",
                "library": driver.text("production.pattern.library", in: window) ?? "missing",
                "responseBinding": try responseBinding(before)])
            try driver.capture("comparison", target: window)
            try await driver.click("production.pattern.details." + result.id, in: window, enabled: false)
            guard let field = before.details[result.id]?.evidence.first else { throw GateBlocked("The actual pattern has no sourced signature to inspect.") }
            try await driver.reveal("production.pattern.evidence.\(result.id).\(field.id)", in: window)
            try driver.visible(["production.pattern.evidence.\(result.id).\(field.id)"], in: window)
            guard driver.text("production.pattern.evidence.\(result.id).\(field.id)", in: window) == field.basis else {
                throw GateBlocked("The native signature relabelled its measured/documented/inferred evidence.")
            }
            try driver.record("pattern visible signature basis", fields: ["field": field.id,
                "basis": driver.text("production.pattern.evidence.\(result.id).\(field.id)", in: window) ?? "missing"])
            try driver.capture("signature", target: window)
            try await driver.click("production.pattern.exclude." + result.id, in: window)
            try await driver.wait("native explicit exclusion") {
                driver.text("production.pattern.exclude." + result.id, in: window) == "excluded"
                    && driver.state("production.pattern.choose." + result.id, in: window) == false
            }
            try await retainComparison("excluded", excluded: [result.id])
            try driver.capture("excluded", target: window)
            try await driver.click("production.pattern.exclude." + result.id, in: window)
            try await driver.wait("native inclusion restores choice") { driver.state("production.pattern.choose." + result.id, in: window) == true }
            try await retainComparison("included", excluded: [])
            try driver.capture("included", target: window)
            try await driver.click("production.pattern.choose." + result.id, in: window)
            let reason = "Use this language deliberately while retaining its stated limitations."
            if result.requiresDeliberateChoice {
                try await driver.wait("empty deliberate choice disabled") { driver.state("production.pattern.confirm", in: window) == false }
                try await driver.fill("production.pattern.reason", value: reason, in: window, requireFocusExit: true)
                guard driver.state("production.pattern.confirm", in: window) == false else { throw GateBlocked("An unacknowledged warning was actionable.") }
                try await driver.click("production.pattern.acknowledge", in: window)
                try await driver.click("production.pattern.confirm", in: window)
            }
            try await driver.wait("native pattern choice saved", seconds: 30) {
                editor.brief?.directorPattern == result.id && driver.text("production.pattern.saved", in: window) == result.id
            }
            let selected = try await PatternRecommendationsStore.capture(editor: editor, mode: before.mode, excluded: before.excluded)
            guard let saved = selected.decision, saved.patternID == result.id, saved.warnings == result.warnings,
                  !result.requiresDeliberateChoice || saved.reason == reason else { throw GateBlocked("The native decision lost its warnings or reason.") }
            let selectedTree = try await retain("selected", snapshot: selected)
            var staleRejected = false
            var staleMessage = ""
            do {
                try await PatternRecommendationsStore.select(nil, expected: before, reason: "Stale negative probe", acknowledged: true, editor: editor)
            } catch { staleMessage = error.localizedDescription; staleRejected = staleMessage.contains("Reload recommendations") }
            guard staleRejected else {
                throw GateBlocked("A stale native pattern snapshot was not explicitly rejected without mutation.")
            }
            try driver.record("pattern stale snapshot refused", fields: ["apiNegativeOnly": true, "briefUnchanged": true, "message": staleMessage])
            let afterStale = try await PatternRecommendationsStore.capture(editor: editor, mode: before.mode, excluded: before.excluded)
            let afterStaleTree = try await retain("after-stale", snapshot: afterStale)
            guard afterStaleTree == selectedTree, afterStale.decision?.id == selected.decision?.id else {
                throw GateBlocked("The refused stale choice changed canonical bytes or its selection pointer.")
            }
            try driver.capture("selected", target: window)
            guard !(window.firstResponder is NSTextView) else { throw GateBlocked("Pattern Undo still targets a text editor.") }
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native pattern Undo", seconds: 30) {
                !PatternRecommendationsStore.isBusy(editor: editor) && editor.brief?.directorPattern == before.selectedID
                    && driver.state("production.pattern.refresh", in: window) == true
                    && driver.text("production.pattern.saved", in: window) == (before.selectedID ?? "none")
            }
            _ = try await retain("undo", snapshot: try await PatternRecommendationsStore.capture(editor: editor, mode: before.mode, excluded: before.excluded))
            try driver.capture("undo", target: window)
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native pattern Redo", seconds: 30) {
                !PatternRecommendationsStore.isBusy(editor: editor) && editor.brief?.directorPattern == result.id
                    && driver.state("production.pattern.refresh", in: window) == true
                    && driver.text("production.pattern.saved", in: window) == result.id
            }
            _ = try await retain("redo", snapshot: try await PatternRecommendationsStore.capture(editor: editor, mode: before.mode, excluded: before.excluded))
            try driver.capture("redo", target: window)
            try await driver.click("production.pattern.none", in: window)
            try await driver.wait("native optional pattern", seconds: 30) {
                editor.brief?.directorPattern == nil && driver.text("production.pattern.saved", in: window) == "none"
            }
            _ = try await retain("none", snapshot: try await PatternRecommendationsStore.capture(editor: editor, mode: before.mode, excluded: before.excluded))
            let afterGates = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
            guard beforeGates == afterGates else { throw GateBlocked("Choosing a pattern changed phase approval.") }
            try afterGates.write(to: directory.appendingPathComponent("pattern-gates-after.yaml"))
            let decisionBytes = try Data(contentsOf: root.appendingPathComponent("brief/pattern-selections/\(saved.id).v1.json"))
            try decisionBytes.write(to: directory.appendingPathComponent("pattern-decision.json"))
            for suffix in ["recommendations.json", "pattern.json", "brief.yaml"] {
                try Data(contentsOf: root.appendingPathComponent("brief/pattern-selections/\(saved.id).\(suffix)"))
                    .write(to: directory.appendingPathComponent("pattern-selected." + suffix))
            }
            try driver.capture("optional-no-pattern", target: window)
            let resultDictionary: [String: Any] = ["nativeRecommendations": true, "exactProviderResult": true,
                "nativeExcludeInclude": true, "nativeDeliberateChoice": result.requiresDeliberateChoice,
                "persistedWarnings": true, "nativeUndoRedo": true, "nativeNoPattern": true,
                "staleSnapshotRejected": true, "gatesUnchanged": true, "patternID": result.id,
                "evidenceBasis": field.basis, "providerSHA256": FileDigest.sha256(of: providerBytes),
                "decisionSHA256": FileDigest.sha256(of: decisionBytes), "liveProvider": false,
                "evidence": driver.result()]
            try JSONSerialization.data(withJSONObject: resultDictionary, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("pattern-result.json"))
            return resultDictionary
        } catch { driver.failure(error); throw error }
    }
}
