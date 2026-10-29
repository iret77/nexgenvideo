import CoreMedia
import NexGenEngine
import SwiftUI
import UniformTypeIdentifiers

struct ShotPlanningView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var draft: ShotPlanningDraftV1?
    @State private var storyboard: StoryboardBundleSnapshot?
    @State private var failure: String?
    @State private var loadedHome: URL?
    @State private var loading = false
    @State private var generation = UUID()
    @State private var blockoutRecovery: PipelineBlockoutRemovalSnapshot?
    @State private var confirmingBlockoutRecovery = false
    @State private var recoveringBlockouts = false

    private var editable: Bool {
        guard failure == nil, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              editor.projectState?.nextPhaseName == "shot_planning",
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil && !loading
    }

    private var canRecoverBlockouts: Bool {
        guard blockoutRecovery != nil, !loading, !recoveringBlockouts,
              editor.projectState?.nextPhaseName == "shot_planning", !editor.agentService.isStreaming,
              !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if loading { ProgressView("Loading Shot Planning…") }
                if let failure {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload Shot Planning") { Task { await load() } }.buttonStyle(InlineActionButtonStyle())
                }
                if let recovery = blockoutRecovery {
                    Text("Remove \(recovery.shotIDs.count) blockout assignments to repair their missing or changed files. Original files and confirmed poses remain; review each blockout before attaching it again.")
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .reviewAcceptanceProbe("shot-planning.blockout.recovery", text: recovery.sha256)
                    Button("Remove all blockout assignments…") { confirmingBlockoutRecovery = true }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!canRecoverBlockouts)
                        .reviewAcceptanceProbe("shot-planning.blockout.recover", state: canRecoverBlockouts)
                }
                if let draft, let storyboard {
                    Text("Choose how each planned shot will be made. References are prepared in the References workspace; the Shot List binds the final models and inputs.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if !editable {
                        Text(editor.projectState?.nextPhaseName == "shot_planning"
                            ? "Wait for the current job before editing."
                            : "Reopen Shot Planning to change approved decisions.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    ForEach(Array(draft.shots.enumerated()), id: \.element.shotID) { index, shot in
                        ShotPlanningRow(shot: shot, draft: draft, storyboard: storyboard, number: index + 1, editable: editable)
                            .id("\(loadedHome?.path ?? "")/\(shot.shotID)")
                    }
                } else if !loading && blockoutRecovery == nil {
                    CockpitStateView.empty(icon: "list.bullet.rectangle", title: "No Shot Planning yet",
                        message: "Approve the visual Storyboard to plan sources, camera movement and required references.")
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("shot-planning.workspace")
        .alert("Remove all blockout assignments?", isPresented: $confirmingBlockoutRecovery) {
            Button("Cancel", role: .cancel) {}
            Button("Remove all assignments", role: .destructive) { recoverBlockouts() }
        } message: {
            Text("Only blockout assignments are removed. Confirmed poses, Clay videos and source media remain. Restore the original files before using Undo to restore an assignment.")
        }
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
    }

    private func load() async {
        let request = UUID(); generation = request
        let home = editor.workingRoot
        if loadedHome != home { draft = nil; storyboard = nil; loadedHome = home }
        loading = true; failure = nil; blockoutRecovery = nil
        defer { if generation == request { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(ShotPlanningDraftV1.currentPath).path) else {
                if draft != nil { failure = "Shot Planning is no longer available. Restore it before applying edits." }
                return
            }
            let value = try await Task.detached(priority: .userInitiated) {
                let board = try PlanningWriterIO.storyboard(dataRoot: root)
                return (try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: board), board)
            }.value
            guard generation == request, !Task.isCancelled, editor.workingRoot == home else { return }
            draft = value.0; storyboard = value.1
        } catch {
            guard generation == request, !Task.isCancelled, editor.workingRoot == home else { return }
            failure = error.localizedDescription
            let recovery = try? await Task.detached(priority: .userInitiated) {
                try PipelineBlockoutRemovalSnapshot.load(dataRoot: root)
            }.value
            guard generation == request, !Task.isCancelled, editor.workingRoot == home else { return }
            blockoutRecovery = recovery
        }
    }

    private func recoverBlockouts() {
        guard canRecoverBlockouts, let snapshot = blockoutRecovery else { return }
        let home = editor.workingRoot
        recoveringBlockouts = true
        Task {
            defer { recoveringBlockouts = false }
            do {
                _ = try await PipelineShotPlanningEditor.removeBlockouts(shotIDs: snapshot.shotIDs,
                    in: snapshot.draft, editor: editor, expectedSHA256: snapshot.sha256)
                guard editor.workingRoot == home else { return }
                await load()
            } catch {
                guard editor.workingRoot == home else { return }
                failure = error.localizedDescription
            }
        }
    }
}

private struct ShotPlanningRow: View {
    let shot: ShotPlanningDraftV1.ShotIntent
    let draft: ShotPlanningDraftV1
    let storyboard: StoryboardBundleSnapshot
    let number: Int
    let editable: Bool
    @Environment(EditorViewModel.self) private var editor
    @State private var baseline: ShotPlanningDraftV1
    @State private var sourceMode: SourceMode
    @State private var movement: CameraMovement
    @State private var movementDetail: String
    @State private var blocking: String
    @State private var chain: ShotPlanningDraftV1.ShotIntent.ChainKind
    @State private var predecessor: String
    @State private var sourceStart: String
    @State private var sourceEnd: String
    @State private var failure: String?
    @State private var choosingSource = false
    @State private var importing = false
    @State private var applying = false
    @State private var importHome: URL?
    @State private var editingSpatialState = false
    @State private var renderingSpatialState = false
    @State private var editingBlockout = false

    init(shot: ShotPlanningDraftV1.ShotIntent, draft: ShotPlanningDraftV1, storyboard: StoryboardBundleSnapshot,
         number: Int, editable: Bool) {
        self.shot = shot; self.draft = draft; self.storyboard = storyboard; self.number = number; self.editable = editable
        _baseline = State(initialValue: draft); _sourceMode = State(initialValue: shot.sourceMode)
        _movement = State(initialValue: shot.camera.movement); _movementDetail = State(initialValue: shot.camera.movementDetail ?? "")
        _blocking = State(initialValue: shot.camera.blocking.joined(separator: "\n"))
        _chain = State(initialValue: shot.chainKind); _predecessor = State(initialValue: shot.predecessorShotID ?? "")
        _sourceStart = State(initialValue: Self.startText(shot.sourceInputRange))
        _sourceEnd = State(initialValue: Self.endText(shot.sourceInputRange))
    }

    private var baseShot: ShotPlanningDraftV1.ShotIntent { baseline.shots.first { $0.shotID == shot.shotID } ?? shot }
    private var requiresAdditionalSourceFootage: Bool {
        baseShot.obligations.contains { $0.kind == .sourceFootage && $0.required && $0.id != baseShot.sourceObligationID }
    }
    private var stale: Bool {
        guard draft.header.revision >= baseline.header.revision else { return false }
        return draft.header.inputs != baseline.header.inputs || draft.storyboardRevision != baseline.storyboardRevision
            || draft.shots.first(where: { $0.shotID == shot.shotID }) != baseShot
    }
    private var canEdit: Bool { editable && !importing && !applying && !stale }
    private var rangeFailure: String? {
        do {
            if let value = try selectedSourceRange(), sourceMode == .imported,
               let timing = storyboard.timing.shots.first(where: { $0.id == shot.shotID }) {
                let chosen = CMTime(value: value.durationTicks, timescale: Int32(value.timebase.ticksPerSecond))
                let planned = CMTime(value: timing.durationTicks, timescale: Int32(storyboard.timing.timebase.ticksPerSecond))
                guard CMTimeCompare(chosen, planned) == 0 else {
                    throw ToolError("Choose exactly \(ProductionTimeEntry.seconds(timing.durationTicks, timebase: storyboard.timing.timebase)) seconds to match this shot.")
                }
            }
            return nil
        }
        catch { return error.localizedDescription }
    }

    private func selectedSourceRange() throws -> SourceFootageRangeV1? {
        guard sourceMode != .generated, let source = baseShot.source else { return nil }
        let timebase = baseShot.sourceInputRange?.timebase ?? storyboard.timing.timebase
        let start = try ProductionTimeEntry.ticks(sourceStart, timebase: timebase)
        let end = try ProductionTimeEntry.ticks(sourceEnd, timebase: timebase)
        guard end > start else { throw ToolError("The source end must be after its start.") }
        let value = SourceFootageRangeV1(source: source, timebase: timebase, startTicks: start, durationTicks: end - start)
        try value.validate()
        return value
    }
    private var candidate: ShotPlanningDraftV1.ShotIntent {
        let base = baseShot
        let source = sourceMode == .generated ? nil : base.source
        var obligations = base.obligations
        let missingSourceID = sourceMode != .generated && source == nil
            ? ShotPlanningSourceObligationID.make(preferred: base.sourceObligationID, obligations: obligations) : nil
        if sourceMode == .generated { obligations.removeAll { $0.id == base.sourceObligationID } }
        if let missingSourceID, !obligations.contains(where: { $0.id == missingSourceID }) {
            obligations.append(.init(id: missingSourceID, kind: .sourceFootage, subject: "Shot \(number)",
                requirement: "Assign the original source video before Shot List approval.", required: true))
        }
        return .init(shotID: shot.shotID, sourceMode: sourceMode, source: source, sourceObligationID: missingSourceID,
            camera: .init(framing: base.camera.framing, movement: movement,
                movementDetail: movementDetail.isEmpty ? nil : movementDetail,
                blocking: blocking.split(separator: "\n").map(String.init), sceneReference: base.camera.sceneReference,
                spatialState: preservesSpatialIntent ? base.camera.spatialState : nil,
                spatialCameraID: preservesSpatialIntent ? base.camera.spatialCameraID : nil,
                spatialDerivation: preservesSpatialIntent ? base.camera.spatialDerivation : nil,
                blockingReference: preservesSpatialIntent ? base.camera.blockingReference : nil),
            obligations: obligations, chainKind: sourceMode == .generated ? chain : .none,
            predecessorShotID: sourceMode == .generated && chain != .none && !predecessor.isEmpty ? predecessor : nil,
            narrativeBeat: base.narrativeBeat, sourceInputRange: try? selectedSourceRange())
    }

    private var canApply: Bool {
        canEdit && rangeFailure == nil && candidate != baseShot
            && (sourceMode != .generated || !requiresAdditionalSourceFootage)
            && (movement != .other || !movementDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (sourceMode != .generated || chain == .none || !predecessor.isEmpty)
    }

    private var preservesSpatialIntent: Bool {
        movement == baseShot.camera.movement && (movementDetail.isEmpty ? nil : movementDetail) == baseShot.camera.movementDetail
            && blocking.split(separator: "\n").map(String.init) == baseShot.camera.blocking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Shot \(number)").fontWeight(AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                if let timing = storyboard.timing.shots.first(where: { $0.id == shot.shotID }) {
                    Text(String(format: "%.2f s", storyboard.timing.timebase.seconds(for: timing.durationTicks)))
                        .monospacedDigit().foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if let timing = storyboard.timing.shots.first(where: { $0.id == shot.shotID }) {
                ForEach(storyboard.storyboard.steps.filter { timing.stepIDs.contains($0.id) }, id: \.id) { step in
                    Text(step.action).textSelection(.enabled)
                }
            }
            if stale {
                Text("The plan changed. Reload this shot before applying your edits.").foregroundStyle(AppTheme.Status.warningColor)
                Button("Reload shot") { reload() }.buttonStyle(InlineActionButtonStyle())
                    .reviewAcceptanceProbe("shot-planning.reload.\(shot.shotID)")
            }
            Picker("Image source", selection: $sourceMode) {
                Text("AI generation").tag(SourceMode.generated).disabled(requiresAdditionalSourceFootage)
                Text("Imported footage").tag(SourceMode.imported)
                Text("AI-enhanced footage").tag(SourceMode.aiEnhanced)
            }.disabled(!canEdit)
                .reviewAcceptanceProbe("shot-planning.source-mode.\(shot.shotID)", text: sourceMode.rawValue)
            if requiresAdditionalSourceFootage {
                Text("Use Revise requirements to change the additional source-footage requirements before choosing AI generation.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Button("Revise requirements…") {
                    _ = editor.agentService.stageTask(AgentTask(title: "Revise Shot \(number) requirements", systemImage: "pencil",
                        prompt: "Revise only the source-footage requirements for Shot Planning shot ID \(baseShot.shotID). Preserve the other requirements and shot decisions. Use the canonical Shot Planning writer and respect phase gates.",
                        requiresDirection: true,
                        originContext: "Shot Planning revision \(baseline.header.revision), shot ID \(baseShot.shotID). Later selections do not replace this target."))
                }
                .buttonStyle(InlineActionButtonStyle()).disabled(!canEdit)
            }
            if sourceMode != .generated {
                Text(candidate.source.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Source video required")
                    .foregroundStyle(candidate.source == nil ? AppTheme.Status.warningColor : AppTheme.Text.secondaryColor)
                Button(candidate.source == nil ? "Choose source video…" : "Replace source video…") {
                    importHome = editor.workingRoot; choosingSource = true
                }
                    .buttonStyle(InlineActionButtonStyle()).disabled(!canEdit)
                    .reviewAcceptanceProbe("shot-planning.choose-source.\(shot.shotID)")
                if let source = candidate.source {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) { sourceRangeFields }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) { sourceRangeFields }
                    }.disabled(!canEdit)
                    if let rangeFailure { Text(rangeFailure).foregroundStyle(AppTheme.Status.warningColor) }
                    if let range = candidate.sourceInputRange,
                       let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) {
                        ProductionInputPreview(reference: source, dataRoot: root, title: "Selected source range",
                            sourceRange: .init(timebase: range.timebase, startTicks: range.startTicks, durationTicks: range.durationTicks))
                    }
                    Text(sourceMode == .imported
                        ? "Choose the exact part to use in this shot. Its duration must match the planned shot."
                        : "Choose the exact part to send to the model. The generated result has its own final trim.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                if sourceMode == .aiEnhanced {
                    Text("This source will be processed by the selected generation model. Costs require separate approval.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("\(shot.camera.framing.scale) · \(shot.camera.framing.cameraView) · \(shot.camera.framing.composition)")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Picker("Camera movement", selection: $movement) {
                        ForEach(CameraMovement.allCases, id: \.self) { value in
                            Text(value.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag(value)
                        }
                    }
                    .reviewAcceptanceProbe("shot-planning.movement.\(shot.shotID)", text: movement.rawValue)
                    TextField(movement == .other ? "Describe camera movement" : "Camera movement detail (optional)", text: $movementDetail, axis: .vertical)
                        .reviewAcceptanceProbe("shot-planning.movement-detail.\(shot.shotID)", text: movementDetail)
                    TextField("Blocking — one action per line", text: $blocking, axis: .vertical)
                        .reviewAcceptanceProbe("shot-planning.blocking.\(shot.shotID)", text: blocking)
                    if sourceMode == .generated {
                        Picker("Connection", selection: $chain) {
                            Text("Independent shot").tag(ShotPlanningDraftV1.ShotIntent.ChainKind.none)
                            Text("Continue from the previous final frame").tag(ShotPlanningDraftV1.ShotIntent.ChainKind.frameContinuation)
                            Text("Extend the previous video").tag(ShotPlanningDraftV1.ShotIntent.ChainKind.nativeExtension)
                        }.reviewAcceptanceProbe("shot-planning.connection.\(shot.shotID)", text: chain.rawValue)
                        if chain != .none {
                            Picker("Previous shot", selection: $predecessor) {
                                Text("Choose a shot").tag("")
                                ForEach(Array(baseline.shots.enumerated()).filter { $0.element.shotID != shot.shotID && $0.element.sourceMode == .generated }, id: \.element.shotID) { index, other in
                                    Text("Shot \(index + 1)").tag(other.shotID)
                                }
                            }.reviewAcceptanceProbe("shot-planning.predecessor.\(shot.shotID)", text: predecessor)
                        }
                    }
                }.padding(.top, AppTheme.Spacing.sm).disabled(!canEdit)
            } label: {
                Text("Camera and continuity")
                    .reviewAcceptanceProbe("shot-planning.camera.disclosure.\(shot.shotID)")
            }
            if baseShot.camera.spatialState != nil && !preservesSpatialIntent {
                Text("Changing camera movement or blocking clears the confirmed spatial state. Plan and confirm its keyframes again after applying.")
                    .foregroundStyle(AppTheme.Status.warningColor)
            }
            Button(canEdit ? "Plan spatial state…" : "Inspect spatial state…") { editingSpatialState = true }
                .buttonStyle(InlineActionButtonStyle())
                .disabled(importing || applying || stale || candidate != baseShot || (!canEdit && baseShot.camera.spatialState == nil))
                .reviewAcceptanceProbe("shot-planning.spatial.open.\(shot.shotID)", state: !importing && !applying && !stale && candidate == baseShot && (canEdit || baseShot.camera.spatialState != nil))
                .help(candidate == baseShot ? "Inspect the actual camera and object poses across this shot." : "Apply or discard the shot changes before opening spatial planning.")
            if baseShot.camera.spatialState != nil {
                Button(baseShot.camera.spatialDerivation == nil ? "Render spatial shot…" : "Inspect Clay video…") { renderingSpatialState = true }
                    .buttonStyle(InlineActionButtonStyle()).disabled(importing || applying || stale || candidate != baseShot)
                    .reviewAcceptanceProbe("shot-planning.clay.open.\(shot.shotID)", state: !importing && !applying && !stale && candidate == baseShot)
            }
            Button("Plan/elevation and blockout…") { editingBlockout = true }
                .buttonStyle(InlineActionButtonStyle()).disabled(importing || applying || stale || candidate != baseShot)
                .reviewAcceptanceProbe("shot-planning.blockout.open.\(shot.shotID)", state: !importing && !applying && !stale && candidate == baseShot)
                .sheet(isPresented: $editingBlockout) {
                    if let home = editor.workingRoot {
                        ShotBlockoutView(expected: baseline, shotID: shot.shotID, home: home, onSaved: { baseline = $0 }).environment(editor)
                    }
                }
            if !candidate.obligations.isEmpty {
                DisclosureGroup("Required references (\(candidate.obligations.count))") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(candidate.obligations, id: \.id) { obligation in
                            Text(obligation.subject).fontWeight(AppTheme.FontWeight.medium)
                            Text(obligation.requirement).foregroundStyle(AppTheme.Text.secondaryColor)
                            if let reason = obligation.allowedSkipReason { Text("Optional: \(reason)").foregroundStyle(AppTheme.Text.secondaryColor) }
                        }
                    }.padding(.top, AppTheme.Spacing.sm)
                }
            }
            if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
            if importing { ProgressView("Attaching source video…") }
            if applying { ProgressView("Checking source and applying changes…") }
            Button("Apply shot changes") {
                let value = candidate, expected = baseline, home = editor.workingRoot
                applying = true; failure = nil
                Task {
                    defer { applying = false }
                    do {
                        let written = try await PipelineShotPlanningEditor.replace(value, in: expected, editor: editor)
                        guard editor.workingRoot == home else { return }
                        baseline = written
                    } catch {
                        guard editor.workingRoot == home else { return }
                        failure = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .disabled(!canApply)
            .reviewAcceptanceProbe("shot-planning.apply.\(shot.shotID)", state: canApply)
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .onChange(of: draft) { _, value in
            if value.header.revision > baseline.header.revision, !stale { baseline = value }
        }
        .onChange(of: baseShot.sourceInputRange) { _, value in
            sourceStart = Self.startText(value); sourceEnd = Self.endText(value)
        }
        .sheet(isPresented: $editingSpatialState) {
            if let home = editor.workingRoot {
                SpatialShotStateSheet(home: home, shotID: shot.shotID, number: number,
                    onSaved: { baseline = $0 }).environment(editor)
            }
        }
        .sheet(isPresented: $renderingSpatialState) {
            if let home = editor.workingRoot {
                SpatialShotClaySheet(home: home, shotID: shot.shotID, number: number,
                    onSaved: { baseline = $0 }).environment(editor)
            }
        }
        .fileImporter(isPresented: $choosingSource, allowedContentTypes: [.movie]) { result in
            switch result {
            case .failure(let error): failure = error.localizedDescription
            case .success(let url):
                guard editor.workingRoot == importHome else { failure = "The project changed. Choose the source video again."; return }
                importing = true; failure = nil
                let value = candidate, expected = baseline
                Task {
                    defer { importing = false }
                    do {
                        baseline = try await PipelineShotPlanningEditor.attachSource(from: url, to: value, in: expected, editor: editor)
                    }
                    catch { failure = error.localizedDescription }
                }
            }
        }
    }

    private func reload() {
        baseline = draft; sourceMode = shot.sourceMode; movement = shot.camera.movement
        movementDetail = shot.camera.movementDetail ?? ""; blocking = shot.camera.blocking.joined(separator: "\n")
        chain = shot.chainKind; predecessor = shot.predecessorShotID ?? ""; failure = nil
        sourceStart = Self.startText(shot.sourceInputRange); sourceEnd = Self.endText(shot.sourceInputRange)
    }

    @ViewBuilder private var sourceRangeFields: some View {
        TextField("Source start (seconds)", text: $sourceStart)
            .reviewAcceptanceProbe("shot-planning.source-start.\(shot.shotID)", text: sourceStart)
        TextField("Source end (seconds)", text: $sourceEnd)
            .reviewAcceptanceProbe("shot-planning.source-end.\(shot.shotID)", text: sourceEnd)
    }

    private static func startText(_ range: SourceFootageRangeV1?) -> String {
        range.map { ProductionTimeEntry.seconds($0.startTicks, timebase: $0.timebase) } ?? "0"
    }

    private static func endText(_ range: SourceFootageRangeV1?) -> String {
        guard let range else { return "" }
        let end = range.startTicks.addingReportingOverflow(range.durationTicks)
        return end.overflow ? "" : ProductionTimeEntry.seconds(end.partialValue, timebase: range.timebase)
    }
}
