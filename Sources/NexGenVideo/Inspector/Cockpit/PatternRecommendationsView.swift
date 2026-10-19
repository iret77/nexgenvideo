import SwiftUI

struct PatternRecommendationsView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: PatternRecommendationsStore.Snapshot?
    @State private var mode = "balanced"
    @State private var excluded: Set<String> = []
    @State private var expanded = false
    @State private var choosing: String?
    @State private var reason = ""
    @State private var acknowledged = false
    @State private var loading = false
    @State private var writing = false
    @State private var failure: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var token = UUID()
    @State private var writeToken: UUID?

    private var canChange: Bool {
        guard let snapshot, isCurrent(snapshot), let root = DataRootResolver.dataRoot(of: snapshot.home) else { return false }
        return snapshot.canEdit && !loading && !writing && !editor.agentService.isStreaming
            && !editor.agentService.isComposerBlocked && !PatternRecommendationsStore.isBusy(editor: editor)
            && editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Patterns are optional. The index compares compatibility; it does not predict creative success.")
                    .interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Picker("Conflict appetite", selection: $mode) {
                        Text("Conservative").tag("conservative")
                        Text("Balanced").tag("balanced")
                        Text("Experimental").tag("experimental")
                    }
                    .disabled(loading || writing)
                    .reviewAcceptanceProbe("production.pattern.mode", text: mode)
                    Button("Refresh") { reload() }.buttonStyle(InlineActionButtonStyle()).disabled(loading || writing)
                        .reviewAcceptanceProbe("production.pattern.refresh", state: !loading && !writing)
                }
                if loading { ProgressView("Comparing patterns…") }
                if let failure {
                    Text(failure).interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Status.errorColor)
                        .reviewAcceptanceProbe("production.pattern.error", text: failure)
                }
                if let value = snapshot {
                    content(value)
                        .reviewAcceptanceProbe("production.pattern.response", text: PatternRecommendationsStore.responseBindingText(value))
                }
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            Text("Director patterns").interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
        }
        .reviewAcceptanceProbe("production.pattern.open", text: expanded ? "open" : "closed")
        .task(id: editor.openWorkingCopyGeneration) {
            cancelLoad(); snapshot = nil; choosing = nil; reason = ""; acknowledged = false; failure = nil
            writeToken = nil; writing = false
            mode = "balanced"; excluded = []
            if expanded { reload() }
        }
        .onChange(of: expanded) { _, open in if open { reload() } else { cancelLoad() } }
        .onChange(of: mode) { _, _ in if expanded { reload() } }
        .onChange(of: editor.engineStateRevision) { _, _ in if expanded && !writing { reload(preservingChoice: true) } }
        .onDisappear { cancelLoad(); writeToken = nil; writing = false }
    }

    @ViewBuilder
    private func content(_ value: PatternRecommendationsStore.Snapshot) -> some View {
        if let coverage = value.envelope.libraryCoverage {
            Text("Compared \(coverage.scored.count) of \(coverage.total) patterns · \(coverage.unscored.count) unauthored · \(coverage.invalid.count) invalid")
                .interfaceFont(size: AppTheme.Typography.metadata).foregroundStyle(AppTheme.Text.secondaryColor)
                .reviewAcceptanceProbe("production.pattern.library", text: "\(coverage.scored.count)/\(coverage.total)")
        }
        if let affect = value.affect {
            Text(affect).interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
                .reviewAcceptanceProbe("production.pattern.affect", text: affect)
        }
        if let invalid = value.envelope.invalidProfiles, !invalid.isEmpty {
            ForEach(invalid.keys.sorted(), id: \.self) { id in
                Text("Invalid profile \(id): \((invalid[id] ?? []).joined(separator: "; "))")
                    .interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Status.errorColor)
            }
        }
        if !value.envelope.available {
            Text(value.envelope.reason ?? "No pattern recommendation is available. Continue without a pattern.")
                .interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
        }
        if !value.canEdit {
            Text("Reopen Brief to change its pattern. These recommendations are read-only.")
                .interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
        }
        Button("Use no pattern") { select(nil, reason: "Continue without a director pattern.", acknowledged: true) }
            .buttonStyle(.capsule(.secondary)).disabled(!canChange || value.selectedID == nil)
            .reviewAcceptanceProbe("production.pattern.none", state: canChange && value.selectedID != nil)
        if let set = value.envelope.recommendations {
            if set.questionsRequiredBeforeRanking {
                Text("Provisional comparison. Missing inputs are not guessed; no winner is ranked.")
                    .interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("production.pattern.provisional", text: "unranked")
            }
            ForEach(set.missingHighImpactInputs, id: \.axis) { item in
                Button(item.question) {
                    editor.agentService.stageTask(.init(title: "Clarify Pattern Fit", systemImage: "questionmark.circle",
                        prompt: "Clarify this pattern-fit input for the current project: \(item.question). Ask a structured question. Preserve missing values until the user answers; never infer a production fact or claim a measurement."))
                }
                .buttonStyle(InlineActionButtonStyle())
                .disabled(editor.agentService.isStreaming || editor.agentService.isComposerBlocked || loading || writing)
            }
            if set.results.isEmpty {
                Text("No authored patterns can be compared with these inputs. A pattern is not required.")
                    .interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
            }
            ForEach(set.results) { result in card(result, set: set, snapshot: value) }
        }
        if let decision = value.decision {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Saved choice: \(decision.patternID ?? "No pattern")")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                if !decision.reason.isEmpty { Text(decision.reason).interfaceFont(size: AppTheme.Typography.ui) }
                ForEach(Array(decision.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).interfaceFont(size: AppTheme.Typography.ui).foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            .reviewAcceptanceProbe("production.pattern.saved", text: decision.patternID ?? "none")
        }
    }

    private func card(_ result: PatternRecommendationsModel.Recommendation,
                      set: PatternRecommendationsModel.Recommendations,
                      snapshot: PatternRecommendationsStore.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            AppDivider()
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(result.patternName).interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                if result.id == snapshot.selectedID { Label("Selected", systemImage: "checkmark.circle") }
            }
            if let score = result.fitScore {
                Text("Compatibility Index \(Int(score.rounded())) · \(PatternRecommendationsModel.label(result.fitBand))")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .reviewAcceptanceProbe("production.pattern.index." + result.id, text: String(Int(score.rounded())))
                ProgressView(value: score, total: 100).accessibilityLabel("Compatibility Index")
            }
            Text("Confidence \(Int((result.confidence * 100).rounded()))% · Input coverage \(Int((result.inputCoverage * 100).rounded()))%")
                .interfaceFont(size: AppTheme.Typography.metadata).foregroundStyle(AppTheme.Text.secondaryColor)
                .reviewAcceptanceProbe("production.pattern.confidence." + result.id,
                    text: "\(result.confidence)|\(result.inputCoverage)")
            if set.slots.bestOverallPatternId == result.id { Text("Best overall").interfaceFont(size: AppTheme.Typography.ui) }
            if set.slots.productionEfficientPatternId == result.id { Text("Production efficient").interfaceFont(size: AppTheme.Typography.ui) }
            if set.slots.creativeStretchPatternId == result.id { Text("Creative stretch").interfaceFont(size: AppTheme.Typography.ui) }
            Text(result.why).interfaceFont(size: AppTheme.Typography.ui)
            ForEach(Array(result.strengths.enumerated()), id: \.offset) { _, strength in
                Label(strength, systemImage: "checkmark").interfaceFont(size: AppTheme.Typography.ui)
            }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            ForEach(result.adaptations, id: \.adaptationId) { adaptation in
                Text("Adaptation · index cap \(Int(adaptation.fitCap.rounded()))")
                    .interfaceFont(size: AppTheme.Typography.metadata)
                ForEach(Array(adaptation.actions.enumerated()), id: \.offset) { _, action in
                    Text("\(PatternRecommendationsModel.label(action.lever)): \(action.directive)")
                        .interfaceFont(size: AppTheme.Typography.ui)
                }
            }
            DisclosureGroup("Evidence and signature") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if let detail = snapshot.details[result.id] {
                        Text(detail.description).interfaceFont(size: AppTheme.Typography.ui)
                        ForEach(detail.evidence) { field in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                Text("\(field.title) · \(PatternRecommendationsModel.label(field.basis))")
                                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                                Text(field.value).interfaceFont(size: AppTheme.Typography.ui)
                                ForEach(Array(field.sources.enumerated()), id: \.offset) { _, source in sourceLink(source, title: source) }
                                if let video = field.referenceURL { sourceLink(video, title: field.referenceTitle ?? "Reference video") }
                            }
                            .reviewAcceptanceProbe("production.pattern.evidence.\(result.id).\(field.id)", text: field.basis)
                        }
                    }
                    ForEach(result.dimensions, id: \.dimension) { dimension in
                        ForEach(dimension.axes, id: \.axis) { axis in
                            Text("\(PatternRecommendationsModel.label(axis.axis)) · \(PatternRecommendationsModel.label(axis.resolution)): \(axis.explanation)")
                                .interfaceFont(size: AppTheme.Typography.ui)
                        }
                    }
                }
            }
            .reviewAcceptanceProbe("production.pattern.details." + result.id)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Choose pattern") {
                    if result.requiresDeliberateChoice { choosing = result.id; reason = ""; acknowledged = false }
                    else { select(result.id, reason: "Selected from the current Pattern-fit comparison.", acknowledged: true) }
                }
                .buttonStyle(.capsule(.secondary))
                .disabled(!canChange || result.excluded || result.id == snapshot.selectedID)
                .reviewAcceptanceProbe("production.pattern.choose." + result.id,
                    state: canChange && !result.excluded && result.id != snapshot.selectedID)
                Button(excluded.contains(result.id) ? "Include again" : "Exclude") {
                    if excluded.contains(result.id) { excluded.remove(result.id) } else { excluded.insert(result.id) }
                    reload()
                }
                .buttonStyle(InlineActionButtonStyle()).disabled(loading || writing)
                .reviewAcceptanceProbe("production.pattern.exclude." + result.id, text: excluded.contains(result.id) ? "excluded" : "included")
            }
            if choosing == result.id {
                Text("This is a deliberate preference, not a qualified recommendation. The warnings remain with the choice.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                TextField("Reason for choosing this pattern", text: $reason, axis: .vertical)
                    .textFieldStyle(.plain).interfaceFont(size: AppTheme.Typography.ui)
                    .reviewAcceptanceProbe("production.pattern.reason", text: reason)
                Toggle("Keep these warnings with my choice", isOn: $acknowledged)
                    .toggleStyle(.checkbox).interfaceFont(size: AppTheme.Typography.ui)
                    .reviewAcceptanceProbe("production.pattern.acknowledge", text: acknowledged ? "on" : "off")
                Button("Confirm deliberate choice") { select(result.id, reason: reason, acknowledged: acknowledged) }
                    .buttonStyle(.capsule(.prominent))
                    .disabled(!canChange || result.excluded || result.id == snapshot.selectedID || !acknowledged || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .reviewAcceptanceProbe("production.pattern.confirm", state: canChange && !result.excluded && result.id != snapshot.selectedID && acknowledged && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sourceLink(_ value: String, title: String) -> some View {
        if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Link(title, destination: url).interfaceFont(size: AppTheme.Typography.metadata)
        } else { Text(title).interfaceFont(size: AppTheme.Typography.metadata).textSelection(.enabled) }
    }

    private func cancelLoad() {
        loadTask?.cancel(); token = UUID(); loading = false
    }

    private func reload(preservingChoice: Bool = false) {
        loadTask?.cancel(); token = UUID()
        let expected = token, chosenMode = mode, omitted = excluded.sorted()
        let previousFingerprint = snapshot?.fingerprint
        loading = true; failure = nil
        if !preservingChoice { choosing = nil }
        loadTask = Task {
            do {
                let captured = try await PatternRecommendationsStore.capture(editor: editor, mode: chosenMode, excluded: omitted)
                guard !Task.isCancelled, expected == token else { return }
                snapshot = captured; loading = false
                if preservingChoice, choosing != nil, previousFingerprint != captured.fingerprint {
                    acknowledged = false
                    failure = "The comparison changed. Review the warnings before confirming your choice."
                }
            } catch {
                guard !Task.isCancelled, expected == token else { return }
                snapshot = nil; loading = false; failure = error.localizedDescription
            }
        }
    }

    private func select(_ id: String?, reason: String, acknowledged: Bool) {
        guard let snapshot, canChange else { return }
        let expected = UUID()
        writeToken = expected
        writing = true; failure = nil
        Task {
            defer { if writeToken == expected { writing = false; writeToken = nil } }
            do {
                try await PatternRecommendationsStore.select(id, expected: snapshot, reason: reason,
                    acknowledged: acknowledged, editor: editor)
                guard writeToken == expected, isCurrent(snapshot) else { return }
                choosing = nil; reload()
            } catch {
                guard writeToken == expected, isCurrent(snapshot) else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func isCurrent(_ snapshot: PatternRecommendationsStore.Snapshot) -> Bool {
        snapshot.home == editor.workingRoot && snapshot.key == editor.openWorkingCopyKey
            && snapshot.generation == editor.openWorkingCopyGeneration
            && snapshot.declaration == .init(packName: editor.declaredPluginName,
                binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
    }
}
