import AppKit
import SwiftUI

struct PreviewContainerView: View {
    @Environment(EditorViewModel.self) var editor

    private var isTimeline: Bool { editor.activePreviewTab == .timeline }
    private var isImage: Bool { editor.activePreviewTab.clipType == .image }
    private var isDocument: Bool { editor.activePreviewTab.clipType == .document }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            // Theater hides the panel's own chrome — the floating theater transport takes over.
            if !editor.theaterActive {
                viewerHeader
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .panelHeaderBar()
            }

            GeometryReader { geo in
                let aspect = generatingAspect ?? CGFloat(editor.timeline.width) / CGFloat(editor.timeline.height)
                let fitSize = fitSize(in: geo.size, aspect: aspect)
                let scaledWidth = fitSize.width * editor.canvasZoom
                let scaledHeight = fitSize.height * editor.canvasZoom
                ZStack {
                    PreviewView()
                    if isImage {
                        imagePreview
                    }
                    if isDocument, let asset = activeMediaAsset {
                        ReadOnlyDocumentPreview(url: asset.url)
                    }
                    if let error = activeFailedError {
                        failedPreview(error: error)
                    }
                    if let asset = activeMediaAsset, asset.isGenerating {
                        generatingPreview(label: asset.generatingLabel)
                    }
                    if let overlay = offlineOverlay {
                        offlinePreview(assetId: overlay.assetId, path: overlay.path, isUnprocessable: overlay.isUnprocessable)
                    }
                    if editor.cropEditingActive {
                        CropOverlayView()
                    } else {
                        TransformOverlayView()
                    }
                }
                .frame(width: scaledWidth, height: scaledHeight)
                .overlay(
                    Rectangle()
                        .stroke(
                            AppTheme.Text.primaryColor.opacity(
                                editor.canvasZoom < 1.0
                                    ? AppTheme.Opacity.moderate
                                    : AppTheme.Opacity.transparent
                            ),
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .offset(x: editor.canvasOffset.width, y: editor.canvasOffset.height)
            }
            .clipped()
            if !editor.theaterActive {
                if isTimeline || supportsSourceTransport {
                    scrubBar
                    transportBar
                } else {
                    imageSettingsBar
                }
            }
        }
        .background(AppTheme.Background.surfaceColor)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        let duration = durationFrames
        let fps = editor.timeline.fps
        let durationTimecode = formatTimecode(frame: duration, fps: fps)

        return ViewThatFits(in: .horizontal) {
            transportRow(
                duration: duration,
                fps: fps,
                durationTimecode: durationTimecode,
                compact: false
            )
            .frame(height: AppTheme.ComponentSize.previewToolbarHeight)
            transportRow(
                duration: duration,
                fps: fps,
                durationTimecode: durationTimecode,
                compact: true
            )
            .frame(height: AppTheme.ComponentSize.previewToolbarHeight)
            narrowTransport(
                duration: duration,
                fps: fps,
                durationTimecode: durationTimecode
            )
            .frame(height: AppTheme.ComponentSize.previewCompactToolbarHeight)
        }
    }

    private func transportRow(
        duration: Int,
        fps: Int,
        durationTimecode: String,
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? AppTheme.Spacing.xs : AppTheme.Spacing.sm) {
            PreviewTimecodeText(
                isTimeline: isTimeline,
                fps: fps,
                durationTimecode: durationTimecode,
                showsDuration: !compact
            )

            Spacer()

            transportControls(duration: duration, compact: compact)

            Spacer()

            if isTimeline || editor.activePreviewTab.clipType == .video {
                captureFrameButton
            }
            settingsMenuButton(label: zoomBadgeLabel, help: "Canvas Zoom") { zoomMenuItems }
        }
        .padding(.horizontal, compact ? AppTheme.Spacing.sm : AppTheme.Spacing.lg)
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "preview.transportBar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func narrowTransport(
        duration: Int,
        fps: Int,
        durationTimecode: String
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                PreviewTimecodeText(
                    isTimeline: isTimeline,
                    fps: fps,
                    durationTimecode: durationTimecode,
                    showsDuration: false
                )
                Spacer(minLength: AppTheme.Spacing.xs)
                if isTimeline || editor.activePreviewTab.clipType == .video {
                    captureFrameButton
                }
                settingsMenuButton(label: zoomBadgeLabel, help: "Canvas Zoom") { zoomMenuItems }
            }
            transportControls(duration: duration, compact: false)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "preview.transportBar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func transportControls(duration: Int, compact: Bool) -> some View {
        HStack(spacing: compact ? AppTheme.Spacing.sm : AppTheme.Spacing.md) {
            transportButton("backward.end.fill", acceptanceIdentifier: "preview.seekStart") { seekTo(0) }
            if !compact {
                transportButton(
                    "backward.frame.fill",
                    acceptanceIdentifier: "preview.stepBackward"
                ) { seekTo(playheadFrame - 1) }
            }
            transportButton(
                editor.isPlaying ? "pause.fill" : "play.fill",
                acceptanceIdentifier: "preview.playPause"
            ) {
                if isTimeline {
                    editor.togglePlayback()
                } else {
                    editor.toggleSourcePlayback()
                }
            }
            if !compact {
                transportButton(
                    "forward.frame.fill",
                    acceptanceIdentifier: "preview.stepForward"
                ) { seekTo(playheadFrame + 1) }
            }
            transportButton("forward.end.fill", acceptanceIdentifier: "preview.seekEnd") { seekTo(duration) }
        }
    }

    // MARK: - Image settings bar

    private var imageSettingsBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer()
            settingsMenuButton(label: zoomBadgeLabel, help: "Canvas Zoom") { zoomMenuItems }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: AppTheme.ComponentSize.previewToolbarHeight)
    }

    // MARK: - Capture frame

    private var captureFrameButton: some View {
        Button(action: editor.captureCurrentFrameToMedia) {
            Image(systemName: "camera")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
                .help("Capture Frame to Media")
        }
        .buttonStyle(.plain)
        .tourAnchor(.screenshotButton)
    }

    // MARK: - Project settings

    @ViewBuilder
    private var zoomMenuItems: some View {
        ForEach(ZoomPreset.allCases, id: \.self) { preset in
            Button {
                editor.canvasOffset = .zero
                editor.canvasZoom = preset.value
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if isZoomPresetActive(preset) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private var zoomBadgeLabel: String {
        if isZoomPresetActive(.fit) {
            return "Fit"
        }
        let percent = Int(editor.canvasZoom * 100)
        return "\(percent)%"
    }

    private func isZoomPresetActive(_ preset: ZoomPreset) -> Bool {
        abs(editor.canvasZoom - preset.value) < 0.01
    }

    private func settingsMenuButton<MenuContent: View>(
        label: String,
        help: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        Menu {
            menu()
        } label: {
            badgeLabel(label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "preview.zoom")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .hoverHighlight()
        .help(help)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.bold, design: .rounded)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.IconSize.mdLg)
    }

    // MARK: - Image preview

    private var imagePreview: some View {
        Group {
            if let asset = activeMediaAsset, let image = asset.thumbnail ?? NSImage(contentsOf: asset.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.previewCanvasColor)
        .allowsHitTesting(false)
    }

    private func fitSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let widthFromHeight = container.height * aspect
        if widthFromHeight <= container.width {
            return CGSize(width: widthFromHeight, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / aspect)
    }

    private var activeMediaAsset: MediaAsset? {
        guard case .mediaAsset(let id, _, _) = editor.activePreviewTab else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }

    private var generatingAspect: CGFloat? {
        guard let asset = activeMediaAsset, asset.isGenerating else { return nil }
        let parts = (asset.generationInput?.aspectRatio ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGFloat(parts[0] / parts[1])
    }

    private var activeFailedError: String? {
        guard let asset = activeMediaAsset,
              case .failed(let error) = asset.generationStatus else { return nil }
        return error
    }

    private var activeMediaMissing: Bool {
        guard let asset = activeMediaAsset, case .none = asset.generationStatus else { return false }
        return editor.isMediaOffline(asset.id)
    }

    /// The offline clip blacking out the current timeline frame, or nil when an online clip covers it.
    private var timelineOfflineClip: Clip? {
        guard isTimeline else { return nil }
        guard !editor.offlineMediaRefs.isEmpty || !editor.unprocessableMediaRefs.isEmpty else { return nil }
        let frame = editor.playheadState.timelineFrame
        var offline: Clip?
        for track in editor.timeline.tracks where track.type != .audio && !track.hidden {
            for clip in track.clips where clip.mediaType != .text {
                guard clip.contains(timelineFrame: frame) else { continue }
                if editor.isMediaOffline(clip.mediaRef) {
                    offline = offline ?? clip
                } else {
                    return nil
                }
            }
        }
        return offline
    }

    private struct OfflineOverlay { let assetId: String?; let path: String?; let isUnprocessable: Bool }

    /// Resolved once per render so the timeline scan runs at most once.
    private var offlineOverlay: OfflineOverlay? {
        if activeMediaMissing, let id = activeMediaAsset?.id {
            return OfflineOverlay(assetId: id, path: activeMediaAsset?.url.path, isUnprocessable: editor.isMediaUnprocessable(id))
        }
        if let clip = timelineOfflineClip {
            return OfflineOverlay(
                assetId: clip.mediaRef,
                path: editor.mediaResolver.expectedURL(for: clip.mediaRef)?.path,
                isUnprocessable: editor.isMediaUnprocessable(clip.mediaRef)
            )
        }
        return nil
    }

    private func relinkFile(assetId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the source file for this clip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await editor.relinkAsset(id: assetId, to: url) }
        }
    }

    private func relinkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds your media"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let result = await editor.relinkOfflineAssets(fromFolder: url)
                if let failure = result.failure {
                    editor.mediaPanelToast = MediaPanelToast(message: failure)
                } else {
                    editor.mediaPanelToast = "Relinked \(result.relinked) of \(result.total) offline clips."
                }
            }
        }
    }

    private func generatingPreview(label: String) -> some View {
        ZStack {
            if let image = activeGeneratingReferenceImage {
                AppTheme.Background.clearColor
                    .overlay { Image(nsImage: image).resizable().scaledToFill().blur(radius: 24) }
                    .clipped()
            }
            AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.strong)
            GeneratingOverlay(label: label, size: .preview)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }

    private var activeGeneratingReferenceImage: NSImage? {
        guard let input = activeMediaAsset?.generationInput else { return nil }
        let refIds = (input.imageURLAssetIds ?? []) + (input.referenceImageAssetIds ?? [])
        for id in refIds {
            guard let ref = editor.mediaAssets.first(where: { $0.id == id }), ref.type == .image else { continue }
            if let image = ref.thumbnail ?? NSImage(contentsOf: ref.url) {
                return image
            }
        }
        return nil
    }

    private static func unprocessablePrefill(path: String?) -> String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "(unknown)"
        return """
        A clip's media couldn't be prepared for playback.

        File: \(file)

        What were you doing when this happened?
        """
    }

    private func offlinePreview(assetId: String?, path: String?, isUnprocessable: Bool) -> some View {
        ZStack {
            AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.strong)
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .interfaceFont(size: AppTheme.Typography.hero)
                    .foregroundStyle(AppTheme.Status.errorColor)
                Text(isUnprocessable ? "Couldn't Prepare Media" : "Media Offline")
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(isUnprocessable
                    ? "NexGenVideo loaded this clip's source file but couldn't prepare it for playback. The file may be corrupt or in an unsupported format."
                    : "NexGenVideo couldn't load this clip's source file. It may be missing, on an ejected drive, or unreadable.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.lg)
                if let path {
                    Text(path)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                }
                if isUnprocessable {
                    Button("Report a Problem") {
                        FeedbackWindowController.shared.show(prefill: Self.unprocessablePrefill(path: path))
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .padding(.top, AppTheme.Spacing.xs)
                } else {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if let assetId {
                            Button("Relink…") { relinkFile(assetId: assetId) }
                                .buttonStyle(.capsule(.prominent, size: .regular))
                        }
                        Button("Relink Folder…") { relinkFolder() }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                    }
                    .padding(.top, AppTheme.Spacing.xs)
                }
            }
            .padding(AppTheme.Spacing.xl)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedPreview(error: String) -> some View {
        ZStack {
            AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.strong)
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .interfaceFont(size: AppTheme.Typography.hero)
                    .foregroundStyle(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.prominent))
                Text("Generation Failed")
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                ScrollView {
                    Text(error)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                }
                .frame(maxWidth: AppTheme.ComponentSize.previewErrorMaxWidth, maxHeight: AppTheme.ComponentSize.previewErrorMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                if let asset = activeMediaAsset, asset.pendingDownloadURL != nil {
                    Button {
                        editor.generationService.retryDownload(asset: asset, editor: editor)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Download")
                        }
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                    }
                    .buttonStyle(.plain)
                    .background(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.soft), in: .capsule)
                    .overlay(
                        Capsule().strokeBorder(
                            AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.muted),
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                    )
                }
            }
            .padding(AppTheme.Spacing.xl)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Viewer context

    private var viewerHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(isTimeline ? "Film Preview" : "Media Preview")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize()
            Text(activeObjectName)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(isTimeline ? "Timeline Clip" : "Original Media")
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
        }
        .workspaceHeaderContent()
        .background {
            if WorkspaceUIAcceptance.isRequested {
                ZStack {
                    AppRelaunchClickProbe(
                        identifier: "preview.selectionContext",
                        acceptanceState: isTimeline && editor.activeTimelineInspectionClipID != nil
                    )
                    if let clipID = editor.activeTimelineInspectionClipID {
                        AppRelaunchClickProbe(
                            identifier: "preview.selectionContext.\(clipID)",
                            acceptanceState: isTimeline
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(isTimeline ? "Film Preview, Timeline Clip" : "Media Preview, Original Media"), \(activeObjectName)"
        )
    }

    private var activeObjectName: String {
        if let asset = activeMediaAsset { return asset.userFacingFilename }
        if let id = editor.activeTimelineInspectionClipID, let location = editor.findClip(id: id) {
            return editor.clipDisplayLabel(for: editor.timeline.tracks[location.trackIndex].clips[location.clipIndex])
        }
        if editor.isTimelineBatchSelection { return "\(editor.selectedClipIds.count) clips" }
        return "Timeline"
    }

    private var supportsSourceTransport: Bool {
        guard let type = editor.activePreviewTab.clipType else { return false }
        return type == .video || type == .audio || type == .lottie
    }

    // MARK: - Scrub bar

    @State private var isScrubbing = false
    @State private var isScrubHovered = false
    @State private var scrubWasPlaying = false

    private var scrubBar: some View {
        let duration = durationFrames

        return GeometryReader { geo in
            let active = isScrubbing || isScrubHovered
            let thumbSize: CGFloat = active ? 10 : 6
            let barHeight: CGFloat = active ? 4 : 3
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.soft))
                    .frame(height: barHeight)
                PreviewScrubProgress(
                    isTimeline: isTimeline,
                    durationFrames: duration,
                    geometry: .init(
                        size: geo.size,
                        barHeight: barHeight,
                        thumbSize: thumbSize
                    )
                )
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isScrubHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginScrubIfNeeded()
                        seekTo(
                            scrubFrame(
                                locationX: value.location.x,
                                width: geo.size.width,
                                durationFrames: duration
                            ),
                            mode: .interactiveScrub
                        )
                    }
                    .onEnded { value in
                        finishScrub(
                            at: scrubFrame(
                                locationX: value.location.x,
                                width: geo.size.width,
                                durationFrames: duration
                            )
                        )
                    }
            )
        }
        .frame(height: AppTheme.ComponentSize.previewScrubberHeight)
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "preview.scrub")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isScrubbing)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isScrubHovered)
        .onDisappear {
            if isScrubHovered {
                NSCursor.pop()
                isScrubHovered = false
            }
            if isScrubbing {
                finishScrub(at: playheadFrame)
            }
        }
    }

    // MARK: - Transport helpers

    private var playheadFrame: Int {
        isTimeline ? editor.playheadState.timelineFrame : editor.playheadState.sourceFrame
    }

    private var durationFrames: Int {
        editor.activePreviewDurationFrames
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        scrubWasPlaying = editor.isPlaying
        if scrubWasPlaying { editor.pause() }
        editor.isScrubbing = true
        isScrubbing = true
    }

    private func finishScrub(at frame: Int) {
        let shouldResume = scrubWasPlaying
        scrubWasPlaying = false
        isScrubbing = false
        editor.isScrubbing = false
        seekTo(frame, mode: .exact)
        if shouldResume { editor.resumePlayback() }
    }

    private func scrubFrame(locationX: CGFloat, width: CGFloat, durationFrames: Int) -> Int {
        guard width > 0 else { return 0 }
        let fraction = max(0, min(1, locationX / width))
        return Int(fraction * CGFloat(max(0, durationFrames)))
    }

    private func seekTo(_ frame: Int, mode: PreviewSeekMode = .exact) {
        if isTimeline {
            editor.seekToFrame(frame, mode: mode)
        } else {
            editor.seekSourceToFrame(frame, mode: mode)
        }
    }

    private func transportButton(
        _ systemName: String,
        acceptanceIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.ComponentSize.previewControlWidth, height: AppTheme.ComponentSize.previewControlHeight)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .background {
            if WorkspaceUIAcceptance.isRequested, let acceptanceIdentifier {
                AppRelaunchClickProbe(identifier: acceptanceIdentifier)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct ReadOnlyDocumentPreview: View {
    let url: URL
    @State private var text = ""
    @State private var error: String?
    @State private var isTruncated = false

    var body: some View {
        ScrollView {
            Group {
                if let error {
                    ContentUnavailableView(
                        "Couldn't Read Text",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(error)
                    )
                } else {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if isTruncated {
                            Label("Showing first 2 MB", systemImage: "doc.text.magnifyingglass")
                                .interfaceFont(size: AppTheme.Typography.metadata)
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .accessibilityIdentifier("preview.documentTruncated")
                        }
                        Text(text)
                            .interfaceFont(size: AppTheme.Typography.reading)
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.previewCanvasColor)
        .task(id: url) {
            let result = await Self.load(url)
            text = result.text
            error = result.error
            isTruncated = result.isTruncated
        }
        .accessibilityIdentifier("preview.readOnlyDocument")
    }

    nonisolated private static func load(
        _ url: URL
    ) async -> (text: String, error: String?, isTruncated: Bool) {
        await Task.detached(priority: .userInitiated) {
            do {
                let read = try BoundedTextFileReader.readUTF8Prefix(
                    from: url,
                    maximumBytes: 2_000_000
                )
                return (read.text, nil, read.isTruncated)
            } catch {
                return ("", error.localizedDescription, false)
            }
        }.value
    }
}

// MARK: - Settings Presets

private enum ZoomPreset: CaseIterable {
    case twentyFivePercent, fiftyPercent, seventyFivePercent, fit, oneTwentyFivePercent, oneFiftyPercent, twoHundredPercent

    var label: String {
        switch self {
        case .twentyFivePercent: "25%"
        case .fiftyPercent: "50%"
        case .seventyFivePercent: "75%"
        case .fit: "Fit"
        case .oneTwentyFivePercent: "125%"
        case .oneFiftyPercent: "150%"
        case .twoHundredPercent: "200%"
        }
    }

    var value: CGFloat {
        switch self {
        case .twentyFivePercent: 0.25
        case .fiftyPercent: 0.50
        case .seventyFivePercent: 0.75
        case .fit: 1.0
        case .oneTwentyFivePercent: 1.25
        case .oneFiftyPercent: 1.50
        case .twoHundredPercent: 2.0
        }
    }
}

// MARK: - Hot-path subviews

private struct PreviewTimecodeText: View {
    @Environment(EditorViewModel.self) var editor
    let isTimeline: Bool
    let fps: Int
    let durationTimecode: String
    let showsDuration: Bool

    var body: some View {
        let frame = isTimeline ? editor.playheadState.timelineFrame : editor.playheadState.sourceFrame
        HStack(spacing: AppTheme.Spacing.none) {
            Text(formatTimecode(frame: frame, fps: fps))
                .foregroundStyle(AppTheme.Accent.timecodeColor)
            if showsDuration {
                Text(" / ")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(durationTimecode)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .monospacedDigit()
        .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "preview.timecode")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PreviewScrubProgress: View {
    struct Geometry {
        let size: CGSize
        let barHeight: CGFloat
        let thumbSize: CGFloat
    }

    @Environment(EditorViewModel.self) var editor
    let isTimeline: Bool
    let durationFrames: Int
    let geometry: Geometry

    var body: some View {
        let frame = isTimeline ? editor.playheadState.timelineFrame : editor.playheadState.sourceFrame
        let duration = durationFrames
        let progress = duration > 0 ? CGFloat(frame) / CGFloat(duration) : 0
        let g = geometry
        ZStack(alignment: .leading) {
            Capsule()
                .fill(AppTheme.Accent.primary)
                .frame(width: max(0, g.size.width * progress), height: g.barHeight)
            Circle()
                .fill(AppTheme.Text.primaryColor)
                .frame(width: g.thumbSize, height: g.thumbSize)
                .shadow(AppTheme.Shadow.handle)
                .position(x: g.size.width * progress, y: g.size.height / 2)
        }
    }
}
