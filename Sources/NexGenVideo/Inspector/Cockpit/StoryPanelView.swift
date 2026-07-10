import SwiftUI

// The front of the pipeline (docs/UI_UX_CONCEPT.md §4 "assisted prose"): the Brief as a structured
// surface and the Treatment as reviewable prose. The AI pre-drafts, the user directs — every action
// composes a structured agent command (the engine phases own the writes), so the artifacts stay the
// single source of truth and nothing lives only in chat.

struct StoryPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    private enum TreatmentState: Equatable {
        case idle, loading
        case loaded(TreatmentData?)
        case failed(CockpitError)
    }

    @State private var treatment: TreatmentState = .idle
    @State private var loadToken = 0
    @State private var briefDraft = ""
    @State private var treatmentDraft = ""

    // Inline-editable structured Brief fields — seeded from `editor.brief` and diffed against it
    // to compose the Apply command (briefEditsCommand), so only changed fields are sent.
    @State private var editedMission = ""
    @State private var editedPlatform = ""
    @State private var editedAspect = ""
    @State private var editedMode = ""

    private static let aspectRatioOptions = [
        "16:9", "9:16", "1:1", "4:5", "5:4", "4:3", "3:4", "21:9", "9:21", "other",
    ]
    // Matches engine/nexgen_engine/brief/schema.py Brief.project_mode (shotlist.Mode).
    private static let projectModeOptions = ["beat", "phrase", "section", "multicam"]

    var body: some View {
        Group {
            if editor.projectState == nil {
                // No pipeline yet → ONE coherent state with the entry point, instead of the
                // brief/treatment fragments each reporting their own flavor of "nothing here".
                CockpitStateView.error(
                    .notInitialized, title: "Story", subject: "the story",
                    activePack: InstalledPack.named(editor.activePluginName),
                    startProduction: { editor.startProduction() },
                    isStarting: editor.productionStarting,
                    retry: { Task { await editor.refreshEngineState() } }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        briefSection
                        treatmentSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.vertical, AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: editor.projectURL) { await loadTreatment() }
        .onChange(of: editor.engineStateRevision) { _, _ in
            Task { await loadTreatment() }
        }
        .onChange(of: editor.brief, initial: true) { _, brief in seedBriefEdits(brief) }
    }

    // MARK: - Brief

    @ViewBuilder
    private var briefSection: some View {
        sectionHeader("Brief")
        if editor.briefUnreadable {
            // A brief EXISTS but can't be read (e.g. legacy schema). Never show the bootstrap
            // prompt here — it would invite drafting over the user's existing brief.
            Label("The brief exists but can't be read (older schema?). Ask the agent to migrate it.",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            promptRow(
                placeholder: "e.g. migrate the brief to the current schema…",
                draft: $briefDraft,
                command: { "The project's brief.yaml fails to load. \($0)" }
            )
        } else if let brief = editor.brief {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                editableTextRow("Mission", text: $editedMission)
                editableTextRow("Platform", text: $editedPlatform)
                if let audience = brief.targetAudience, !audience.isEmpty {
                    briefRow("Audience", audience)
                }
                editableMenuRow("Aspect", selection: $editedAspect, options: Self.aspectRatioOptions)
                briefRow("Length", brief.lengthMode)
                editableMenuRow("Mode", selection: $editedMode, options: Self.projectModeOptions)
                briefRow("Budget", String(format: "€%.0f", brief.budgetEur))
                briefRow("Medium", brief.visualMedium)
                if let notes = brief.visualMediumNotes, !notes.isEmpty {
                    proseBlock("Medium notes", notes)
                }
                if let notes = brief.notes, !notes.isEmpty {
                    proseBlock("Notes", notes)
                }
                if let apply = briefEditsCommand(against: brief) {
                    applyBriefEditsRow(apply)
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
            promptRow(
                placeholder: "Open-ended direction for the brief…",
                draft: $briefDraft,
                command: { "Update the project brief: \($0). Apply it via the brief phase and show the diff." }
            )
        } else {
            Text("No brief yet — this is where the project starts.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            promptRow(
                placeholder: "Describe the video you want…",
                draft: $briefDraft,
                command: { "Draft the project brief from this direction, then walk me through the open choices: \($0)" }
            )
        }
    }

    private func briefRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 70, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func editableTextRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 70, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .labelsHidden()
        }
    }

    private func editableMenuRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 70, alignment: .leading)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { selection.wrappedValue = option }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
                }
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            Spacer(minLength: 0)
        }
    }

    private func applyBriefEditsRow(_ command: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button("Apply changes") {
                editor.agentService.send(text: command, mentions: [])
                editor.agentPanelVisible = true
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .controlSize(.small)
        }
    }

    private func seedBriefEdits(_ brief: BriefData?) {
        guard let brief else {
            editedMission = ""; editedPlatform = ""; editedAspect = ""; editedMode = ""
            return
        }
        editedMission = brief.mission
        editedPlatform = brief.targetPlatform
        editedAspect = brief.aspectRatio
        editedMode = brief.projectMode
    }

    /// One structured command per changed field, folded into a single agent message — the visible,
    /// reviewable diff that replaces free-prose guessing. `nil` when nothing changed.
    private func briefEditsCommand(against brief: BriefData) -> String? {
        var clauses: [String] = []
        if editedMission != brief.mission { clauses.append("mission → \"\(editedMission)\"") }
        if editedPlatform != brief.targetPlatform { clauses.append("target_platform → \"\(editedPlatform)\"") }
        if editedAspect != brief.aspectRatio { clauses.append("aspect_ratio → \"\(editedAspect)\"") }
        if editedMode != brief.projectMode { clauses.append("project_mode → \"\(editedMode)\"") }
        guard !clauses.isEmpty else { return nil }
        return "Update the project brief: \(clauses.joined(separator: "; ")). Apply it via the brief phase and show the diff."
    }

    private func proseBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(label.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(text)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Treatment

    @ViewBuilder
    private var treatmentSection: some View {
        sectionHeader("Treatment")
        switch treatment {
        case .idle, .loading:
            ProgressView().controlSize(.small)
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load the treatment",
                                   subject: "the treatment") { Task { await loadTreatment() } }
        case .loaded(nil):
            Text("No treatment yet.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            promptRow(
                placeholder: "Direction for the treatment (optional)…",
                draft: $treatmentDraft,
                allowEmpty: true,
                command: { note in
                    note.isEmpty
                        ? "Draft the treatment from the brief and analysis, then present it for review."
                        : "Draft the treatment from the brief and analysis. Direction: \(note). Then present it for review."
                }
            )
        case .loaded(.some(let data)):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("v\(data.version)")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium).monospaced())
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Text(data.bodyMarkdown)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppTheme.Spacing.mdLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.md).fill(AppTheme.Background.raisedColor))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
            promptRow(
                placeholder: "Revise the treatment…",
                draft: $treatmentDraft,
                command: { "Revise the treatment (a new version, never overwrite): \($0). Then present it for review." }
            )
        }
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
    }

    /// Assisted prose: the field sends a structured command; the agent (and the engine phase behind
    /// it) writes the artifact; the panel re-reads it — a draft is a suggestion, never a fait accompli.
    private func promptRow(
        placeholder: String,
        draft: Binding<String>,
        allowEmpty: Bool = false,
        command: @escaping (String) -> String
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            TextField(placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
                .onSubmit { submit(draft: draft, allowEmpty: allowEmpty, command: command) }
            Button {
                submit(draft: draft, allowEmpty: allowEmpty, command: command)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: AppTheme.FontSize.lg))
            }
            .buttonStyle(.plain)
            .disabled(!allowEmpty && draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit(draft: Binding<String>, allowEmpty: Bool, command: (String) -> String) {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !text.isEmpty else { return }
        draft.wrappedValue = ""
        editor.agentService.send(text: command(text), mentions: [])
        editor.agentPanelVisible = true
    }

    private func loadTreatment() async {
        guard let dir = editor.workingRoot else {
            treatment = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        // Silent when already populated: a post-agent-turn refresh must not tear down the view
        // (killing field focus) just to show a spinner.
        if case .loaded = treatment {} else { treatment = .loading }
        let result = await CockpitDataService.treatment(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let data): treatment = .loaded(data)
        case .failure(let error): treatment = .failed(error)
        }
    }
}
