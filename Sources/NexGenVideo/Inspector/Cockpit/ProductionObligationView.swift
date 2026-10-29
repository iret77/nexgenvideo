import NexGenEngine
import SwiftUI

struct ProductionObligationView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: PipelineShotPlanningPromotionStore.Snapshot?
    @State private var loadedHome: URL?
    @State private var failure: String?
    @State private var loading = false
    @State private var generation = UUID()

    private var editable: Bool {
        guard !loading, failure == nil, snapshot?.canAssign == true, loadedHome == editor.workingRoot,
              ["bible", "shotlist"].contains(editor.projectState?.nextPhaseName ?? ""),
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                Text("Shot references").interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                Text("Assign the prepared assets to the needs recorded in Shot Planning. Inspect each choice before confirming it.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if loading { ProgressView("Reading production references…") }
                if let failure {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload references") { Task { await load() } }.buttonStyle(InlineActionButtonStyle()).disabled(loading)
                }
                if let snapshot, let home = loadedHome, let root = DataRootResolver.dataRoot(of: home) {
                    if let message = snapshot.assignmentMessage {
                        Text(message).foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Open Bible") { editor.revealCockpit(.bible) }.buttonStyle(InlineActionButtonStyle())
                    }
                    if snapshot.draft.shots.allSatisfy({ $0.obligations.isEmpty }) {
                        Text("No additional references are required by this Shot Planning.").foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    ForEach(Array(snapshot.draft.shots.enumerated()), id: \.element.shotID) { index, shot in
                        ForEach(shot.obligations, id: \.id) { obligation in
                            ProductionObligationRow(shot: shot, obligation: obligation, number: index + 1,
                                snapshot: snapshot, dataRoot: root, editable: editable)
                                .id(home.path + ":" + shot.shotID + ":" + obligation.id)
                        }
                    }
                    if !["bible", "shotlist"].contains(editor.projectState?.nextPhaseName ?? "") {
                        Text("Reopen Bible to change approved reference choices.").foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                } else if !loading, failure == nil {
                    Text("The prepared reference candidates will appear here during Bible. The workflow dock shows the next production action.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }.padding(AppTheme.Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("production.references.workspace")
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .onDisappear { generation = UUID() }
    }

    private func load() async {
        let token = UUID(); generation = token
        let home = editor.workingRoot
        if loadedHome != home { snapshot = nil; loadedHome = home }
        loading = true; failure = nil
        defer { if generation == token { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            let value = try await Task.detached(priority: .userInitiated) {
                let path = root.appendingPathComponent(PipelineShotPlanningPromotionStore.preparationPath)
                if !FileManager.default.fileExists(atPath: path.path),
                   (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil {
                    return PipelineShotPlanningPromotionStore.Snapshot?.none
                }
                return try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root)
            }.value
            guard generation == token, !Task.isCancelled, editor.workingRoot == home else { return }
            if value == nil, snapshot != nil { throw ToolError("The prepared references are no longer available. Restore them before assigning a shot.") }
            snapshot = value
        } catch {
            guard generation == token, !Task.isCancelled, editor.workingRoot == home else { return }
            failure = error.localizedDescription
        }
    }
}

private struct ProductionObligationRow: View {
    let shot: ShotPlanningDraftV1.ShotIntent
    let obligation: ShotPlanningDraftV1.Obligation
    let number: Int
    let snapshot: PipelineShotPlanningPromotionStore.Snapshot
    let dataRoot: URL
    let editable: Bool
    @Environment(EditorViewModel.self) private var editor
    @State private var baseline: PipelineShotPlanningPromotionStore.Snapshot
    @State private var assetID: String
    @State private var skip: Bool
    @State private var sourceStart: String
    @State private var sourceEnd: String
    @State private var saving = false
    @State private var failure: String?
    @State private var inspectingGeometry = false

    init(shot: ShotPlanningDraftV1.ShotIntent, obligation: ShotPlanningDraftV1.Obligation, number: Int,
         snapshot: PipelineShotPlanningPromotionStore.Snapshot, dataRoot: URL, editable: Bool) {
        self.shot = shot; self.obligation = obligation; self.number = number; self.snapshot = snapshot
        self.dataRoot = dataRoot; self.editable = editable
        _baseline = State(initialValue: snapshot)
        let resolution = snapshot.resolutions.first { $0.shotID == shot.shotID && $0.obligationID == obligation.id }
        if case .asset(let id, _) = resolution?.outcome { _assetID = State(initialValue: id) } else { _assetID = State(initialValue: "") }
        if case .skipped = resolution?.outcome { _skip = State(initialValue: true) } else { _skip = State(initialValue: false) }
        let range = snapshot.sourceRanges[shot.shotID]
        _sourceStart = State(initialValue: range.map { ProductionTimeEntry.seconds($0.startTicks, timebase: $0.timebase) } ?? "0")
        _sourceEnd = State(initialValue: Self.endText(range))
    }

    private var candidates: [AssetGraphNodeV1] { baseline.eligibleAssets(shotID: shot.shotID, obligationID: obligation.id) }
    private var selected: AssetGraphNodeV1? { candidates.first { $0.id == assetID } }
    private var stale: Bool { baseline.fingerprint != snapshot.fingerprint }
    private var canEdit: Bool { editable && !saving && !stale }
    private var resolution: ShotPlanningPromotionV1.Resolution? {
        baseline.resolutions.first { $0.shotID == shot.shotID && $0.obligationID == obligation.id }
    }
    private var selectionError: String? {
        do { _ = try selection(); return nil } catch { return error.localizedDescription }
    }
    private var choiceUnchanged: Bool {
        guard let resolution else { return false }
        switch resolution.outcome {
        case .asset(let id, _):
            return !skip && assetID == id && (obligation.kind != .sourceFootage || (try? selection()) == baseline.sourceRanges[shot.shotID])
        case .skipped(let reason): return skip && reason == obligation.allowedSkipReason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Shot \(number) · \(obligation.subject)").fontWeight(AppTheme.FontWeight.semibold)
            Text(obligation.requirement).textSelection(.enabled)
            if let resolution {
                switch resolution.outcome {
                case .asset(let id, _):
                    Label("Assigned: \(baseline.assets.first(where: { $0.id == id }).map(assetLabel) ?? "Asset unavailable")", systemImage: "checkmark.circle")
                case .skipped(let reason):
                    Text("Alternative confirmed: \(reason)").foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if stale {
                Text("The prepared references changed. Review the latest choices before confirming this assignment.")
                    .foregroundStyle(AppTheme.Status.warningColor)
                Button("Reload this reference") { reload() }.buttonStyle(InlineActionButtonStyle()).disabled(saving)
                    .reviewAcceptanceProbe("production.references.reload.\(shot.shotID).\(obligation.id)")
            }
            if let alternative = obligation.allowedSkipReason, !obligation.required {
                Toggle("Use the planned alternative", isOn: $skip).disabled(!canEdit)
                Text(alternative).foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if !skip {
                Picker("Reference", selection: $assetID) {
                    Text("Choose a prepared asset").tag("")
                    ForEach(candidates, id: \.id) { asset in Text(assetLabel(asset)).tag(asset.id) }
                }.disabled(!canEdit)
                    .reviewAcceptanceProbe("production.references.asset.\(shot.shotID).\(obligation.id)", text: assetID)
                if candidates.isEmpty {
                    Text("No prepared asset satisfies this requirement yet.").foregroundStyle(AppTheme.Status.warningColor)
                }
                if let selected {
                    if obligation.kind == .sourceFootage {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.md) { rangeFields }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) { rangeFields }
                        }.disabled(!canEdit)
                    }
                    if (selected.modality == .image || selected.modality == .video)
                        && (obligation.kind != .sourceFootage || selectionError == nil) {
                        ProductionInputPreview(reference: reference(selected), dataRoot: dataRoot, title: assetLabel(selected),
                            sourceRange: previewRange)
                            .reviewAcceptanceProbe("production.references.preview.\(shot.shotID).\(obligation.id)", text: selected.sha256)
                    } else if selected.modality == .geometry {
                        Button("Inspect location geometry…") { inspectingGeometry = true }.buttonStyle(InlineActionButtonStyle())
                    }
                }
            }
            if let selectionError { Text(selectionError).foregroundStyle(AppTheme.Text.secondaryColor) }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            Button(saving ? "Confirming…" : "Confirm reference choice") { Task { await save() } }
                .buttonStyle(.capsule(.prominent, size: .regular)).disabled(!canEdit || selectionError != nil || choiceUnchanged)
                .reviewAcceptanceProbe("production.references.confirm.\(shot.shotID).\(obligation.id)",
                    state: canEdit && selectionError == nil && !choiceUnchanged)
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .onChange(of: snapshot) { _, value in
            let next = value.resolutions.first { $0.shotID == shot.shotID && $0.obligationID == obligation.id }
            if value.preparation == baseline.preparation, value.draft == baseline.draft, value.timing == baseline.timing,
               value.assets == baseline.assets, next == resolution, value.sourceRanges[shot.shotID] == baseline.sourceRanges[shot.shotID] {
                baseline = value
            }
        }
        .onChange(of: assetID) { _, value in
            guard obligation.kind == .sourceFootage, let asset = candidates.first(where: { $0.id == value }) else { return }
            if let range = baseline.sourceRanges[shot.shotID], range.source.path == asset.path, range.source.sha256 == asset.sha256 {
                sourceStart = ProductionTimeEntry.seconds(range.startTicks, timebase: range.timebase); sourceEnd = Self.endText(range)
            } else {
                sourceStart = "0"
                if shot.sourceMode == .imported, let timing = baseline.timing.shots.first(where: { $0.id == shot.shotID }) {
                    sourceEnd = ProductionTimeEntry.seconds(timing.durationTicks, timebase: baseline.timing.timebase)
                } else if let duration = asset.durationSeconds,
                          let end = try? ProductionTimeEntry.containedEndTicks(duration, timebase: baseline.timing.timebase) {
                    sourceEnd = ProductionTimeEntry.seconds(end, timebase: baseline.timing.timebase)
                } else { sourceEnd = "" }
            }
        }
        .sheet(isPresented: $inspectingGeometry) {
            VStack(spacing: AppTheme.Spacing.md) {
                HStack { Spacer(); Button("Done") { inspectingGeometry = false }.keyboardShortcut(.cancelAction) }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                SpatialSceneWorkspaceView()
            }.padding(.vertical, AppTheme.Spacing.lg)
                .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        }
    }

    @ViewBuilder private var rangeFields: some View {
        TextField("Source start (seconds)", text: $sourceStart)
        TextField("Source end (seconds)", text: $sourceEnd)
    }

    private var previewRange: ProductionInputRange? {
        guard let range = try? selection() else { return nil }
        return .init(timebase: range.timebase, startTicks: range.startTicks, durationTicks: range.durationTicks)
    }

    private func selection() throws -> SourceFootageRangeV1? {
        if skip {
            guard !obligation.required, obligation.allowedSkipReason != nil else { throw ToolError("This reference is required.") }
            return nil
        }
        guard let asset = selected else { throw ToolError("Choose a prepared asset.") }
        guard obligation.kind == .sourceFootage else { return nil }
        let timebase = baseline.timing.timebase
        let start = try ProductionTimeEntry.ticks(sourceStart, timebase: timebase)
        let end = try ProductionTimeEntry.ticks(sourceEnd, timebase: timebase)
        guard end > start, let duration = asset.durationSeconds, timebase.seconds(for: end) <= duration else {
            throw ToolError("Choose a start and end inside this source video.")
        }
        if shot.sourceMode == .imported, let timing = baseline.timing.shots.first(where: { $0.id == shot.shotID }), end - start != timing.durationTicks {
            throw ToolError("Choose exactly \(ProductionTimeEntry.seconds(timing.durationTicks, timebase: timebase)) seconds to match this shot.")
        }
        let value = SourceFootageRangeV1(source: reference(asset), timebase: timebase, startTicks: start, durationTicks: end - start)
        try value.validate()
        return value
    }

    private func save() async {
        guard canEdit else { return }
        let home = editor.workingRoot
        saving = true; failure = nil
        defer { saving = false }
        do {
            let range = try selection()
            try await PipelineShotPlanningPromotionStore.recordResolution(shotID: shot.shotID, obligationID: obligation.id,
                assetID: skip ? nil : assetID, skipReason: skip ? obligation.allowedSkipReason : nil, sourceInputRange: range,
                expectedDraftFingerprint: baseline.preparation.draft.sha256, expectedPreparationFingerprint: baseline.fingerprint, editor: editor)
            guard editor.workingRoot == home else { return }
            let root = dataRoot
            let fresh = try await Task.detached(priority: .userInitiated) {
                try PipelineShotPlanningPromotionStore.readSnapshot(dataRoot: root)
            }.value
            guard editor.workingRoot == home, !Task.isCancelled else { return }
            baseline = fresh
        } catch { if editor.workingRoot == home { failure = error.localizedDescription } }
    }

    private func reload() {
        baseline = snapshot; failure = nil
        switch resolution?.outcome {
        case .asset(let id, _): assetID = id; skip = false
        case .skipped: assetID = ""; skip = true
        case nil: assetID = ""; skip = false
        }
        let range = baseline.sourceRanges[shot.shotID]
        sourceStart = range.map { ProductionTimeEntry.seconds($0.startTicks, timebase: $0.timebase) } ?? "0"
        sourceEnd = Self.endText(range)
    }

    private func reference(_ asset: AssetGraphNodeV1) -> CanonicalArtifactReferenceV1 {
        .init(id: asset.id, role: "core.production-asset", path: asset.path, sha256: asset.sha256)
    }

    private func assetLabel(_ asset: AssetGraphNodeV1) -> String {
        [URL(fileURLWithPath: asset.path).lastPathComponent,
         asset.viewID?.replacingOccurrences(of: "_", with: " ")].compactMap { $0 }.joined(separator: " · ")
    }

    private static func endText(_ range: SourceFootageRangeV1?) -> String {
        guard let range else { return "" }
        let end = range.startTicks.addingReportingOverflow(range.durationTicks)
        return end.overflow ? "" : ProductionTimeEntry.seconds(end.partialValue, timebase: range.timebase)
    }
}
