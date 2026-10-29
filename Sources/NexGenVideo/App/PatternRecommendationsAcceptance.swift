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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: directory, name: "native-pattern")
        do {
            window.makeKeyAndOrderFront(nil)
            try await driver.wait("pattern action can start") { !editor.agentService.isStreaming && !editor.agentService.isComposerBlocked }
            let beforeGates = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile))
            try beforeGates.write(to: directory.appendingPathComponent("pattern-gates-before.yaml"))
            let before = try await PatternRecommendationsStore.capture(editor: editor)
            guard before.canEdit, let result = before.envelope.recommendations?.results.first(where: { !$0.excluded }),
                  let provider = PackCatalog.registry(activePack: editor.declaredPluginName).patternProvider else {
                throw GateBlocked("The actual pack fixture has no selectable authored pattern; it cannot prove native selection.")
            }
            let brief = try YAMLArtifactStore(dataRoot: root).load(Brief.self, at: PipelineLayout.briefFile)
            var options: [String: Any] = ["match_mode": "balanced", "excluded_pattern_ids": [String]()]
            if let url = AudioProjectLayout.expectedAnalysisArtifactURL(dataRoot: root) {
                let analysis = try JSONDecoder().decode(AnalysisSurfaceData.self, from: Data(contentsOf: url))
                options["perceived_bpm"] = analysis.perceivedBpm
            }
            let affect = root.appendingPathComponent("analysis/affect.json")
            if FileManager.default.fileExists(atPath: affect.path) {
                options["affect_profile"] = try JSONSerialization.jsonObject(with: Data(contentsOf: affect))
            }
            let providerBytes = try provider.recommend(briefJSON: JSONEncoder().encode(brief),
                optionsJSON: JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]))
            try providerBytes.write(to: directory.appendingPathComponent("pattern-provider.json"))
            try await driver.click("editor.workspace.production", in: window, enabled: false)
            try await driver.click("pipeline.overview.select.brief", in: window, enabled: false)
            try await driver.click("production.pattern.open", in: window, enabled: false)
            try await driver.wait("actual pattern comparison") {
                driver.text("production.pattern.index." + result.id, in: window) == result.fitScore.map { String(Int($0.rounded())) }
                    && driver.text("production.pattern.library", in: window) != nil
            }
            try driver.record("pattern visible provider values", fields: ["patternID": result.id,
                "index": driver.text("production.pattern.index." + result.id, in: window) ?? "missing",
                "confidenceCoverage": driver.text("production.pattern.confidence." + result.id, in: window) ?? "missing",
                "library": driver.text("production.pattern.library", in: window) ?? "missing"])
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
            try driver.capture("excluded", target: window)
            try await driver.click("production.pattern.exclude." + result.id, in: window)
            try await driver.wait("native inclusion restores choice") { driver.state("production.pattern.choose." + result.id, in: window) == true }
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
            let selected = try await PatternRecommendationsStore.capture(editor: editor)
            guard let saved = selected.decision, saved.patternID == result.id, saved.warnings == result.warnings,
                  !result.requiresDeliberateChoice || saved.reason == reason else { throw GateBlocked("The native decision lost its warnings or reason.") }
            let selectedBrief = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.briefFile))
            var staleRejected = false
            do {
                try await PatternRecommendationsStore.select(nil, expected: before, reason: "Stale negative probe", acknowledged: true, editor: editor)
            } catch { staleRejected = error.localizedDescription.contains("Reload recommendations") }
            guard staleRejected, try Data(contentsOf: root.appendingPathComponent(PipelineLayout.briefFile)) == selectedBrief else {
                throw GateBlocked("A stale native pattern snapshot was not explicitly rejected without mutation.")
            }
            try driver.record("pattern stale snapshot refused", fields: ["apiNegativeOnly": true, "briefUnchanged": true])
            try driver.capture("selected", target: window)
            try driver.pressKey(6, characters: "z", modifiers: .command, in: window)
            try await driver.wait("native pattern Undo", seconds: 30) { editor.brief?.directorPattern == before.selectedID }
            try driver.pressKey(6, characters: "Z", modifiers: [.command, .shift], in: window)
            try await driver.wait("native pattern Redo", seconds: 30) { editor.brief?.directorPattern == result.id }
            try await driver.click("production.pattern.none", in: window)
            try await driver.wait("native optional pattern", seconds: 30) {
                editor.brief?.directorPattern == nil && driver.text("production.pattern.saved", in: window) == "none"
            }
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
            let result: [String: Any] = ["nativeRecommendations": true, "exactProviderResult": true,
                "nativeExcludeInclude": true, "nativeDeliberateChoice": result.requiresDeliberateChoice,
                "persistedWarnings": true, "nativeUndoRedo": true, "nativeNoPattern": true,
                "staleSnapshotRejected": true, "gatesUnchanged": true, "patternID": result.id,
                "evidenceBasis": field.basis, "providerSHA256": FileDigest.sha256(of: providerBytes),
                "decisionSHA256": FileDigest.sha256(of: decisionBytes), "liveProvider": false,
                "evidence": driver.result()]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("pattern-result.json"))
            return result
        } catch { driver.failure(error); throw error }
    }
}
