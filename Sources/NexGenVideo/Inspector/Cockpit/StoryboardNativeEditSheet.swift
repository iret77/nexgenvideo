import NexGenEngine
import SwiftUI

struct StoryboardNativeEditRequest: Identifiable {
    enum Kind {
        case timing, framing, split, duplicate, steps, addMoment
        case moment(StoryboardTimingV1.Moment)
        case action(StoryboardV2.StoryStep, StoryboardCausalityV2.Binding)
    }
    let id = UUID()
    let kind: Kind
    let shot: StoryboardTimingV1.PlannedShot
    let snapshot: StoryboardBundleSnapshot
    let home: URL
}

struct StoryboardNativeEditSheet: View {
    let request: StoryboardNativeEditRequest
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var first: String
    @State private var second: String
    @State private var third: String
    @State private var additional: Set<String>
    @State private var failure: String?
    @State private var applying = false

    init(request: StoryboardNativeEditRequest) {
        self.request = request
        let shot = request.shot, timebase = request.snapshot.timing.timebase
        var a = "", b = "", c = ""
        switch request.kind {
        case .timing:
            a = ProductionTimeEntry.seconds(shot.startTicks, timebase: timebase)
            b = ProductionTimeEntry.seconds(shot.durationTicks, timebase: timebase)
        case .framing: a = shot.framing.scale; b = shot.framing.cameraView; c = shot.framing.composition
        case .split, .addMoment: break
        case .duplicate: a = ProductionTimeEntry.seconds(shot.startTicks + shot.durationTicks, timebase: timebase)
        case .steps: a = shot.primaryStepID
        case .moment(let moment): a = ProductionTimeEntry.seconds(moment.offsetTicks, timebase: timebase); b = moment.intent
        case .action(let step, let binding): a = step.action; b = binding.reason
        }
        _first = State(initialValue: a); _second = State(initialValue: b); _third = State(initialValue: c)
        _additional = State(initialValue: Set(shot.additionalStepIDs))
    }

    private var title: String {
        switch request.kind {
        case .timing: "Shot timing"
        case .framing: "Sketch framing"
        case .split: "Split shot"
        case .duplicate: "Duplicate shot"
        case .steps: "Story steps"
        case .addMoment: "Add sketch moment"
        case .moment: "Edit sketch moment"
        case .action: "Edit story action"
        }
    }

    private var enabled: Bool {
        guard !applying else { return false }
        guard editor.workingRoot == request.home, editor.projectState?.nextPhaseName == "storyboard",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: request.home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(title).interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    fields
                    if let validation { Text(validation).foregroundStyle(AppTheme.Text.secondaryColor) }
                }.textFieldStyle(.roundedBorder).padding(.vertical, AppTheme.Spacing.sm)
            }
            if !enabled { Text("Reopen Storyboard and finish the current production action before applying changes.").foregroundStyle(AppTheme.Text.secondaryColor) }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .reviewAcceptanceProbe("storyboard.edit.cancel")
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Apply") { apply() }.buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!enabled || validation != nil || !hasChanges)
                    .keyboardShortcut(.defaultAction).reviewAcceptanceProbe("storyboard.edit.apply")
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .reviewAcceptanceProbe("storyboard.edit.sheet", text: title)
    }

    @ViewBuilder private var fields: some View {
        switch request.kind {
        case .timing:
            field("Start in song (s)", text: $first, probe: "first")
            field("Shot duration (s)", text: $second, probe: "second")
            Text("Timing changes preserve neighboring cuts. Gaps and overlaps remain visible for review.").foregroundStyle(AppTheme.Text.secondaryColor)
        case .framing:
            field("Shot scale", text: $first, probe: "first")
            field("Camera view", text: $second, probe: "second")
            field("Composition", text: $third, probe: "third")
            Text("Changing the framing removes this shot's current sketch assignments. Choose or generate matching sketches before approval. Existing image files remain available.")
                .foregroundStyle(AppTheme.Status.warningColor)
        case .split:
            field("Split after (s from shot start)", text: $first, probe: "first")
            Text("Creates two shots at this cut. Both retain their story steps and the relevant sketch moments.").foregroundStyle(AppTheme.Text.secondaryColor)
        case .duplicate:
            field("New shot start in song (s)", text: $first, probe: "first")
            Text("Creates a separate shot with the same duration and sketches. Existing cuts keep their positions.").foregroundStyle(AppTheme.Text.secondaryColor)
        case .steps:
            Picker("Primary story step", selection: $first) {
                ForEach(request.snapshot.storyboard.steps, id: \.id) { step in Text(step.action).tag(step.id) }
            }
            Text("Additional story steps").fontWeight(AppTheme.FontWeight.medium)
            ForEach(request.snapshot.storyboard.steps.filter { $0.id != first }, id: \.id) { step in
                Toggle(step.action, isOn: Binding(get: { additional.contains(step.id) }, set: { selected in
                    if selected { additional.insert(step.id) } else { additional.remove(step.id) }
                }))
            }
            Text("Every story step must remain assigned to at least one shot. Changing the main action creates a new shot identity and requires sketch review.")
                .foregroundStyle(AppTheme.Text.secondaryColor)
        case .addMoment:
            field("Time within shot (s)", text: $first, probe: "first")
            field("Visible action", text: $second, probe: "second")
            Text("The first moment starts at 0. Later moments must have distinct times inside the shot.").foregroundStyle(AppTheme.Text.secondaryColor)
        case .moment(let moment):
            field("Time within shot (s)", text: $first, probe: "first")
            field("Visible action", text: $second, probe: "second")
            if moment.asset != nil {
                Text("Changing the visible action removes this moment's image assignment until a matching sketch is selected.")
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
        case .action(let step, _):
            Text("Current action").fontWeight(AppTheme.FontWeight.medium)
            Text(step.action).foregroundStyle(AppTheme.Text.secondaryColor).textSelection(.enabled)
            field("Revised action", text: $first, probe: "first")
            field("Connection to the Script", text: $second, probe: "second")
            Text("The existing scene and Script-event links are preserved. A changed action requires new sketch review in every affected shot.")
                .foregroundStyle(AppTheme.Status.warningColor)
        }
    }

    private func field(_ title: String, text: Binding<String>, probe: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title).foregroundStyle(AppTheme.Text.secondaryColor)
            TextField(title, text: text, axis: .vertical)
                .reviewAcceptanceProbe("storyboard.edit.\(probe)", text: text.wrappedValue)
        }
    }

    private var validation: String? {
        do {
            _ = try PipelineStoryboardEditor.preview(command(), state: .init(request.snapshot))
            return nil
        } catch { return error.localizedDescription }
    }

    private var hasChanges: Bool {
        guard let plan = try? PipelineStoryboardEditor.preview(command(), state: .init(request.snapshot)) else { return false }
        return plan.state != PipelineStoryboardEditor.State(request.snapshot)
    }

    private func command() throws -> PipelineStoryboardEditor.Command {
        let shotID = request.shot.id, timebase = request.snapshot.timing.timebase
        switch request.kind {
        case .timing: return .setTiming(shotID: shotID, startTicks: try ProductionTimeEntry.ticks(first, timebase: timebase),
            durationTicks: try ProductionTimeEntry.ticks(second, timebase: timebase))
        case .framing: return .setFraming(shotID: shotID, framing: .init(scale: first, composition: third, cameraView: second))
        case .split: return .split(shotID: shotID, offsetTicks: try ProductionTimeEntry.ticks(first, timebase: timebase))
        case .duplicate: return .duplicate(shotID: shotID, startTicks: try ProductionTimeEntry.ticks(first, timebase: timebase))
        case .steps: return .setShotSteps(shotID: shotID, primaryStepID: first,
            additionalStepIDs: request.snapshot.storyboard.steps.filter { $0.id != first && additional.contains($0.id) }.map(\.id))
        case .addMoment: return .insertMoment(shotID: shotID, offsetTicks: try ProductionTimeEntry.ticks(first, timebase: timebase), intent: second)
        case .moment(let moment): return .setMoment(shotID: shotID, momentID: moment.id,
            offsetTicks: try ProductionTimeEntry.ticks(first, timebase: timebase), intent: second)
        case .action(let step, let binding):
            guard !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("Describe the action and its connection to the Script.")
            }
            return .replaceStep(.init(id: step.id, sceneID: step.sceneID,
                eventIDs: step.eventIDs, function: step.function, action: first),
                binding: .init(stepID: binding.stepID, beatIDs: binding.beatIDs, reason: second))
        }
    }

    private func apply() {
        guard enabled else { return }
        applying = true
        Task {
            defer { applying = false }
            do {
                _ = try await PipelineStoryboardEditor.apply(command(), expectedFingerprint: request.snapshot.fingerprint, editor: editor)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
