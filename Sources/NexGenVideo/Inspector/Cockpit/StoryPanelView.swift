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
                    isStarting: editor.productionStarted,
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
                action: "Repair brief",
                command: { "The project's brief.yaml fails to load. \($0)" }
            )
        } else if let brief = editor.brief {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                ForEach(briefGroups(brief)) { group in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        sectionHeader(group.id)
                        ForEach(group.rows) { row in briefRowView(row) }
                    }
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
                action: "Update brief",
                command: { "Update the project brief: \($0). Apply it via the brief phase and show the diff." }
            )
        } else {
            Text("No brief yet — this is where the project starts.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            promptRow(
                placeholder: "Describe the video you want…",
                draft: $briefDraft,
                action: "Draft brief",
                command: { "Draft the project brief from this direction, then walk me through the open choices: \($0)" }
            )
        }
    }

    // MARK: - Brief rows

    /// The brief is what the user approves, so the panel lays out every field the payload carries —
    /// grouped, and skipping what isn't set rather than printing a column of dashes. Rows are built as
    /// data so a group that ends up empty can drop out entirely.
    private enum BriefRow: Identifiable {
        case value(String, String)
        case prose(String, String)
        case editableText(String, Binding<String>)
        case editableMenu(String, Binding<String>, [String])

        var id: String {
            switch self {
            case .value(let label, _), .prose(let label, _),
                 .editableText(let label, _), .editableMenu(let label, _, _):
                return label
            }
        }
    }

    private struct BriefGroup: Identifiable {
        let id: String
        let rows: [BriefRow]
    }

    @ViewBuilder
    private func briefRowView(_ row: BriefRow) -> some View {
        switch row {
        case .value(let label, let value): briefRow(label, value)
        case .prose(let label, let text): proseBlock(label, text)
        case .editableText(let label, let text): editableTextRow(label, text: text)
        case .editableMenu(let label, let selection, let options):
            editableMenuRow(label, selection: selection, options: options)
        }
    }

    private func briefGroups(_ brief: BriefData) -> [BriefGroup] {
        [
            BriefGroup(id: "Creative", rows: creativeRows(brief)),
            BriefGroup(id: "Delivery", rows: deliveryRows(brief)),
            BriefGroup(id: "Production", rows: productionRows(brief)),
            BriefGroup(id: "Budget", rows: budgetRows(brief)),
            BriefGroup(id: "Notes", rows: notesRows(brief)),
        ].filter { !$0.rows.isEmpty }
    }

    private func creativeRows(_ brief: BriefData) -> [BriefRow] {
        var rows: [BriefRow] = []
        Self.add(&rows, "Concept", brief.conceptType)
        Self.add(&rows, "Concept detail", brief.conceptTypeOther)
        Self.add(&rows, "Medium", brief.visualMedium)
        Self.add(&rows, "Medium detail", brief.visualMediumOther)
        Self.addProse(&rows, "Medium notes", brief.visualMediumNotes)
        Self.add(&rows, "Tone", brief.tone.joined(separator: ", "))
        Self.add(&rows, "Tone detail", brief.toneOther)
        Self.add(&rows, "References", brief.styleReferences.joined(separator: ", "))
        Self.add(&rows, "Figures", brief.figures)
        Self.add(&rows, "Figures detail", brief.figuresOther)
        Self.add(&rows, "Figure count", brief.figureCountHint)
        Self.add(&rows, "Lyrics", brief.lyricsIntegration)
        Self.add(&rows, "Lyrics detail", brief.lyricsIntegrationOther)
        return rows
    }

    private func deliveryRows(_ brief: BriefData) -> [BriefRow] {
        var rows: [BriefRow] = [.editableText("Mission", $editedMission)]
        Self.add(&rows, "Mission detail", brief.missionOther)
        rows.append(.editableText("Platform", $editedPlatform))
        Self.add(&rows, "Audience", brief.targetAudience)
        rows.append(.editableMenu("Aspect", $editedAspect, Self.aspectRatioOptions))
        Self.add(&rows, "Aspect detail", brief.aspectRatioOther)
        Self.add(&rows, "Length", brief.lengthMode)
        Self.add(&rows, "Cut handles", brief.cutHandlesMode)
        return rows
    }

    private func productionRows(_ brief: BriefData) -> [BriefRow] {
        var rows: [BriefRow] = [.editableMenu("Mode", $editedMode, Self.projectModeOptions)]
        Self.add(&rows, "Video model", brief.modelPreference)
        Self.add(&rows, "Model detail", brief.modelPreferenceOther)
        Self.add(&rows, "Frame images", brief.frameImageModel)
        Self.add(&rows, "Image detail", brief.frameImageModelOther)
        Self.add(&rows, "Bible images", brief.bibleImageModel)
        Self.add(&rows, "Composite images", brief.compositeImageModel)
        Self.add(&rows, "Stems", brief.stemsProvider)
        Self.add(&rows, "Resolution", brief.finalResolution)
        Self.add(&rows, "Preview pass", brief.previewMode)
        Self.add(&rows, "Chords", brief.enableChordAnalysis.map { $0 ? "On" : "Off" })
        Self.add(&rows, "Text overlays", brief.allowTextOverlays.map { $0 ? "Allowed" : "Not allowed" })
        Self.add(&rows, "Genre cross", brief.allowGenreCrossPatterns.map { $0 ? "Allowed" : "Not allowed" })
        Self.add(&rows, "Director pattern", brief.directorPattern)
        return rows
    }

    private func budgetRows(_ brief: BriefData) -> [BriefRow] {
        var rows: [BriefRow] = []
        // The engine rejects a budget of 0, so 0 here can only mean the payload didn't carry one.
        Self.add(&rows, "Budget", brief.budgetEur > 0 ? Self.euro(brief.budgetEur) : nil)
        // Absent = no hard stop at all, which is the default and worth stating.
        Self.add(&rows, "Hard stop", brief.budgetStopEur.map(Self.euro) ?? "none")
        return rows
    }

    private func notesRows(_ brief: BriefData) -> [BriefRow] {
        var rows: [BriefRow] = []
        Self.addProse(&rows, "Notes", brief.notes)
        return rows
    }

    private static func add(_ rows: inout [BriefRow], _ label: String, _ value: String?) {
        guard let value = trimmed(value) else { return }
        rows.append(.value(label, value))
    }

    private static func addProse(_ rows: inout [BriefRow], _ label: String, _ value: String?) {
        guard let value = trimmed(value) else { return }
        rows.append(.prose(label, value))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func euro(_ amount: Double) -> String {
        String(format: amount == amount.rounded() ? "€%.0f" : "€%.2f", amount)
    }

    private func briefRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.briefLabelWidth, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func editableTextRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.briefLabelWidth, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .labelsHidden()
        }
    }

    private func editableMenuRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.ComponentSize.briefLabelWidth, alignment: .leading)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { selection.wrappedValue = option }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
                }
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
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
                editor.agentService.send(controlTurn: Self.applyBriefTurn(command))
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
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
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
                action: "Draft treatment",
                command: { note in
                    note.isEmpty
                        ? "Draft the treatment from the brief and analysis, then present it for review."
                        : "Draft the treatment from the brief and analysis. Direction: \(note). Then present it for review."
                }
            )
        case .loaded(.some(let data)):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("v\(data.version)")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium).monospaced())
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
                action: "Revise treatment",
                command: { "Revise the treatment (a new version, never overwrite): \($0). Then present it for review." }
            )
        }
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
    }

    /// Assisted prose: the field sends a structured command; the agent (and the engine phase behind
    /// it) writes the artifact; the panel re-reads it — a draft is a suggestion, never a fait accompli.
    private func promptRow(
        placeholder: String,
        draft: Binding<String>,
        allowEmpty: Bool = false,
        action: String,
        command: @escaping (String) -> String
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            TextField(placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
                .onSubmit {
                    submit(
                        draft: draft,
                        allowEmpty: allowEmpty,
                        action: action,
                        command: command
                    )
                }
            Button {
                submit(
                    draft: draft,
                    allowEmpty: allowEmpty,
                    action: action,
                    command: command
                )
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: AppTheme.FontSize.lg))
            }
            .buttonStyle(.plain)
            .disabled(!allowEmpty && draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit(
        draft: Binding<String>,
        allowEmpty: Bool,
        action: String,
        command: (String) -> String
    ) {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !text.isEmpty else { return }
        draft.wrappedValue = ""
        editor.agentService.send(
            controlTurn: Self.proseTurn(
                command: command(text),
                action: action,
                typedText: text
            )
        )
        editor.agentPanelVisible = true
    }

    static func applyBriefTurn(_ command: String) -> AgentControlTurn {
        AgentControlTurn(
            command: command,
            selections: [.init(label: "Brief", values: ["Changes applied"])]
        )
    }

    static func proseTurn(
        command: String,
        action: String,
        typedText: String
    ) -> AgentControlTurn {
        AgentControlTurn(
            command: command,
            selections: typedText.isEmpty ? [.init(label: "Action", values: [action])] : [],
            typedText: typedText
        )
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
