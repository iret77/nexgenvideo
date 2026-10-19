import NexGenEngine
import SwiftUI

struct ProductionFrameCandidatesView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshots: [PipelineProductionFrameCandidates.Snapshot] = []
    @State private var picked: [String: Set<String>] = [:]
    @State private var iteration: IterationTarget?
    @State private var busy = false
    @State private var canWrite = false
    @State private var loadedHome: URL?
    @State private var actionFailure: String?
    @State private var loadFailure: String?
    @State private var observedHome: URL?
    @State private var observedGeneration: UUID?
    @State private var loadToken = UUID()
    @State private var loading = false
    @State private var busyHome: URL?
    @State private var busyGeneration: UUID?

    private struct IterationTarget: Identifiable {
        let snapshot: PipelineProductionFrameCandidates.Snapshot
        let kind: PipelineProductionFrameCandidates.IterationKind
        let ids: [String]
        var id: String { snapshot.shotID + "/" + snapshot.role }
    }

    private var writable: Bool {
        guard canWrite, !busy, !loading, loadedHome == editor.workingRoot, !editor.agentService.isStreaming,
              !editor.agentService.isComposerBlocked, let home = editor.workingRoot,
              let root = DataRootResolver.dataRoot(of: home) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack {
                Text("Frame candidates").fontWeight(AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Reload") { actionFailure = nil; loadFailure = nil; Task { await load() } }.disabled(busy || loading)
                    .reviewAcceptanceProbe("frames.candidates.reload", state: !busy && !loading)
            }
            if loading {
                ProgressView("Reading frame candidates…").controlSize(.small)
            } else if busy {
                ProgressView(busyHome == editor.workingRoot && busyGeneration == editor.openWorkingCopyGeneration
                    ? "Applying frame selection…" : "Finishing the previous frame selection…")
                    .controlSize(.small)
            }
            if let actionFailure { Text(actionFailure).foregroundStyle(AppTheme.Status.errorColor) }
            if let loadFailure, loadFailure != actionFailure { Text(loadFailure).foregroundStyle(AppTheme.Status.errorColor) }
            if let loadedHome, loadedHome == editor.workingRoot {
                if snapshots.isEmpty { Text("This production plan needs no generated boundary frames.") }
                ForEach(Array(snapshots.enumerated()), id: \.offset) { _, snapshot in section(snapshot) }
            }
        }
        .padding(AppTheme.Spacing.md)
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("frames.candidates.workspace")
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.openWorkingCopyGeneration?.uuidString ?? ""):\(editor.engineStateRevision)") { await load() }
        .sheet(item: $iteration) { target in
            ProductionFrameIterationSheet(snapshot: target.snapshot, kind: target.kind, candidateIDs: target.ids)
                .environment(editor)
        }
    }

    private func section(_ snapshot: PipelineProductionFrameCandidates.Snapshot) -> some View {
        let key = snapshot.shotID + "/" + snapshot.role
        let selection = picked[key] ?? []
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(snapshot.role.capitalized) frame · Shot \(shotNumber(snapshot.shotID))")
                    .fontWeight(AppTheme.FontWeight.semibold)
                    .reviewAcceptanceProbe("frames.role.\(snapshot.shotID).\(snapshot.role)", text: String(snapshot.items.count))
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Remix…") {
                    iteration = .init(snapshot: snapshot, kind: .remix, ids: selection.sorted())
                }.disabled(!writable || selection.count < 2)
                    .reviewAcceptanceProbe("frames.remix.\(snapshot.shotID).\(snapshot.role)", state: writable && selection.count >= 2)
            }
            if snapshot.items.isEmpty { Text("Generate this boundary frame to review candidates.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.ComponentSize.reviewRedoPopoverWidth), spacing: AppTheme.Spacing.md)], spacing: AppTheme.Spacing.md) {
                ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { number, item in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ProductionInputPreview(reference: .init(id: item.id, role: "host.frame-candidate-image",
                            path: item.candidate.receipt.frame.path, sha256: item.candidate.usage.outputSHA256),
                            dataRoot: DataRootResolver.dataRoot(of: snapshot.home) ?? snapshot.home,
                            title: "Candidate \(number + 1)")
                        if item.id == snapshot.index.active {
                            Text("Current frame").foregroundStyle(AppTheme.Status.successColor)
                                .reviewAcceptanceProbe("frames.current.\(snapshot.shotID).\(snapshot.role)", text: item.id)
                        }
                        if let unavailable = item.unavailable { Text(unavailable).foregroundStyle(AppTheme.Text.secondaryColor) }
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Button("Use") { select(item.id, snapshot: snapshot) }
                                .buttonStyle(InlineActionButtonStyle(variant: .approval))
                                .disabled(!writable || item.unavailable != nil)
                                .reviewAcceptanceProbe("frames.use.\(item.id)", state: writable && item.unavailable == nil)
                            Button("Redo…") { iteration = .init(snapshot: snapshot, kind: .redo, ids: [item.id]) }
                                .buttonStyle(InlineActionButtonStyle())
                                .disabled(!writable || item.unavailable != nil)
                                .reviewAcceptanceProbe("frames.redo.\(item.id)", state: writable && item.unavailable == nil)
                        }
                        Toggle("Use as remix source", isOn: Binding(get: { selection.contains(item.id) }, set: { value in
                            var values = picked[key] ?? []
                            if value { values.insert(item.id) } else { values.remove(item.id) }
                            picked[key] = values
                        })).disabled(!writable || item.unavailable != nil)
                            .reviewAcceptanceProbe("frames.pick.\(item.id)", state: writable && item.unavailable == nil,
                                text: selection.contains(item.id) ? "selected" : "unselected")
                    }
                    .padding(AppTheme.Spacing.md)
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                }
            }
        }
    }

    private func shotNumber(_ id: String) -> Int {
        guard let index = snapshots.firstIndex(where: { $0.shotID == id }) else { return 0 }
        return Set(snapshots.prefix(index).map(\.shotID)).count + 1
    }

    private func select(_ id: String, snapshot: PipelineProductionFrameCandidates.Snapshot) {
        guard writable else { return }
        let home = editor.workingRoot
        let generation = editor.openWorkingCopyGeneration
        busyHome = home; busyGeneration = generation
        busy = true; actionFailure = nil; loadFailure = nil
        Task {
            defer { busy = false; busyHome = nil; busyGeneration = nil }
            do { try await PipelineProductionFrameCandidates.select(candidateID: id, snapshot: snapshot, editor: editor) }
            catch {
                guard editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else { return }
                actionFailure = error.localizedDescription
            }
            guard editor.workingRoot == home, editor.openWorkingCopyGeneration == generation else { return }
            await load()
        }
    }

    private func load() async {
        let token = UUID(); loadToken = token
        let home = editor.workingRoot
        let generation = editor.openWorkingCopyGeneration
        if observedHome != home || observedGeneration != generation {
            observedHome = home; observedGeneration = generation
            snapshots = []; picked = [:]; iteration = nil; loadedHome = nil; canWrite = false
            actionFailure = nil; loadFailure = nil
        }
        loading = true
        defer { if loadToken == token { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else {
            snapshots = []; loadedHome = nil; canWrite = false
            loadFailure = home == nil
                ? "Open a production project to review its frame candidates."
                : "The production data couldn't be read. Reopen the project, then reload frame candidates."
            return
        }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        do {
            let values = try await PipelineProductionFrameCandidates.capture(home: home)
            let allowed = await Task.detached { (try? PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "frames")) != nil }.value
            guard !Task.isCancelled, home == editor.workingRoot,
                  editor.openWorkingCopyGeneration == generation, loadToken == token else { return }
            snapshots = values; loadedHome = home; canWrite = allowed
            loadFailure = nil
            for snapshot in values {
                let key = snapshot.shotID + "/" + snapshot.role
                picked[key] = (picked[key] ?? []).intersection(Set(snapshot.items.filter { $0.unavailable == nil }.map(\.id)))
            }
        } catch {
            guard !Task.isCancelled, home == editor.workingRoot,
                  editor.openWorkingCopyGeneration == generation, loadToken == token else { return }
            canWrite = false; snapshots = []; loadedHome = nil; loadFailure = error.localizedDescription
        }
    }
}

private struct ProductionFrameIterationSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    let snapshot: PipelineProductionFrameCandidates.Snapshot
    let kind: PipelineProductionFrameCandidates.IterationKind
    let candidateIDs: [String]
    @State private var aspects: [String: PipelineProductionFrameCandidates.Aspect] = [:]
    @State private var reason = PipelineProductionFrameCandidates.Aspect.continuity
    @State private var note = ""
    @State private var busy = false
    @State private var canWrite = false
    @State private var failure: String?

    private var ready: Bool {
        guard canWrite, !busy, snapshot.home == editor.workingRoot, !editor.agentService.isStreaming,
              !editor.agentService.isComposerBlocked, let root = DataRootResolver.dataRoot(of: snapshot.home),
              candidateIDs.allSatisfy({ aspects[$0] != nil }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(kind == .redo ? "Regenerate frame" : "Remix frame").fontWeight(AppTheme.FontWeight.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("The approved scene and boundary state remain binding. The generated result becomes another candidate; the current frame stays selected.")
                    Picker("Correct", selection: $reason) {
                        ForEach(PipelineProductionFrameCandidates.Aspect.allCases) { Text($0.rawValue).tag($0) }
                    }.reviewAcceptanceProbe("frames.iteration.reason", text: reason.rawValue)
                    ForEach(candidateIDs, id: \.self) { id in
                        if let item = snapshot.items.first(where: { $0.id == id }) {
                            SheetThumbnailView(label: "Selected source", path: item.candidate.receipt.frame.path,
                                projectDir: snapshot.home, tileHeight: AppTheme.Layout.productionAssetPreviewHeight)
                            Picker("Preserve from this source", selection: Binding(get: { aspects[id] }, set: { aspects[id] = $0 })) {
                                Text("Choose an aspect").tag(Optional<PipelineProductionFrameCandidates.Aspect>.none)
                                ForEach(PipelineProductionFrameCandidates.Aspect.allCases) { Text($0.rawValue).tag(Optional($0)) }
                            }.reviewAcceptanceProbe("frames.iteration.aspect.\(id)", text: aspects[id]?.rawValue ?? "")
                        }
                    }
                    TextField("Additional direction", text: $note, axis: .vertical)
                        .reviewAcceptanceProbe("frames.iteration.note", text: note)
                    if let failure { Text(failure).foregroundStyle(AppTheme.Status.errorColor) }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy)
                    .reviewAcceptanceProbe("frames.iteration.cancel", state: !busy)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button(kind == .redo ? "Regenerate" : "Remix") { submit() }
                    .buttonStyle(InlineActionButtonStyle(variant: .approval)).disabled(!ready)
                    .reviewAcceptanceProbe("frames.iteration.submit", state: ready)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("frames.iteration.sheet")
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") {
            canWrite = false
            guard snapshot.home == editor.workingRoot, let root = DataRootResolver.dataRoot(of: snapshot.home) else { return }
            let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
                binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
            let allowed = await Task.detached {
                (try? PipelinePlanningWriteAccess(dataRoot: root, declaration: declaration, phase: "frames")) != nil
            }.value
            guard !Task.isCancelled, snapshot.home == editor.workingRoot else { return }
            canWrite = allowed
        }
    }

    private func submit() {
        guard ready else { return }
        busy = true; failure = nil
        Task {
            do {
                let ref = try await PipelineProductionFrameCandidates.requestIteration(kind: kind,
                    sources: aspects.mapValues { [$0] }, reason: reason, note: note, snapshot: snapshot, editor: editor)
                guard editor.workingRoot == snapshot.home else { throw PipelineProductionFrameCandidates.changed() }
                guard editor.agentService.send(controlTurn: AgentControlTurn(command:
                    "Generate one new \(snapshot.role) frame for shot \(snapshot.shotID) using the host-recorded frame iteration \(ref.path), SHA256 \(ref.sha256). Compile the exact canonical boundary intent with frameRole=\(snapshot.role). Preserve every required canonical and candidate reference in the host frame plan. Prepare its generation package for approval and record the completed image; do not replace the current candidate selection.",
                    selections: [.init(label: "Action", values: [kind.rawValue]), .init(label: "Shot", values: [snapshot.shotID]),
                        .init(label: "Frame role", values: [snapshot.role]), .init(label: "Candidate IDs", values: candidateIDs)], typedText: note)) else {
                    throw GateBlocked("The frame request was saved, but the agent is busy. Close this sheet and continue Frames to run it.")
                }
                editor.agentPanelVisible = true
                dismiss()
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}
