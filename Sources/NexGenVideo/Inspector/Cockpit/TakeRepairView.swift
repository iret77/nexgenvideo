import SwiftUI
import NexGenEngine

struct TakeRepairView: View {
    @Environment(EditorViewModel.self) private var editor
    let snapshot: TakeReview.Snapshot
    let canWrite: Bool
    @State private var operation = TakeRepairPlan.Operation.revisePrompt
    @State private var reason = ""
    @State private var policy = TakeIterationPolicyV1()
    @State private var assessment: TakeIterationAssessmentV1?
    @State private var message: String?
    @State private var busy = false
    @State private var persisted: TakeRepairPlan?

    private var saved: Bool {
        persisted?.takeID == snapshot.take.id && persisted?.operation == operation
            && persisted?.reason == reason && persisted?.policy == policy
    }

    var body: some View {
        DisclosureGroup("Iteration decision") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if let assessment {
                    Text(guidance(assessment)).foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("\(assessment.iterations.count) recorded prompt revisions · \(assessment.completedFailedIterations) failed iterations on the current axis")
                }
                Text("A failed iteration needs a complete reviewed batch failing on the same axis. Provider errors and unreviewed outputs do not prove a model limit. No recommendation requires another paid run.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Picker("Next action", selection: $operation) {
                    ForEach(TakeRepairPlan.Operation.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(busy)
                TextField("Explain the single change, clean rewrite or stop", text: $reason).disabled(busy)
                DisclosureGroup("Iteration limits") {
                    TextField("Rolls per prompt revision", value: $policy.rollsPerPrompt, format: .number)
                    TextField("Failed iterations before clean rewrite", value: $policy.failuresBeforeRewrite, format: .number)
                    TextField("Clean failures before model-limit review", value: $policy.cleanFailuresBeforeModelLimit, format: .number)
                    TextField("Control channels before model-limit review", value: $policy.channelsBeforeModelLimit, format: .number)
                    TextField("Iterations before simplifying the shot", value: $policy.iterationsBeforeSimplification, format: .number)
                }.disabled(busy)
                Button("Save iteration decision") {
                    let choice = operation, explanation = reason, limits = policy
                    busy = true
                    Task {
                        do {
                            try await TakeRepairPlan.save(snapshot: snapshot, operation: choice, reason: explanation, policy: limits, editor: editor)
                            message = "Decision saved. The host checks the actual request against it before generation."
                            await load()
                        } catch { message = error.localizedDescription }
                        busy = false
                    }
                }.buttonStyle(InlineActionButtonStyle(variant: .approval))
                    .disabled(busy || !canWrite || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? policy.validate()) == nil)
                Button("Continue with agent") {
                    editor.agentService.send(controlTurn: AgentControlTurn(
                        command: "Read get_render_manifest for \(snapshot.take.phase) and the recorded iteration decision for shot \(snapshot.take.shotID). Apply that decision through the canonical workflow. A stop or rescue decision must not start a generation. Changes to approved shot truth require explicit rewind. Any generation still needs the existing spend approval.",
                        selections: [.init(label: "Shot", values: [snapshot.take.shotID]), .init(label: "Decision", values: [operation.label])],
                        typedText: reason))
                }.buttonStyle(InlineActionButtonStyle()).disabled(busy || !saved || !canWrite)
                if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor) }
            }.padding(.vertical, AppTheme.Spacing.sm)
        }
        .task(id: snapshot.take.id) { await load() }
    }

    private func load() async {
        let home = snapshot.home, input = snapshot.take.generationInput
        do {
            let value = try await Task.detached(priority: .utility) {
                guard let root = DataRootResolver.dataRoot(of: home), let shotID = input.promptShotId else { throw ToolError("The iteration project is unavailable.") }
                let current = try TakeRepairPlan.current(shotID: shotID, dataRoot: root)
                return (try TakeRepairPlan.assessment(input: input, dataRoot: root, policy: current?.plan.policy ?? TakeIterationPolicyV1()), current?.plan)
            }.value
            assessment = value.0
            persisted = value.1
            if reason.isEmpty, let plan = value.1, plan.takeID == snapshot.take.id {
                operation = plan.operation; reason = plan.reason; policy = plan.policy
            }
        } catch { message = error.localizedDescription }
    }

    private func guidance(_ value: TakeIterationAssessmentV1) -> String {
        switch value.recommendation {
        case .reviewPending: String(localized: "Review the recorded candidates before diagnosing the failure.")
        case .chooseCandidate: String(localized: "An accepted candidate exists. Choose it or explain why another attempt is needed.")
        case .rerollAvailable: String(localized: "The prompt revision has rolls remaining within the configured limit.")
        case .reviseOneVariable: String(localized: "This revision's batch is complete. Change one variable before another batch.")
        case .cleanRewriteAndChannelChange: String(localized: "Rewrite the prompt from scratch and change the control channel.")
        case .modelLimitEligible: String(localized: "The failure persisted across multiple control channels. Review whether the current route limits the shot, or simplify it, rescue existing coverage or stop.")
        case .simplifyShot: String(localized: "Review the shot's complexity. Simplify the action or framing through an explicit rewind, rescue existing coverage, or stop.")
        }
    }
}
