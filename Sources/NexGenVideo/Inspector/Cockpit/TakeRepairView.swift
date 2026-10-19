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
    @State private var reviewSHA256: String?
    @State private var loadedIdentity: LoadIdentity?

    private struct LoadIdentity: Equatable {
        let home: URL?
        let generation: UUID?
        let revision: Int
        let takeID: String
    }

    private var loadIdentity: LoadIdentity {
        .init(home: editor.workingRoot, generation: editor.openWorkingCopyGeneration,
              revision: editor.engineStateRevision, takeID: snapshot.take.id)
    }

    private var saved: Bool {
        reviewSHA256 != nil && persisted?.reviewSHA256 == reviewSHA256
            && loadedIdentity == loadIdentity && loadedIdentity?.generation != nil
            && persisted?.takeID == snapshot.take.id && persisted?.operation == operation
            && persisted?.reason == reason && persisted?.policy == policy
    }

    private var hasCurrentReview: Bool {
        reviewSHA256 != nil && loadedIdentity == loadIdentity && loadedIdentity?.generation != nil
    }

    private var canSave: Bool {
        !busy && canWrite && hasCurrentReview && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? policy.validate()) != nil
    }

    private var canContinue: Bool {
        !busy && saved && canWrite && !editor.agentService.isStreaming
            && !editor.agentService.isComposerBlocked && editor.agentService.canStream
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if !hasCurrentReview {
                    Text("Complete and save the take review before recording an iteration decision.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .reviewAcceptanceProbe("take.repair.prerequisite")
                }
                if let assessment {
                    Text(guidance(assessment)).foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("\(assessment.iterations.count) recorded prompt revisions · \(assessment.completedFailedIterations) failed iterations on the current axis")
                }
                Text("A failed iteration needs a complete reviewed batch failing on the same axis. Provider errors and unreviewed outputs do not prove a model limit. No recommendation requires another paid run.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Picker("Next action", selection: $operation) {
                    ForEach(TakeRepairPlan.Operation.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(busy)
                    .reviewAcceptanceProbe("take.repair.operation", state: !busy, text: operation.rawValue)
                TextField("Explain the single change, clean rewrite or stop", text: $reason).disabled(busy)
                    .reviewAcceptanceProbe("take.repair.reason", state: !busy, text: reason)
                DisclosureGroup {
                    TextField("Rolls per prompt revision", value: $policy.rollsPerPrompt, format: .number)
                        .reviewAcceptanceProbe("take.repair.rolls", text: String(policy.rollsPerPrompt))
                    TextField("Failed iterations before clean rewrite", value: $policy.failuresBeforeRewrite, format: .number)
                        .reviewAcceptanceProbe("take.repair.failures", text: String(policy.failuresBeforeRewrite))
                    TextField("Clean failures before model-limit review", value: $policy.cleanFailuresBeforeModelLimit, format: .number)
                        .reviewAcceptanceProbe("take.repair.clean-failures", text: String(policy.cleanFailuresBeforeModelLimit))
                    TextField("Control channels before model-limit review", value: $policy.channelsBeforeModelLimit, format: .number)
                        .reviewAcceptanceProbe("take.repair.channels", text: String(policy.channelsBeforeModelLimit))
                    TextField("Iterations before simplifying the shot", value: $policy.iterationsBeforeSimplification, format: .number)
                        .reviewAcceptanceProbe("take.repair.simplify-after", text: String(policy.iterationsBeforeSimplification))
                } label: {
                    Text("Iteration limits").reviewAcceptanceProbe("take.repair.limits")
                }.disabled(busy)
                Button("Save iteration decision") {
                    let choice = operation, explanation = reason, limits = policy
                    busy = true
                    Task {
                        do {
                            try await TakeRepairPlan.save(snapshot: snapshot, operation: choice, reason: explanation, policy: limits, editor: editor)
                            await load()
                            if saved { message = "Decision saved. The host checks the actual request against it before generation." }
                        } catch { message = error.localizedDescription }
                        busy = false
                    }
                }.buttonStyle(InlineActionButtonStyle(variant: .approval))
                    .disabled(!canSave).reviewAcceptanceProbe("take.repair.save", state: canSave)
                Button("Continue with agent") {
                    guard canContinue else { return }
                    let sent = editor.agentService.send(controlTurn: AgentControlTurn(
                        command: "Read get_render_manifest for \(snapshot.take.phase) and the recorded iteration decision for shot \(snapshot.take.shotID). Apply that decision through the canonical workflow. A stop or rescue decision must not start a generation. Changes to approved shot truth require explicit rewind. Any generation still needs the existing spend approval.",
                        selections: [.init(label: "Shot", values: [snapshot.take.shotID]), .init(label: "Decision", values: [operation.label])],
                        typedText: reason))
                    message = sent ? nil : "The agent could not continue. Check its current status and try again."
                }.buttonStyle(InlineActionButtonStyle()).disabled(!canContinue)
                    .reviewAcceptanceProbe("take.repair.continue", state: canContinue, text: reviewSHA256 ?? "")
                if loadedIdentity == loadIdentity, let persisted, persisted.reviewSHA256 != reviewSHA256 {
                    Text("Take review changed. Save the decision again before continuing.").foregroundStyle(AppTheme.Text.secondaryColor)
                }
                if let message { Text(message).foregroundStyle(AppTheme.Text.secondaryColor).reviewAcceptanceProbe("take.repair.message", text: message) }
            }.padding(.vertical, AppTheme.Spacing.sm)
        } label: {
            Text("Iteration decision").reviewAcceptanceProbe("take.repair.open")
        }
        .task(id: loadIdentity) { await load() }
    }

    private func load() async {
        let home = snapshot.home, take = snapshot.take, input = snapshot.take.generationInput
        let identity = loadIdentity
        reviewSHA256 = nil; loadedIdentity = nil; assessment = nil; persisted = nil; message = nil
        do {
            let value = try await Task.detached(priority: .utility) {
                guard let root = DataRootResolver.dataRoot(of: home), let shotID = input.promptShotId else { throw ToolError("The iteration project is unavailable.") }
                let current = try TakeRepairPlan.current(shotID: shotID, dataRoot: root)
                let review = try TakeReview.load(take: take, dataRoot: root)
                let bytes = review == nil ? nil : try Data(contentsOf: ProjectLocalFile.resolve(TakeReview.path(takeID: take.id), dataRoot: root))
                if let bytes, try JSONDecoder().decode(TakeReview.self, from: bytes) != review {
                    throw ToolError("The take review changed while loading the iteration decision.")
                }
                return (try TakeRepairPlan.assessment(input: input, dataRoot: root, policy: current?.plan.policy ?? TakeIterationPolicyV1()),
                    current?.plan, bytes.map { FileDigest.sha256(of: $0) })
            }.value
            guard !Task.isCancelled, editor.workingRoot == home, loadIdentity == identity else { return }
            assessment = value.0
            reviewSHA256 = value.2; loadedIdentity = identity
            persisted = value.1
            if reason.isEmpty, let plan = value.1, plan.takeID == snapshot.take.id {
                operation = plan.operation; reason = plan.reason; policy = plan.policy
            }
        } catch {
            guard !Task.isCancelled, editor.workingRoot == home, loadIdentity == identity else { return }
            persisted = nil; message = error.localizedDescription
        }
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
