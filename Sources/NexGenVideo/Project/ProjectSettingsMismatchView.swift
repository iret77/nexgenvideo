import SwiftUI

struct ProjectSettingsMismatchView: View {
    @Environment(EditorViewModel.self) var editor
    let mismatch: EditorViewModel.SettingsMismatch

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Text("Clip Settings Mismatch")
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text("The clip you're adding has different settings than the current project.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.xl, verticalSpacing: AppTheme.Spacing.sm) {
                GridRow {
                    Text("")
                    Text("Project")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text("Clip")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                GridRow {
                    Text("FPS")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("\(editor.timeline.fps)")
                        .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("\(mismatch.clipFPS)")
                        .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                        .foregroundStyle(
                            mismatch.clipFPS != editor.timeline.fps
                                ? AppTheme.Status.warningColor
                                : AppTheme.Text.primaryColor
                        )
                }
                GridRow {
                    Text("Resolution")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("\(editor.timeline.width) x \(editor.timeline.height)")
                        .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("\(mismatch.clipWidth) x \(mismatch.clipHeight)")
                        .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                        .foregroundStyle(
                            resolutionMismatch ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor
                        )
                }
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Button("Keep Current") {
                    dismiss()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.regular)

                Button("Change to Match") {
                    editor.applyTimelineSettings(
                        fps: mismatch.clipFPS,
                        width: mismatch.clipWidth,
                        height: mismatch.clipHeight
                    )
                    dismiss()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.regular)
            }
        }
        .padding(AppTheme.Spacing.xl + AppTheme.Spacing.md)
        .frame(width: AppTheme.ComponentSize.projectMismatchWidth)
    }

    private func dismiss() {
        editor.pendingSettingsContinuation?()
        editor.pendingSettingsContinuation = nil
        editor.pendingSettingsMismatch = nil
    }

    private var resolutionMismatch: Bool {
        mismatch.clipWidth != editor.timeline.width || mismatch.clipHeight != editor.timeline.height
    }
}
