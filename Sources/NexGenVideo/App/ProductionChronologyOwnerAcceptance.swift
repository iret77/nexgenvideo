import AppKit
import NexGenEngine

@MainActor
enum ProductionChronologyOwnerAcceptance {
    enum Defect: String, CaseIterable {
        case unknownOrder, discontinuity, unresolvedDecision

        var diagnostic: String {
            switch self {
            case .unknownOrder: "treatmentCausality.state.unknownOrder"
            case .discontinuity: "treatmentCausality.state.discontinuity"
            case .unresolvedDecision: "treatmentCausality.unresolvedDecisions"
            }
        }
    }

    static func run(output: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Chronology acceptance requires its isolated native process.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let runtime = ProductionRepairAcceptanceRuntime()
        let context = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: runtime.service())
        defer { context.editor.agentService.cancel(); context.document.close() }
        NSDocumentController.shared.addDocument(context.document)
        context.document.makeWindowControllers()
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw GateBlocked("The chronology document has no actual editor window.")
        }
        window.setContentSize(AppTheme.Window.projectMin)
        context.document.showWindows(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "chronology-owner")
        let editor = context.editor, root = context.dataRoot
        await editor.refreshEngineState()
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        try await rewindTreatment(context: context, driver: driver)
        var evidence: [[String: Any]] = []
        for defect in Defect.allCases {
            let prior = try await graph(root)
            let defectRevision = prior.header.revision + 1
            let instruction = "Keep both wall changes, but prepare the explicit " + defect.rawValue + " draft for review."
            runtime.arm(try arguments(defect: defect), expectedText: instruction)
            try await revise(instruction, context: context, driver: driver, revision: defectRevision)
            let invalid = try await graph(root, approval: false)
            guard invalid.header.revision == defectRevision else { throw GateBlocked("The native revision did not create its next immutable Treatment revision.") }
            let gateBefore = try await gates(root)
            try await preserve(invalid, root: root, output: output.appendingPathComponent(defect.rawValue), stage: "draft")
            let failure: String
            do {
                _ = try await graph(root)
                throw GateBlocked("The independent chronology reader accepted the deliberately unresolved draft.")
            } catch let error as ProductionPlanningError {
                guard case .invalid(let reason) = error, reason == defect.diagnostic else { throw error }
                failure = reason
            }
            try await driver.wait("native chronology refusal") {
                driver.state("pipeline.overview.dock.diagnostics", in: window) == true
                    && driver.state("pipeline.overview.approve.treatment", in: window) != true
            }
            try await driver.click("pipeline.overview.dock.diagnostics", in: window)
            try await driver.wait("actual chronology diagnostic") {
                driver.text("pipeline.overview.dock.diagnostic-text", in: window)?.contains(failure) == true
            }
            try driver.capture("blocked-" + defect.rawValue, target: window)
            try await driver.click("pipeline.overview.dock.diagnostics-done", in: window)
            try await driver.wait("diagnostic dismissed") { driver.text("pipeline.overview.dock.diagnostic-text", in: window) == nil }
            guard let home = editor.workingRoot else { throw GateBlocked("The chronology working copy disappeared.") }
            var denied = false
            do {
                try await NativeGateWriter.approve(projectDir: home, phase: "treatment", declaredPack: nil,
                    declaredProductionContract: .current, editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator)
            } catch { denied = true }
            guard denied, try await gates(root) == gateBefore else { throw GateBlocked("The independent gate path mutated approval for an invalid chronology.") }
            try gateBefore.write(to: output.appendingPathComponent(defect.rawValue).appendingPathComponent("refused-gates.yaml"), options: .atomic)
            let correction = "Order the red wall change before the blue change, preserve the intervening red state, and resolve the world-time decision."
            runtime.arm(try arguments(defect: nil), expectedText: correction)
            try await revise(correction, context: context, driver: driver, revision: defectRevision + 1)
            let repaired = try await graph(root)
            guard repaired.header.revision == defectRevision + 1,
                  repaired.beats.map(\.id) == invalid.beats.map(\.id), repaired.stateChanges.count == 2,
                  repaired.stateChanges[0].after == repaired.stateChanges[1].before,
                  repaired.unresolvedDecisions.isEmpty else { throw GateBlocked("The native correction lost story identity, state persistence or its explicit decision.") }
            try await driver.wait("repaired Treatment can be approved") { driver.state("pipeline.overview.approve.treatment", in: window) == true }
            try await driver.click("pipeline.overview.approve.treatment", in: window)
            try await driver.wait("repaired Treatment actually approved") {
                editor.projectState?.phases.first(where: { $0.phase == "treatment" })?.approved == true
                    && editor.projectState?.nextPhaseName == "script"
            }
            let persisted = try await Task.detached { try YAMLArtifactStore(dataRoot: root).load(Gates.self, at: PipelineLayout.gatesFile) }.value
            guard persisted.get("treatment").approved, !persisted.get("script").approved else {
                throw GateBlocked("Treatment repair silently approved its downstream Script.")
            }
            try await preserve(repaired, root: root, output: output.appendingPathComponent(defect.rawValue), stage: "repaired")
            let refs = [invalid.treatmentReference, repaired.treatmentReference]
            for reference in refs {
                _ = try await Task.detached { try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root) }.value
            }
            let row: [String: Any] = ["defect": defect.rawValue, "diagnostic": failure,
                "draftRevision": invalid.header.revision, "repairedRevision": repaired.header.revision,
                "gateBytesUnchangedOnRefusal": true, "actualNativeCorrection": true,
                "actualNativeApproval": true, "downstreamScriptPending": true,
                "draftTreatmentSHA256": invalid.treatmentReference.sha256, "repairedTreatmentSHA256": repaired.treatmentReference.sha256]
            evidence.append(row); try driver.record("chronology repaired " + defect.rawValue, fields: row)
            if defect != Defect.allCases.last { try await rewindTreatment(context: context, driver: driver) }
        }
        let result: [String: Any] = ["schema": "chronology-owner-acceptance/v1", "cases": evidence,
            "transport": "isolated deterministic agent responses through actual host ToolExecutor",
            "semanticModelQualityClaim": false, "providerGenerations": 0,
            "runtimeToolCalls": runtime.completedCalls]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("chronology-result.json"), options: .atomic)
        return result
    }

    private static func rewindTreatment(context: ProductionPlanningAcceptanceFixture.Context,
                                        driver: ProductionVisualSourcesDriver) async throws {
        let editor = context.editor
        try await driver.wait("idle before explicit rewind") { !editor.agentService.isStreaming }
        try await driver.menu("pipeline.overview.actions.treatment", title: "Rewind to here…", in: driver.window)
        try await driver.wait("native rewind confirmation") { NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && AppNativeMenuAcceptance.buttons(in: $0).contains { $0.title == "Rewind to Treatment" } } }
        guard let confirmation = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow && AppNativeMenuAcceptance.buttons(in: $0).contains { $0.title == "Rewind to Treatment" } }) else {
            throw GateBlocked("The explicit Treatment rewind confirmation disappeared.")
        }
        try driver.capture("rewind-confirmation", target: confirmation)
        try AppNativeMenuAcceptance.accessibilityClick("Rewind to Treatment", in: confirmation, driver: driver)
        try await driver.wait("explicit rewind persisted") {
            editor.projectState?.nextPhaseName == "treatment" && editor.projectState?.phases.first(where: { $0.phase == "treatment" })?.approved == false
        }
        try await ProductionV2PlanningAcceptance.selectPhase("treatment", context: context, driver: driver)
    }

    private static func revise(_ text: String, context: ProductionPlanningAcceptanceFixture.Context,
                               driver: ProductionVisualSourcesDriver, revision: Int) async throws {
        let window = driver.window, root = context.dataRoot
        try await driver.fill("story.prose.input.Revise treatment", value: text, in: window)
        try await driver.click("story.prose.action.Revise treatment", in: window)
        try await driver.wait("actual agent Treatment write", seconds: 30) {
            !context.editor.agentService.isStreaming
                && (try? TreatmentCausalityStoreV2.requireCurrent(dataRoot: root, approval: false).header.revision) == revision
        }
        guard context.editor.agentService.streamError == nil,
              context.editor.agentService.messages.contains(where: { message in
                  message.role == .assistant && message.blocks.contains {
                      if case .toolUse(_, let name, _) = $0 { return name == "write_treatment" }; return false
                  }
              }) else { throw GateBlocked("The native prose action did not execute its actual canonical writer.") }
    }

    private static func graph(_ root: URL, approval: Bool = true) async throws -> TreatmentCausalityV2 {
        try await Task.detached { try TreatmentCausalityStoreV2.requireCurrent(dataRoot: root, approval: approval) }.value
    }

    private static func gates(_ root: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) }.value
    }

    private static func preserve(_ graph: TreatmentCausalityV2, root: URL, output: URL, stage: String) async throws {
        try await Task.detached {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let graphPath = TreatmentCausalityV2.versionPath(graph.header.revision)
            let source = try ProjectLocalFile.requireHash(graph.treatmentReference.sha256,
                at: graph.treatmentReference.path, dataRoot: root)
            let files = [(stage + ".v2.json", try Data(contentsOf: ProjectLocalFile.resolve(graphPath, dataRoot: root))),
                         (stage + ".md", try Data(contentsOf: source)),
                         (stage + "-gates.yaml", try Data(contentsOf: ProjectLocalFile.resolve(PipelineLayout.gatesFile, dataRoot: root)))]
            for (name, bytes) in files { try bytes.write(to: output.appendingPathComponent(name), options: .atomic) }
        }.value
    }

    private static func arguments(defect: Defect?) throws -> String {
        let body = ["The pale wall changes from dark to red.", "The same wall changes from red to blue."]
        let stateChanges: [[String: Any]] = [
            ["elementID": "wall", "beatID": "beat-red", "causeBeatID": "beat-red", "before": "dark", "after": "red", "excerpt": body[0]],
            ["elementID": "wall", "beatID": "beat-blue", "causeBeatID": "beat-blue", "before": defect == .discontinuity ? "green" : "red", "after": "blue", "excerpt": body[1]],
        ]
        let proposal: [String: Any] = ["mode": "abstract", "applicationReason": "The same wall has two explicitly related visual states, without inventing a narrative cause.",
            "beats": [["id": "beat-red", "sceneID": "red", "excerpt": body[0], "elementIDs": ["wall"]],
                      ["id": "beat-blue", "sceneID": "blue", "excerpt": body[1], "elementIDs": ["wall"]]],
            "edges": [], "temporalRelations": [["firstBeatID": "beat-red", "secondBeatID": "beat-blue",
                "kind": defect == .unknownOrder ? "unknown" : "before", "reason": "The red state must persist until the next wall change."]],
            "elements": [["id": "wall", "label": "Pale wall", "introductionBeatID": "beat-red", "payoffBeatIDs": [],
                "noPayoffReason": "The wall is visual context, not a planted narrative element."]],
            "stateChanges": stateChanges,
            "unresolvedDecisions": defect == .unresolvedDecision ? [["id": "wall-time", "affectedBeatIDs": ["beat-red", "beat-blue"],
                "question": "Which wall change happens first?", "alternatives": ["red before blue", "blue before red"]]] : [],
            "changeReview": ["reviewer": "Isolated deterministic acceptance response", "upstreamCause": "The user directed the wall-state revision.",
                "downstreamConsequence": "Script and all later approvals must remain pending until the state sequence is confirmed.",
                "affectedBeatIDs": ["beat-red", "beat-blue"], "checks": StoryCausalityDraftV1.ReviewQuestion.allCases.map {
                    ["question": $0.rawValue, "verdict": "satisfied", "explanation": "Both explicit wall changes and their stable identities remain in the draft."] }]]
        let args: [String: Any] = ["origin": "agent_revision", "summary_oneline": "The wall changes from dark through red to blue.",
            "body_markdown": body.joined(separator: "\n\n"), "causality_plan": proposal]
        return String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
    }

}
