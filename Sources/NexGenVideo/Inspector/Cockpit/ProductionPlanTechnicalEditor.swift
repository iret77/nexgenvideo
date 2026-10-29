import NexGenEngine
import SwiftUI

struct ProductionPlanTechnicalEditor: View {
    let shotID: String
    let number: Int
    let home: URL
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: PipelineProductionPlanWriter.CandidateSnapshot?
    @State private var delivery = ShotDeliveryModeV1.providerVideo
    @State private var candidateID: String?
    @State private var modeID: String?
    @State private var conditioning = PipelineProductionPlanWriter.Conditioning.none
    @State private var nativeDuration = ""
    @State private var sourceIn = "0"
    @State private var resolution: String?
    @State private var loading = false
    @State private var applying = false
    @State private var stale = false
    @State private var failure: String?
    @State private var generation = UUID()

    private var candidate: PipelineProductionPlanWriter.Candidate? { snapshot?.candidates.first { $0.id == candidateID } }
    private var intent: ShotPlanningDraftV1.ShotIntent? { snapshot?.draft.shots.first { $0.shotID == shotID } }
    private var editable: Bool {
        guard editor.workingRoot == home, editor.projectState?.nextPhaseName == "shotlist",
              !loading, !applying, !stale, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }
    private var conditioningChoices: [PipelineProductionPlanWriter.Conditioning] {
        if intent?.chainKind == .frameContinuation { return [.predecessorFrame] }
        if intent?.chainKind == .nativeExtension { return [.nativeExtension] }
        if intent?.sourceMode == .aiEnhanced { return [.sourceVideo] }
        return [.none, .start, .startEnd]
    }
    private var change: PipelineProductionPlanWriter.TechnicalChange? {
        guard let snapshot else { return nil }
        if delivery == .timelineAnimatedStill {
            return .init(delivery: delivery, candidateID: nil, modeID: nil, conditioning: .none,
                nativeDurationTicks: nil, sourceInTicks: 0, resolution: resolution)
        }
        guard let duration = try? ProductionTimeEntry.ticks(nativeDuration, timebase: snapshot.projection.timebase),
              let start = try? ProductionTimeEntry.ticks(sourceIn, timebase: snapshot.projection.timebase) else { return nil }
        return .init(delivery: delivery, candidateID: candidateID, modeID: modeID, conditioning: conditioning,
            nativeDurationTicks: duration, sourceInTicks: start, resolution: resolution)
    }
    private var evaluation: PipelineProductionPlanWriter.Evaluation? {
        guard let snapshot, let change else { return nil }
        return PipelineProductionPlanWriter.evaluateNative(change, snapshot: snapshot)
    }
    private var canApply: Bool { editable && evaluation?.canApply == true && change != snapshot?.currentChange }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Production settings · Shot \(number)")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if loading { ProgressView("Loading current models and references…") }
                    if let snapshot {
                        Text(snapshot.shot.primaryAction).textSelection(.enabled)
                        if let timing = snapshot.projection.timing(for: shotID) {
                            Text("Planned duration: \(ProductionTimeEntry.seconds(timing.durationTicks, timebase: snapshot.projection.timebase)) s")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        Picker("Output", selection: $delivery) {
                            Text("Generated video").tag(ShotDeliveryModeV1.providerVideo)
                            if intent?.sourceMode == .generated && intent?.chainKind == ShotPlanningDraftV1.ShotIntent.ChainKind.none {
                                Text("Animated still").tag(ShotDeliveryModeV1.timelineAnimatedStill)
                            }
                        }.disabled(!editable).reviewAcceptanceProbe("production.technical.delivery", text: delivery.rawValue)
                        if delivery == .providerVideo { videoFields(snapshot) }
                        else {
                            Text("Frames supplies the approved image. The timeline animates it across the complete planned shot.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        if let evaluation {
                            ForEach(evaluation.deficits, id: \.self) { reason in
                                Label(reason, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(AppTheme.Status.warningColor).textSelection(.enabled)
                            }
                        } else {
                            Text("Enter valid times in seconds.").foregroundStyle(AppTheme.Status.warningColor)
                        }
                    }
                    if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor).textSelection(.enabled) }
                    if stale { Text("The Shot List, references or model capabilities changed. Reload before applying this edit.").foregroundStyle(AppTheme.Status.warningColor) }
                    if stale || failure != nil {
                        Button(snapshot == nil ? "Reload settings" : "Discard edits and reload") { Task { await load() } }
                            .buttonStyle(InlineActionButtonStyle()).disabled(loading || applying)
                    }
                }.textFieldStyle(.roundedBorder)
            }.disabled(loading || applying)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Spacer(minLength: AppTheme.Spacing.sm)
                if applying { ProgressView().controlSize(.small) }
                Button("Apply production settings") { apply() }
                    .buttonStyle(.capsule(.prominent, size: .regular)).keyboardShortcut(.defaultAction)
                    .disabled(!canApply).reviewAcceptanceProbe("production.technical.apply", state: canApply)
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui).padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .task { await load() }
        .onChange(of: editor.engineStateRevision) { _, _ in if !applying { Task { await checkCurrent() } } }
        .onChange(of: editor.workingRoot) { _, value in if value != home { stale = true } }
        .onChange(of: candidateID) { _, _ in
            if let candidate, !candidate.modeIDs.contains(modeID ?? "") { modeID = candidate.modeIDs.first }
        }
    }

    private func videoFields(_ snapshot: PipelineProductionPlanWriter.CandidateSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Picker("Model", selection: $candidateID) {
                Text(snapshot.currentChange.candidateID == nil ? "Choose an available model" : "Choose model").tag(String?.none)
                ForEach(snapshot.candidates) { candidate in
                    Text("\(candidate.displayName) · \(candidate.offering.providerID)").tag(Optional(candidate.id))
                }
            }.reviewAcceptanceProbe("production.technical.model", text: candidateID)
            if snapshot.candidates.isEmpty {
                Text("No connected provider currently offers a verified video model. Connect a provider and refresh its models in Settings.")
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
            if let candidate {
                Picker("Provider mode", selection: $modeID) {
                    Text("Choose mode").tag(String?.none)
                    ForEach(candidate.modeIDs, id: \.self) {
                        Text($0.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized).tag(Optional($0))
                    }
                }
                Picker("Resolution", selection: $resolution) {
                    Text("Provider default").tag(String?.none)
                    if let resolution, !candidate.resolutions.contains(resolution) {
                        Text("Unavailable: \(resolution)").tag(Optional(resolution)).disabled(true)
                    }
                    ForEach(candidate.resolutions, id: \.self) { Text($0).tag(Optional($0)) }
                }
                if !candidate.durationValues.isEmpty {
                    Text("Available durations: \(candidate.durationValues.map { "\($0) s" }.joined(separator: ", "))")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else if let minimum = candidate.durationMinimum, let maximum = candidate.durationMaximum {
                    Text("Available duration: \(minimum)–\(maximum) s").foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            Picker("Conditioning", selection: $conditioning) {
                ForEach(conditioningChoices, id: \.self) { Text(conditioningLabel($0)).tag($0) }
            }
            TextField("Generated duration (s)", text: $nativeDuration)
                .reviewAcceptanceProbe("production.technical.duration", text: nativeDuration)
            TextField("Use generated video from (s)", text: $sourceIn)
                .reviewAcceptanceProbe("production.technical.trim", text: sourceIn)
            if let change, let timing = snapshot.projection.timing(for: shotID) {
                let end = change.sourceInTicks.addingReportingOverflow(timing.durationTicks)
                if !end.overflow {
                    Text("Selected output: \(sourceIn)–\(ProductionTimeEntry.seconds(end.partialValue, timebase: snapshot.projection.timebase)) s")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if intent?.sourceMode == .aiEnhanced {
                Text("The source video's selected input range stays bound to Shot Planning. These times select the new provider output.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }.disabled(!editable)
    }

    private func conditioningLabel(_ value: PipelineProductionPlanWriter.Conditioning) -> String {
        switch value {
        case .none: "Text and references"
        case .start: "Start frame"
        case .startEnd: "Start and end frames"
        case .predecessorFrame: "Previous shot's last frame"
        case .nativeExtension: "Extend previous shot's video"
        case .sourceVideo: "Selected source video"
        }
    }

    private func load() async {
        let token = UUID(); generation = token
        loading = true; failure = nil
        defer { if generation == token { loading = false } }
        guard editor.workingRoot == home else { stale = true; return }
        do {
            let value = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shotID, editor: editor)
            guard !Task.isCancelled, generation == token, editor.workingRoot == home else { return }
            snapshot = value; stale = false
            let current = value.currentChange
            delivery = current.delivery; candidateID = current.candidateID; modeID = current.modeID
            conditioning = current.conditioning; resolution = current.resolution
            nativeDuration = current.nativeDurationTicks.map {
                ProductionTimeEntry.seconds($0, timebase: value.projection.timebase)
            } ?? ""
            sourceIn = ProductionTimeEntry.seconds(current.sourceInTicks, timebase: value.projection.timebase)
        } catch {
            guard generation == token, editor.workingRoot == home else { return }
            failure = error.localizedDescription; stale = true
        }
    }

    private func checkCurrent() async {
        guard !loading, !applying, !stale, let snapshot, editor.workingRoot == home else { return }
        let token = generation
        do {
            let current = try await PipelineProductionPlanWriter.readCandidateSnapshot(shotID: shotID, editor: editor)
            guard generation == token, !applying else { return }
            if current.fingerprint != snapshot.fingerprint { stale = true }
        } catch { if generation == token && !applying { stale = true } }
    }

    private func apply() {
        guard canApply, let snapshot, let change else { return }
        applying = true; failure = nil
        Task {
            defer { applying = false }
            do {
                _ = try await PipelineProductionPlanWriter.applyNative(change, snapshot: snapshot, editor: editor)
                if editor.workingRoot == home { dismiss() }
            } catch {
                guard editor.workingRoot == home else { return }
                failure = error.localizedDescription
                applying = false
                await checkCurrent()
            }
        }
    }
}
