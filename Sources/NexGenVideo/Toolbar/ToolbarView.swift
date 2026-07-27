import AppKit
import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("arrow.uturn.backward", help: "Undo (⌘Z)", action: undo)
                toolbarButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: redo)
            }

            AppDivider()
                .frame(height: AppTheme.Spacing.xl)

            // Tool mode
            HStack(spacing: AppTheme.Spacing.md) {
                toolModeButton("cursorarrow", mode: .pointer, help: "Pointer (V)")
                toolModeButton("scissors", mode: .razor, help: "Razor (C)")
            }

            AppDivider()
                .frame(height: AppTheme.Spacing.xl)

            // Split, trim buttons — trim is edit-only chrome (docs/UI_UX_CONCEPT.md §3)
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("square.split.2x1", help: "Split at Playhead (⌘K)", action: editor.splitAtPlayhead)
                bracketButton("[", help: "Trim Start to Playhead (Q)", isDisabled: !editor.allowsTimelineEditChrome, action: editor.trimStartToPlayhead)
                bracketButton("]", help: "Trim End to Playhead (W)", isDisabled: !editor.allowsTimelineEditChrome, action: editor.trimEndToPlayhead)
            }

            AppDivider()
                .frame(height: AppTheme.Spacing.xl)

            // Add content
            HStack(spacing: AppTheme.Spacing.md) {
                textGlyphButton("T", help: "Add Text", action: { _ = editor.addTextClip() })
            }

            Spacer()

            // Zoom
            HStack(spacing: AppTheme.Spacing.xs) {
                zoomButton(
                    "minus.magnifyingglass",
                    help: "Zoom Out",
                    isDisabled: editor.zoomScale <= editor.minZoomScale,
                    action: zoomOut
                )
                // Log-mapped so slider travel is uniform per zoom factor
                let zoomBinding = Binding(
                    get: { log(editor.zoomScale) },
                    set: { editor.zoomScale = exp($0) }
                )
                Slider(value: zoomBinding, in: log(editor.minZoomScale)...log(Zoom.max))
                    .controlSize(.mini)
                    .tint(AppTheme.Accent.primary)
                    .frame(width: AppTheme.ComponentSize.toolbarZoomWidth)
                zoomButton(
                    "plus.magnifyingglass",
                    help: "Zoom In",
                    isDisabled: editor.zoomScale >= Zoom.max,
                    action: zoomIn
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbarButton(_ systemName: String, help: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .help(help)
    }

    private func zoomButton(
        _ systemName: String,
        help: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isDisabled ? AppTheme.Text.mutedColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }

    private func zoomOut() {
        setZoomScale(editor.zoomScale / Zoom.toolbarStepFactor)
    }

    private func zoomIn() {
        setZoomScale(editor.zoomScale * Zoom.toolbarStepFactor)
    }

    private func setZoomScale(_ zoomScale: Double) {
        editor.zoomScale = min(Zoom.max, max(editor.minZoomScale, zoomScale))
    }

    private func undo() {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    private func redo() {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode, help: String) -> some View {
        let isActive = editor.toolMode == mode
        // Razor (and any future edit-only tool) is inert in Produce — the timeline shows status there, no trim tooling.
        let disabled = mode != .pointer && !editor.allowsTimelineEditChrome
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight(isActive: isActive)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .help(help)
    }

    private func textGlyphButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: AppTheme.FontSize.xlSm, weight: AppTheme.FontWeight.bold, design: .serif))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func bracketButton(_ bracket: String, help: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(bracket)
                .font(.system(size: AppTheme.FontSize.lgXl, weight: AppTheme.FontWeight.semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .help(help)
    }

}
