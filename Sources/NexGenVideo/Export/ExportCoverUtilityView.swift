import NexGenEngine
import SwiftUI

struct ExportCoverUtilityView: View {
    @Environment(EditorViewModel.self) private var editor

    private var pipelineApproved: Bool {
        guard let state = editor.projectState, !state.phases.isEmpty else { return false }
        return state.phases.allSatisfy { $0.approved && $0.approvalCurrent } && state.phases.contains { $0.phase == "render" }
    }

    var body: some View {
        if editor.activePluginName == "musicvideo" {
            DisclosureGroup("Album cover") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Create square, landscape or portrait artwork. Keep the clean image and optionally create a separate artist/title variant.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Create cover artwork…") {
                        editor.runActivePackStarter()
                        editor.setWorkspaceFocus(.production)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(!pipelineApproved || editor.agentService.isComposerBlocked || editor.agentService.isStreaming)
                    .reviewAcceptanceProbe("export.cover.start")
                    if !pipelineApproved {
                        Text("Approve Render and the earlier production phases to create cover artwork.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    Text("Format, references, model, cost approval and Keep/Revise/Skip decisions continue in Production. Artist and title are requested explicitly.")
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    LibraryAssetPickerButton(purpose: .workspace(.export), acceptedTypes: [.image], title: "Browse project images") {
                        editor.selectMediaAsset($0)
                    }
                }
                .padding(.top, AppTheme.Spacing.sm)
            }
            .reviewAcceptanceProbe("export.cover.open")
        }
    }
}
