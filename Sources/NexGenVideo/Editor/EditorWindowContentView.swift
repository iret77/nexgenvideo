import SwiftUI

/// The document window's SwiftUI content: the stage chrome (title bar + editor), the export and
/// settings-mismatch sheets, and the orthogonal Theater overlay. Reads `theaterActive` reactively —
/// entering theater drops the title bar so the maximized player fills the window.
struct EditorWindowContentView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            if !editor.theaterActive {
                TitleBarView()
            }
            EditorView()
                .focusEffectDisabled()
        }
        .sheet(isPresented: $editor.showExportDialog) {
            ExportView().environment(editor)
        }
        .sheet(item: $editor.pendingSettingsMismatch) { mismatch in
            ProjectSettingsMismatchView(mismatch: mismatch).environment(editor)
        }
        .overlay { TheaterOverlayView() }
        .overlay { TourOverlay() }
    }
}

/// Floating theater chrome, drawn only while theater is active. The player (a maximized preview) sits
/// beneath; this layer stays transparent except for the exit control and the transport cluster, so
/// clicks fall through to the player. Esc also exits (EditorWindowController).
struct TheaterOverlayView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if editor.theaterActive {
            ZStack {
                Color.clear.allowsHitTesting(false)
                exitButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(AppTheme.Spacing.lg)
                transportCluster
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, AppTheme.Spacing.xl)
            }
        }
    }

    private var exitButton: some View {
        Button { editor.theaterActive = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .background(Circle().fill(Color.black.opacity(AppTheme.Opacity.strong)))
        }
        .buttonStyle(.plain)
        .help("Exit theater (Esc)")
    }

    private var transportCluster: some View {
        let fps = editor.timeline.fps
        let duration = max(0, editor.timeline.totalFrames)
        return VStack(spacing: AppTheme.Spacing.sm) {
            scrubBar(duration: duration)
                .frame(width: AppTheme.ComponentSize.theaterTransportWidth, height: AppTheme.Spacing.mdLg)
            HStack(spacing: AppTheme.Spacing.lg) {
                timecode(editor.playheadState.timelineFrame, fps: fps, color: AppTheme.Accent.timecodeColor)
                controlButton("backward.end.fill") { editor.seekToFrame(0) }
                controlButton("backward.frame.fill") { editor.stepBackward() }
                controlButton(editor.isPlaying ? "pause.fill" : "play.fill") { editor.togglePlayback() }
                controlButton("forward.frame.fill") { editor.stepForward() }
                controlButton("forward.end.fill") { editor.seekToFrame(duration) }
                timecode(duration, fps: fps, color: AppTheme.Text.secondaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(Capsule().fill(Color.black.opacity(AppTheme.Opacity.strong)))
    }

    private func timecode(_ frame: Int, fps: Int, color: Color) -> some View {
        Text(formatTimecode(frame: frame, fps: fps))
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(color)
            .monospacedDigit()
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
        }
        .buttonStyle(.plain)
    }

    private func scrubBar(duration: Int) -> some View {
        GeometryReader { geo in
            let progress = duration > 0 ? CGFloat(editor.playheadState.timelineFrame) / CGFloat(duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(AppTheme.Opacity.moderate))
                    .frame(height: AppTheme.Slider.trackHeight)
                Capsule().fill(AppTheme.Accent.primary)
                    .frame(width: max(0, geo.size.width * progress), height: AppTheme.Slider.trackHeight)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { seek($0.location.x, width: geo.size.width, duration: duration, mode: .interactiveScrub) }
                    .onEnded { seek($0.location.x, width: geo.size.width, duration: duration, mode: .exact) }
            )
        }
    }

    private func seek(_ x: CGFloat, width: CGFloat, duration: Int, mode: PreviewSeekMode) {
        guard width > 0 else { return }
        let fraction = max(0, min(1, x / width))
        editor.seekToFrame(Int(fraction * CGFloat(duration)), mode: mode)
    }
}
