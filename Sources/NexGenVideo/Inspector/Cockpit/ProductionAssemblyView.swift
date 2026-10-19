import NexGenEngine
import SwiftUI

struct ProductionAssemblyView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: PipelineProductionAssemblyController.Snapshot?
    @State private var loading = false
    @State private var reading = false
    @State private var building = false
    @State private var failure: String?
    @State private var loadToken = UUID()
    @State private var replacement: PipelineProductionAssemblyController.Snapshot?

    private var idle: Bool {
        guard !loading, !building, !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    private var writable: Bool { idle && editor.projectState?.nextPhaseName == "render" }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Production cut").fontWeight(AppTheme.FontWeight.semibold)
            if let snapshot {
                Text(snapshot.message).foregroundStyle(AppTheme.Text.secondaryColor)
                    .reviewAcceptanceProbe("production.assembly.state", text: stateLabel(snapshot.state))
                switch snapshot.state {
                case .ready:
                    Button("Build production cut") { build(snapshot, rebuild: false) }
                        .buttonStyle(InlineActionButtonStyle(variant: .approval)).disabled(!writable)
                        .reviewAcceptanceProbe("production.assembly.build", state: writable)
                case .drifted:
                    Text("Rebuilding replaces the production tracks with the currently selected takes and planned timing.")
                        .foregroundStyle(AppTheme.Status.warningColor)
                    WrapLayout(spacing: AppTheme.Spacing.sm) {
                        Button("Keep current cut") { editor.setWorkspaceFocus(.edit) }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!idle)
                            .reviewAcceptanceProbe("production.assembly.keep", state: idle)
                        Button("Rebuild production cut…") { replacement = snapshot }
                            .buttonStyle(InlineActionButtonStyle()).disabled(!writable)
                            .reviewAcceptanceProbe("production.assembly.rebuild", state: writable)
                    }
                    if editor.projectState?.nextPhaseName != "render" {
                        Text("Reopen Render before replacing its production tracks.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                case .assembled:
                    Button("Open cut") { editor.setWorkspaceFocus(.edit) }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!idle)
                        .reviewAcceptanceProbe("production.assembly.open")
                case .blocked:
                    Button("Check selected takes again") { Task { await load() } }
                        .buttonStyle(InlineActionButtonStyle()).disabled(!idle)
                        .reviewAcceptanceProbe("production.assembly.check")
                }
            }
            if loading || building { ProgressView(building ? "Building production cut…" : "Checking production cut…") }
            if let failure {
                Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                Button("Check production cut again") { Task { await load() } }
                    .buttonStyle(InlineActionButtonStyle()).disabled(loading || building)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .task(id: "\(editor.openWorkingCopyKey ?? "")/\(editor.engineStateRevision)/\(editor.timelineRenderRevision)") { await load() }
        .confirmationDialog("Replace the production tracks?", isPresented: Binding(
            get: { replacement != nil }, set: { if !$0 { replacement = nil } }
        ), titleVisibility: .visible) {
            if let replacement {
                Button("Rebuild production cut", role: .destructive) { build(replacement, rebuild: true) }
                    .reviewAcceptanceProbe("production.assembly.confirm-rebuild")
            }
            Button("Cancel", role: .cancel) { replacement = nil }
                .reviewAcceptanceProbe("production.assembly.cancel-rebuild")
        } message: {
            Text("Changes on the production tracks will be replaced by the approved plan and selected takes. Other tracks are preserved.")
        }
    }

    private func load() async {
        guard !building else { return }
        let token = UUID(); loadToken = token
        let key = editor.openWorkingCopyKey
        snapshot = nil; failure = nil; loading = true
        defer { if token == loadToken { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(250))
            while reading {
                try await Task.sleep(for: .milliseconds(50))
                guard token == loadToken else { return }
            }
            guard !Task.isCancelled, token == loadToken else { return }
            reading = true
            defer { reading = false }
            let value = try await PipelineProductionAssemblyController.capture(editor: editor)
            guard !Task.isCancelled, token == loadToken, editor.openWorkingCopyKey == key else { return }
            snapshot = value
        } catch {
            guard !Task.isCancelled, token == loadToken, editor.openWorkingCopyKey == key else { return }
            failure = error.localizedDescription
        }
    }

    private func build(_ expected: PipelineProductionAssemblyController.Snapshot, rebuild: Bool) {
        guard writable else { return }
        building = true; failure = nil; replacement = nil
        let key = editor.openWorkingCopyKey
        Task {
            do {
                try await PipelineProductionAssemblyController.build(expected: expected, rebuild: rebuild, editor: editor)
                building = false
                if editor.openWorkingCopyKey == key { await load() }
            } catch {
                building = false
                if editor.openWorkingCopyKey == key { failure = error.localizedDescription }
            }
        }
    }

    private func stateLabel(_ state: PipelineProductionAssemblyController.State) -> String {
        switch state {
        case .ready: "ready"
        case .assembled: "assembled"
        case .drifted: "drifted"
        case .blocked: "blocked"
        }
    }
}
