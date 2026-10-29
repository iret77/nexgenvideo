import AppKit
import NexGenEngine

@MainActor
enum ProductionSanityOwnerAcceptance {
    static func run(output: URL) async throws -> [String: Any] {
        guard WorkspaceUIAcceptance.isRequested else { throw GateBlocked("Sanity acceptance requires its isolated native process.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let runtime = ProductionRepairAcceptanceRuntime()
        let context = try await ProductionPlanningAcceptanceFixture.makePromotion(agentService: runtime.service())
        defer { context.editor.agentService.cancel(); context.document.close() }
        let editor = context.editor, root = context.dataRoot
        NSDocumentController.shared.addDocument(context.document)
        if context.document.windowControllers.isEmpty { context.document.makeWindowControllers() }
        guard let window = context.document.windowControllers.compactMap({ $0 as? EditorWindowController }).first?.window else {
            throw GateBlocked("The Sanity document has no actual editor window.")
        }
        window.setContentSize(AppTheme.Window.projectMin)
        context.document.showWindows(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let driver = ProductionVisualSourcesDriver(window: window, output: output, name: "sanity-owner")
        await editor.refreshEngineState()
        try await driver.click("editor.workspace.production", in: window, enabled: false)
        let initial = try await projection(root)
        guard let target = initial.shots.first else { throw GateBlocked("The actual plan has no shot to inspect.") }
        let invalidProposal = try await proposal(in: context, missingAnchor: true)
        try await ProductionPlanningAcceptanceFixture.run("write_shotlist", args: ["origin": "agentRevision",
            "proposal": try ProductionPlanningAcceptanceFixture.object(invalidProposal)], in: context)
        let invalid = try await projection(root)
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
        try await ProductionV2PlanningAcceptance.approve("shotlist", artifact: ProductionPlanProjectionV1.versionPath(invalid.header.revision),
            next: "sanity", context: context, driver: driver)
        let run = await context.executor.execute(name: "run_phase", args: ["phase": "sanity"])
        let report = try await audit(root)
        guard report.errors.count == 1, report.errors.first?.code == "BLOCKING_ANCHOR_MISSING",
              report.errors.first?.shotId == target.id else {
            throw GateBlocked("The deliberate missing blocking anchor did not produce its actual deterministic finding.")
        }
        try await preserve(context: context, output: output, name: "blocked", projection: invalid)
        try await ProductionV2PlanningAcceptance.selectPhase("sanity", context: context, driver: driver)
        let finding = "sanity.finding.BLOCKING_ANCHOR_MISSING." + target.id
        try await driver.wait("actual blocking Sanity finding") { driver.text(finding, in: window)?.hasPrefix("error:") == true }
        try await driver.reveal(finding, in: window)
        try driver.visible([finding, "pipeline.overview.approve.sanity"], in: window)
        try driver.capture("blocking-finding", target: window)
        try await driver.click(finding, in: window, enabled: false)
        guard editor.inspectedObject == .shot(target.id) else { throw GateBlocked("The native finding did not inspect its actual shot.") }
        try await driver.wait("Sanity approval unavailable") { driver.state("pipeline.overview.approve.sanity", in: window) == false }
        let before = try await gateBytes(root)
        guard let home = editor.workingRoot else { throw GateBlocked("The Sanity working copy disappeared.") }
        var refused = false
        do {
            try await NativeGateWriter.approve(projectDir: home, phase: "sanity", declaredPack: nil,
                declaredProductionContract: .current, editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator)
        } catch { refused = true }
        guard refused, try await gateBytes(root) == before else { throw GateBlocked("Sanity approved its actual unresolved error.") }
        try before.write(to: output.appendingPathComponent("refused-gates.yaml"), options: .atomic)
        let script = try await Task.detached { try PlanningWriterIO.script(dataRoot: root) }.value
        let scriptBefore = try await Task.detached { try Data(contentsOf: ProjectLocalFile.resolve(ScriptV1.currentPath, dataRoot: root)) }.value
        let wrongPhase = await context.executor.execute(name: "write_script", args: ["origin": "agentRevision",
            "summary": script.summary, "scenes": try ProductionPlanningAcceptanceFixture.object(script.scenes)])
        let scriptAfter = try await Task.detached { try Data(contentsOf: ProjectLocalFile.resolve(ScriptV1.currentPath, dataRoot: root)) }.value
        guard wrongPhase.isError, scriptAfter == scriptBefore, try await gateBytes(root) == before else {
            throw GateBlocked("The wrong-phase writer changed canonical Script or approval bytes.")
        }
        let refusal = text(wrongPhase)
        guard refusal.contains("write_script"), refusal.lowercased().contains("phase") else {
            throw GateBlocked("The valid Script call was not refused by its actual phase capability contract: " + refusal)
        }
        try await rewind(context: context, driver: driver)
        editor.inspectedObject = .shot(target.id)
        guard editor.selectedObjectRevisionTask != nil else { throw GateBlocked("The selected shot has no actual scoped revision task.") }
        let fixedProposal = try await proposal(in: context, missingAnchor: false)
        let direction = "Remove the unnecessary character blocking from this abstract shape shot; retain its action, source, framing and timing."
        let arguments: [String: Any] = ["origin": "agentRevision", "proposal": try ProductionPlanningAcceptanceFixture.object(fixedProposal)]
        let json = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        guard let serialized = String(data: json, encoding: .utf8) else { throw GateBlocked("The scoped revision arguments are not UTF-8.") }
        runtime.arm(serialized, expectedText: direction, tool: "write_shotlist")
        try await driver.menu("agent.task.choose", title: "Revise Selected Object", in: window)
        try await driver.fill("agent.composer.input", value: direction, in: window)
        try driver.visible(["agent.composer.input", "agent.task.run"], in: window)
        try driver.capture("scoped-sanity-correction", target: window)
        try await driver.click("agent.task.run", in: window)
        try await driver.wait("actual scoped plan correction", seconds: 45) {
            !editor.agentService.isStreaming && runtime.completedCalls == 1
        }
        guard editor.agentService.streamError == nil else { throw GateBlocked(editor.agentService.streamError ?? "The native correction failed.") }
        let corrected = try await projection(root)
        guard corrected.header.revision > invalid.header.revision,
              corrected.shots.map(\.id) == invalid.shots.map(\.id), corrected.timings == invalid.timings,
              corrected.shots.first?.blocking.isEmpty == true else { throw GateBlocked("The correction lost canonical shot identity or timing.") }
        try await ProductionV2PlanningAcceptance.approve("shotlist", artifact: ProductionPlanProjectionV1.versionPath(corrected.header.revision),
            next: "sanity", context: context, driver: driver)
        try await ProductionPlanningAcceptanceFixture.prepareImportedSanity(in: context)
        let clean = try await audit(root)
        guard clean.errors.isEmpty else { throw GateBlocked("The actual repaired Sanity report still has errors.") }
        try await ProductionV2PlanningAcceptance.selectPhase("sanity", context: context, driver: driver)
        try await ProductionV2PlanningAcceptance.approve("sanity", artifact: PipelineLayout.sanityReportFile,
            next: "frames", context: context, driver: driver)
        try await preserve(context: context, output: output, name: "repaired", projection: corrected)
        let result: [String: Any] = ["schema": "sanity-owner-acceptance/v1", "shotID": target.id,
            "blockedRevision": invalid.header.revision, "repairedRevision": corrected.header.revision,
            "finding": "BLOCKING_ANCHOR_MISSING", "actualFindingInspected": true,
            "nativeApprovalRefused": refused, "gateBytesUnchangedOnRefusal": true,
            "wrongPhaseTool": "write_script", "wrongPhaseRefusal": refusal,
            "canonicalScriptUnchanged": scriptAfter == scriptBefore, "actualScopedCorrection": true,
            "runtimeToolCalls": runtime.completedCalls, "sanityRunnerReportedError": run.isError,
            "repairedErrors": clean.errors.count, "nextPhase": editor.projectState?.nextPhaseName ?? "missing",
            "transport": "isolated deterministic response through actual host ToolExecutor", "semanticModelQualityClaim": false,
            "providerGenerations": 0]
        try driver.record("actual Sanity repaired", fields: result)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("sanity-result.json"), options: .atomic)
        return result
    }

    private static func proposal(in context: ProductionPlanningAcceptanceFixture.Context,
                                 missingAnchor: Bool) async throws -> PipelineProductionPlanWriter.Proposal {
        let root = context.dataRoot
        let (plan, preparation) = try await Task.detached {
            (try ProductionPlanningLineageV2.projection(dataRoot: root),
             try PipelineShotPlanningPromotionStore.requirePreparation(dataRoot: root))
        }.value
        let shots = plan.shots.enumerated().map { index, shot in
            let value = ExecutionShotV1(id: shot.id, sourceMode: shot.sourceMode, startState: shot.startState,
                endState: shot.endState, primaryAction: shot.primaryAction, camera: shot.camera,
                blocking: missingAnchor && index == 0 ? [.init(entityID: "shape", relation: "Beside the wall")] : [],
                timedActionBeats: shot.timedActionBeats, continuityLocks: shot.continuityLocks,
                transitionIntent: shot.transitionIntent, renderability: shot.renderability, risks: shot.risks,
                rescue: shot.rescue, acceptance: shot.acceptance, generationRequirement: shot.generationRequirement)
            return PipelineProductionPlanWriter.ShotProposal(execution: value, nativeDurationTicks: nil,
                sourceInTicks: 0, sourceInputRange: nil, coreInputs: .init(), referenceDemands: [],
                selectedModelID: nil, selectedOffering: nil)
        }
        return .init(expectedDraftFingerprint: preparation.draft.sha256,
            expectedAssetGraphFingerprint: preparation.graph.sha256, shots: shots)
    }

    private static func rewind(context: ProductionPlanningAcceptanceFixture.Context,
                               driver: ProductionVisualSourcesDriver) async throws {
        try await driver.wait("idle before Shot List rewind") { !context.editor.agentService.isStreaming }
        try await driver.menu("pipeline.overview.actions.shotlist", title: "Rewind to here…", in: driver.window)
        try await driver.wait("actual Shot List rewind confirmation") {
            NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && AppNativeMenuAcceptance.buttons(in: $0).contains { $0.title == "Rewind to Shot List" } }
        }
        guard let sheet = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow && AppNativeMenuAcceptance.buttons(in: $0).contains { $0.title == "Rewind to Shot List" } }) else {
            throw GateBlocked("The native Shot List rewind confirmation disappeared.")
        }
        try AppNativeMenuAcceptance.accessibilityClick("Rewind to Shot List", in: sheet, driver: driver)
        try await driver.wait("Shot List actually pending") { context.editor.projectState?.nextPhaseName == "shotlist" }
        try await ProductionV2PlanningAcceptance.selectPhase("shotlist", context: context, driver: driver)
    }

    private static func projection(_ root: URL) async throws -> ProductionPlanProjectionV1 {
        try await Task.detached { try ProductionPlanningLineageV2.projection(dataRoot: root) }.value
    }

    private static func audit(_ root: URL) async throws -> SanityArtifact {
        try await Task.detached { try SanityArtifactStore.load(dataRoot: root) }.value
    }

    private static func gateBytes(_ root: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: root.appendingPathComponent(PipelineLayout.gatesFile)) }.value
    }

    private static func preserve(context: ProductionPlanningAcceptanceFixture.Context, output: URL,
                                 name: String, projection: ProductionPlanProjectionV1) async throws {
        let root = context.dataRoot
        try await Task.detached {
            for (suffix, path) in [(".v5.yaml", ProductionPlanProjectionV1.versionPath(projection.header.revision)),
                                   ("-sanity.json", PipelineLayout.sanityReportFile), ("-gates.yaml", PipelineLayout.gatesFile)] {
                let source = try ProjectLocalFile.resolve(path, dataRoot: root)
                try Data(contentsOf: source).write(to: output.appendingPathComponent(name + suffix), options: .atomic)
            }
        }.value
    }

    private static func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n")
    }
}
