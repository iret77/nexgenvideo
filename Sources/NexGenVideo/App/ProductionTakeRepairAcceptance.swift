import AppKit
import NexGenEngine

@MainActor
enum ProductionTakeRepairAcceptance {
    static func run(snapshot: TakeReview.Snapshot, context: ProductionPlanningAcceptanceFixture.Context,
                    driver: ProductionVisualSourcesDriver, sheet: NSWindow) async throws {
        let editor = context.editor, root = context.dataRoot, shotID = snapshot.take.shotID
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
        try await driver.fill("take.repair.reason", value: reason, in: sheet)
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.limits", content: "take.repair.rolls",
            expanded: true, driver: driver, in: sheet)
        try await driver.fill("take.repair.rolls", value: "0", in: sheet)
        guard driver.state("take.repair.save", in: sheet) == false else { throw failed("An invalid native iteration limit can be saved.") }
        let policy = TakeIterationPolicyV1(rollsPerPrompt: 5, failuresBeforeRewrite: 4,
            cleanFailuresBeforeModelLimit: 3, channelsBeforeModelLimit: 3, iterationsBeforeSimplification: 12)
        for (id, value) in [("rolls", 5), ("failures", 4), ("clean-failures", 3), ("channels", 3), ("simplify-after", 12)] {
            try await driver.fill("take.repair." + id, value: String(value), in: sheet)
        }
        try driver.capture("take-repair-limits", target: sheet)
        try await driver.click("take.repair.save", in: sheet)
        try await driver.wait("native stop decision saved", seconds: 30) { driver.state("take.repair.continue", in: sheet) == true }
        let stopped = try await Task.detached { try TakeRepairPlan.current(shotID: shotID, dataRoot: root) }.value
        guard let stopped, stopped.plan.operation == .stop, stopped.plan.reason == reason,
              stopped.plan.takeID == snapshot.take.id, stopped.plan.policy == policy,
              stopped.plan.decidedBy == "native-user" else { throw failed("The saved stop decision differs from its actual native fields.") }
        let requests = MusicvideoGenerationHTTP.requests.count, spends = editor.generationLog.spendEvents.count
        let messages = Set(editor.agentService.messages.map(\.id))
        try await driver.click("take.repair.continue", in: sheet)
        try await driver.wait("real repair control turn completed", seconds: 30) {
            !editor.agentService.isStreaming && editor.agentService.messages.contains {
                !messages.contains($0.id) && $0.role == .assistant && $0.blocks.contains {
                    if case .text(let text) = $0 { return text == "Acceptance transport received render." }; return false
                }
            }
        }
        var denied = false
        do { _ = try await TakeRepairPlan.requireForGeneration(input: snapshot.take.generationInput, home: snapshot.home) }
        catch { denied = error.localizedDescription.contains("Generation is paused by the recorded decision") }
        guard denied, MusicvideoGenerationHTTP.requests.count == requests, editor.generationLog.spendEvents.count == spends else {
            throw failed("The real generation guard did not preserve the native stop decision without spending or dispatch.")
        }
        try await driver.picker("take.repair.operation", title: TakeRepairPlan.Operation.rescueRange.label,
            expected: TakeRepairPlan.Operation.rescueRange.rawValue, in: sheet)
        guard driver.state("take.repair.continue", in: sheet) == false else { throw failed("Changing a decision retained stale continuation authority.") }
        let rescueReason = "Inspect the existing source interval; do not generate another candidate."
        try await driver.fill("take.repair.reason", value: rescueReason, in: sheet)
        try await driver.click("take.repair.save", in: sheet)
        try await driver.wait("native rescue decision saved", seconds: 30) { driver.state("take.repair.continue", in: sheet) == true }
        let rescue = try await Task.detached { try TakeRepairPlan.current(shotID: shotID, dataRoot: root) }.value
        guard let rescue, rescue.id != stopped.id, rescue.plan.operation == .rescueRange,
              rescue.plan.reason == rescueReason, rescue.plan.policy == policy,
              try await Task.detached(operation: { try TakeRepairPlan.load(id: stopped.id, dataRoot: root) }).value == stopped.plan else {
            throw failed("The explicit rescue decision lost its values or the earlier stop history.")
        }
        try driver.capture("take-repair-rescue", target: sheet)
        try driver.record("native take repair stop and rescue", fields: ["takeID": snapshot.take.id,
            "stopSHA256": stopped.id, "rescueSHA256": rescue.id, "reviewSHA256": rescue.plan.reviewSHA256,
            "invalidLimitBlocked": true, "staleContinuationBlocked": true, "actualGenerationGuardBlocked": denied,
            "providerRequestsBefore": requests, "providerRequestsAfter": MusicvideoGenerationHTTP.requests.count,
            "spendEventsBefore": spends, "spendEventsAfter": editor.generationLog.spendEvents.count])
        try await ProductionNativeDisclosureAcceptance.toggle("take.repair.open", content: "take.repair.reason",
            expanded: false, driver: driver, in: sheet)
    }

    private static func failed(_ message: String) -> GateBlocked { GateBlocked("Native take repair: " + message) }
}
