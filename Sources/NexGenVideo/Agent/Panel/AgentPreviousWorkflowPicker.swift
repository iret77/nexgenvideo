import AppKit
import SwiftUI

struct AgentPreviousWorkflowPicker: View {
    let scope: PreviousWorkflowMaterialScope
    let selection: PreviousWorkflowMaterialSelection?
    let isSubmitting: Bool
    let load: @MainActor (PreviousWorkflowMaterialScope) async throws -> PreviousWorkflowMaterialCatalog
    let isCurrent: @MainActor (PreviousWorkflowMaterialScope) -> Bool
    let onSelect: (PreviousWorkflowMaterial) -> Void
    let onRemove: () -> Void

    private struct Request: Hashable {
        let scope: PreviousWorkflowMaterialScope
        let expanded: Bool
        let retry: UUID
    }

    private enum Phase {
        case idle
        case loading
        case ready(PreviousWorkflowMaterialScope, PreviousWorkflowMaterialCatalog)
        case failed(PreviousWorkflowMaterialScope)
    }

    @State private var expanded = false
    @State private var retry = UUID()
    @State private var requestID: UUID?
    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let selection, selection.scope == scope {
                HStack(spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Selected from previous workflow")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text(selection.displayName)
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                    .interfaceFont(size: AppTheme.Typography.ui)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Button("Remove", action: onRemove)
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(isSubmitting)
                        .reviewAcceptanceProbe("agent.dialog.previous-workflow.clear-selection")
                }
                .reviewAcceptanceProbe("agent.dialog.previous-workflow.selected", text: selection.materialID)
            }
            Button {
                expanded.toggle()
            } label: {
                Label("From previous workflow", systemImage: expanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(isSubmitting)
            .reviewAcceptanceProbe("agent.dialog.previous-workflow.open", text: expanded ? "expanded" : "collapsed")
            if expanded { content }
        }
        .task(id: Request(scope: scope, expanded: expanded, retry: retry)) {
            await loadCatalog()
        }
        .onDisappear { requestID = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready(let loadedScope, let catalog) where loadedScope == scope:
            if catalog.items.isEmpty && catalog.unavailableCount == 0 {
                Text("No previous material for this step.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            if catalog.unavailableCount > 0 {
                Text(scope.role == .script
                     ? "Some previous material can’t be reused. Choose a file below, or paste story text above."
                     : "Some previous material can’t be reused. Choose reference images below.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .reviewAcceptanceProbe("agent.dialog.previous-workflow.unavailable", text: String(catalog.unavailableCount))
            }
            ForEach(catalog.items) { material in
                AgentPreviousWorkflowMaterialRow(material: material, isSubmitting: isSubmitting) {
                    guard isCurrent(scope), !isSubmitting else { return }
                    onSelect(material)
                    expanded = false
                }
            }
        case .failed(let failedScope) where failedScope == scope:
            Text("Previous materials couldn’t be loaded. Retry, or choose a file instead.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.errorColor)
                .fixedSize(horizontal: false, vertical: true)
                .reviewAcceptanceProbe("agent.dialog.previous-workflow.error")
            Button("Retry") { retry = UUID() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isSubmitting)
                .reviewAcceptanceProbe("agent.dialog.previous-workflow.retry")
        default:
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading previous materials…")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .reviewAcceptanceProbe("agent.dialog.previous-workflow.loading")
        }
    }

    @MainActor
    private func loadCatalog() async {
        let id = UUID()
        requestID = id
        guard expanded else { return }
        let expected = scope
        phase = .loading
        do {
            let catalog = try await load(expected)
            guard !Task.isCancelled, requestID == id, scope == expected, isCurrent(expected) else { return }
            phase = .ready(expected, catalog)
        } catch {
            guard !Task.isCancelled, requestID == id, scope == expected, isCurrent(expected) else { return }
            phase = .failed(expected)
        }
    }
}

private struct AgentPreviousWorkflowMaterialRow: View {
    let material: PreviousWorkflowMaterial
    let isSubmitting: Bool
    let onSelect: () -> Void
    private struct PreviewKey: Hashable {
        let id: String
        let fingerprint: String
        let scope: PreviousWorkflowMaterialScope
    }

    private struct DecodedPreview {
        let key: PreviewKey
        let image: NSImage?
    }

    @State private var decodedPreview: DecodedPreview?

    private var previewKey: PreviewKey {
        .init(id: material.id, fingerprint: material.selection.historyFingerprint, scope: material.selection.scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(material.displayName)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(material.subline)
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            switch material.preview {
            case .text(let text):
                Text(text)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(4)
            case .image:
                if let decodedPreview, decodedPreview.key == previewKey, let previewImage = decodedPreview.image {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: AppTheme.ComponentSize.agentAssetPickerHeight)
                } else {
                    Text(decodedPreview?.key == previewKey ? "Preview unavailable" : "Preparing preview…")
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            Button(useLabel, action: onSelect)
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(isSubmitting)
                .reviewAcceptanceProbe("agent.dialog.previous-workflow.choice." + material.id, text: material.id)
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.muted),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .task(id: previewKey) {
            guard !Task.isCancelled else { return }
            if case .image(let data) = material.preview {
                decodedPreview = .init(key: previewKey, image: NSImage(data: data))
            } else { decodedPreview = nil }
        }
    }

    private var useLabel: String {
        switch material.role {
        case .script: "Use this story"
        case .character: "Use this character"
        case .location: "Use this location"
        }
    }
}
