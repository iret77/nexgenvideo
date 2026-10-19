import AppKit
import NexGenEngine

@MainActor
enum ProductionTakeRepairAcceptance {
    static func run(snapshot: TakeReview.Snapshot, context: ProductionPlanningAcceptanceFixture.Context,
                    driver: ProductionVisualSourcesDriver, sheet: NSWindow) async throws {
        let editor = context.editor, root = context.dataRoot, shotID = snapshot.take.shotID
        let requests = MusicvideoGenerationHTTP.requests.count, spends = editor.generationLog.spendEvents.count
        let before = try await retainedState(snapshot: snapshot, root: root, driver: driver, label: "before")
        let reviewSHA = before[TakeReview.path(takeID: snapshot.take.id)]
        let initialReview = try await Task.detached { try TakeReview.load(take: snapshot.take, dataRoot: root) }.value
        guard let initialReview, initialReview.findings.count == 1, initialReview.findings[0].pass == .identity,
              initialReview.findings[0].verdict == .rejected else { throw failed("Repair requires the actual one-pass identity rejection.") }
        try driver.record("native take repair decisions begin", fields: ["takeID": snapshot.take.id, "shotID": shotID, "files": before,
            "providerRequestsBefore": requests, "spendEventsBefore": spends])
        if let _ = try await Task.detached(operation: { try TakeRepairPlan.current(shotID: shotID, dataRoot: root) }).value {
            throw failed("The shot already had an iteration decision before native input.")
        }
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: true, driver: driver, in: sheet)
        guard driver.state("take.repair.save", in: sheet) == false, driver.state("take.repair.continue", in: sheet) == false else {
            throw failed("An empty, unsaved repair decision is actionable.")
        }
        try await driver.picker("take.repair.operation", title: TakeRepairPlan.Operation.stop.label,
            expected: TakeRepairPlan.Operation.stop.rawValue, in: sheet)
        let reason = "Stop new generation while the rejected candidate's usable source range is inspected."
        try await driver.fill("take.repair.reason", value: reason, in: sheet, requireFocusExit: true)
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.limits", content: "take.repair.rolls",
            expanded: true, driver: driver, in: sheet)
        try await driver.fill("take.repair.rolls", value: "0", in: sheet, requireFocusExit: true)
        let invalidLimitBlocked = driver.state("take.repair.save", in: sheet) == false
        guard invalidLimitBlocked else { throw failed("An invalid native iteration limit can be saved.") }
        let policy = TakeIterationPolicyV1(rollsPerPrompt: 5, failuresBeforeRewrite: 4,
            cleanFailuresBeforeModelLimit: 3, channelsBeforeModelLimit: 3, iterationsBeforeSimplification: 12)
        for (id, value) in [("rolls", 5), ("failures", 4), ("clean-failures", 3), ("channels", 3), ("simplify-after", 12)] {
            try await driver.fill("take.repair." + id, value: String(value), in: sheet, requireFocusExit: true)
        }
        try driver.capture("take-repair-limits", target: sheet)
        try await driver.click("take.repair.save", in: sheet)
        try await driver.wait("native stop decision saved", seconds: 30) { driver.state("take.repair.continue", in: sheet) == true }
        let stopped = try await Task.detached { try TakeRepairPlan.current(shotID: shotID, dataRoot: root) }.value
        guard let stopped, stopped.plan.operation == .stop, stopped.plan.reason == reason,
              stopped.plan.takeID == snapshot.take.id, stopped.plan.reviewSHA256 == reviewSHA, stopped.plan.policy == policy,
              stopped.plan.decidedBy == "native-user" else { throw failed("The saved stop decision differs from its actual native fields.") }
        let stoppedTurn = try await continueDecision(stopped.plan, editor: editor, driver: driver, sheet: sheet)
        var denied = false
        do { _ = try await TakeRepairPlan.requireForGeneration(input: snapshot.take.generationInput, home: snapshot.home) }
        catch { denied = error.localizedDescription.contains("Generation is paused by the recorded decision") }
        guard denied, MusicvideoGenerationHTTP.requests.count == requests, editor.generationLog.spendEvents.count == spends else {
            throw failed("The real generation guard did not preserve the native stop decision without spending or dispatch.")
        }
        try await retainDecision(stopped, snapshot: snapshot, root: root, turn: stoppedTurn,
            guardResult: "paused", driver: driver)
        let decisions: [(TakeRepairPlan.Operation, String)] = [
            (.reroll, "Keep this exact compiled prompt, references and route for another explicitly approved roll."),
            (.revisePrompt, "Change only the action line after inspecting the rejected candidate."),
            (.changeReference, "Replace one conditioning reference; retain the current route and output settings."),
            (.changeModel, "Choose another verified model route while retaining the current intent and references."),
            (.cleanRewriteWithReference, "Rewrite the action intent and replace one reference; this is a user decision, not evidence of a model limit."),
            (.cleanRewriteWithModel, "Rewrite the action intent and change the route; keep the approved camera, timing and references."),
            (.simplifyShot, "Stop generation and explicitly rewind Shot Planning before simplifying the action.")
        ]
        guard Set(decisions.map(\.0) + [.stop, .rescueRange]) == Set(TakeRepairPlan.Operation.allCases),
              decisions.count + 2 == TakeRepairPlan.Operation.allCases.count else { throw failed("The native repair sequence omits an available operation.") }
        for (operation, explanation) in decisions {
            try await driver.picker("take.repair.operation", title: operation.label, expected: operation.rawValue, in: sheet)
            guard driver.state("take.repair.continue", in: sheet) == false else { throw failed("An unsaved decision retained continuation authority.") }
            try driver.record("native repair choice pending", fields: ["operation": operation.rawValue,
                "continueEnabled": driver.state("take.repair.continue", in: sheet) == true])
            try await driver.fill("take.repair.reason", value: explanation, in: sheet, requireFocusExit: true)
            try await driver.click("take.repair.save", in: sheet)
            try await driver.wait("saved native repair " + operation.rawValue, seconds: 30) { driver.state("take.repair.continue", in: sheet) == true }
            guard let choice = try await Task.detached(operation: { try TakeRepairPlan.current(shotID: shotID, dataRoot: root) }).value,
                  choice.plan.operation == operation, choice.plan.reason == explanation, choice.plan.policy == policy,
                  choice.plan.takeID == snapshot.take.id, choice.plan.reviewSHA256 == reviewSHA, choice.plan.decidedBy == "native-user" else {
                throw failed("The actual saved repair decision differs from its native fields.")
            }
            let turn = try await continueDecision(choice.plan, editor: editor, driver: driver, sheet: sheet)
            let guardResult: String
            do {
                let accepted = try await TakeRepairPlan.requireForGeneration(input: snapshot.take.generationInput, home: snapshot.home)
                guard operation == .reroll, accepted == choice.id else { throw failed("An unchanged request bypassed the native repair decision.") }
                guardResult = "unchanged-reroll-allowed"
            } catch {
                if operation == .simplifyShot, error.localizedDescription.contains("Generation is paused by the recorded decision") {
                    guardResult = "paused"
                } else if operation != .reroll, error.localizedDescription.contains("The request does not match the recorded repair decision") {
                    guardResult = "unchanged-request-rejected"
                } else { throw error }
            }
            guard MusicvideoGenerationHTTP.requests.count == requests, editor.generationLog.spendEvents.count == spends else {
                throw failed("Selecting a repair decision generated or spent without a separate actual request.")
            }
            try driver.capture("take-repair-" + operation.rawValue, target: sheet)
            try await retainDecision(choice, snapshot: snapshot, root: root, turn: turn, guardResult: guardResult, driver: driver)
        }
        try await driver.picker("take.repair.operation", title: TakeRepairPlan.Operation.rescueRange.label,
            expected: TakeRepairPlan.Operation.rescueRange.rawValue, in: sheet)
        let staleContinuationBlocked = driver.state("take.repair.continue", in: sheet) == false
        guard staleContinuationBlocked else { throw failed("Changing a decision retained stale continuation authority.") }
        try driver.record("native repair choice pending", fields: ["operation": TakeRepairPlan.Operation.rescueRange.rawValue,
            "continueEnabled": driver.state("take.repair.continue", in: sheet) == true])
        let rescueReason = "Inspect the existing source interval; do not generate another candidate."
        try await driver.fill("take.repair.reason", value: rescueReason, in: sheet, requireFocusExit: true)
        try await driver.click("take.repair.save", in: sheet)
        try await driver.wait("native rescue decision saved", seconds: 30) { driver.state("take.repair.continue", in: sheet) == true }
        let rescue = try await Task.detached { try TakeRepairPlan.current(shotID: shotID, dataRoot: root) }.value
        guard let rescue, rescue.id != stopped.id, rescue.plan.operation == .rescueRange,
              rescue.plan.reason == rescueReason, rescue.plan.policy == policy, rescue.plan.reviewSHA256 == reviewSHA,
              try await Task.detached(operation: { try TakeRepairPlan.load(id: stopped.id, dataRoot: root) }).value == stopped.plan else {
            throw failed("The explicit rescue decision lost its values or the earlier stop history.")
        }
        let rescueTurn = try await continueDecision(rescue.plan, editor: editor, driver: driver, sheet: sheet)
        do {
            _ = try await TakeRepairPlan.requireForGeneration(input: snapshot.take.generationInput, home: snapshot.home)
            throw failed("A rescue decision permitted an unchanged generation request.")
        } catch {
            guard error.localizedDescription.contains("Generation is paused by the recorded decision") else { throw error }
        }
        try await retainDecision(rescue, snapshot: snapshot, root: root, turn: rescueTurn, guardResult: "paused", driver: driver)
        let after = try await retainedState(snapshot: snapshot, root: root, driver: driver, label: "after")
        guard before == after,
              MusicvideoGenerationHTTP.requests.count == requests, editor.generationLog.spendEvents.count == spends else {
            throw failed("Repair decisions changed the current take, review, gate chain or provider spending.")
        }
        try driver.record("native take repair decisions complete", fields: ["takeID": snapshot.take.id, "shotID": shotID,
            "files": after, "providerRequestsBefore": requests, "providerRequestsAfter": MusicvideoGenerationHTTP.requests.count,
            "spendEventsBefore": spends, "spendEventsAfter": editor.generationLog.spendEvents.count,
            "claim": "Nine native decisions and direct unchanged-request guard checks; no repaired output or model-limit quality claim."])
        try driver.capture("take-repair-rescue", target: sheet)
        try driver.record("native take repair stop and rescue", fields: ["takeID": snapshot.take.id,
            "stopSHA256": stopped.id, "rescueSHA256": rescue.id, "reviewSHA256": rescue.plan.reviewSHA256,
            "invalidLimitBlocked": invalidLimitBlocked, "staleContinuationBlocked": staleContinuationBlocked, "actualGenerationGuardBlocked": denied,
            "providerRequestsBefore": requests, "providerRequestsAfter": MusicvideoGenerationHTTP.requests.count,
            "spendEventsBefore": spends, "spendEventsAfter": editor.generationLog.spendEvents.count])
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: false, driver: driver, in: sheet)
    }

    private static func continueDecision(_ plan: TakeRepairPlan, editor: EditorViewModel,
                                         driver: ProductionVisualSourcesDriver, sheet: NSWindow) async throws -> [AgentMessage] {
        let previous = Set(editor.agentService.messages.map(\.id))
        try await driver.click("take.repair.continue", in: sheet)
        try await driver.wait("real repair control turn completed", seconds: 30) {
            !editor.agentService.isStreaming && editor.agentService.messages.contains {
                !previous.contains($0.id) && $0.role == .assistant && $0.blocks.contains {
                    if case .text(let text) = $0 { return text == "Acceptance transport received render." }; return false
                }
            }
        }
        let messages = editor.agentService.messages.filter { !previous.contains($0.id) }
        guard let user = messages.first(where: { $0.role == .user }), user.hidden,
              user.userPresentation?.typedText == plan.reason,
              user.userPresentation?.choiceRecord?.selections.contains(where: { $0.label == "Decision" && $0.values == [plan.operation.label] }) == true else {
            throw failed("The actual repair control turn lost the native decision or its attributed reason.")
        }
        return messages
    }

    private static func retainDecision(_ value: (id: String, plan: TakeRepairPlan), snapshot: TakeReview.Snapshot,
                                       root: URL, turn: [AgentMessage], guardResult: String,
                                       driver: ProductionVisualSourcesDriver) async throws {
        let output = driver.output.appendingPathComponent("take-repair-evidence")
        let hashes = try await Task.detached {
            let current = try Data(contentsOf: ProjectLocalFile.resolve(TakeRepairPlan.currentPath(shotID: snapshot.take.shotID), dataRoot: root))
            let archive = try Data(contentsOf: ProjectLocalFile.requireHash(value.id, at: TakeRepairPlan.archivePath(id: value.id), dataRoot: root))
            guard current == archive, try JSONDecoder().decode(TakeRepairPlan.self, from: archive) == value.plan else { throw failed("The current decision differs from its immutable history.") }
            let files = [value.id + ".json": archive, value.plan.operation.rawValue + "-current.json": current,
                value.plan.operation.rawValue + "-turn.json": try PlanningWriterIO.json(turn)]
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var hashes: [String: String] = [:]
            for (name, bytes) in files {
                try bytes.write(to: output.appendingPathComponent(name), options: .atomic)
                hashes[name] = FileDigest.sha256(of: bytes)
            }
            return hashes
        }.value
        try driver.record("native attributed repair decision", fields: ["id": value.id, "operation": value.plan.operation.rawValue,
            "reason": value.plan.reason, "files": hashes, "unchangedRequestGuard": guardResult])
    }

    private static func retainedState(snapshot: TakeReview.Snapshot, root: URL, driver: ProductionVisualSourcesDriver,
                                      label: String) async throws -> [String: String] {
        let output = driver.output.appendingPathComponent("take-repair-evidence/" + label)
        return try await Task.detached {
            let paths = [PipelineLayout.gatesFile, PipelineLayout.lineageFile,
                PipelineRenderTakeStore.takePath(id: snapshot.take.id, phase: snapshot.take.phase),
                PipelineRenderTakeStore.indexPath(phase: snapshot.take.phase), TakeReview.path(takeID: snapshot.take.id)]
            var hashes: [String: String] = [:]
            for path in paths {
                let bytes = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: root))
                let destination = output.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination, options: .atomic)
                hashes[path] = FileDigest.sha256(of: bytes)
            }
            return hashes
        }.value
    }

    nonisolated private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native take repair: " + message) }
}
